import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  archiveArgs,
  assertListing,
  checkListing,
  stopsBeforeBuild,
  exportArgs,
  landBumpCommit,
  recoverUploadedBump,
  uploadLandPoll,
  bumpBuildNumber,
  createFailures,
  marketingVersion,
  parseArgs,
  redact,
  reviewNotes,
  TERMS_LINE,
} from "./release-lib.mjs";

const yaml = readFileSync(new URL("../project.yml", import.meta.url), "utf8");

test("parseArgs accepts submit, products, and --dry-run", () => {
  assert.deepEqual(parseArgs(["--dry-run"]), { dryRun: true, submit: false, products: false, help: false });
  assert.deepEqual(parseArgs(["submit"]), { dryRun: false, submit: true, products: false, help: false });
  assert.deepEqual(parseArgs(["submit", "--dry-run"]), { dryRun: true, submit: true, products: false, help: false });
  assert.deepEqual(parseArgs(["products", "--dry-run"]), { dryRun: true, submit: false, products: true, help: false });
});

test("build number increments and the marketing version is readable", () => {
  const sample = `    MARKETING_VERSION: "1.0"\n    CURRENT_PROJECT_VERSION: "9"\n`;
  assert.equal(marketingVersion(sample), "1.0");
  const once = bumpBuildNumber(sample);
  assert.equal(once.from, "9");
  assert.equal(once.to, "10");
  assert.match(once.yaml, /CURRENT_PROJECT_VERSION: "10"/);
  assert.equal(marketingVersion(yaml), "1.0");
  assert.match(bumpBuildNumber(yaml).from, /^\d+$/);
});

test("listing files fit the App Store and end with the terms line", () => {
  const description = readFileSync(new URL("../appstore/metadata/description.txt", import.meta.url), "utf8").trim();
  const promotional = readFileSync(new URL("../appstore/metadata/promotional.txt", import.meta.url), "utf8").trim();
  const whatsNew = readFileSync(new URL("../appstore/metadata/whats-new.txt", import.meta.url), "utf8").trim();
  const keywords = readFileSync(new URL("../appstore/metadata/keywords.txt", import.meta.url), "utf8").trim();
  assertListing({ description, promotional, whatsNew, keywords });
  assert.equal(description.trimEnd().endsWith(TERMS_LINE), true);
});

test("TKL-439: the listing leads with the lifter hero, and the subtitle fits", () => {
  const description = readFileSync(new URL("../appstore/metadata/description.txt", import.meta.url), "utf8").trim();
  const promotional = readFileSync(new URL("../appstore/metadata/promotional.txt", import.meta.url), "utf8").trim();
  const { subtitle } = JSON.parse(readFileSync(new URL("../appstore/metadata/urls.json", import.meta.url), "utf8"));
  const hero = "A real program for your gym and your week, free. Log your sets, and next week moves up.";
  assert.equal(description.startsWith(hero), true);
  assert.equal(promotional, hero);
  assert.match(subtitle, /free/i);
  assert.doesNotThrow(() => assertListing({ description, promotional, subtitle }));
  assert.throws(() => assertListing({ description, subtitle: "x".repeat(31) }), /subtitle is 31 characters/);
  assert.doesNotMatch(description + promotional + subtitle, /TrueCoach|Everything you pay/);
});

test("TKL-442: Lifter Pro leads with the week designed around how last week went, at the same price", () => {
  const description = readFileSync(new URL("../appstore/metadata/description.txt", import.meta.url), "utf8").trim();
  const line = "A week designed around how last week went";
  const paragraphs = description.split(/\n\s*\n/);
  assert.equal(paragraphs[1].startsWith("Lifter Pro: a week designed around how last week went"), true, paragraphs[1]);
  const subs = JSON.parse(readFileSync(new URL("../appstore/subscriptions.json", import.meta.url), "utf8"));
  const lifter = subs.groups.find((g) => g.displayName === "Lifter Pro").products;
  assert.deepEqual(lifter.map((p) => p.priceUSD), ["5.99", "39.99"]);
  for (const p of lifter) {
    assert.equal(p.localization.description, line);
    assert.ok(p.localization.description.length <= 55);
  }
  const storekit = readFileSync(new URL("../AICoach.storekit", import.meta.url), "utf8");
  assert.doesNotMatch(storekit, /AI-designed training weeks/);
  assert.equal(storekit.split(`"description": "${line}"`).length - 1, 2);
});

