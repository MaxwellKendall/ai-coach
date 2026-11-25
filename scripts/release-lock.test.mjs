import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import test from "node:test";

test("npm release excludes a second worktree before upload and recovers after the holder dies", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "release-lock-test-"));
  const uploads = join(dir, "uploads");
  const ready = join(dir, "ready");
  const env = { ...process.env, HOME: dir, TEST_UPLOADS: uploads, TEST_READY: ready };
  const mock = `
    import { appendFileSync, writeFileSync } from "node:fs";
    if (process.argv.includes("--dry-run") || process.argv.includes("--help")) process.exit(0);
    appendFileSync(process.env.TEST_UPLOADS, process.env.FACTORY_RUN_ID + "\\n");
    if (process.env.FACTORY_RUN_ID === "holder") {
      writeFileSync(process.env.TEST_READY, String(process.pid));
      setInterval(() => {}, 1000);
    }
  `;
  const roots = ["first", "second"].map((name) => {
    const root = join(dir, name);
    mkdirSync(join(root, "scripts"), { recursive: true });
    mkdirSync(join(root, "appstore"));
    for (const file of ["package.json", "appstore/review.json", "scripts/release-lock.py"]) {
      const source = new URL(`../${file}`, import.meta.url);
      if (existsSync(source)) cpSync(source, join(root, file));
    }
    writeFileSync(join(root, "scripts", "release.mjs"), mock);
    return root;
  });

  const holder = spawn("npm", ["run", "release"], {
    cwd: roots[0], env: { ...env, FACTORY_RUN_ID: "holder" }, detached: true, stdio: ["ignore", "ignore", "pipe"],
  });
  let holderError = "";
  holder.stderr.setEncoding("utf8").on("data", (chunk) => { holderError += chunk; });
  const holderClosed = once(holder, "close");
  t.after(async () => {
    if (holder.exitCode === null && holder.signalCode === null) process.kill(-holder.pid, "SIGKILL");
    await holderClosed;
    rmSync(dir, { recursive: true, force: true });
  });

  for (let tries = 0; !existsSync(ready) && tries < 1200; tries++) await setTimeout(25);
  assert.ok(existsSync(ready), `first release reached the upload stub: ${holderError}`);
  const run = (id, ...args) => spawnSync("npm", ["run", "release", "--", ...args], {
    cwd: roots[1], env: { ...env, FACTORY_RUN_ID: id }, encoding: "utf8", timeout: 30000,
  });

  const lockFile = join(dir, "dev/factory/state/locks/com.maxwellkendall.aicoach.release.lock");
  const holderPid = Number(readFileSync(ready, "utf8"));
  assert.equal(readFileSync(lockFile, "utf8"), `holder (PID ${holderPid})\n`);

  for (const mode of [[], ["submit"], ["products"]]) {
    const contending = run("contender", ...mode);
    assert.equal(contending.status, 1, contending.stderr);
    assert.match(contending.stderr, /holder.*PID/i);
  }
  assert.equal(run("preview", "--dry-run").status, 0);
  assert.equal(run("help", "--help").status, 0);
  assert.equal(readFileSync(uploads, "utf8"), "holder\n");

  process.kill(holderPid, "SIGKILL");
  await holderClosed;
  assert.equal(run("takeover").status, 0);
  assert.equal(run("next").status, 0);
  assert.equal(readFileSync(uploads, "utf8"), "holder\ntakeover\nnext\n");
});

test("a held lock names the processes that hold it, even when the recorded PID is gone", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "release-lock-orphan-"));
  const ready = join(dir, "ready");
  const env = { ...process.env, HOME: dir, TEST_READY: ready };
  // The release exits at once but leaves a detached child behind that still holds the lock descriptor.
  const mock = `
    import { spawn } from "node:child_process";
    import { fstatSync, statSync, writeFileSync } from "node:fs";
    import { homedir } from "node:os";
    if (process.argv.includes("--dry-run") || process.argv.includes("--help")) process.exit(0);
    if (process.env.FACTORY_RUN_ID === "crashed") {
      // libuv closes extra descriptors on spawn, so hand the lock to the child on purpose
      // to stand in for any tool that leaks or daemonizes with it.
      const { ino } = statSync(homedir() + "/dev/factory/state/locks/com.maxwellkendall.aicoach.release.lock");
      const fd = [...Array(64).keys()].slice(3).find((n) => { try { return fstatSync(n).ino === ino; } catch { return false; } });
      const child = spawn("sleep", ["300"], { detached: true, stdio: ["ignore", "ignore", "ignore", fd] });
      child.unref();
      writeFileSync(process.env.TEST_READY, JSON.stringify({ parent: process.pid, child: child.pid }));
    }
  `;
  const root = join(dir, "repo");
  mkdirSync(join(root, "scripts"), { recursive: true });
  mkdirSync(join(root, "appstore"));
  for (const file of ["package.json", "appstore/review.json", "scripts/release-lock.py"]) {
    cpSync(new URL(`../${file}`, import.meta.url), join(root, file));
  }
  writeFileSync(join(root, "scripts", "release.mjs"), mock);
  const run = (id) => spawnSync("npm", ["run", "release"], {
    cwd: root, env: { ...env, FACTORY_RUN_ID: id }, encoding: "utf8", timeout: 30000,
  });

  assert.equal(run("crashed").status, 0);
  const { parent, child } = JSON.parse(readFileSync(ready, "utf8"));
  t.after(() => {
    try { process.kill(child, "SIGKILL"); } catch {}
    rmSync(dir, { recursive: true, force: true });
  });
  assert.throws(() => process.kill(parent, 0), /ESRCH/, "recorded PID has exited");

  const blocked = run("contender");
  assert.equal(blocked.status, 1, blocked.stderr);
  assert.match(blocked.stderr, new RegExp(`crashed \\(PID ${parent}\\)`));
  assert.match(blocked.stderr, new RegExp(`PID ${parent} is no longer running`));
  assert.match(blocked.stderr, new RegExp(`\\b${child}\\b.*sleep`));

  process.kill(child, "SIGKILL");
  for (let tries = 0; tries < 200; tries++) {
    try { process.kill(child, 0); await setTimeout(25); } catch { break; }
  }
  assert.equal(run("takeover").status, 0);
});
