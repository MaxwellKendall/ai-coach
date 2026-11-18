// FIT-431: record the review path on the iPhone 17 Pro simulator.
// Credentials are read from .env, compiled into the UI test for that one build, and the stub is restored after.
// Output is redacted. The compressed file is build/review/demo.mp4.
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadEnv } from "./load-env.mjs";
import { redact } from "./release-lib.mjs";
import { CHAPTERS, assembleArgs, parseCue, parseCues, partFiles } from "./chapters-lib.mjs";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const secretsPath = resolve(root, "Tests/UITests/Secrets.swift");
// Always written back, even if this process started while a previous run had left credentials in the file.
const stub = `import Foundation

/// The review demo reads its logins from the environment. scripts/demo-video.mjs replaces this
/// file for one recording and writes this stub back afterwards. Do not put a password here.
enum ReviewDemoSecrets {
    static let clientEmail = ProcessInfo.processInfo.environment["DEMO_CLIENT_EMAIL"] ?? ""
    static let coachEmail = ProcessInfo.processInfo.environment["DEMO_COACH_EMAIL"] ?? ""
    static let password = ProcessInfo.processInfo.environment["DEMO_PASSWORD"] ?? ""
}
`;
const outDir = resolve(root, "build/review");
const rawPath = resolve(outDir, "raw.mp4");
// TKL-460: the chapters go beside the review path's video, not over it.
const outPath = resolve(outDir, process.argv.includes("--chapters") ? "chapters.mp4" : "demo.mp4");
// FIT-458: the UI test writes each screen it shows here; scripts/screen-coverage.mjs checks it against the inventory.
const shownPath = resolve(outDir, "screens-shown.txt");
// Until the demo covers every screen (FIT-459, FIT-460), a gap is reported but doesn't fail the run or the release.
const requireCoverage = process.argv.includes("--require-coverage");
// TKL-460: `--chapters` records the invited-client and coach chapters instead, in the Debug build's no-server demo mode
// (`-demo YES`): no demo-account logins, nothing written to production. Each part of a chapter is recorded on its own
// between the UI test's cues, joined after a title card, and coverage is checked for the client and coach roles (failing on a gap).
const chapters = process.argv.includes("--chapters");
const cuesPath = resolve(outDir, "cues.txt");

loadEnv(resolve(root, ".env"));
const clientEmail = process.env.DEMO_CLIENT_EMAIL || "";
const coachEmail = process.env.DEMO_COACH_EMAIL || "";
const password = process.env.DEMO_PASSWORD || "";
if (!chapters && (!clientEmail || !coachEmail || !password)) {
  console.error("DEMO_CLIENT_EMAIL, DEMO_COACH_EMAIL and DEMO_PASSWORD must be set. See RELEASE.md.");
  process.exit(1);
}
const hidden = password ? [password, Buffer.from(password, "utf8").toString("base64")] : [];

let keyboardWas;
function restore() {
  writeFileSync(secretsPath, stub);
  if (keyboardWas !== undefined) {
    spawnSync("defaults", ["write", "com.apple.iphonesimulator", "ConnectHardwareKeyboard", "-bool", keyboardWas]);
    keyboardWas = undefined;
  }
}
process.on("exit", restore);

function scrub(text) {
  return redact(String(text), hidden);
}

