import type { LambdaFunctionURLEvent } from "aws-lambda";
import { describe, expect, it } from "vitest";
import { hashToken, serve, type Account, type Store } from "../lambda/mcp.ts";
import { oauth, s256, type AuthStore, type Config } from "../lambda/oauth.ts";

const origin = "https://dev.example.com";
const claude = "https://claude.ai/api/mcp/auth_callback";

function memoryAuth() {
  const items = new Map<string, Record<string, any>>();
  const store: AuthStore = {
    async put(key, item) { items.set(key, item); },
    async get(key) { return items.get(key); },
    async take(key) { const item = items.get(key); items.delete(key); return item; },
  };
  return { store, items };
}

const exchanged: { code: string; verifier: string }[] = [];
const config: Config = {
  origin,
  site: { appName: "Rep & Recipe", origin, appId: "" },
  providers: ["apple", "google"],
  authorizeUrl: (params) => `https://cognito.example/oauth2/authorize?${new URLSearchParams(params)}`,
  async exchange(code, verifier) { exchanged.push({ code, verifier }); return { uid: "new-user" }; },
};

const request = (method: string, path: string, opts: { query?: Record<string, string>; body?: string; headers?: Record<string, string> } = {}) => ({
  rawPath: path, rawQueryString: new URLSearchParams(opts.query ?? {}).toString(), body: opts.body ?? "", isBase64Encoded: false,
  headers: opts.headers ?? {}, requestContext: { http: { method } },
}) as unknown as LambdaFunctionURLEvent;

const run = async (event: LambdaFunctionURLEvent, store: AuthStore) => (await oauth(event, store, config)) as any;
const form = (fields: Record<string, string>) => new URLSearchParams(fields).toString();
const location = (r: any) => new URL(r.headers.Location);

