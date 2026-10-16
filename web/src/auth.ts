// FIT-127: sign-in through the Cognito hosted UI (Google or Apple), as the app does, with PKCE: this is a public
// client, so there's no secret. Tokens stay in this browser's localStorage and refresh themselves for 30 days.

export type Config = {
  region: string;
  clientId: string;
  cognitoDomain: string;
  graphqlUrl: string;
  providers: string[];
};

export type Provider = "google" | "apple";

type Tokens = { id: string; refresh: string; expiresAt: number };

const TOKENS = "aicoach.tokens";
const PENDING = "aicoach.signin";

const redirectUri = () => `${location.origin}/`;

function base64url(bytes: Uint8Array) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function random() {
  return base64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function challenge(verifier: string) {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

/** Leaves for the provider's sign-in; it comes back to this page with a code. */
export async function signIn(config: Config, provider: Provider) {
  const verifier = random();
  const state = random();
  sessionStorage.setItem(PENDING, JSON.stringify({ verifier, state }));
  const params = new URLSearchParams({
    response_type: "code",
    client_id: config.clientId,
    redirect_uri: redirectUri(),
    scope: "openid email profile",
    identity_provider: provider === "google" ? "Google" : "SignInWithApple",
    code_challenge: await challenge(verifier),
    code_challenge_method: "S256",
    state,
  });
  location.assign(`https://${config.cognitoDomain}/oauth2/authorize?${params}`);
}

async function tokenRequest(config: Config, body: Record<string, string>) {
  const response = await fetch(`https://${config.cognitoDomain}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: config.clientId, ...body }),
  });
  if (!response.ok) throw new Error(`Sign-in failed (${response.status})`);
  return (await response.json()) as { id_token: string; refresh_token?: string; expires_in: number };
}

function store(tokens: Tokens) {
  localStorage.setItem(TOKENS, JSON.stringify(tokens));
}

function stored(): Tokens | null {
  try {
    return JSON.parse(localStorage.getItem(TOKENS) ?? "null");
  } catch {
    return null;
  }
}

/** On the way back from the provider: trades the code for tokens, and tidies the address bar. */
export async function finishSignIn(config: Config) {
  const query = new URLSearchParams(location.search);
  const code = query.get("code");
  if (!code) return;
  const pending = JSON.parse(sessionStorage.getItem(PENDING) ?? "null");
  sessionStorage.removeItem(PENDING);
  history.replaceState(null, "", "/");
  if (!pending || pending.state !== query.get("state")) throw new Error("Sign-in didn't finish. Try again.");
  const t = await tokenRequest(config, {
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri(),
    code_verifier: pending.verifier,
  });
  store({ id: t.id_token, refresh: t.refresh_token ?? "", expiresAt: Date.now() + t.expires_in * 1000 });
}

/** A current ID token, refreshed when it's about to expire; null when signed out. */
export async function idToken(config: Config): Promise<string | null> {
  const tokens = stored();
  if (!tokens) return null;
  if (tokens.expiresAt - 60_000 > Date.now()) return tokens.id;
  try {
    const t = await tokenRequest(config, { grant_type: "refresh_token", refresh_token: tokens.refresh });
    store({ ...tokens, id: t.id_token, expiresAt: Date.now() + t.expires_in * 1000 });
    return t.id_token;
  } catch {
    localStorage.removeItem(TOKENS);
    return null;
  }
}

export function signOut(config: Config) {
  localStorage.removeItem(TOKENS);
  const params = new URLSearchParams({ client_id: config.clientId, logout_uri: redirectUri() });
  location.assign(`https://${config.cognitoDomain}/logout?${params}`);
}

export type User = { uid: string; name?: string; email?: string; provider?: Provider };

export function user(token: string): User {
  const claims = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  // Cognito names federated users after their provider (as Account.Provider reads it in the app).
  const username: string = claims["cognito:username"] ?? "";
  const provider = username.startsWith("Google_") ? "google" : username.startsWith("SignInWithApple_") ? "apple" : undefined;
  return { uid: claims.sub, name: claims.name, email: claims.email, provider };
}
