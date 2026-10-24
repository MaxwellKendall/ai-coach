import { createHash, randomBytes } from "node:crypto";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { esc, layout, type Site } from "./sharePages.ts";

/**
 * FIT-151: sign-in for agents that connect to the MCP server, as the MCP authorization spec asks: protected-resource
 * metadata (RFC 9728), authorization-server metadata (RFC 8414), dynamic client registration (RFC 7591), and the
 * authorization code flow with PKCE (S256 only) and rotating refresh tokens. Cognito can't register clients, so this
 * is the authorization server, and the person signs in through Cognito's hosted UI with Apple or Google, as in the
 * app; a first sign-in makes the account. Access tokens are MCPTOKEN items, as the FIT-149 links are, with an expiry.
 */

export interface AuthStore {
  /** The partition key is `key`, the sort key its first segment (MCPTOKEN#… → MCPTOKEN). */
  put(key: string, item: Record<string, any>, seconds?: number): Promise<void>;
  get(key: string): Promise<Record<string, any> | undefined>;
  /** Reads and deletes, so a code or refresh token works once. */
  take(key: string): Promise<Record<string, any> | undefined>;
}

export interface Config {
  /** The issuer, e.g. https://dev.barbrabell.com; the MCP endpoint is {origin}/mcp. */
  origin: string;
  site: Site;
  providers: string[];
  /** Cognito's hosted UI, for the person's sign-in. */
  authorizeUrl(params: Record<string, string>): string;
  /** Trades Cognito's code for the Cognito user it signed in. */
  exchange(code: string, verifier: string, redirectUri: string): Promise<{ uid: string }>;
  /** FIT-236: an email and password checked with Cognito, for accounts made with one (App Review's and the directory's
   * reviewers); undefined when they don't match. Without it the page offers only Apple and Google. */
  passwordSignIn?(email: string, password: string): Promise<{ uid: string } | undefined>;
}

export const ACCESS_SECONDS = 3600;
export const REFRESH_DAYS = 90;

const hash = (s: string) => createHash("sha256").update(s).digest("hex");
const random = () => randomBytes(32).toString("base64url");
export const s256 = (verifier: string) => createHash("sha256").update(verifier).digest("base64url");

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "Authorization, Content-Type, Mcp-Protocol-Version", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (statusCode: number, body: unknown): LambdaFunctionURLResult =>
  ({ statusCode, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...cors }, body: JSON.stringify(body) });
