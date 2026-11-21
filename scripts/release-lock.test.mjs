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
