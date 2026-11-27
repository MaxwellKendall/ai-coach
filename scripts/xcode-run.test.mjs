// TKL-1092: every xcodebuild entry point in ai-coach-app routes through the machine-wide Xcode lock.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { xcodeCommand } from "./xcode-run.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));

test("xcodeCommand routes through xcode-lock.js when available and preserves args including -jobs", () => {
  const res = xcodeCommand(["-scheme", "AICoach", "-jobs", "4", "build"], {
    env: { FACTORY_XCODE_LOCK_BIN: "/fake/xcode-lock.js" },
    exists: (p) => p === "/fake/xcode-lock.js",
  });
  assert.equal(res.locked, true);
  assert.equal(res.command, process.execPath);
  assert.deepEqual(res.args, ["/fake/xcode-lock.js", "-scheme", "AICoach", "-jobs", "4", "build"]);
});

test("xcodeCommand falls back to xcodebuild when lock helper is absent or bypassed", () => {
  const missing = xcodeCommand(["-scheme", "AICoach", "test"], {
    env: { FACTORY_XCODE_LOCK_BIN: "/nonexistent/xcode-lock.js" },
    exists: () => false,
  });
  assert.equal(missing.locked, false);
  assert.equal(missing.command, "xcodebuild");
  assert.deepEqual(missing.args, ["-scheme", "AICoach", "test"]);

  const bypassed = xcodeCommand(["-scheme", "AICoach", "-jobs", "4", "build"], {
    env: { FACTORY_XCODE_LOCK_BIN: "/fake/xcode-lock.js", XCODE_LOCK_BYPASS: "1" },
    exists: () => true,
  });
  assert.equal(bypassed.locked, false);
  assert.equal(bypassed.command, "xcodebuild");
});

test("every ai-coach-app script that invokes xcodebuild routes through the machine-wide lock", () => {
  for (const rel of [
    "scripts/device-install-lib.mjs",
    "scripts/demo-video.mjs",
    "scripts/paywall-shots.mjs",
    "scripts/release.mjs",
  ]) {
    const src = readFileSync(join(root, rel), "utf8");
    assert.match(src, /xcodeCommand/, `${rel} must route xcodebuild through xcodeCommand`);
  }
  for (const rel of [
    "scripts/eval.sh",
    "scripts/log-eval.sh",
    "scripts/program-eval.sh",
    "scripts/week-eval.sh",
  ]) {
    const src = readFileSync(join(root, rel), "utf8");
    assert.match(src, /xcode-lock\.js/, `${rel} must route xcodebuild through xcode-lock.js`);
  }
});
