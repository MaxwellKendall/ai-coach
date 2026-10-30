import { generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { appleSubject, define, verifyChallenge } from "../lambda/appleAuth.ts";
import { checkAppleToken, sha256, type AppleKey } from "../lambda/appleToken.ts";

const now = new Date("2026-10-16T12:00:00Z");
const seconds = now.getTime() / 1000;
const pair = () => generateKeyPairSync("rsa", { modulusLength: 2048 });
const apple = pair();
const keys: AppleKey[] = [{ ...apple.publicKey.export({ format: "jwk" }), kid: "K1" }];
const nonce = "raw-nonce-from-the-app";

function token(claims: Record<string, unknown> = {}, { kid = "K1", alg = "RS256", key = apple.privateKey } = {}) {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = enc({ alg, kid });
  const body = enc({
    iss: "https://appleid.apple.com",
    aud: "com.maxwellkendall.aicoach",
    sub: "001877.abc.1234",
    email: "x@privaterelay.appleid.com",
    iat: seconds - 5,
    exp: seconds + 600,
    nonce: sha256(nonce),
    ...claims,
  });
  return `${head}.${body}.${sign("RSA-SHA256", Buffer.from(`${head}.${body}`), key).toString("base64url")}`;
}

const why = (t: string, n = nonce) => {
  const r = checkAppleToken(t, n, keys, now);
  return r.ok ? "ok" : r.why;
};

describe("Apple's identity token (FIT-138)", () => {
  it("accepts a good one and reads the user", () => {
    expect(checkAppleToken(token(), nonce, keys, now)).toEqual({ ok: true, claims: { sub: "001877.abc.1234", email: "x@privaterelay.appleid.com" } });
  });
  it("refuses another app's", () => expect(why(token({ aud: "com.someone.else" }))).toBe("audience"));
  it("FIT-295: refuses the retired consumer app's", () =>
    expect(why(token({ aud: "com.maxwellkendall.liftplan" }))).toBe("audience"));
  it("refuses one not from Apple", () => expect(why(token({ iss: "https://evil.example" }))).toBe("issuer"));
  it("refuses an expired one", () => expect(why(token({ exp: seconds - 1 }))).toBe("expired"));
  it("refuses one issued too long ago", () => expect(why(token({ iat: seconds - 11 * 60 }))).toBe("too old"));
  it("refuses one signed by another key", () => expect(why(token({}, { key: pair().privateKey }))).toBe("signature"));
  it("refuses one whose claims were edited", () => {
    const [h, , s] = token().split(".");
    const edited = Buffer.from(JSON.stringify({ sub: "someone.else" })).toString("base64url");
    expect(why(`${h}.${edited}.${s}`)).toBe("signature");
  });
  it("refuses a key Apple doesn't publish", () => expect(why(token({}, { kid: "K9" }))).toBe("unknown key"));
  it("refuses alg none", () => expect(why(token({}, { alg: "none" }))).toBe("algorithm"));
  it("refuses a nonce that doesn't match", () => expect(why(token(), "another-nonce")).toBe("nonce"));
  it("refuses the hashed nonce sent back as is", () => expect(why(token(), sha256(nonce))).toBe("nonce"));
  it("refuses a token without a nonce", () => expect(why(token({ nonce: undefined }))).toBe("nonce"));
  it("refuses junk", () => {
    expect(why("not.a.jwt")).toBe("not JSON");
    expect(why("")).toBe("not a JWT");
  });
});

describe("custom auth (FIT-138)", () => {
  it("knows the Apple user behind native and federated usernames", () => {
    expect(appleSubject("apple_001877.abc.1234")).toBe("001877.abc.1234");
    expect(appleSubject("SignInWithApple_001877.abc.1234")).toBe("001877.abc.1234");
    expect(appleSubject("Google_1074")).toBeUndefined();
  });

  const run = (session: { challengeName: string; challengeResult: boolean }[]) =>
    define({ request: { session }, response: {} } as never).then((e) => e.response);
  it("asks for Apple's token once, then issues tokens", async () => {
    expect(await run([])).toMatchObject({ challengeName: "CUSTOM_CHALLENGE", issueTokens: false, failAuthentication: false });
    expect(await run([{ challengeName: "CUSTOM_CHALLENGE", challengeResult: true }])).toMatchObject({ issueTokens: true, failAuthentication: false });
  });
  it("fails on a wrong answer, with no second try", async () => {
    expect(await run([{ challengeName: "CUSTOM_CHALLENGE", challengeResult: false }])).toMatchObject({ issueTokens: false, failAuthentication: true });
  });
  it("Verify runs as Lambda calls it, with (event, context)", async () => {
    // The first real sign-in failed: the time was an optional second parameter, and Lambda passed its context there.
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const event = { userName: "SignInWithApple_001877.abc.1234", request: { challengeAnswer: JSON.stringify({ identityToken: "x", nonce }) }, response: {} };
    const out = await (verifyChallenge as (e: unknown, c: unknown) => Promise<{ response: { answerCorrect: boolean } }>)(event, { awsRequestId: "r1" });
    expect(out.response.answerCorrect).toBe(false);
    expect(log).toHaveBeenCalledWith("refused", "not a JWT");
    log.mockRestore();
  });
  it("never issues tokens for another challenge", async () => {
    expect(await run([{ challengeName: "SRP_A", challengeResult: true }])).toMatchObject({ issueTokens: false, failAuthentication: true });
  });
});
