// FIT-431: one command from main to an App Store Connect version ready for review.
// `npm run release` stops before submitting. `npm run release -- submit` sends it.
// `--dry-run` does the local checks and the read-only App Store Connect calls, and does not upload,
// change the listing, refresh the prod review account, deploy the video, or submit.
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Asc, loadAscEnv } from "./asc.mjs";
import { loadEnv } from "./load-env.mjs";
import {
  EDITABLE_VERSION_STATES,
  assertListing,
  bumpBuildNumber,
  marketingVersion,
  parseArgs,
  redact,
  reviewNotes,
  subscriptionWarning,
  videoHostingNote,
} from "./release-lib.mjs";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
process.chdir(root);
loadEnv();

const { dryRun, submit, help } = parseArgs(process.argv.slice(2));
if (help) {
  console.log("npm run release [--dry-run] [submit]\n\nStops with a version ready for review. submit sends it to App Review.\n--dry-run changes nothing in App Store Connect, prod, or git.");
  process.exit(0);
}

const review = JSON.parse(readFileSync("appstore/review.json", "utf8"));
const urls = JSON.parse(readFileSync("appstore/metadata/urls.json", "utf8"));
const listing = {
  description: readFileSync("appstore/metadata/description.txt", "utf8").trim(),
  promotional: readFileSync("appstore/metadata/promotional.txt", "utf8").trim(),
  whatsNew: readFileSync("appstore/metadata/whats-new.txt", "utf8").trim(),
  keywords: readFileSync("appstore/metadata/keywords.txt", "utf8").trim(),
};
const hidden = [process.env.DEMO_PASSWORD, process.env.ASC_CONTACT_PHONE].filter(Boolean);

const failures = [];
function fail(message) {
  const text = redact(message, hidden);
  failures.push(text);
  console.error(text);
  if (!dryRun) process.exitCode = 1;
}

function scrub(text) {
  return redact(String(text), hidden).replace(/^Password: .+$/gm, "Password: (not printed)");
}

function run(command, args, { cwd = root, env = process.env } = {}) {
  console.log(`\n$ ${scrub([command, ...args].join(" "))}`);
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const take = (pending, chunk, write) => {
      const text = pending + chunk;
      const end = text.lastIndexOf("\n");
      if (end < 0) return text;
      write(scrub(text.slice(0, end + 1)));
      return text.slice(end + 1);
    };
    child.stdout.on("data", (chunk) => { out = take(out, String(chunk), (line) => process.stdout.write(line)); });
    child.stderr.on("data", (chunk) => { err = take(err, String(chunk), (line) => process.stderr.write(line)); });
    child.on("error", reject);
    child.on("close", (code) => {
      if (out) process.stdout.write(scrub(out));
      if (err) process.stderr.write(scrub(err));
      resolvePromise(code ?? 1);
    });
  });
}

function capture(command, args, { cwd = root, env = process.env } = {}) {
  const result = spawnSync(command, args, { cwd, env, encoding: "utf8" });
  return { code: result.status ?? 1, stdout: result.stdout || "", stderr: result.stderr || "" };
}

function git(args) {
  return capture("git", args).stdout.trim();
}

const branch = git(["rev-parse", "--abbrev-ref", "HEAD"]);
const dirty = git(["status", "--porcelain"]);
const head = git(["log", "-1", "--oneline"]);
console.log(dryRun ? "Dry run. Nothing will be uploaded, changed in App Store Connect, or submitted." : "Release.");
console.log(`${branch} @ ${head}`);
if (branch !== "main") fail(`Preflight: branch is ${branch}, not main.`);
else console.log("Preflight: on main.");
if (dirty) fail("Preflight: the working tree is not clean.");
else console.log("Preflight: clean tree.");

try {
  assertListing(listing);
  console.log("Preflight: listing files fit the App Store limits, and the description ends with the Terms of Use line.");
} catch (error) {
  fail(`Preflight: ${error.message}`);
}

const yaml = readFileSync("project.yml", "utf8");
const marketing = marketingVersion(yaml);
let buildNumber = bumpBuildNumber(yaml).from;