test("review notes are filled from the caller and keep no placeholder", () => {
  const template = readFileSync(new URL("../appstore/metadata/review-notes.txt", import.meta.url), "utf8");
  const notes = reviewNotes(template, {
    VIDEO_URL: "https://barbrabell.com/review/demo.mp4",
    CLIENT_EMAIL: "client@example.com",
    CLIENT_PASSWORD: "secret-value",
    COACH_EMAIL: "coach@example.com",
    INVITE_CODES: "ABC234 (12d)",
  });
  assert.equal(notes.includes("{{"), false);
  assert.match(notes, /client@example.com/);
  assert.match(notes, /ABC234/);
});

test("redact removes a secret without touching the rest of the line", () => {
  assert.equal(redact("Password: secret-value\nok", ["secret-value"]), "Password: ••••\nok");
});

test("review notes tell Apple how to reach each paywall and include the reply", () => {
  const template = readFileSync(new URL("../appstore/metadata/review-notes.txt", import.meta.url), "utf8");
  assert.match(template, /Lifter Pro/);
  assert.match(template, /Coach Pro/);
  assert.match(template, /Terms of Use link to the description and the paywall/);
  assert.equal(template.includes("sells nothing"), false);
});

test("the committed demo secrets file has no password", () => {
  const source = readFileSync(new URL("../Tests/UITests/Secrets.swift", import.meta.url), "utf8");
  assert.match(source, /environment\["DEMO_PASSWORD"\]/);
  assert.equal(source.includes("base64"), false);
});

test("archive and export sign with the Xcode account, not the API key (TKL-760)", () => {
  for (const args of [archiveArgs(), exportArgs()]) {
    assert.ok(args.includes("-allowProvisioningUpdates"));
    assert.equal(args.filter((arg) => arg.startsWith("-authenticationKey")).length, 0);
  }
  assert.equal(archiveArgs()[0], "archive");
  assert.equal(exportArgs()[0], "-exportArchive");
  assert.ok(exportArgs().includes("build/ExportOptions.plist"));
});

// TKL-774: a run that uploaded a build but never landed its bump left main one build behind,
// and the next release failed at upload. The bump now lands through a PR right after the upload.
function fakeGit(results = {}) {
  const calls = [];
  const exec = (command, args) => {
    calls.push([command, ...args].join(" "));
    const key = Object.keys(results).find((prefix) => calls.at(-1).startsWith(prefix));
    return key ? results[key] : { code: 0, stdout: "", stderr: "" };
  };
  return { calls, exec };
}

test("landBumpCommit pushes a branch, squash-merges its PR, and moves HEAD to the merged main", () => {
  const { calls, exec } = fakeGit();
  const result = landBumpCommit("20", exec);
  assert.equal(result.landed, true);
  assert.deepEqual(calls, [
    "git push origin HEAD:refs/heads/release/build-20",
    "gh pr create --base main --head release/build-20 --title Build 20: project.yml matches the upload --body npm run release uploaded build 20 to App Store Connect. This lands its CURRENT_PROJECT_VERSION bump so the next release starts from 20.",
    "gh pr merge release/build-20 --squash --delete-branch",
    "git fetch --quiet origin main",
    "git diff --quiet HEAD origin/main",
    "git reset --keep origin/main",
  ]);
});

test("landBumpCommit leaves HEAD alone when the merged main differs from it", () => {
  const { calls, exec } = fakeGit({ "git diff --quiet": { code: 1, stdout: "", stderr: "" } });
  const result = landBumpCommit("20", exec);
  assert.equal(result.landed, true);
  assert.ok(!calls.some((call) => call.startsWith("git reset")));
});

