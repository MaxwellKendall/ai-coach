/** Pure pieces of `npm run release` (FIT-431). No network, no secrets printed. */

export const TERMS_LINE = "Terms of Use: https://barbrabell.com/terms";

export const EDITABLE_VERSION_STATES = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

const LIMITS = { subtitle: 30, description: 4000, promotional: 170, whatsNew: 4000, keywords: 100 };

export function parseArgs(argv) {
  const args = argv.filter((a) => a !== "--");
  return {
    dryRun: args.includes("--dry-run"),
    submit: args.includes("submit"),
    products: args.includes("products"),
    help: args.includes("--help") || args.includes("-h"),
  };
}

export function marketingVersion(yaml) {
  const match = yaml.match(/^ {4}MARKETING_VERSION: "([^"]+)"/m);
  if (!match) throw new Error("MARKETING_VERSION is missing from project.yml");
  return match[1];
}

/** Increment CURRENT_PROJECT_VERSION. The widgets read the same setting. */
export function bumpBuildNumber(yaml) {
  const pattern = /^( {4}CURRENT_PROJECT_VERSION: ")(\d+)(")\s*$/m;
  const match = yaml.match(pattern);
  if (!match) throw new Error("CURRENT_PROJECT_VERSION is missing from project.yml");
  const from = match[2];
  const to = String(Number(from) + 1);
  return { yaml: yaml.replace(pattern, `$1${to}$3`), from, to };
}

export function assertListing(listing) {
  for (const [key, max] of Object.entries(LIMITS)) {
    const value = listing[key] ?? "";
    if (value.length > max) throw new Error(`${key} is ${value.length} characters; the App Store limit is ${max}`);
  }
  if (!listing.description.trimEnd().endsWith(TERMS_LINE)) {
    throw new Error(`description must end with "${TERMS_LINE}" (FIT-386)`);
  }
}

export function reviewNotes(template, fields) {
  let notes = template;
  for (const [key, value] of Object.entries(fields)) notes = notes.replaceAll(`{{${key}}}`, value ?? "");
  const left = notes.match(/\{\{[A-Z0-9_]+\}\}/);
  if (left) throw new Error(`review notes still have ${left[0]}`);
  if (notes.length > 4000) throw new Error(`review notes are ${notes.length} characters; the App Store limit is 4000`);
  return notes;
}

export function redact(text, secrets) {
  let out = text;
  for (const secret of secrets) {
    if (secret && secret.length >= 4) out = out.split(secret).join("••••");
  }
  return out;
}

export function videoHostingNote() {
  return [
    "Hosting: https://barbrabell.com/review/demo.mp4 is not a route yet.",
    "CloudFront serves files only at /cards/*, /exercises/*, and /app/* (infra/lib/stack.ts).",
    "Nothing in the repo uploads /review/, so this command does not deploy the video.",
    "The manual step, once a /review/* behavior exists, is in RELEASE.md.",
  ].join("\n");
}

// Signing uses the Apple ID signed in to Xcode on this Mac (TKL-760): the release
// API key has no cloud-signing access, so it is kept for App Store Connect API calls only.
export function archiveArgs(archivePath = "build/AICoach.xcarchive") {
  return ["archive", "-scheme", "AICoach", "-configuration", "Release", "-destination", "generic/platform=iOS", "-archivePath", archivePath, "-allowProvisioningUpdates"];
}

export function exportArgs(archivePath = "build/AICoach.xcarchive") {
  return ["-exportArchive", "-archivePath", archivePath, "-exportPath", "build/export", "-exportOptionsPlist", "build/ExportOptions.plist", "-allowProvisioningUpdates"];
}

/**
 * Land the build-number bump on origin/main through a squash-merged PR (TKL-774).
 * Runs right after App Store Connect has the build: if the bump stays on this machine,
 * main says the old number and the next release fails at upload. `exec` is spawnSync-like:
 * (command, args) => { code, stdout, stderr }. Never force-pushes; HEAD moves to the merged
 * main only when their trees match, so nothing but the bump commit is replaced.
 */
export function landBumpCommit(number, exec) {
  const branch = `release/build-${number}`;
  const steps = [
    ["git", ["push", "origin", `HEAD:refs/heads/${branch}`]],
    ["gh", ["pr", "create", "--base", "main", "--head", branch,
      "--title", `Build ${number}: project.yml matches the upload`,
      "--body", `npm run release uploaded build ${number} to App Store Connect. This lands its CURRENT_PROJECT_VERSION bump so the next release starts from ${number}.`]],
    ["gh", ["pr", "merge", branch, "--squash", "--delete-branch"]],
    ["git", ["fetch", "--quiet", "origin", "main"]],
  ];
  for (let i = 0; i < steps.length; i++) {
    const [command, args] = steps[i];
    const result = exec(command, args);
    if (result.code !== 0) {
      const rest = steps.slice(i).map(([c, a]) => `  ${c} ${a.map((x) => (/\s/.test(x) ? JSON.stringify(x) : x)).join(" ")}`);
      return {
        landed: false,
        message: `Build ${number} is uploaded, but its bump did not land on origin/main: \`${command} ${args.slice(0, 2).join(" ")}\` failed.\n`
          + `${String(result.stderr || result.stdout).trim()}\n`
          + `Land it before the next release (it fails at upload otherwise):\n${rest.join("\n")}`,
      };
    }
  }
  if (exec("git", ["diff", "--quiet", "HEAD", "origin/main"]).code === 0) exec("git", ["reset", "--keep", "origin/main"]);
  return { landed: true, message: `Build ${number} landed on origin/main through ${branch}.` };
}

/**
 * TKL-774: the upload consumes the build number, so the bump lands right after it, before
 * processing is polled; a poll error or timeout must not leave origin/main one build behind.
 * upload/poll are async and throw on failure; land returns landBumpCommit's { landed, message }.
 * Returns { buildId, landing, error }: landing is undefined only when the upload failed.
 */
export async function uploadLandPoll({ upload, land, poll }) {
  try {
    await upload();
  } catch (error) {
    return { buildId: undefined, landing: undefined, error: error.message };
  }
  let landing;
  try {
    landing = land();
  } catch (error) {
    landing = { landed: false, message: `The build is uploaded, but landing its bump threw: ${error.message}` };
  }
  try {
    return { buildId: await poll(), landing, error: undefined };
  } catch (error) {
    return { buildId: undefined, landing, error: error.message };
  }
}

/**
 * Every failure the run reports, and which of them stop the build bump, archive and upload.
 * Subscription and listing failures are App Store Connect metadata: they are reported and
 * fail the run, but never keep a TestFlight build from shipping (TKL-795).
 */
export function createFailures() {
  const all = [];
  const blocking = [];
  return {
    all,
    add(message, { blocksUpload = true } = {}) {
      all.push(message);
      if (blocksUpload) blocking.push(message);
    },
    blocksUpload: () => blocking.length > 0,
    get length() { return all.length; },
  };
}