if (await run("xcodegen", ["generate"]) !== 0) fail("Preflight: xcodegen failed.");
if (failures.length && !dryRun) process.exit(1);

console.log("\nPreflight: build and unit tests.");
if (await run("xcodebuild", ["-scheme", "AICoach", "-destination", "platform=iOS Simulator,name=iPhone 17 Pro", "-quiet", "test"]) !== 0) {
  fail("Preflight: build or unit tests failed.");
}
if (failures.length && !dryRun) process.exit(1);

let asc;
let store;
try {
  asc = new Asc(loadAscEnv(), { dryRun });
  store = await readStore(asc, review.bundleId);
} catch (error) {
  fail(`App Store Connect: ${error.message}`);
}
if (store) reportStore(store);

const warning = store ? subscriptionWarning(store.subscriptions, store.reviewItems) : { warn: false, lines: [] };
if (warning.warn) {
  console.log(`\n${warning.lines.join("\n")}`);
  failures.push(warning.lines[0]);
} else if (store) {
  const names = store.subscriptions.map((sub) => `${sub.name} ${sub.state}`).join(", ");
  console.log(names
    ? `\nSubscriptions on the app record, none in a state that submits with this version: ${names}.\nFIT-386: confirm Version ${marketing}'s In-App Purchases and Subscriptions section is empty. A first subscription added only on that page is not always visible to the API.`
    : "\nNo subscriptions returned for this app.");
}

if (!dryRun && !failures.length) {
  const bumped = bumpBuildNumber(readFileSync("project.yml", "utf8"));
  writeFileSync("project.yml", bumped.yaml);
  buildNumber = bumped.to;
  const added = capture("git", ["add", "project.yml"]);
  if (added.code !== 0) fail("Could not stage project.yml.");
  const committed = capture("git", ["commit", "-m", `FIT-431: build ${bumped.to}`, "-m", "Co-Authored-By: Claude <noreply@anthropic.com>"]);
  if (committed.code !== 0) fail(`Could not commit the build number.\n${scrub(committed.stderr)}`);
  else console.log(`Committed build ${bumped.from} → ${bumped.to}.`);
} else {
  console.log(`\nBuild number stays ${buildNumber}${dryRun ? " (dry run does not bump or commit)." : "."}`);
}

if (!dryRun && !failures.length) {
  try {
    await archiveAndUpload(buildNumber);
    store.uploadedBuildId = await pollBuild(asc, store.app.id, buildNumber);
  } catch (error) {
    fail(error.message);
  }
} else {
  console.log("\nWould archive and upload with xcodebuild (API key read at runtime, not printed):");
  console.log("  xcodebuild archive -scheme AICoach -configuration Release -destination generic/platform=iOS -archivePath build/AICoach.xcarchive -allowProvisioningUpdates -authenticationKeyPath <set> -authenticationKeyID <set> -authenticationKeyIssuerID <set>");
  console.log("  xcodebuild -exportArchive -archivePath build/AICoach.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates -authenticationKeyPath <set> -authenticationKeyID <set> -authenticationKeyIssuerID <set>");
  console.log(`  then poll builds until build ${buildNumber} (or the next one, on a real run) is VALID.`);
}

let inviteLine = "(none — not read)";
const inviteArgs = ["run", "review-invites", "--", "prod", review.reviewCoachUid];
if (!dryRun && !failures.length) inviteArgs.push("--mint", String(review.inviteCount));
const invites = capture("npm", inviteArgs, {
  cwd: resolve(root, "infra"),
  env: { ...process.env, AWS_PROFILE: process.env.AWS_PROFILE || "aicoach-dev" },
});
if (invites.code !== 0) {
  fail(`Invite codes: ${scrub(invites.stderr || invites.stdout).split("\n")[0]}`);
  inviteLine = "(none — the list failed)";
} else {
  const codes = invites.stdout.trim().split("\n").filter((line) => /^\S+ \(\d+d\)$/.test(line));
  inviteLine = codes.length ? codes.join(", ") : "(none)";
  console.log(`Invite codes with more than 2 days left: ${codes.length}${dryRun ? " (not minted)." : " (minted up to the configured count)."}`);
}