test("landBumpCommit stops at the first failed step and says how to land it by hand", () => {
  const { calls, exec } = fakeGit({ "gh pr merge": { code: 1, stdout: "", stderr: "checks pending" } });
  const result = landBumpCommit("20", exec);
  assert.equal(result.landed, false);
  assert.equal(calls.length, 3);
  assert.match(result.message, /checks pending/);
  assert.match(result.message, /gh pr merge release\/build-20 --squash --delete-branch/);
  assert.match(result.message, /build 20 is uploaded/i);
});

function sequence({ uploadError, pollError, landed = true } = {}) {
  const steps = [];
  return {
    steps,
    upload: async () => { steps.push("upload"); if (uploadError) throw new Error(uploadError); },
    land: () => { steps.push("land"); return { landed, message: landed ? "landed" : "not landed" }; },
    poll: async () => { steps.push("poll"); if (pollError) throw new Error(pollError); return "build-id"; },
  };
}

test("uploadLandPoll lands the bump right after the upload, before processing is polled", async () => {
  const s = sequence();
  const result = await uploadLandPoll(s);
  assert.deepEqual(s.steps, ["upload", "land", "poll"]);
  assert.deepEqual(result, { buildId: "build-id", landing: { landed: true, message: "landed" }, error: undefined });
});

test("uploadLandPoll awaits the checkpoint after upload and before polling", async () => {
  const s = sequence();
  s.checkpoint = async () => {
    await Promise.resolve();
    s.steps.push("checkpoint");
  };
  await uploadLandPoll(s);
  assert.deepEqual(s.steps, ["upload", "checkpoint", "land", "poll"]);
});

test("uploadLandPoll skips the checkpoint on upload failure and skips polling on checkpoint failure", async () => {
  const failedUpload = sequence({ uploadError: "upload failed" });
  failedUpload.checkpoint = async () => assert.fail("no build was uploaded");
  await uploadLandPoll(failedUpload);
  assert.deepEqual(failedUpload.steps, ["upload"]);

  const s = sequence();
  s.checkpoint = async () => { throw new Error("Linear unavailable"); };
  const result = await uploadLandPoll(s);
  assert.deepEqual(s.steps, ["upload", "land"]);
  assert.equal(result.landing.landed, true);
  assert.match(result.error, /Linear unavailable/);
});

test("uploadLandPoll still lands the bump when processing fails or times out (TKL-774 verify)", async () => {
  const s = sequence({ pollError: "Build 20 was not VALID after 40 minutes." });
  const result = await uploadLandPoll(s);
  assert.deepEqual(s.steps, ["upload", "land", "poll"]);
  assert.equal(result.landing.landed, true);
  assert.equal(result.buildId, undefined);
  assert.match(result.error, /not VALID after 40 minutes/);
});

test("uploadLandPoll neither lands nor polls when the upload fails", async () => {
  const s = sequence({ uploadError: "xcodebuild -exportArchive failed." });
  const result = await uploadLandPoll(s);
  assert.deepEqual(s.steps, ["upload"]);
  assert.equal(result.landing, undefined);
  assert.match(result.error, /exportArchive failed/);
});

test("uploadLandPoll still polls when landing fails, and reports the landing", async () => {
  const s = sequence({ landed: false });
  const result = await uploadLandPoll(s);
  assert.deepEqual(s.steps, ["upload", "land", "poll"]);
  assert.equal(result.landing.landed, false);
  assert.equal(result.buildId, "build-id");
});

test("uploadLandPoll counts a throwing land step as not landed and keeps going", async () => {
  const s = sequence();
  s.land = () => { s.steps.push("land"); throw new Error("spawn gh ENOENT"); };
  const result = await uploadLandPoll(s);
  assert.deepEqual(s.steps, ["upload", "land", "poll"]);
  assert.equal(result.landing.landed, false);
  assert.match(result.landing.message, /ENOENT/);
});

test("release uses uploadLandPoll on a real run, so the bump lands before polling", () => {
  const source = readFileSync(new URL("./release.mjs", import.meta.url), "utf8");
  const call = source.indexOf("await uploadLandPoll(");
  assert.ok(call > 0, "release.mjs calls uploadLandPoll");
  assert.ok(!/await archiveAndUpload\(buildNumber\);\s*store\.uploadedBuildId = await pollBuild/.test(source), "no poll straight after upload");
  const realRun = source.lastIndexOf("if (!dryRun && !failures.blocksUpload()) {", call);
  assert.ok(realRun > 0 && source.indexOf("} else {", realRun) > call, "inside the real-run upload block");
});

