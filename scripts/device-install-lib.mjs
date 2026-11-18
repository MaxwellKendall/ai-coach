// TKL-796: install the app on a physical iPhone only from origin/main, in Release,
// and record what each phone has so the next install can't silently drop unmerged work.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";

export const USAGE = `Usage: npm run device-install -- [--device UDID] [--branch-ok] [--configuration Release|Debug] [--dry-run]

Builds the checked-out commit and installs it on a paired iPhone.
Refuses a commit that isn't on origin/main (or a tree with uncommitted changes) unless --branch-ok.
Release (prod backend) is the default; it is what Maxwell runs. Records sha + configuration per
device in <git common dir>/device-install.json and warns when an install replaces unmerged work.`;

export function parseArgs(argv) {
  const opts = { branchOk: false, configuration: "Release", device: null, dryRun: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--branch-ok") opts.branchOk = true;
    else if (a === "--dry-run") opts.dryRun = true;
    else if (a === "--help" || a === "-h") opts.help = true;
    else if (a === "--device") opts.device = argv[++i] ?? null;
    else if (a === "--configuration") {
      const c = argv[++i];
      if (c !== "Debug" && c !== "Release") throw new Error("--configuration must be Debug or Release");
      opts.configuration = c;
    } else throw new Error(`unknown option ${a}`);
  }
  return opts;
}

const short = (sha) => (sha ? sha.slice(0, 8) : "unknown");

// Pure decision: refuse (a reason) or go ahead with zero or more warnings.
export function planInstall({ head, headOnMain, dirty, branchOk, configuration = "Release", previous, previousOnMain }) {
  const warnings = [];
  let refuse = null;
  if (!branchOk && dirty) refuse = `the working tree has uncommitted changes, so the build would not match ${short(head)}`;
  else if (!branchOk && !headOnMain) refuse = `${short(head)} is not on origin/main; land it first`;
  if (previous && previous.sha && previous.sha !== head && previousOnMain === false) {
    warnings.push(
      `this install replaces ${short(previous.sha)} (branch ${previous.branch || "unknown"}, ${previous.configuration}, installed ${previous.installedAt}), which is not on origin/main. That work disappears from the phone.`,
    );
  }
  if (previous && previous.configuration && previous.configuration !== configuration) {
    warnings.push(`configuration changes ${previous.configuration} → ${configuration} (Debug and Release use different backends).`);
  }
  return { refuse, warnings };
}

function gitIn(cwd) {
  return (...args) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

// Shared by every worktree of the repo, and never tracked.
export function recordPath(cwd) {
  const common = gitIn(cwd)("rev-parse", "--git-common-dir");
  return join(realpathSync(isAbsolute(common) ? common : resolve(cwd, common)), "device-install.json");
}

export function readRecord(path) {
  if (!existsSync(path)) return {};
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return {};
  }
}

function onOriginMain(git, sha) {
  try {
    git("merge-base", "--is-ancestor", sha, "origin/main");
    return true;
  } catch {
    return false;
  }
}

function defaultExec(cmd, args, cwd) {
  return execFileSync(cmd, args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], maxBuffer: 64 * 1024 * 1024 });
}

// The single paired physical iPhone, when --device isn't given.
function findDevice(exec, cwd) {
  mkdirSync(join(cwd, "build"), { recursive: true });
  const out = join(cwd, "build", "devices.json");
  exec("xcrun", ["devicectl", "list", "devices", "--json-output", out], cwd);
  const devices = (JSON.parse(readFileSync(out, "utf8")).result?.devices || []).filter(
    (d) => d.hardwareProperties?.reality === "physical" && d.connectionProperties?.pairingState === "paired",
  );
  if (devices.length !== 1) throw new Error(`found ${devices.length} paired iPhones; pass --device UDID`);
  return devices[0].hardwareProperties.udid;
}

// Returns an exit code: 0 installed (or planned), 1 error, 2 refused.
export async function run(argv, { cwd = process.cwd(), exec = defaultExec, log = console.log, fetch = true } = {}) {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (e) {
    log(`device-install: ${e.message}\n${USAGE}`);
    return 1;
  }
  if (opts.help) {
    log(USAGE);
    return 0;
  }
  const git = gitIn(cwd);
  const root = git("rev-parse", "--show-toplevel");
  if (fetch) git("fetch", "--quiet", "origin");
  const head = git("rev-parse", "HEAD");
  const branch = git("rev-parse", "--abbrev-ref", "HEAD");
  const dirty = git("status", "--porcelain", "--untracked-files=no") !== "";
  const path = recordPath(cwd);
  const record = readRecord(path);

  let device = opts.device;
  if (!device && !opts.dryRun) {
    try {
      device = findDevice(exec, root);
    } catch (e) {
      log(`device-install: ${e.message}`);
      return 1;
    }
  }
  const previous = device ? record[device] || null : null;
  const plan = planInstall({
    head,
    headOnMain: onOriginMain(git, head),
    dirty,
    branchOk: opts.branchOk,
    configuration: opts.configuration,
    previous,
    previousOnMain: previous?.sha ? onOriginMain(git, previous.sha) : null,
  });

  if (plan.refuse) {
    log(`device-install: refused: ${plan.refuse}. Install from origin/main, or pass --branch-ok to install it anyway.`);
    return 2;
  }
  for (const w of plan.warnings) log(`device-install: WARNING: ${w}`);
  log(`device-install: ${short(head)} (${branch}) in ${opts.configuration} → ${device || "the paired iPhone"}`);
  if (opts.dryRun) return 0;

  const derived = join(root, "build", "device");
  exec("xcodegen", ["generate"], root);
  exec(
    "xcodebuild",
    ["-scheme", "AICoach", "-configuration", opts.configuration, "-destination", "generic/platform=iOS",
      "-derivedDataPath", derived, "-allowProvisioningUpdates", "build"],
    root,
  );
  const app = join(derived, "Build", "Products", `${opts.configuration}-iphoneos`, "AICoach.app");
  exec("xcrun", ["devicectl", "device", "install", "app", "--device", device, app], root);

  const latest = readRecord(path);
  latest[device] = { sha: head, branch, configuration: opts.configuration, installedAt: new Date().toISOString(), onMain: onOriginMain(git, head) };
  writeFileSync(path, JSON.stringify(latest, null, 2) + "\n");
  log(`device-install: installed ${short(head)} and recorded it in ${path}`);
  return 0;
}