let recreatedPassword;
if (!dryRun && !failures.length) {
  console.log("\nRefreshing the prod review account.");
  const refreshed = capture("npm", ["run", "review-account", "--", "prod", review.reviewCoachUid, "--coach", "--athlete"], {
    cwd: resolve(root, "infra"),
    env: { ...process.env, AWS_PROFILE: process.env.AWS_PROFILE || "aicoach-dev" },
  });
  process.stdout.write(scrub(refreshed.stdout));
  process.stderr.write(scrub(refreshed.stderr));
  if (refreshed.code !== 0) fail("review-account failed.");
  recreatedPassword = refreshed.stdout.match(/^Password: (\S+)/m)?.[1];
  if (recreatedPassword) hidden.push(recreatedPassword);
} else {
  console.log(`\nWould run: AWS_PROFILE=aicoach-dev npm run review-account -- prod ${review.reviewCoachUid} --coach --athlete`);
  console.log("Dry run does not refresh the prod review account.");
}

const clientEmail = process.env.DEMO_CLIENT_EMAIL || "";
const coachEmail = process.env.DEMO_COACH_EMAIL || "";
if (!clientEmail || !coachEmail || !process.env.DEMO_PASSWORD) fail("DEMO_CLIENT_EMAIL, DEMO_COACH_EMAIL and DEMO_PASSWORD must be set.");
let notes = "";
try {
  const extra = recreatedPassword
    ? `\n\nThe shared review account was recreated this run: ${review.reviewAccountEmail} / ${recreatedPassword}`
    : "";
  notes = reviewNotes(readFileSync("appstore/metadata/review-notes.txt", "utf8"), {
    VIDEO_URL: review.videoUrl,
    CLIENT_EMAIL: clientEmail,
    CLIENT_PASSWORD: process.env.DEMO_PASSWORD || "",
    COACH_EMAIL: coachEmail,
    INVITE_CODES: inviteLine,
  }) + extra;
  console.log(`Review notes are ${notes.length} characters. The demo password is not printed.`);
} catch (error) {
  fail(error.message);
}

console.log("\nDemo video.");
const secretsStub = readFileSync("Tests/UITests/Secrets.swift", "utf8");
const video = await run("node", ["scripts/demo-video.mjs"]);
writeFileSync("Tests/UITests/Secrets.swift", secretsStub);
if (video !== 0) fail("The review demo UI test failed. build/review/demo.mp4 is still produced when the recording finished.");
console.log(videoHostingNote());

if (store && asc && notes) {
  try {
    await syncListing({
      asc, dryRun: dryRun || failures.length > 0, store, marketing, listing, urls, notes,
      buildId: store.uploadedBuildId, phone: process.env.ASC_CONTACT_PHONE,
    });
  } catch (error) {
    fail(`Listing: ${error.message}`);
  }
}

if (submit) {
  if (dryRun || failures.length) console.log("\nWould create the review submission and set it submitted. Not sent.");
  else {
    try {
      await sendToReview(asc, store);
      console.log("Submitted for review.");
    } catch (error) {
      fail(`Submit: ${error.message}`);
    }
  }
} else {
  console.log("\nStopped before submission. Screenshots were not changed.");
  console.log("When the listing looks right: npm run release -- submit");
}

console.log("\n---");
console.log(dryRun ? "Dry run complete." : "Release command finished.");
if (failures.length) {
  console.log("Needs attention:");
  for (const item of failures) console.log(`- ${item}`);
  process.exitCode = 1;
}

