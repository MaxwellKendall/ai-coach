// TKL-772: regenerate appstore/screenshots/lifter-pro.png and coach-pro.png with a clean status bar.
// PAYWALL_SIMULATOR (a name or UDID) runs on a simulator of its own; default iPhone 17 Pro.
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { paywallShotSteps } from "./paywall-shots-lib.mjs";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const wanted = process.env.PAYWALL_SIMULATOR || "iPhone 17 Pro";
const list = JSON.parse(spawnSync("xcrun", ["simctl", "list", "devices", "available", "-j"], { encoding: "utf8" }).stdout);
const device = Object.values(list.devices).flat().find((item) => item.udid === wanted || item.name === wanted);
if (!device) {
  console.error(`Simulator ${wanted} is not available.`);
  process.exit(1);
}

if (spawnSync("xcodegen", ["generate"], { cwd: root, stdio: "inherit" }).status !== 0) process.exit(1);
let failed = 0;
for (const [command, args, { allowFailure }] of paywallShotSteps(device.udid)) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const status = spawnSync(command, args, { cwd: root, stdio: "inherit" }).status;
  if (status !== 0 && !allowFailure) {
    failed = status ?? 1;
    // Still clear the override below; skip only to the last step.
    if (command === "xcodebuild") continue;
    break;
  }
}
console.log(failed ? "Paywall screenshots failed." : "Paywall screenshots: appstore/screenshots/lifter-pro.png, coach-pro.png");
process.exit(failed);
