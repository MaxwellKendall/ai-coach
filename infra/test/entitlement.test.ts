import { readFileSync } from "node:fs";
import { X509Certificate, createPrivateKey, generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, it } from "vitest";
import { APPLE_ROOT_G3, app, checkEntitlement } from "../lambda/entitlement.ts";

/**
 * FIT-123: the proxy's check of the app's Pro transaction. Signed with a test chain shaped like Apple's
 * (fixtures/storekit/make.sh), trusted here by passing its root's fingerprint in place of Apple's.
 */
const dir = new URL("./fixtures/storekit/", import.meta.url);
const pem = (name: string) => readFileSync(new URL(name, dir), "utf8");
const der = (name: string) => new X509Certificate(pem(name)).raw.toString("base64");
const x5c = [der("leaf.pem"), der("intermediate.pem"), der("root.pem")];
const testRoot = new X509Certificate(pem("root.pem")).fingerprint256;
const leafKey = createPrivateKey(pem("leaf.pkcs8.key"));

const now = new Date("2027-01-04T12:00:00Z");
const transaction = {
  bundleId: app.bundleId, productId: app.products[0], environment: "Production",
  purchaseDate: now.getTime() - 86_400_000, expiresDate: now.getTime() + 13 * 86_400_000,
};

function jws(payload: object, { chain = x5c, key = leafKey } = {}) {
  const head = Buffer.from(JSON.stringify({ alg: "ES256", x5c: chain })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = sign("sha256", Buffer.from(`${head}.${body}`), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${head}.${body}.${signature}`;
}

describe("entitlement: Apple's signed proof of Pro", () => {
  it("trusts this app's Pro, signed by the chain, until it expires", () => {
    expect(checkEntitlement(jws(transaction), now, testRoot)).toMatchObject({ pro: true, environment: "Production" });
    const lapsed = { ...transaction, expiresDate: now.getTime() - 1 };
    expect(checkEntitlement(jws(lapsed), now, testRoot)).toEqual({ pro: false, why: "expired" });
  });

  it("refuses a refunded one, another app's, or another product", () => {
    expect(checkEntitlement(jws({ ...transaction, revocationDate: now.getTime() }), now, testRoot)).toEqual({ pro: false, why: "revoked" });
    expect(checkEntitlement(jws({ ...transaction, bundleId: "com.other.app" }), now, testRoot)).toMatchObject({ pro: false });
    expect(checkEntitlement(jws({ ...transaction, productId: "coins" }), now, testRoot)).toMatchObject({ pro: false });
  });

  it("refuses one not signed by the leaf: an edited payload or another key", () => {
    const [head, , signature] = jws(transaction).split(".");
    const edited = Buffer.from(JSON.stringify({ ...transaction, expiresDate: now.getTime() + 9e12 })).toString("base64url");
    expect(checkEntitlement(`${head}.${edited}.${signature}`, now, testRoot)).toEqual({ pro: false, why: "signature" });
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    expect(checkEntitlement(jws(transaction, { key: privateKey }), now, testRoot)).toEqual({ pro: false, why: "signature" });
  });

  it("refuses a chain that doesn't end at the trusted root, or doesn't link", () => {
    // The real check trusts only Apple's root: this test chain is refused.
    expect(checkEntitlement(jws(transaction), now)).toEqual({ pro: false, why: "not Apple's root" });
    expect(checkEntitlement(jws(transaction, { chain: [x5c[0], x5c[0], x5c[2]] }), now, testRoot)).toEqual({ pro: false, why: "chain" });
  });

  it("refuses nothing, junk, or the wrong shape", () => {
    expect(checkEntitlement(undefined, now)).toEqual({ pro: false, why: "none" });
    expect(checkEntitlement("abc", now)).toEqual({ pro: false, why: "not a JWS" });
    expect(checkEntitlement("a.b.c", now)).toEqual({ pro: false, why: "not JSON" });
  });

  it("pins Apple Root CA - G3", () => {
    expect(APPLE_ROOT_G3).toBe("63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79");
  });
});
