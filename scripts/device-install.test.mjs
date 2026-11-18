// TKL-796: installs on Maxwell's phone come from origin/main, in Release, and are recorded.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { parseArgs, planInstall, recordPath, run } from "./device-install-lib.mjs";

const git = (cwd, ...args) => execFileSync("git", args, { cwd, encoding: "utf8" }).trim();

// A clone whose origin/main is one commit, plus an unmerged branch commit on top.
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "device-install-"));
  const origin = join(dir, "origin.git");
  const repo = join(dir, "repo");
  execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin]);
  execFileSync("git", ["clone", "-q", origin, repo], { stdio: "ignore" });
  for (const [k, v] of [["user.email", "t@example.com"], ["user.name", "t"], ["commit.gpgsign", "false"]]) git(repo, "config", k, v);
  writeFileSync(join(repo, "a.txt"), "a\n");
  git(repo, "add", "a.txt");
  git(repo, "commit", "-q", "-m", "main commit");
  git(repo, "push", "-q", "origin", "HEAD:main");
  const mainSha = git(repo, "rev-parse", "HEAD");
  git(repo, "checkout", "-q", "-b", "TKL-1-fix");
  writeFileSync(join(repo, "a.txt"), "fix\n");
  git(repo, "commit", "-q", "-am", "branch fix");
  const branchSha = git(repo, "rev-parse", "HEAD");
  return { repo, mainSha, branchSha };
}

// Records every external command instead of building or installing.
function fakeExec() {
  const calls = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    return "";
  };
  return { exec, calls };
}

function capture() {
  const lines = [];
  return { log: (s) => lines.push(String(s)), lines };
}

test("parseArgs defaults to Release and knows --branch-ok, --device, --dry-run", () => {
  assert.deepEqual(parseArgs([]), { branchOk: false, configuration: "Release", device: null, dryRun: false, help: false });
  assert.deepEqual(parseArgs(["--branch-ok", "--device", "ABC", "--dry-run"]), {
    branchOk: true, configuration: "Release", device: "ABC", dryRun: true, help: false,
  });
  assert.equal(parseArgs(["--configuration", "Debug"]).configuration, "Debug");
  assert.throws(() => parseArgs(["--configuration", "Beta"]), /Debug or Release/);
  assert.throws(() => parseArgs(["--bogus"]), /unknown option/);
});

test("planInstall refuses a commit that is not on origin/main unless --branch-ok", () => {
  const off = planInstall({ head: "b", headOnMain: false, dirty: false, branchOk: false, previous: null, previousOnMain: null });
  assert.match(off.refuse, /not on origin\/main/);
  const ok = planInstall({ head: "b", headOnMain: false, dirty: false, branchOk: true, previous: null, previousOnMain: null });
  assert.equal(ok.refuse, null);
  const main = planInstall({ head: "m", headOnMain: true, dirty: false, branchOk: false, previous: null, previousOnMain: null });
  assert.equal(main.refuse, null);
  assert.deepEqual(main.warnings, []);
});

test("planInstall refuses uncommitted changes unless --branch-ok", () => {
  const dirty = planInstall({ head: "m", headOnMain: true, dirty: true, branchOk: false, previous: null, previousOnMain: null });
  assert.match(dirty.refuse, /uncommitted/);
});

test("planInstall warns when it would replace a commit that is not on origin/main", () => {
  const previous = { sha: "b", configuration: "Release", branch: "TKL-1-fix", installedAt: "2026-11-18T10:00:00Z" };
  const plan = planInstall({ head: "m", headOnMain: true, dirty: false, branchOk: false, previous, previousOnMain: false });
  assert.equal(plan.refuse, null);
  assert.equal(plan.warnings.length, 1);
  assert.match(plan.warnings[0], /replaces b .*TKL-1-fix.*not on origin\/main/);
  const fine = planInstall({ head: "m", headOnMain: true, dirty: false, branchOk: false, previous: { ...previous, sha: "m0" }, previousOnMain: true });
  assert.deepEqual(fine.warnings, []);
});

test("planInstall warns when the configuration changes (Debug and Release use different backends)", () => {
  const previous = { sha: "m0", configuration: "Release", branch: "main", installedAt: "x" };
  const plan = planInstall({ head: "m", headOnMain: true, dirty: false, branchOk: false, configuration: "Debug", previous, previousOnMain: true });
  assert.match(plan.warnings.join("\n"), /Release → Debug/);
});

test("run refuses an unmerged branch and builds nothing", async () => {
  const { repo } = fixture();
  const { exec, calls } = fakeExec();
  const out = capture();
  const code = await run(["--device", "DEV1"], { cwd: repo, exec, log: out.log, fetch: false });
  assert.equal(code, 2);
  assert.match(out.lines.join("\n"), /not on origin\/main.*--branch-ok/s);
  assert.deepEqual(calls, []);
  assert.equal(existsSync(recordPath(repo)), false);
});

test("run installs origin/main in Release and records the sha and configuration", async () => {
  const { repo, mainSha } = fixture();
  git(repo, "checkout", "-q", mainSha);
  const { exec, calls } = fakeExec();
  const code = await run(["--device", "DEV1"], { cwd: repo, exec, log: capture().log, fetch: false });
  assert.equal(code, 0);
  const xcodebuild = calls.find((c) => c[0] === "xcodebuild");
  assert.ok(xcodebuild, "xcodebuild ran");
  assert.equal(xcodebuild[xcodebuild.indexOf("-configuration") + 1], "Release");
  assert.ok(calls.some((c) => c[0] === "xcrun" && c.includes("devicectl") && c.includes("install") && c.includes("DEV1")));
  const record = JSON.parse(readFileSync(recordPath(repo), "utf8"));
  assert.equal(record.DEV1.sha, mainSha);
  assert.equal(record.DEV1.configuration, "Release");
});

test("run with --branch-ok installs the branch, and the next main install warns it replaces it", async () => {
  const { repo, mainSha, branchSha } = fixture();
  const first = await run(["--device", "DEV1", "--branch-ok"], { cwd: repo, exec: fakeExec().exec, log: capture().log, fetch: false });
  assert.equal(first, 0);
  assert.equal(JSON.parse(readFileSync(recordPath(repo), "utf8")).DEV1.sha, branchSha);

  git(repo, "checkout", "-q", mainSha);
  const out = capture();
  const second = await run(["--device", "DEV1"], { cwd: repo, exec: fakeExec().exec, log: out.log, fetch: false });
  assert.equal(second, 0);
  assert.match(out.lines.join("\n"), new RegExp(`WARNING.*replaces ${branchSha.slice(0, 8)}.*TKL-1-fix.*not on origin/main`));
  assert.equal(JSON.parse(readFileSync(recordPath(repo), "utf8")).DEV1.sha, mainSha);
});

test("--dry-run plans but neither builds nor records", async () => {
  const { repo, mainSha } = fixture();
  git(repo, "checkout", "-q", mainSha);
  const { exec, calls } = fakeExec();
  const code = await run(["--device", "DEV1", "--dry-run"], { cwd: repo, exec, log: capture().log, fetch: false });
  assert.equal(code, 0);
  assert.deepEqual(calls, []);
  assert.equal(existsSync(recordPath(repo)), false);
});

test("the record lives in the shared git dir, so every worktree sees the same phone", () => {
  const { repo } = fixture();
  const wt = join(repo, "..", "wt");
  git(repo, "worktree", "add", "-q", wt, "HEAD");
  assert.equal(recordPath(wt), recordPath(repo));
});
