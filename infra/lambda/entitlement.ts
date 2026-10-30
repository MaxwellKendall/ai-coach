import { X509Certificate, verify } from "node:crypto";

/**
 * FIT-123: whether a request comes from someone with Pro. The app sends its current Pro transaction as Apple signed
 * it (StoreKit 2's `jwsRepresentation`): a JWS whose header carries the signing chain, leaf to Apple's root. It's
 * trusted when the chain ends at Apple Root CA - G3, each certificate signs the next, the leaf and intermediate are
 * Apple's App Store ones, the leaf signed the JWS, and the transaction is this app's Pro, unexpired and not revoked.
 * The same checks as Apple's App Store Server Library, without its dependency.
 */

/** Apple Root CA - G3's SHA-256 fingerprint (macOS SystemRootCertificates.keychain, checked 2026-10-12). */
export const APPLE_ROOT_G3 = "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79";

export const app = {
  bundleId: "com.maxwellkendall.aicoach",
  products: ["com.maxwellkendall.aicoach.pro.yearly", "com.maxwellkendall.aicoach.pro.monthly"],
};
const apps = [app];

/** The DER of the extension OIDs Apple marks its certificates with (Apple's WWDR intermediate; App Store signing leaf). */
const oid = (hex: string) => Buffer.from(hex, "hex");
const INTERMEDIATE_OID = oid("060a2a864886f76364060201"); // 1.2.840.113635.100.6.2.1
const LEAF_OID = oid("060a2a864886f76364060b01"); // 1.2.840.113635.100.6.11.1

export type Check = { pro: true; expires: Date; environment: string } | { pro: false; why: string };

export function checkEntitlement(jws: string | null | undefined, now: Date, root = APPLE_ROOT_G3): Check {
  if (!jws) return { pro: false, why: "none" };
  const parts = jws.split(".");
  if (parts.length !== 3) return { pro: false, why: "not a JWS" };
  const [head, body, signature] = parts;
  let header: { alg?: string; x5c?: string[] };
  let payload: Record<string, unknown>;
  try {
    header = JSON.parse(Buffer.from(head, "base64url").toString());
    payload = JSON.parse(Buffer.from(body, "base64url").toString());
  } catch {
    return { pro: false, why: "not JSON" };
  }
  if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length !== 3) return { pro: false, why: "header" };
  let chain: X509Certificate[];
  try {
    chain = header.x5c.map((der) => new X509Certificate(Buffer.from(der, "base64")));
  } catch {
    return { pro: false, why: "certificates" };
  }
  const [leaf, intermediate, top] = chain;
  if (top.fingerprint256 !== root) return { pro: false, why: "not Apple's root" };
  if (!intermediate.verify(top.publicKey) || !leaf.verify(intermediate.publicKey)) return { pro: false, why: "chain" };
  if (!chain.every((cert) => new Date(cert.validFrom) <= now && now <= new Date(cert.validTo))) return { pro: false, why: "expired certificate" };
  if (!intermediate.raw.includes(INTERMEDIATE_OID) || !leaf.raw.includes(LEAF_OID)) return { pro: false, why: "not App Store certificates" };
  const signed = verify("sha256", Buffer.from(`${head}.${body}`), { key: leaf.publicKey, dsaEncoding: "ieee-p1363" },
                        Buffer.from(signature, "base64url"));
  if (!signed) return { pro: false, why: "signature" };
  if (!apps.some((a) => payload.bundleId === a.bundleId && a.products.includes(payload.productId as string))) return { pro: false, why: "not this app's Pro" };
  if (payload.revocationDate) return { pro: false, why: "revoked" };
  const expires = new Date(Number(payload.expiresDate));
  if (!(expires > now)) return { pro: false, why: "expired" };
  return { pro: true, expires, environment: String(payload.environment) };
}