function exec(command, args, { allowFailure = false } = {}) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.error) throw result.error;
  if (!allowFailure && result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed\n${scrub(result.stderr || result.stdout || "")}`);
  }
  return result.stdout || "";
}

function run(command, args) {
  console.log(`\n$ ${scrub([command, ...args].join(" "))}`);
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { cwd: root, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
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

function b64(value) {
  return Buffer.from(value, "utf8").toString("base64");
}

const deviceList = JSON.parse(exec("xcrun", ["simctl", "list", "devices", "available", "-j"]));
let udid;
let deviceName;
// DEMO_SIMULATOR (a name or UDID) records on a simulator of its own, so another run's tests can't take the screen.
const wanted = process.env.DEMO_SIMULATOR;
if (wanted) {
  for (const devices of Object.values(deviceList.devices)) {
    const found = devices.find((item) => (item.udid === wanted || item.name === wanted) && item.isAvailable);
    if (found) { udid = found.udid; deviceName = found.name; break; }
  }
  if (!udid) {
    console.error(`DEMO_SIMULATOR ${wanted} is not an available simulator.`);
    process.exit(1);
  }
}
for (const preferred of ["iPhone 17 Pro", "iPhone 17 Pro Max"]) {
  if (udid) break;
  for (const devices of Object.values(deviceList.devices)) {
    const found = devices.find((item) => item.name === preferred && item.isAvailable);
    if (found) { udid = found.udid; deviceName = found.name; break; }
  }
}
if (!udid) {
  console.error("No iPhone 17 Pro simulator is available.");
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });
if (!chapters) writeFileSync(secretsPath, `import Foundation

/// Generated by scripts/demo-video.mjs for one recording. The environment stub is restored after the run.
enum ReviewDemoSecrets {
    static let clientEmail = String(decoding: Data(base64Encoded: "${b64(clientEmail)}")!, as: UTF8.self)
    static let coachEmail = String(decoding: Data(base64Encoded: "${b64(coachEmail)}")!, as: UTF8.self)
    static let password = String(decoding: Data(base64Encoded: "${b64(password)}")!, as: UTF8.self)
}
`);
console.log(chapters ? `Recording the client and coach chapters on ${deviceName}, in demo mode.` : `Recording on ${deviceName}. The password is not printed.`);

try {
  const current = exec("defaults", ["read", "com.apple.iphonesimulator", "ConnectHardwareKeyboard"], { allowFailure: true }).trim();
  keyboardWas = current === "1" || current === "true" ? "true" : "false";
} catch {
  keyboardWas = "false";
}
exec("defaults", ["write", "com.apple.iphonesimulator", "ConnectHardwareKeyboard", "-bool", "false"]);

if (await run("xcodegen", ["generate"]) !== 0) process.exit(1);

console.log(`Installing a fresh ${deviceName} copy so the recording starts at the first launch.`);
exec("xcrun", ["simctl", "boot", udid], { allowFailure: true });
exec("xcrun", ["simctl", "bootstatus", udid, "-b"]);
exec("xcrun", ["simctl", "keychain", udid, "reset"]);
exec("xcrun", ["simctl", "uninstall", udid, "com.maxwellkendall.aicoach"], { allowFailure: true });
exec("xcrun", ["simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4"], { allowFailure: true });

const destination = `platform=iOS Simulator,id=${udid}`;
// The chapters' demo mode is Debug-only (App/DebugRole.swift); the review path records the Release build.
const configuration = chapters ? "Debug" : "Release";
if (await run("xcodebuild", ["build-for-testing", "-scheme", "ReviewDemo", "-configuration", configuration, "-destination", destination, "-derivedDataPath", "build/dd", "-quiet"]) !== 0) {
  console.error("ReviewDemo failed to build.");
  process.exit(1);
}

rmSync(shownPath, { force: true });
process.env.TEST_RUNNER_DEMO_SCREENS = shownPath;

/** Starts simctl recording to `path`; resolves with the child once it says "Recording started". */
function startRecording(path) {
  const child = spawn("xcrun", ["simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", path], { stdio: ["ignore", "pipe", "pipe"] });
  return new Promise((resolvePromise) => {
    const fallback = setTimeout(() => resolvePromise(child), 15000);
    const listen = (chunk) => {
      if (!String(chunk).includes("Recording started")) return;
      clearTimeout(fallback);
      resolvePromise(child);
    };
    child.stdout.on("data", listen);
    child.stderr.on("data", listen);
  });
}

async function stopRecording(child) {
  if (child.exitCode !== null) return;
  const closed = new Promise((resolvePromise) => child.on("close", resolvePromise));
  child.kill("SIGINT");
  await closed;
}

if (chapters) {
  // TKL-460: one recording per part, started at the UI test's `begin` cue and stopped at its `end`; each cue is
  // acknowledged in cues.txt.ack once the recording has started or been written, and the test waits for that.
  const ackPath = `${cuesPath}.ack`;
  const partPath = (index) => resolve(outDir, `part-${index}.mp4`);
  rmSync(cuesPath, { force: true });
  rmSync(ackPath, { force: true });
  writeFileSync(cuesPath, "");
  process.env.TEST_RUNNER_DEMO_CUES = cuesPath;
  let handled = 0;
  let parts = 0;
  let recording = null;
  let watching = true;
  let problem = null;
  const watcher = (async () => {
    while (watching) {
      const lines = readFileSync(cuesPath, "utf8").split("\n").filter((line) => line.trim());
      for (const line of lines.slice(handled)) {
        handled++;
        try {
          const cue = parseCue(line);
          if (cue.kind === "begin") {
            if (recording) await stopRecording(recording);
            recording = await startRecording(partPath(parts++));
            await new Promise((resolvePromise) => setTimeout(resolvePromise, 300));
          } else if (recording) {
            await stopRecording(recording);
            recording = null;
          }
          appendFileSync(ackPath, `${cue.id}\n`);
        } catch (error) {
          problem ??= error.message;
        }
      }
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
    }
  })();
  const testCode = await run("xcodebuild", [
    "test-without-building", "-scheme", "ReviewDemo", "-configuration", configuration,
    "-destination", destination, "-derivedDataPath", "build/dd",
    ...CHAPTERS.map((chapter) => `-only-testing:${chapter.test}`),
  ]);
  watching = false;
  await watcher;
  if (recording) await stopRecording(recording);

  let files;
  try {
    if (problem) throw new Error(problem);
    files = partFiles(parseCues(readFileSync(cuesPath, "utf8")), CHAPTERS, partPath);
    const missing = files.find((part) => !existsSync(part.file));
    if (missing) throw new Error(`${missing.file} was not written`);
  } catch (error) {
    console.error(`The chapters weren't recorded: ${error.message}.`);
    process.exit(1);
  }
  const cards = {};
  for (const chapter of CHAPTERS) {
    cards[chapter.id] = resolve(outDir, `card-${chapter.id}.png`);
    if (await run("swift", ["scripts/title-card.swift", chapter.title, chapter.detail, cards[chapter.id]]) !== 0) process.exit(1);
  }
  if (await run("ffmpeg", assembleArgs({ parts: files, cards, out: outPath })) !== 0) {
    console.error(`ffmpeg failed. The parts are still in ${outDir}`);
    process.exit(1);
  }
  const length = exec("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", outPath]).trim();
  console.log(`Chapters video: ${outPath} (${files.length} parts)`);
  console.log(`Duration: ${Number(length).toFixed(1)}s`);
  restore();
  const fresh = await run("node", ["scripts/screen-inventory.mjs", "--check"]);
  const covered = await run("node", ["scripts/screen-coverage.mjs", shownPath, "--roles", "client,coach"]);
  process.exit(testCode || fresh || covered ? 1 : 0);
}

