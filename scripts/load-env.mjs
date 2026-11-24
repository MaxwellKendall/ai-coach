import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

/** Load KEY=VALUE lines from a gitignored .env. Does not override variables already set, and never prints values. */
export function loadEnv(path = resolve(".env"), env = process.env) {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const body = trimmed.startsWith("export ") ? trimmed.slice(7).trim() : trimmed;
    const eq = body.indexOf("=");
    if (eq < 1) continue;
    const key = body.slice(0, eq).trim();
    let value = body.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (env[key] === undefined) env[key] = value;
  }
}

/** TKL-1003: the studio's shared secrets, readable from every worktree and either agent account (see ~/dev/CLAUDE.md). */
export const SHARED_SECRETS = resolve(homedir(), "dev/.secrets.env");

/**
 * Loads the gitignored repo `.env`, then the shared secrets, so a run in a fresh worktree (which has no `.env`)
 * still has the standing test logins. The repo's own `.env` wins key by key, and a variable already in the
 * environment wins over both. Never prints values.
 */
export function loadSecrets(root = process.cwd(), env = process.env, shared = SHARED_SECRETS) {
  loadEnv(resolve(root, ".env"), env);
  loadEnv(shared, env);
}