test("TKL-450: the listing names the ready programs lifters search for, and the keywords carry them", () => {
  const description = readFileSync(new URL("../appstore/metadata/description.txt", import.meta.url), "utf8");
  const keywords = readFileSync(new URL("../appstore/metadata/keywords.txt", import.meta.url), "utf8").trim().split(",");
  const programs = JSON.parse(readFileSync(new URL("../Resources/Seed/programs.json", import.meta.url), "utf8"));
  // The search terms each program answers: descriptive only, no trademarked program names (Maxwell, 2026-11-17).
  const searched = { "push-pull-legs": ["ppl", "push", "pull", "legs"], "upper-lower-4": ["upper", "lower"], "tiered-linear": ["linear", "progression"] };
  const named = programs.filter((p) => description.includes(p.name) && searched[p.slug]);
  assert.ok(named.length >= 2, `named in the description: ${named.map((p) => p.name)}`);
  for (const p of named) for (const term of searched[p.slug]) assert.ok(keywords.includes(term), `${p.slug}: keyword ${term}`);
  assert.doesNotMatch(description + keywords.join(","), /5\/3\/1|531|GZCL|nSuns|Starting Strength|StrongLifts|PHUL|PHAT/i);
});

// TKL-795: a 409 on a subscription in review stopped the run before the bump and upload.
test("subscription and listing failures are reported but never block the bump and upload", () => {
  const f = createFailures();
  f.add("App Store Connect: 409 UNMODIFIABLE", { blocksUpload: false });
  f.add("Listing: refused", { blocksUpload: false });
  assert.equal(f.all.length, 2);
  assert.equal(f.blocksUpload(), false);
  f.add("Preflight: the working tree is not clean.");
  assert.equal(f.blocksUpload(), true);
  assert.equal(f.all.length, 3);
});

test("release plans subscriptions before the upload but writes them only after it (TKL-795)", () => {
  const source = readFileSync(new URL("./release.mjs", import.meta.url), "utf8");
  const upload = source.indexOf("await uploadLandPoll(");
  const prepareBody = source.slice(source.indexOf("async function prepareSubscriptions("), source.indexOf("async function applyStoreSubscriptions("));
  assert.ok(prepareBody.length > 0);
  assert.doesNotMatch(prepareBody, /applySubscriptionPlan/, "prepareSubscriptions no longer writes before the bump");
  const realApply = source.indexOf("await applyStoreSubscriptions(");
  assert.ok(realApply > upload, "subscriptions are written after the upload");
  const bump = source.indexOf("const bumped = bumpBuildNumber(");
  const gate = source.lastIndexOf("if (", bump);
  assert.match(source.slice(gate, bump), /!failures\.blocksUpload\(\)/, "the bump is gated only on upload blockers");
  const uploadGate = source.lastIndexOf("if (", upload);
  assert.match(source.slice(uploadGate, upload), /!failures\.blocksUpload\(\)/, "the upload is gated only on upload blockers");
  const prepare = source.slice(source.indexOf("subscriptionPlan = await prepareSubscriptions("), source.indexOf("const bumped = bumpBuildNumber("));
  assert.match(prepare, /blocksUpload: false/, "a subscription read or plan failure does not block the upload");
});

