// TKL-772: the paywall review screenshots get a clean status bar (9:41, full bars, no "◀ App" back link).
import { test } from "node:test";
import assert from "node:assert/strict";
import { paywallShotSteps, statusBarOverride } from "./paywall-shots-lib.mjs";

test("the status bar override pins the time, battery and signal", () => {
  assert.deepEqual(statusBarOverride("UDID"), [
    "simctl", "status_bar", "UDID", "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
    "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
  ]);
});

test("the paywall run overrides the status bar before the capture and clears it after", () => {
  const steps = paywallShotSteps("UDID");
  const commands = steps.map(([command, args]) => `${command} ${args.join(" ")}`);
  const override = commands.findIndex((line) => line.includes("status_bar UDID override"));
  const capture = commands.findIndex((line) => line.startsWith("xcodebuild ") && line.includes(" test "));
  const clear = commands.findIndex((line) => line.includes("status_bar UDID clear"));
  assert.ok(override >= 0 && capture > override && clear > capture, commands.join("\n"));
  // The app is reinstalled so it launches fresh, never as a link back from another app.
  const uninstall = commands.findIndex((line) => line.includes("simctl uninstall UDID com.maxwellkendall.aicoach"));
  assert.ok(uninstall >= 0 && uninstall < capture);
  assert.match(commands[capture], /-only-testing:AICoachUITests\/PaywallScreenshotUITests/);
  assert.match(commands[capture], /-scheme ReviewDemo -configuration Debug/); // the scheme with the UI tests; -paywall is Debug-only
  assert.match(commands[capture], /platform=iOS Simulator,id=UDID/);
});