const fail = (error: string, description: string, statusCode = 400) => json(statusCode, { error, error_description: description });
const redirect = (location: string): LambdaFunctionURLResult => ({ statusCode: 302, headers: { Location: location, "Cache-Control": "no-store" }, body: "" });
const page = (statusCode: number, body: string): LambdaFunctionURLResult =>
  ({ statusCode, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" }, body });

export const resourceMetadataUrl = (origin: string) => `${origin}/.well-known/oauth-protected-resource/mcp`;

/** What the MCP endpoint answers without a token: where to sign in. */
export const unauthorized = (origin: string): LambdaFunctionURLResult => ({
  statusCode: 401,
  headers: { "Content-Type": "application/json", "WWW-Authenticate": `Bearer resource_metadata="${resourceMetadataUrl(origin)}"`, ...cors },
  body: JSON.stringify({ error: "invalid_token", error_description: "Sign in to connect." }),
});

/** Claude, ChatGPT and local clients: https, or http only to this machine. */
function allowedRedirect(uri: unknown) {
  if (typeof uri !== "string") return false;
  try {
    const url = new URL(uri);
    if (url.hash) return false;
    if (url.protocol === "https:") return true;
    return url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  } catch {
    return false;
  }
}

function body(event: LambdaFunctionURLEvent) {
  return event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString() : (event.body ?? "");
}

function messagePage(config: Config, title: string, text: string) {
  return layout(config.site, {
    title, description: config.site.appName, path: "/oauth/authorize",
    body: `<section class="hero"><h1>${esc(title)}</h1><p class="lede">${esc(text)}</p></section>`,
  });
}

const PROVIDERS: Record<string, { label: string; cognito: string }> = {
  apple: { label: "Continue with Apple", cognito: "SignInWithApple" },
  google: { label: "Continue with Google", cognito: "Google" },
};

function consentPage(config: Config, request: string, client: string, returnHost: string, emailError?: string) {
  const buttons = config.providers.filter((p) => PROVIDERS[p]).map((p, i) =>
    `<a class="button${i === 0 ? " primary" : ""}" data-signin href="/oauth/start?request=${request}&amp;provider=${p}">${PROVIDERS[p].label}</a>`).join("");
  return layout(config.site, {
    title: `Connect ${client}`,
    description: `Connect ${client} to ${config.site.appName}.`,
    path: "/oauth/authorize",
    body: `<section class="hero">
      <h1>Connect ${esc(client)} to your training</h1>
      <p class="lede">${esc(client)} will read your goals, plan and logged workouts, log sessions for you, and change your plan when you agree.</p>
      <div class="actions">${buttons || `<p class="fine">Sign-in isn't set up on this server yet.</p>`}</div>
      ${config.passwordSignIn ? emailForm(request, emailError) : ""}
      <p class="fine">Then you're back at ${esc(returnHost)}. New here? Signing in makes your account; ask ${esc(client)} to set you up.</p>
      <p class="fine">By continuing you agree to the <a href="/terms">terms</a> and <a href="/privacy">privacy policy</a>.</p>
    </section>
    <script>
      // The account's days follow this browser's time zone.
      const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
      for (const a of document.querySelectorAll("[data-signin]")) a.href += "&tz=" + encodeURIComponent(tz);
      for (const i of document.querySelectorAll("[data-tz]")) i.value = tz;
    </script>`,
  });
}

/** FIT-236: for an account made with an email and password; Apple and Google stay the way in for everyone else. */
function emailForm(request: string, error?: string) {
  return `<details class="email"${error ? " open" : ""}>
        <summary>Sign in with email</summary>
        <form method="post" action="/oauth/email">
          <input type="hidden" name="request" value="${request}">
          <input type="hidden" name="tz" value="UTC" data-tz>
          <label>Email <input type="email" name="email" autocomplete="username" required></label>
          <label>Password <input type="password" name="password" autocomplete="current-password" required></label>
          ${error ? `<p class="error" role="alert">${esc(error)}</p>` : ""}
          <button class="button" type="submit">Sign in</button>
        </form>
      </details>`;
}

const zone = (tz: string | null) => {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz ?? "UTC" });
    return tz ?? "UTC";
  } catch {
    return "UTC";
  }
};

/** The person signed in: a one-time code for the agent, sent back to its redirect URI. */
async function signedIn(store: AuthStore, origin: string, request: Record<string, any>, uid: string) {
  const back = new URL(request.redirect_uri);
  if (request.state) back.searchParams.set("state", request.state);
  back.searchParams.set("iss", origin);
  const ours = random();
  await store.put(`OAUTH#code#${hash(ours)}`, {
    uid, tz: request.tz, agent: request.client_name, client_id: request.client_id, redirect_uri: request.redirect_uri, code_challenge: request.code_challenge,
  }, 5 * 60);
  back.searchParams.set("code", ours);
  return redirect(back.toString());
}

async function issue(store: AuthStore, grant: { uid: string; tz: string; agent: string; client_id: string }) {
  const access = random();
  const refresh = random();
  await store.put(`MCPTOKEN#${hash(access)}`, { ...grant, kind: "oauth" }, ACCESS_SECONDS);
  await store.put(`OAUTH#refresh#${hash(refresh)}`, grant, REFRESH_DAYS * 86_400);
  return json(200, { access_token: access, token_type: "Bearer", expires_in: ACCESS_SECONDS, refresh_token: refresh, scope: "training" });
}

/** The OAuth routes, or undefined for a path that isn't one. */
export async function oauth(event: LambdaFunctionURLEvent, store: AuthStore, config: Config): Promise<LambdaFunctionURLResult | undefined> {
  const path = event.rawPath;
  const method = event.requestContext.http.method;
  const query = new URLSearchParams(event.rawQueryString ?? "");
  const { origin } = config;
  if (!path.startsWith("/oauth/") && !path.startsWith("/.well-known/oauth-")) return undefined;
  if (method === "OPTIONS") return { statusCode: 204, headers: cors, body: "" };

  if (path.startsWith("/.well-known/oauth-protected-resource")) {
    return json(200, { resource: `${origin}/mcp`, authorization_servers: [origin], bearer_methods_supported: ["header"], scopes_supported: ["training"] });
  }
  if (path.startsWith("/.well-known/oauth-authorization-server")) {
    return json(200, {
      issuer: origin,
      authorization_endpoint: `${origin}/oauth/authorize`,
      token_endpoint: `${origin}/oauth/token`,
      registration_endpoint: `${origin}/oauth/register`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: ["training"],
    });
  }

  if (path === "/oauth/register" && method === "POST") {
    let asked: any;
    try {
      asked = JSON.parse(body(event));
    } catch {
      return fail("invalid_client_metadata", "The body is JSON.");
    }
    const uris = asked?.redirect_uris;
    if (!Array.isArray(uris) || !uris.length || uris.length > 10 || !uris.every(allowedRedirect)) {
      return fail("invalid_redirect_uri", "Give https redirect URIs (or http on localhost).");
    }
    const name = typeof asked.client_name === "string" && asked.client_name.trim() ? asked.client_name.trim().slice(0, 60) : "Your agent";
    const id = random();
    await store.put(`OAUTHCLIENT#${id}`, { client_name: name, redirect_uris: uris, createdAt: new Date().toISOString() });
    return json(201, {
      client_id: id, client_id_issued_at: Math.floor(Date.now() / 1000), client_name: name, redirect_uris: uris,
      grant_types: ["authorization_code", "refresh_token"], response_types: ["code"], token_endpoint_auth_method: "none",
    });
  }

  if (path === "/oauth/authorize" && method === "GET") {
    const clientId = query.get("client_id") ?? "";
    const redirectUri = query.get("redirect_uri") ?? "";
    const client = clientId ? await store.get(`OAUTHCLIENT#${clientId}`) : undefined;
    // Without a known client and one of its redirect URIs, there's nowhere safe to send an error back to.
    if (!client || !(client.redirect_uris as string[]).includes(redirectUri)) {
      return page(400, messagePage(config, "This link can't connect", "Start again from your agent's connector settings."));
    }
    const back = (error: string, description: string) => {
      const url = new URL(redirectUri);
      url.searchParams.set("error", error);
      url.searchParams.set("error_description", description);
      if (query.get("state")) url.searchParams.set("state", query.get("state")!);
      return redirect(url.toString());
    };
    if (query.get("response_type") !== "code") return back("unsupported_response_type", "Only code.");
    const challenge = query.get("code_challenge") ?? "";
    if (!/^[A-Za-z0-9_-]{43}$/.test(challenge) || query.get("code_challenge_method") !== "S256") return back("invalid_request", "PKCE with S256 is required.");
    const request = random();
    await store.put(`OAUTH#request#${request}`, {
      client_id: clientId, client_name: client.client_name, redirect_uri: redirectUri, state: query.get("state") ?? "", code_challenge: challenge,
    }, 15 * 60);
    return page(200, consentPage(config, request, client.client_name, new URL(redirectUri).host));
  }

  if (path === "/oauth/start" && method === "GET") {
    const id = query.get("request") ?? "";
    const request = /^[A-Za-z0-9_-]{43}$/.test(id) ? await store.get(`OAUTH#request#${id}`) : undefined;
    const provider = PROVIDERS[query.get("provider") ?? ""];
    if (!request || !provider) return page(400, messagePage(config, "This sign-in has expired", "Start again from your agent's connector settings."));
    const verifier = random();
    await store.put(`OAUTH#request#${id}`, { ...request, tz: zone(query.get("tz")), verifier }, 15 * 60);
    return redirect(config.authorizeUrl({
      response_type: "code", redirect_uri: `${origin}/oauth/callback`, scope: "openid email profile", identity_provider: provider.cognito,
      code_challenge: s256(verifier), code_challenge_method: "S256", state: id,
    }));
  }

  if (path === "/oauth/callback" && method === "GET") {
    const id = query.get("state") ?? "";
    const request = /^[A-Za-z0-9_-]{43}$/.test(id) ? await store.take(`OAUTH#request#${id}`) : undefined;
    if (!request?.verifier) return page(400, messagePage(config, "This sign-in has expired", "Start again from your agent's connector settings."));
    const code = query.get("code");
    if (!code) {
      const back = new URL(request.redirect_uri);
      if (request.state) back.searchParams.set("state", request.state);
      back.searchParams.set("iss", origin);
      back.searchParams.set("error", "access_denied");
      return redirect(back.toString());
    }
    const { uid } = await config.exchange(code, request.verifier, `${origin}/oauth/callback`);
    return signedIn(store, origin, request, uid);
  }

  if (path === "/oauth/email" && method === "POST" && config.passwordSignIn) {
    const form = new URLSearchParams(body(event));
    const id = form.get("request") ?? "";
    const request = /^[A-Za-z0-9_-]{43}$/.test(id) ? await store.get(`OAUTH#request#${id}`) : undefined;
    if (!request) return page(400, messagePage(config, "This sign-in has expired", "Start again from your agent's connector settings."));
    const account = await config.passwordSignIn((form.get("email") ?? "").trim().toLowerCase(), form.get("password") ?? "");
    if (!account) {
      return page(401, consentPage(config, id, request.client_name, new URL(request.redirect_uri).host, "That email and password don't match an account."));
    }
    await store.take(`OAUTH#request#${id}`);
    return signedIn(store, origin, { ...request, tz: zone(form.get("tz")) }, account.uid);
  }

  if (path === "/oauth/token" && method === "POST") {
    const form = new URLSearchParams(body(event));
    const grantType = form.get("grant_type");
    const clientId = form.get("client_id");
    if (grantType === "authorization_code") {
      const code = await store.take(`OAUTH#code#${hash(form.get("code") ?? "")}`);
      if (!code || (clientId && clientId !== code.client_id)) return fail("invalid_grant", "Unknown or used code.");
      if (form.get("redirect_uri") && form.get("redirect_uri") !== code.redirect_uri) return fail("invalid_grant", "redirect_uri doesn't match.");
      if (s256(form.get("code_verifier") ?? "") !== code.code_challenge) return fail("invalid_grant", "code_verifier doesn't match.");
      return issue(store, { uid: code.uid, tz: code.tz, agent: code.agent, client_id: code.client_id });
    }
    if (grantType === "refresh_token") {
      const grant = await store.take(`OAUTH#refresh#${hash(form.get("refresh_token") ?? "")}`);
      if (!grant || (clientId && clientId !== grant.client_id)) return fail("invalid_grant", "Unknown or used refresh token; sign in again.");
      return issue(store, { uid: grant.uid, tz: grant.tz, agent: grant.agent, client_id: grant.client_id });
    }
    return fail("unsupported_grant_type", "authorization_code or refresh_token.");
  }

  return json(404, { error: "not_found" });
}