async function readStore(client, bundleId) {
  const apps = await client.get(`/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&limit=1`);
  const app = apps.data?.[0];
  if (!app) throw new Error(`No App Store Connect app for ${bundleId}.`);
  const versions = (await client.get(`/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS&limit=20`)).data || [];
  const subscriptions = [];
  try {
    const groups = await client.get(`/v1/apps/${app.id}/subscriptionGroups?include=subscriptions&limit=20`);
    for (const item of groups.included || []) {
      if (item.type !== "subscriptions") continue;
      subscriptions.push({
        id: item.id,
        name: item.attributes?.name || item.id,
        productId: item.attributes?.productId || "",
        state: item.attributes?.state || "UNKNOWN",
        onVersion: false,
      });
    }
  } catch (error) {
    console.log(`Could not list subscriptions: ${error.message}`);
  }
  const reviewItems = [];
  const submissions = [];
  try {
    const listed = await client.get(`/v1/reviewSubmissions?filter[app]=${app.id}&limit=10`);
    for (const item of listed.data || []) submissions.push({ id: item.id, state: item.attributes?.state });
    for (const submission of submissions) {
      const items = await client.get(`/v1/reviewSubmissions/${submission.id}/items?include=appStoreVersion,subscriptionVersion`);
      for (const item of items.data || []) {
        if (item.type !== "reviewSubmissionItems") continue;
        reviewItems.push({ id: item.id, kind: itemKind(item.relationships || {}), state: item.attributes?.state });
      }
    }
  } catch (error) {
    console.log(`Could not list review submissions: ${error.message}`);
  }
  for (const version of versions) {
    await markVersionSubscriptions(client, version.id, subscriptions);
  }
  let builds = [];
  try {
    builds = (await client.get(`/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=8`)).data || [];
  } catch (error) {
    console.log(`Could not list builds: ${error.message}`);
  }
  return { app, versions, subscriptions, reviewItems, submissions, builds };
}

function itemKind(relationships) {
  if (relationships.subscriptionVersion?.data || relationships.subscription?.data) return "subscription";
  if (relationships.inAppPurchaseVersion?.data || relationships.inAppPurchaseV2?.data) return "inAppPurchase";
  if (relationships.appStoreVersion?.data) return "appStoreVersion";
  return "other";
}

async function markVersionSubscriptions(client, versionId, subscriptions) {
  const full = await client.get(`/v1/appStoreVersions/${versionId}`);
  for (const [key, value] of Object.entries(full.data?.relationships || {})) {
    if (!/purchase|subscription/i.test(key)) continue;
    const link = value.links?.related || value.links?.self;
    if (!link) continue;
    try {
      const related = await client.get(link.replace("https://api.appstoreconnect.apple.com", ""));
      for (const row of [].concat(related.data || [])) {
        const match = subscriptions.find((sub) => sub.id === row.id);
        if (match) match.onVersion = true;
        else subscriptions.push({
          id: row.id,
          name: row.attributes?.name || key,
          productId: row.attributes?.productId || "",
          state: row.attributes?.state || "ON_VERSION",
          onVersion: true,
        });
      }
    } catch {
      // The relationship is listed but this key has no readable collection.
    }
  }
}

function reportStore(found) {
  console.log(`\nApp: ${found.app.attributes?.name || "(no name)"} ${found.app.attributes?.bundleId} (${found.app.id})`);
  if (!found.versions.length) console.log("No iOS version records.");
  for (const version of found.versions) {
    console.log(`Version ${version.attributes.versionString}: ${version.attributes.appStoreState}`);
  }
  if (!found.builds.length) console.log("No builds listed.");
  for (const build of found.builds.slice(0, 5)) {
    console.log(`Build ${build.attributes.version}: ${build.attributes.processingState} uploaded ${build.attributes.uploadedDate}`);
  }
  for (const submission of found.submissions) console.log(`Review submission ${submission.id}: ${submission.state}`);
  for (const item of found.reviewItems) console.log(`Review item ${item.kind}${item.state ? ` (${item.state})` : ""}`);
}

