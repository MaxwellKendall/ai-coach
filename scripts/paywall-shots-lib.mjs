// TKL-772: the commands that regenerate the paywall review screenshots with a clean status bar.

/** `xcrun` arguments for the App Store status bar: 9:41, full battery and signal. */
export function statusBarOverride(udid) {
  return [
    "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
    "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
  ];
}

/**
 * The run, in order, as [command, args, { allowFailure }]: a fresh install (so the app never launches as a link back
 * from another app), the status bar override, PaywallScreenshotUITests, then the override cleared.
 */
export function paywallShotSteps(udid) {
  return [
    ["xcrun", ["simctl", "boot", udid], { allowFailure: true }],
    ["xcrun", ["simctl", "bootstatus", udid, "-b"], {}],
    ["xcrun", ["simctl", "uninstall", udid, "com.maxwellkendall.aicoach"], { allowFailure: true }],
    ["xcrun", statusBarOverride(udid), {}],
    ["xcodebuild", [
      "-scheme", "ReviewDemo", "-configuration", "Debug", "-destination", `platform=iOS Simulator,id=${udid}`, "test",
      "-only-testing:AICoachUITests/PaywallScreenshotUITests",
    ], {}],
    ["xcrun", ["simctl", "status_bar", udid, "clear"], { allowFailure: true }],
  ];
}