describe("OAuth for agents (FIT-151)", () => {
  it("points agents from the MCP endpoint to its metadata, then to the authorization server", async () => {
    const accounts: Store = { account: async () => undefined } as unknown as Store;
    const denied: any = await serve(request("POST", "/mcp", { body: "{}" }), accounts, origin);
    expect(denied.statusCode).toBe(401);
    expect(denied.headers["WWW-Authenticate"]).toBe(`Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp"`);
    const { store } = memoryAuth();
    const resource = JSON.parse((await run(request("GET", "/.well-known/oauth-protected-resource/mcp"), store))!.body!);
    expect(resource).toMatchObject({ resource: `${origin}/mcp`, authorization_servers: [origin] });
    const server = JSON.parse((await run(request("GET", "/.well-known/oauth-authorization-server"), store))!.body!);
    expect(server).toMatchObject({ issuer: origin, registration_endpoint: `${origin}/oauth/register`, code_challenge_methods_supported: ["S256"] });
    expect(await run(request("POST", "/mcp"), store)).toBeUndefined();
  });

  it("registers a client, signs a new person in through Cognito, and gives the agent tokens for that account", async () => {
    const { store, items } = memoryAuth();
    const registered: any = await run(request("POST", "/oauth/register", { body: JSON.stringify({ client_name: "Claude", redirect_uris: [claude] }) }), store);
    expect(registered.statusCode).toBe(201);
    const { client_id } = JSON.parse(registered.body);

    const verifier = "v".repeat(50);
    const consent: any = await run(request("GET", "/oauth/authorize", { query: {
      response_type: "code", client_id, redirect_uri: claude, code_challenge: s256(verifier), code_challenge_method: "S256", state: "claude-state",
    } }), store);
    expect(consent.statusCode).toBe(200);
    expect(consent.body).toContain("Connect Claude to your training");
    expect(consent.body).toContain("claude.ai");
    const start = /href="(\/oauth\/start\?[^"]+)"/.exec(consent.body)![1].replace(/&amp;/g, "&");
    expect(start).toContain("provider=apple");

    const startQuery = Object.fromEntries(new URL(start, origin).searchParams);
    const toCognito = location(await run(request("GET", "/oauth/start", { query: { ...startQuery, tz: "Europe/Berlin" } }), store));
    expect(toCognito.searchParams.get("identity_provider")).toBe("SignInWithApple");
    expect(toCognito.searchParams.get("redirect_uri")).toBe(`${origin}/oauth/callback`);

    const back = location(await run(request("GET", "/oauth/callback", { query: { code: "cognito-code", state: toCognito.searchParams.get("state")! } }), store));
    expect(s256(exchanged.at(-1)!.verifier)).toBe(toCognito.searchParams.get("code_challenge"));
    expect(`${back.origin}${back.pathname}`).toBe(claude);
    expect(back.searchParams.get("state")).toBe("claude-state");
    const code = back.searchParams.get("code")!;

    const wrong: any = await run(request("POST", "/oauth/token", { body: form({ grant_type: "authorization_code", code, client_id, code_verifier: "w".repeat(50) }) }), store);
    expect(wrong.statusCode).toBe(400); // and the code is spent
    const again = await run(request("GET", "/oauth/callback", { query: { code: "cognito-code", state: toCognito.searchParams.get("state")! } }), store);
    expect(again!.statusCode).toBe(400); // the sign-in, too

    // Start over to get a good code.
    const consent2: any = await run(request("GET", "/oauth/authorize", { query: {
      response_type: "code", client_id, redirect_uri: claude, code_challenge: s256(verifier), code_challenge_method: "S256", state: "s2",
    } }), store);
    const start2 = new URL(/href="(\/oauth\/start\?[^"]+)"/.exec(consent2.body)![1].replace(/&amp;/g, "&"), origin);
    start2.searchParams.set("tz", "Europe/Berlin");
    const cognito2 = location(await run(request("GET", "/oauth/start", { query: Object.fromEntries(start2.searchParams) }), store));
    const code2 = location(await run(request("GET", "/oauth/callback", { query: { code: "c2", state: cognito2.searchParams.get("state")! } }), store)).searchParams.get("code")!;
    const tokens = JSON.parse((await run(request("POST", "/oauth/token", { body: form({ grant_type: "authorization_code", code: code2, client_id, redirect_uri: claude, code_verifier: verifier }) }), store))!.body!);
    expect(tokens).toMatchObject({ token_type: "Bearer", expires_in: 3600 });

    // The access token is the account's MCP connection, in the browser's time zone, named for the client.
    const grant = items.get(`MCPTOKEN#${hashToken(tokens.access_token)}`);
    expect(grant).toMatchObject({ uid: "new-user", tz: "Europe/Berlin", agent: "Claude" });
    const mcpStore = { account: async (h: string) => (h === hashToken(tokens.access_token) ? (grant as Account) : undefined) } as unknown as Store;
    const ping: any = await serve(request("POST", "/mcp", { body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }), headers: { authorization: `Bearer ${tokens.access_token}` } }), mcpStore, origin);
    expect(ping.statusCode).toBe(200);

    // Refresh tokens rotate: each works once.
    const refreshed = JSON.parse((await run(request("POST", "/oauth/token", { body: form({ grant_type: "refresh_token", refresh_token: tokens.refresh_token, client_id }) }), store))!.body!);
    expect(refreshed.access_token).not.toBe(tokens.access_token);
    const reused: any = await run(request("POST", "/oauth/token", { body: form({ grant_type: "refresh_token", refresh_token: tokens.refresh_token, client_id }) }), store);
    expect(JSON.parse(reused.body).error).toBe("invalid_grant");
  });

  it("refuses redirects it can't trust and authorization without PKCE", async () => {
    const { store } = memoryAuth();
    const bad: any = await run(request("POST", "/oauth/register", { body: JSON.stringify({ redirect_uris: ["http://evil.example/cb"] }) }), store);
    expect(bad.statusCode).toBe(400);
    const { client_id } = JSON.parse((await run(request("POST", "/oauth/register", { body: JSON.stringify({ redirect_uris: [claude, "http://localhost:3000/cb"] }) }), store))!.body!);
    const elsewhere = await run(request("GET", "/oauth/authorize", { query: { response_type: "code", client_id, redirect_uri: "https://evil.example/cb", code_challenge: s256("x".repeat(50)), code_challenge_method: "S256" } }), store);
    expect(elsewhere!.statusCode).toBe(400); // a page, not a redirect
    const plain = location(await run(request("GET", "/oauth/authorize", { query: { response_type: "code", client_id, redirect_uri: claude, code_challenge: "abc", code_challenge_method: "plain", state: "s" } }), store));
    expect(plain.searchParams.get("error")).toBe("invalid_request");
    expect(plain.searchParams.get("state")).toBe("s");
  });

  it("keeps FIT-149's links working, and tells a bad link apart from a missing sign-in", async () => {
    const token = "t".repeat(43);
    const me: Account = { uid: "me", tz: "UTC", agent: "claude" };
    const store = { account: async (h: string) => (h === hashToken(token) ? me : undefined) } as unknown as Store;
    const ping = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" });
    expect(((await serve(request("POST", `/mcp/${token}`, { body: ping }), store, origin)) as any).statusCode).toBe(200);
    const badLink: any = await serve(request("POST", `/mcp/${"u".repeat(43)}`, { body: ping }), store, origin);
    expect(badLink.statusCode).toBe(401);
    expect(badLink.headers["WWW-Authenticate"]).toBeUndefined();
    const expired: any = await serve(request("POST", "/mcp", { body: ping, headers: { authorization: `Bearer ${"e".repeat(43)}` } }), store, origin);
    expect(expired.headers["WWW-Authenticate"]).toContain("resource_metadata");
  });
});