async function archiveAndUpload(number) {
  mkdirSync("build", { recursive: true });
  writeFileSync("build/ExportOptions.plist", exportPlist(review.teamId));
  const auth = ["-allowProvisioningUpdates", "-authenticationKeyPath", process.env.ASC_KEY_PATH, "-authenticationKeyID", process.env.ASC_KEY_ID, "-authenticationKeyIssuerID", process.env.ASC_ISSUER_ID];
  console.log(`\nArchiving build ${number}.`);
  if (await run("xcodebuild", ["archive", "-scheme", "AICoach", "-configuration", "Release", "-destination", "generic/platform=iOS", "-archivePath", "build/AICoach.xcarchive", ...auth]) !== 0) {
    throw new Error("xcodebuild archive failed.");
  }
  console.log("Uploading the archive.");
  if (await run("xcodebuild", ["-exportArchive", "-archivePath", "build/AICoach.xcarchive", "-exportPath", "build/export", "-exportOptionsPlist", "build/ExportOptions.plist", ...auth]) !== 0) {
    throw new Error("xcodebuild -exportArchive failed.");
  }
}

function exportPlist(teamId) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${teamId}</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
`;
}

async function pollBuild(client, appId, number) {
  const deadline = Date.now() + 40 * 60 * 1000;
  while (Date.now() < deadline) {
    const found = await client.get(`/v1/builds?filter[app]=${appId}&filter[version]=${encodeURIComponent(number)}&limit=5`);
    const build = found.data?.[0];
    if (!build) console.log(`Build ${number} is not listed yet.`);
    else {
      const state = build.attributes.processingState;
      console.log(`Build ${number}: ${state}`);
      if (state === "VALID") return build.id;
      if (state === "FAILED" || state === "INVALID") throw new Error(`Build ${number} is ${state}.`);
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 20_000));
  }
  throw new Error(`Build ${number} was still processing after 40 minutes.`);
}

async function syncListing({ asc: client, dryRun: preview, store: found, marketing: versionString, listing: copy, urls: links, notes: reviewText, buildId, phone }) {
  let version = found.versions.find((item) => item.attributes.versionString === versionString);
  console.log("\nScreenshots are left as they are.");
  if (!version) {
    console.log(preview ? `Would create iOS ${versionString}.` : `Creating iOS ${versionString}.`);
    if (preview) return;
    const created = await client.post("/v1/appStoreVersions", {
      data: {
        type: "appStoreVersions",
        attributes: { platform: "IOS", versionString },
        relationships: { app: { data: { type: "apps", id: found.app.id } } },
      },
    });
    version = created.data;
    found.versions.unshift(version);
  }
  const state = version.attributes.appStoreState;
  if (!EDITABLE_VERSION_STATES.has(state)) {
    console.log(`Version ${versionString} is ${state}, so the listing is not edited.`);
    return;
  }
  console.log(preview ? `Would set the ${versionString} listing (${state}).` : `Setting the ${versionString} listing.`);
  const localizations = await client.get(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`);
  let localization = (localizations.data || []).find((item) => item.attributes.locale === "en-US") || localizations.data?.[0];
  const attributes = {
    description: copy.description,
    keywords: copy.keywords,
    promotionalText: copy.promotional,
    supportUrl: links.supportUrl,
    marketingUrl: links.marketingUrl,
    whatsNew: copy.whatsNew,
  };
  if (!localization) {
    if (preview) console.log("Would create the en-US version localization.");
    else localization = (await client.post("/v1/appStoreVersionLocalizations", {
      data: { type: "appStoreVersionLocalizations", attributes: { locale: "en-US", ...attributes }, relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version.id } } } },
    })).data;
  } else if (preview) {
    console.log(`Would update ${localization.attributes.locale}: description, What's New, promotional text, keywords, support and marketing URLs.`);
  } else {
    try {
      await client.patch(`/v1/appStoreVersionLocalizations/${localization.id}`, { data: { type: "appStoreVersionLocalizations", id: localization.id, attributes } });
    } catch (error) {
      if (!/whatsNew|whats.new/i.test(error.message)) throw error;
      console.log("What's New was refused (usual for the first version). Sending the listing without it.");
      const { whatsNew, ...rest } = attributes;
      void whatsNew;
      await client.patch(`/v1/appStoreVersionLocalizations/${localization.id}`, { data: { type: "appStoreVersionLocalizations", id: localization.id, attributes: rest } });
    }
  }
  if (preview) console.log(`Would set the app name, subtitle and privacy policy URL.`);
  else await patchAppInfo(client, found.app.id, links);
  if (buildId) {
    console.log(preview ? "Would attach the processed build." : "Attaching the processed build.");
    if (!preview) {
      await client.patch(`/v1/appStoreVersions/${version.id}`, {
        data: { type: "appStoreVersions", id: version.id, relationships: { build: { data: { type: "builds", id: buildId } } } },
      });
    }
  } else console.log("No new build to attach.");
  await writeReviewDetails(client, version.id, reviewText, phone, preview);
}