const recorder = spawn("xcrun", ["simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", rawPath], { stdio: "ignore" });
await new Promise((resolvePromise) => setTimeout(resolvePromise, 1000));
const testCode = await run("xcodebuild", [
  "test-without-building", "-scheme", "ReviewDemo", "-configuration", configuration,
  "-destination", destination, "-derivedDataPath", "build/dd",
  "-only-testing:AICoachUITests/ReviewDemoUITests/testReviewPath",
]);
recorder.kill("SIGINT");
await new Promise((resolvePromise) => recorder.on("close", resolvePromise));

if (await run("ffmpeg", [
  "-y", "-i", rawPath, "-vf", "scale=886:-2:flags=lanczos,fps=30",
  "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p",
  "-crf", "26", "-preset", "medium", "-movflags", "+faststart", "-an", outPath,
]) !== 0) {
  console.error(`ffmpeg failed. The raw recording is still at ${rawPath}`);
  process.exit(1);
}
const duration = exec("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", outPath]).trim();
console.log(`Demo video: ${outPath}`);
console.log(`Duration: ${Number(duration).toFixed(1)}s`);
restore();

const fresh = await run("node", ["scripts/screen-inventory.mjs", "--check"]);
const covered = await run("node", ["scripts/screen-coverage.mjs", shownPath]);
if (fresh !== 0 || covered !== 0) {
  console.log(requireCoverage ? "The demo does not cover every screen." : "Coverage gaps are reported only; pass --require-coverage to fail on them.");
}
process.exit(testCode || (requireCoverage && (fresh || covered)) ? 1 : 0);
