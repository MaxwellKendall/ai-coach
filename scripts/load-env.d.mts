// Types for load-env.mjs, so infra's TypeScript can share the one env loader (TKL-1003).
type Env = Record<string, string | undefined>;

/** Load KEY=VALUE lines from a gitignored .env. Does not override variables already set, and never prints values. */
export declare function loadEnv(path?: string, env?: Env): void;

/** The studio's shared secrets file: ~/dev/.secrets.env. */
export declare const SHARED_SECRETS: string;

/** Load the repo's .env, then the shared secrets. The repo's .env wins; a variable already set wins over both. */
export declare function loadSecrets(root?: string, env?: Env, shared?: string): void;