async function patchAppInfo(client, appId, links) {
  const infos = await client.get(`/v1/apps/${appId}/appInfos?include=appInfoLocalizations&limit=5`);
  const localization = (infos.included || []).find((item) => item.type === "appInfoLocalizations" && item.attributes.locale === "en-US")
    || (infos.included || []).find((item) => item.type === "appInfoLocalizations");
  if (!localization) {
    console.log("No app info localization to update (name, subtitle, privacy URL).");
    return;
  }
  await client.patch(`/v1/appInfoLocalizations/${localization.id}`, {
    data: {
      type: "appInfoLocalizations",
      id: localization.id,
      attributes: { name: links.name, subtitle: links.subtitle, privacyPolicyUrl: links.privacyPolicyUrl },
    },
  });
}

async function writeReviewDetails(client, versionId, reviewText, phone, preview) {
  let existing;
  try {
    existing = (await client.get(`/v1/appStoreVersions/${versionId}/appStoreReviewDetail`)).data;
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  const contactPhone = phone || existing?.attributes?.contactPhone;
  const hasPhone = Boolean(existing?.attributes?.contactPhone);
  console.log(`Review contact phone: ${hasPhone || phone ? "available" : "missing"}. Demo account: ${process.env.DEMO_CLIENT_EMAIL}. Notes: ${reviewText.length} characters.`);
  if (!contactPhone) {
    throw new Error("Review contact phone is missing. Set ASC_CONTACT_PHONE in .env (it is not committed).");
  }
  const attributes = {
    contactFirstName: review.contact.firstName,
    contactLastName: review.contact.lastName,
    contactEmail: review.contact.email,
    contactPhone,
    demoAccountName: process.env.DEMO_CLIENT_EMAIL,
    demoAccountPassword: process.env.DEMO_PASSWORD,
    demoAccountRequired: true,
    notes: reviewText,
  };
  if (preview) {
    console.log("Would set review contact, the demo account from the environment, and the notes. Nothing was sent.");
    return;
  }
  if (existing?.id) {
    await client.patch(`/v1/appStoreReviewDetails/${existing.id}`, { data: { type: "appStoreReviewDetails", id: existing.id, attributes } });
  } else {
    await client.post("/v1/appStoreReviewDetails", {
      data: {
        type: "appStoreReviewDetails",
        attributes,
        relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: versionId } } },
      },
    });
  }
}

async function sendToReview(client, found) {
  const open = found.submissions.find((item) => !["COMPLETE", "COMPLETED"].includes(item.state));
  if (open && ["WAITING_FOR_REVIEW", "IN_REVIEW"].includes(open.state)) {
    throw new Error(`A review submission is already ${open.state}.`);
  }
  const version = found.versions.find((item) => item.attributes.versionString === marketingVersion(readFileSync("project.yml", "utf8")));
  if (!version) throw new Error("No version record to submit.");
  let submissionId = open?.id;
  if (!submissionId) {
    const made = await client.post("/v1/reviewSubmissions", {
      data: { type: "reviewSubmissions", relationships: { app: { data: { type: "apps", id: found.app.id } } } },
    });
    submissionId = made.data.id;
    await client.post("/v1/reviewSubmissionItems", {
      data: {
        type: "reviewSubmissionItems",
        relationships: {
          reviewSubmission: { data: { type: "reviewSubmissions", id: submissionId } },
          appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
        },
      },
    });
  }
  await client.patch(`/v1/reviewSubmissions/${submissionId}`, {
    data: { type: "reviewSubmissions", id: submissionId, attributes: { submitted: true } },
  });
}
