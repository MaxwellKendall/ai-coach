/** Pure pieces of `npm run release` (FIT-431). No network, no secrets printed. */

export const TERMS_LINE = "Terms of Use: https://barbrabell.com/terms";

export const EDITABLE_VERSION_STATES = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

/** States in which a subscription would go out with the next submission (FIT-386). */
export const ATTACHED_SUBSCRIPTION_STATES = new Set([
  "READY_TO_SUBMIT",
  "WAITING_FOR_REVIEW",
  "IN_REVIEW",
  "PENDING_BINARY_APPROVAL",
  "DEVELOPER_ACTION_NEEDED",
]);

const LIMITS = { description: 4000, promotional: 170, whatsNew: 4000, keywords: 100 };

export function parseArgs(argv) {
  const args = argv.filter((a) => a !== "--");
  return {
    dryRun: args.includes("--dry-run"),
    submit: args.includes("submit"),
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

/**
 * Subscriptions that would ride with this version. `onVersion` is set when a version relationship
 * points at one; review items are submission items whose relationship is a subscription or in-app purchase.
 */
export function subscriptionWarning(subscriptions, reviewItems) {
  const attached = subscriptions.filter((s) => s.onVersion || ATTACHED_SUBSCRIPTION_STATES.has(s.state));
  const viaReview = reviewItems.filter((item) => item.kind === "subscription" || item.kind === "inAppPurchase");
  const lines = [];
  if (attached.length || viaReview.length) {
    lines.push("Warning (FIT-386): version 1.0 must ship without Pro's subscriptions.");
    for (const sub of attached) lines.push(`- ${sub.name} (${sub.productId}) ${sub.onVersion ? "on the version" : sub.state}`);
    for (const item of viaReview) lines.push(`- review submission item ${item.id} is a ${item.kind}`);
    lines.push("Remove them from the version's In-App Purchases and Subscriptions before submitting.");
  }
  return { warn: lines.length > 0, lines, attached, viaReview };
}

export function videoHostingNote() {
  return [
    "Hosting: https://barbrabell.com/review/demo.mp4 is not a route yet.",
    "CloudFront serves files only at /cards/*, /exercises/*, and /app/* (infra/lib/stack.ts).",
    "Nothing in the repo uploads /review/, so this command does not deploy the video.",
    "The manual step, once a /review/* behavior exists, is in RELEASE.md.",
  ].join("\n");
}
