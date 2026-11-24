// TKL-1003: the standing test logins come from the repo's own .env first, then the studio's shared
// ~/dev/.secrets.env, so a run in a fresh worktree (which has no .env) still signs in.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import { SHARED_SECRETS, loadSecrets } from "./load-env.mjs";

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "credentials-"));
  const shared = join(dir, "shared.env");
  writeFileSync(
    shared,
    "DEMO_COACH_EMAIL=coach@barbrabell.com\nDEMO_CLIENT_EMAIL=client@barbrabell.com\nDEMO_PASSWORD=from-shared\n",
  );
  return { dir, shared };
}

test("a worktree with no .env still gets the shared credentials", () => {
  const { dir, shared } = fixture();
  const env = {};
  loadSecrets(dir, env, shared);
  assert.equal(env.DEMO_COACH_EMAIL, "coach@barbrabell.com");
  assert.equal(env.DEMO_CLIENT_EMAIL, "client@barbrabell.com");
  assert.equal(env.DEMO_PASSWORD, "from-shared");
});

test("the repo's own .env wins over the shared file, key by key", () => {
  const { dir, shared } = fixture();
  writeFileSync(join(dir, ".env"), "DEMO_PASSWORD=from-repo\n");
  const env = {};
  loadSecrets(dir, env, shared);
  assert.equal(env.DEMO_PASSWORD, "from-repo");
  assert.equal(env.DEMO_COACH_EMAIL, "coach@barbrabell.com", "keys the repo .env omits still come from the shared file");
});

test("a variable already in the environment is never overwritten", () => {
  const { dir, shared } = fixture();
  const env = { DEMO_PASSWORD: "from-the-shell" };
  loadSecrets(dir, env, shared);
  assert.equal(env.DEMO_PASSWORD, "from-the-shell");
});

test("a missing shared file is not an error", () => {
  const { dir } = fixture();
  const env = {};
  loadSecrets(dir, env, join(dir, "nothing-here.env"));
  assert.deepEqual(env, {});
});

test("the shared file is the studio's documented one", () => {
  assert.equal(SHARED_SECRETS, resolve(process.env.HOME ?? "", "dev/.secrets.env"));
});
