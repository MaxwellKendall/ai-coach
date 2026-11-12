import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  assertListing,
  bumpBuildNumber,
  marketingVersion,
  parseArgs,
  redact,
  reviewNotes,
  subscriptionWarning,
  TERMS_LINE,
} from "./release-lib.mjs";

const yaml = readFileSync(new URL("../project.yml", import.meta.url), "utf8");

test("parseArgs accepts submit and --dry-run together", () => {
  assert.deepEqual(parseArgs(["--dry-run"]), { dryRun: true, submit: false, help: false });
  assert.deepEqual(parseArgs(["submit"]), { dryRun: false, submit: true, help: false });
  assert.deepEqual(parseArgs(["submit", "--dry-run"]), { dryRun: true, submit: true, help: false });
});

test("build number increments and the marketing version is readable", () => {
  const sample = `    MARKETING_VERSION: "1.0"\n    CURRENT_PROJECT_VERSION: "9"\n`;
  assert.equal(marketingVersion(sample), "1.0");
  const once = bumpBuildNumber(sample);
  assert.equal(once.from, "9");
  assert.equal(once.to, "10");
  assert.match(once.yaml, /CURRENT_PROJECT_VERSION: "10"/);
  assert.equal(marketingVersion(yaml), "1.0");
  assert.match(bumpBuildNumber(yaml).from, /^\d+$/);
});

test("listing files fit the App Store and end with the terms line", () => {
  const description = readFileSync(new URL("../appstore/metadata/description.txt", import.meta.url), "utf8").trim();
  const promotional = readFileSync(new URL("../appstore/metadata/promotional.txt", import.meta.url), "utf8").trim();
  const whatsNew = readFileSync(new URL("../appstore/metadata/whats-new.txt", import.meta.url), "utf8").trim();
  const keywords = readFileSync(new URL("../appstore/metadata/keywords.txt", import.meta.url), "utf8").trim();
  assertListing({ description, promotional, whatsNew, keywords });
  assert.equal(description.trimEnd().endsWith(TERMS_LINE), true);
});

test("review notes are filled from the caller and keep no placeholder", () => {
  const template = readFileSync(new URL("../appstore/metadata/review-notes.txt", import.meta.url), "utf8");
  const notes = reviewNotes(template, {
    VIDEO_URL: "https://barbrabell.com/review/demo.mp4",
    CLIENT_EMAIL: "client@example.com",
    CLIENT_PASSWORD: "secret-value",
    COACH_EMAIL: "coach@example.com",
    INVITE_CODES: "ABC234 (12d)",
  });
  assert.equal(notes.includes("{{"), false);
  assert.match(notes, /client@example.com/);
  assert.match(notes, /ABC234/);
});

test("redact removes a secret without touching the rest of the line", () => {
  assert.equal(redact("Password: secret-value\nok", ["secret-value"]), "Password: ••••\nok");
});

test("FIT-386 warns when a subscription is ready to submit or named on a review item", () => {
  const quiet = subscriptionWarning(
    [{ name: "Pro Annual", productId: "pro.yearly", state: "APPROVED", onVersion: false }],
    [{ id: "item-1", kind: "appStoreVersion" }],
  );
  assert.equal(quiet.warn, false);

  const ready = subscriptionWarning(
    [{ name: "Pro Monthly", productId: "pro.monthly", state: "READY_TO_SUBMIT", onVersion: false }],
    [],
  );
  assert.equal(ready.warn, true);
  assert.match(ready.lines[0], /FIT-386/);

  const onVersion = subscriptionWarning(
    [{ name: "Pro Annual", productId: "pro.yearly", state: "APPROVED", onVersion: true }],
    [],
  );
  assert.equal(onVersion.warn, true);
});

test("the committed demo secrets file has no password", () => {
  const source = readFileSync(new URL("../Tests/UITests/Secrets.swift", import.meta.url), "utf8");
  assert.match(source, /environment\["DEMO_PASSWORD"\]/);
  assert.equal(source.includes("base64"), false);
});
