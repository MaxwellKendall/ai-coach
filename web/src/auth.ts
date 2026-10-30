// FIT-127: sign-in through the Cognito hosted UI (Google or Apple), as the app does, with PKCE: this is a public
// client, so there's no secret. Tokens stay in this browser's localStorage and refresh themselves for 30 days.

export type Config = {
  region: string;
  clientId: string;
  cognitoDomain: string;
  graphqlUrl: string;
  providers: string[];
  /** FIT-295: the App Store listing, once there is one; the web quiz links to it. */
  appStoreUrl?: string;
};

export type Provider = "google" | "apple";

type Tokens = { id: string; refresh: string; expiresAt: number };

const TOKENS = "aicoach.tokens";
const PENDING = "aicoach.signin";
/** FIT-137: while linking another sign-in, the account's own tokens wait here. */
const LINKING = "aicoach.linking";

const redirectUri = () => `${location.origin}${import.meta.env.BASE_URL}`;

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

/** FIT-137: sign in once more with the other provider, to link it to this account. */
export async function startLink(config: Config, provider: Provider) {
  const tokens = localStorage.getItem(TOKENS);
  if (!tokens) return;
  sessionStorage.setItem(LINKING, tokens);
  await signIn(config, provider);
}

/** On the way back from the provider: trades the code for tokens, and tidies the address bar. When linking, the new
 *  sign-in's ID token goes to linkAccount and the account's own tokens come back; returns what to say. */
export async function finishSignIn(config: Config): Promise<string | undefined> {
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
  const linking = sessionStorage.getItem(LINKING);
  if (!linking) {
    store({ id: t.id_token, refresh: t.refresh_token ?? "", expiresAt: Date.now() + t.expires_in * 1000 });
    return;
  }
  sessionStorage.removeItem(LINKING);
  // Back to the account's own tokens, then link; a refresh afterwards carries the new identity.
  const mine = JSON.parse(linking) as Tokens;
  store({ ...mine, expiresAt: 0 });
  const token = await idToken(config);
  if (!token) throw new Error("Sign in again to link.");
  const response = await fetch(config.graphqlUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: token },
    body: JSON.stringify({ query: "mutation($t: String!) { linkAccount(token: $t) }", variables: { t: t.id_token } }),
  });
  const json = await response.json();
  if (json.errors?.length) throw new Error(json.errors[0].message);
  store({ ...mine, expiresAt: 0 });
  return `${json.data.linkAccount === "google" ? "Google" : "Apple"} is linked. You can sign in with either.`;
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

export type User = { uid: string; name?: string; email?: string; provider?: Provider; linked: Provider[] };

export function user(token: string): User {
  const claims = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  // Cognito names federated users after their provider (as Account.Provider reads it in the app).
  const username: string = claims["cognito:username"] ?? "";
  const provider = username.startsWith("Google_") ? "google" : username.startsWith("SignInWithApple_") || username.startsWith("apple_") ? "apple" : undefined;
  // FIT-137: every sign-in on the account: the one it was made with, and any linked to it.
  const identities: { providerName: string }[] = typeof claims.identities === "string" ? JSON.parse(claims.identities) : claims.identities ?? [];
  const linked = new Set<Provider>(provider ? [provider] : []);
  for (const i of identities) linked.add(i.providerName === "Google" ? "google" : "apple");
  return { uid: claims.sub, name: claims.name, email: claims.email, provider, linked: [...linked] };
}
