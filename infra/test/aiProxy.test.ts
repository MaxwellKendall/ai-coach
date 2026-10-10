import { describe, expect, it } from "vitest";
import { allowedRequest, day, limits } from "../lambda/aiProxy.ts";

/** FIT-102: what the AI proxy lets through to Claude. */
describe("aiProxy: the request it sends on", () => {
  const request = { model: "claude-haiku-5-5", max_tokens: 8_000, system: "You coach.", messages: [{ role: "user", content: "Hi" }], tools: [{ name: "answer" }] };

  it("keeps only what the Messages API needs from the app", () => {
    const allowed = allowedRequest(JSON.stringify({ ...request, metadata: { user_id: "x" }, thinking: { type: "enabled", budget_tokens: 9000 } }));
    expect(allowed).toEqual({ body: request });
  });

  it("allows Haiku only", () => {
    expect(allowedRequest(JSON.stringify({ ...request, model: "claude-opus-5-5" }))).toEqual({ error: "Only claude-haiku-5-5 is available." });
  });

  it("caps the answer's length", () => {
    const allowed = allowedRequest(JSON.stringify({ ...request, max_tokens: 64_000 }));
    expect("body" in allowed && allowed.body.max_tokens).toBe(limits.maxTokens);
  });

  it("takes the request AppSync has already parsed", () => {
    expect(allowedRequest(request)).toEqual(allowedRequest(JSON.stringify(request)));
    expect("body" in allowedRequest(request)).toBe(true);
  });

  it("refuses a request that's too long, isn't JSON, or has no messages", () => {
    const long = [{ role: "user", content: "x".repeat(limits.maxRequestChars) }];
    expect(allowedRequest(JSON.stringify({ ...request, messages: long }))).toEqual({ error: "The request is too long." });
    expect(allowedRequest("{nope")).toEqual({ error: "The request isn't JSON." });
    expect(allowedRequest(JSON.stringify({ ...request, messages: [] }))).toEqual({ error: "The request has no messages." });
  });

  it("counts each user's requests by UTC day", () => {
    expect(day(new Date("2026-10-10T23:59:00Z"))).toBe("2026-10-10");
    expect(day(new Date("2026-10-11T00:00:00Z"))).toBe("2026-10-11");
  });
});
