// TKL-908: demo-video.mjs compiles the demo logins into Tests/UITests/Secrets.swift for one recording. A run the
// factory stops (SIGTERM at its timeout) or someone interrupts (SIGINT) must still write the stub back.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const lib = fileURLToPath(new URL("./demo-video-lib.mjs", import.meta.url));

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  test(`a ${signal} mid-recording restores the secrets stub and exits non-zero`, async () => {
    const dir = mkdtempSync(join(tmpdir(), "demo-video-"));
    const file = join(dir, "Secrets.swift");
    const script = `
      import { writeFileSync } from "node:fs";
      import { restoreOnStop } from ${JSON.stringify(lib)};
      writeFileSync(${JSON.stringify(file)}, "real logins");
      restoreOnStop(() => writeFileSync(${JSON.stringify(file)}, "stub"));
      console.log("ready");
      setInterval(() => {}, 1000);
    `;
    const child = spawn(process.execPath, ["--input-type=module", "-e", script], { stdio: ["ignore", "pipe", "inherit"] });
    await new Promise((resolve) => child.stdout.once("data", resolve));
    child.kill(signal);
    const code = await new Promise((resolve) => child.on("close", (exitCode) => resolve(exitCode)));
    try {
      assert.equal(readFileSync(file, "utf8"), "stub");
      assert.notEqual(code, 0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}

test("a normal exit restores the stub once", async () => {
  const dir = mkdtempSync(join(tmpdir(), "demo-video-"));
  const file = join(dir, "count");
  writeFileSync(file, "");
  const script = `
    import { appendFileSync } from "node:fs";
    import { restoreOnStop } from ${JSON.stringify(lib)};
    restoreOnStop(() => appendFileSync(${JSON.stringify(file)}, "x"));
  `;
  const child = spawn(process.execPath, ["--input-type=module", "-e", script], { stdio: "inherit" });
  const code = await new Promise((resolve) => child.on("close", resolve));
  try {
    assert.equal(code, 0);
    assert.equal(readFileSync(file, "utf8"), "x");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an early recorder exit is reported even if it has already closed", async () => {
  const { startRecorder } = await import("./demo-video-lib.mjs");
  const recorder = startRecorder(process.execPath, ["-e", "console.error('Resource busy'); process.exit(1)"]);
  await assert.rejects(recorder.waitForStart(), /Resource busy/);
  await assert.rejects(recorder.stop(), /Resource busy/);
});

test("a recorder that starts can be stopped and finalized", async () => {
  const { startRecorder } = await import("./demo-video-lib.mjs");
  const script = "process.on('SIGINT', () => process.exit(0)); console.error('Recording started'); setInterval(() => {}, 1000)";
  const recorder = startRecorder(process.execPath, ["-e", script]);
  try {
    await recorder.waitForStart();
  } finally {
    await recorder.stop();
  }
});
