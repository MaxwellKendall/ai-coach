// TKL-1003: the studio's standing test logins — the three accounts any ticket may use, with no approval
// (see "Test credentials" in the repo CLAUDE.md). They come from ~/dev/.secrets.env, so every worktree and
// either agent account reads the same ones, and the repo's own .env still wins. Values are never printed.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { loadSecrets } from "../../scripts/load-env.mjs";

export const ROLES = ["coach", "client", "lifter"] as const;
export type Role = (typeof ROLES)[number];
export type Account = { role: Role; email: string };
export type Credentials = { stage: string; password: string; accounts: Account[]; missing: string[] };

/** The variable holding one role's login, e.g. DEMO_COACH_EMAIL. */
export const variableFor = (role: Role) => `DEMO_${role.toUpperCase()}_EMAIL`;

export const HOW_TO_SET =
  "Set them in ~/dev/.secrets.env (shared by every run) or the repo's gitignored .env, then run this again.";

/** The standing logins in the environment, and the names of any that are not set. */
export function demoCredentials(env: Record<string, string | undefined> = process.env): Credentials {
  const accounts: Account[] = [];
  const missing: string[] = [];
  for (const role of ROLES) {
    // Cognito usernames here are the lowercase email, however the variable is written.
    const email = (env[variableFor(role)] ?? "").trim().toLowerCase();
    if (email) accounts.push({ role, email });
    else missing.push(variableFor(role));
  }
  const password = env.DEMO_PASSWORD ?? "";
  if (!password) missing.push("DEMO_PASSWORD");
  return { stage: env.DEMO_STAGE || "prod", password, accounts, missing };
}

/** Loads the shared secrets into the environment first, for a script run without sourcing them. */
export function loadDemoCredentials(env: Record<string, string | undefined> = process.env): Credentials {
  loadSecrets(fileURLToPath(new URL("../..", import.meta.url)), env);
  return demoCredentials(env);
}

export type PoolClient = { id: string; name: string; flows: string[] };
export type PasswordFlow = "USER_PASSWORD_AUTH" | "ADMIN_USER_PASSWORD_AUTH";

/**
 * A user pool client that can check a password. Prefers the plain flow (the MCP client has it on every stage);
 * falls back to the admin flow (dev's smoke-test client). Undefined when no client allows either.
 */
export function passwordClient(clients: PoolClient[]): { id: string; flow: PasswordFlow } | undefined {
  const user = clients.find((c) => c.flows.includes("ALLOW_USER_PASSWORD_AUTH"));
  if (user) return { id: user.id, flow: "USER_PASSWORD_AUTH" };
  const admin = clients.find((c) => c.flows.includes("ALLOW_ADMIN_USER_PASSWORD_AUTH"));
  return admin ? { id: admin.id, flow: "ADMIN_USER_PASSWORD_AUTH" } : undefined;
}

export type Step = "ok" | "wrong password" | "set the password" | "missing";

/** What to do about one account. Never creates one: coach-demo.ts and lifter-demo.ts own that, with the data. */
export function nextStep(state: { exists: boolean; signsIn: boolean }, fix: boolean): Step {
  if (!state.exists) return "missing";
  if (state.signsIn) return "ok";
  return fix ? "set the password" : "wrong password";
}

/** The lines of infra/.demo-accounts.STAGE with these passwords applied, keeping any other account's. */
export function mergedLines(existing: string, entries: [string, string][]) {
  const saved = new Map(
    existing
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((l) => l.split(" ") as [string, string]),
  );
  for (const [email, password] of entries) saved.set(email, password);
  return [...saved].map(([email, password]) => `${email} ${password}`).join("\n") + "\n";
}

/**
 * Keeps infra/.demo-accounts.STAGE honest, the file demoAccount.ts writes. Without this, that file would still
 * hold the password an earlier run made, and a ticket reading it would be told the wrong one.
 */
export function savePasswords(stage: string, entries: [string, string][]) {
  if (!entries.length) return;
  const file = new URL(`../.demo-accounts.${stage}`, import.meta.url);
  writeFileSync(file, mergedLines(existsSync(file) ? readFileSync(file, "utf8") : "", entries), { mode: 0o600 });
}