test("a dry run with no upload blockers says which build it would bump to (TKL-795)", () => {
  const source = readFileSync(new URL("./release.mjs", import.meta.url), "utf8");
  assert.match(source, /else if \(dryRun && !failures\.blocksUpload\(\)\) \{\n\s+console\.log\(`\\nWould bump build \$\{buildNumber\} → \$\{bumpBuildNumber\(yaml\)\.to\}/);
});

// [verify] round 1: an over-limit listing went through fail() with the blocking default and exited before the bump.
test("a listing that breaks the App Store limits is reported but does not stop the build (TKL-795)", () => {
  const failures = createFailures();
  const listing = { description: `${"x".repeat(4001)}\n${TERMS_LINE}`, promotional: "", whatsNew: "", keywords: "" };
  const messages = [];
  assert.equal(checkListing(listing, (message, options) => { messages.push(message); failures.add(message, options); }), false);
  assert.match(messages[0], /^Preflight: description is \d+ characters/);
  assert.equal(failures.length, 1);
  assert.equal(failures.blocksUpload(), false);
  assert.equal(stopsBeforeBuild(failures, false), false, "a real run goes on to the build, bump and upload");
  failures.add("Preflight: the working tree is not clean.");
  assert.equal(stopsBeforeBuild(failures, false), true, "a dirty tree still stops a real run");
  assert.equal(stopsBeforeBuild(failures, true), false, "a dry run never exits early");
});

test("checkListing passes the shipped listing", () => {
  const read = (name) => readFileSync(new URL(`../appstore/metadata/${name}`, import.meta.url), "utf8").trim();
  const listing = { description: read("description.txt"), promotional: read("promotional.txt"), whatsNew: read("whats-new.txt"), keywords: read("keywords.txt") };
  assert.equal(checkListing(listing, () => assert.fail("the shipped listing fails its own check")), true);
});

test("release.mjs checks the listing with checkListing and exits early only on upload blockers (TKL-795)", () => {
  const source = readFileSync(new URL("./release.mjs", import.meta.url), "utf8");
  assert.match(source, /checkListing\(listing, fail\)/);
  assert.doesNotMatch(source, /assertListing\(/, "no direct assertListing call that would block the upload");
  assert.doesNotMatch(source, /failures\.length && !dryRun\) process\.exit/, "no early exit on non-blocking failures");
  const exits = source.match(/if \(stopsBeforeBuild\(failures, dryRun\)\) process\.exit\(1\);/g) || [];
  assert.equal(exits.length, 2, "both preflight exits use stopsBeforeBuild");
});

test("resume after a saved upload checkpoint lands the archived bump without using HEAD", () => {
  const sha = "a".repeat(40);
  const release = spawnSync(process.execPath, ["--input-type=module", "-e", `
    import { writeSync } from "node:fs";
    import { uploadLandPoll } from ${JSON.stringify(new URL("./release-lib.mjs", import.meta.url).href)};
    await uploadLandPoll({
      upload: async () => {},
      checkpoint: () => { writeSync(1, "20 ${sha}"); process.exit(75); },
      land: () => { throw new Error("unexpected landing"); },
      poll: () => { throw new Error("unexpected poll"); },
    });
  `], { encoding: "utf8" });
  assert.equal(release.status, 75);
  const [build, archivedSha] = release.stdout.split(" ");
  assert.deepEqual([build, archivedSha], ["20", sha]);
  const calls = [];
  let current = 19;
  let openPR = false;
  const exec = (command, args) => {
    calls.push([command, ...args]);
    if (args[0] === "show") {
      let version = 20;
      if (args[1].startsWith("origin/main:")) version = current;
      if (args[1].includes("^:")) version = 19;
      return { code: 0, stdout: `    CURRENT_PROJECT_VERSION: "${version}"` };
    }
    if (args[0] === "diff-tree") return { code: 0, stdout: "project.yml\n" };
    if (args[1] === "list") return { code: 0, stdout: openPR ? "42\n" : "" };
    if (args[1] === "create") openPR = true;
    if (args[1] === "merge") { current = 20; openPR = false; }
    return { code: 0, stdout: "" };
  };
  recoverUploadedBump(build, archivedSha, exec);
  assert.ok(calls.some((call) => call.join(" ") === `git push origin ${sha}:refs/heads/release/build-20`));
  assert.equal(current, 20);
  const writes = () => calls.filter((call) => ["push", "reset"].includes(call[1]) || (call[0] === "gh" && ["create", "merge"].includes(call[2])));
  assert.equal(writes().length, 3);
  recoverUploadedBump(build, archivedSha, exec);
  assert.equal(writes().length, 3, "a retry after merge performs no writes");

  current = 19;
  openPR = true;
  recoverUploadedBump(build, archivedSha, exec);
  assert.equal(writes().length, 5, "a retry with an open PR skips creation");
  assert.equal(current, 20);
});
