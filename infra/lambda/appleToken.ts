import { createHash, createPublicKey, verify, type JsonWebKey } from "node:crypto";

/**
 * FIT-138: Apple's identity token from the native Sign in with Apple sheet. Trusted when Apple signed it (RS256 with a
 * key from Apple's JWKS), it's for this app (audience = the bundle ID), it hasn't expired, it's fresh, and its nonce is
 * the SHA-256 of the nonce the app sent with it. The app asks Apple with the hash and keeps the raw nonce, so a token
 * seen somewhere else can't be replayed without it.
 */

export const APPLE_ISSUER = "https://appleid.apple.com";
export const BUNDLE_ID = "com.maxwellkendall.aicoach";
/** A token older than this is refused even if Apple's own expiry is later: sign-in takes seconds. */
const MAX_AGE_SECONDS = 10 * 60;

export type AppleKey = JsonWebKey & { kid: string };
export type AppleClaims = { sub: string; email?: string };
export type Result = { ok: true; claims: AppleClaims } | { ok: false; why: string };

export const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");

export function checkAppleToken(token: string, nonce: string, keys: AppleKey[], now: Date, audience = BUNDLE_ID): Result {
  const parts = token.split(".");
  if (parts.length !== 3) return { ok: false, why: "not a JWT" };
  const [head, body, signature] = parts;
  let header: { alg?: string; kid?: string };
  let claims: Record<string, unknown>;
  try {
    header = JSON.parse(Buffer.from(head, "base64url").toString());
    claims = JSON.parse(Buffer.from(body, "base64url").toString());
  } catch {
    return { ok: false, why: "not JSON" };
  }
  if (header.alg !== "RS256") return { ok: false, why: "algorithm" };
  const jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) return { ok: false, why: "unknown key" };
  const signed = verify("RSA-SHA256", Buffer.from(`${head}.${body}`), createPublicKey({ key: jwk, format: "jwk" }),
                        Buffer.from(signature, "base64url"));
  if (!signed) return { ok: false, why: "signature" };
  if (claims.iss !== APPLE_ISSUER) return { ok: false, why: "issuer" };
  if (claims.aud !== audience) return { ok: false, why: "audience" };
  const seconds = now.getTime() / 1000;
  if (!(typeof claims.exp === "number" && claims.exp > seconds)) return { ok: false, why: "expired" };
  if (!(typeof claims.iat === "number" && seconds - claims.iat <= MAX_AGE_SECONDS)) return { ok: false, why: "too old" };
  if (!nonce || claims.nonce !== sha256(nonce)) return { ok: false, why: "nonce" };
  if (typeof claims.sub !== "string" || !claims.sub) return { ok: false, why: "subject" };
  return { ok: true, claims: { sub: claims.sub, email: typeof claims.email === "string" ? claims.email : undefined } };
}

let cached: AppleKey[] = [];

/** Apple's signing keys, fetched again when a token names one we haven't seen (Apple rotates them). */
export async function verifyAppleToken(token: string, nonce: string, now = new Date()): Promise<Result> {
  let result = checkAppleToken(token, nonce, cached, now);
  if (!result.ok && result.why === "unknown key") {
    const response = await fetch(`${APPLE_ISSUER}/auth/keys`);
    if (!response.ok) return { ok: false, why: `Apple's keys: ${response.status}` };
    cached = ((await response.json()) as { keys: AppleKey[] }).keys;
    result = checkAppleToken(token, nonce, cached, now);
  }
  return result;
}
