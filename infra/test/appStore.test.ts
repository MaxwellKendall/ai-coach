import { readFileSync } from "node:fs";
import { X509Certificate, createPrivateKey, generateKeyPairSync, sign } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * FIT-437: Lifter Pro and Coach Pro bought in the App Store, and one entitlement across both stores. Apple's JWS are
 * signed with the test chain shaped like Apple's (fixtures/storekit/make.sh, test-only keys), trusted here by passing
 * its root's fingerprint in. The table is a small in-memory stand-in that runs the expressions the plan code writes.
 */
const items = new Map<string, Record<string, any>>();
const keyOf = (key: { PK: string; SK: string }) => `${key.PK}|${key.SK}`;
const { ConditionalCheckFailedException } = await import("@aws-sdk/client-dynamodb");
const failed = () => new ConditionalCheckFailedException({ message: "condition", $metadata: {} });

function get(item: Record<string, any> | undefined, path: string) {
  return path.split(".").reduce<any>((at, part) => at?.[part], item);
}
function holds(condition: string | undefined, item: Record<string, any> | undefined, names: Record<string, string>, values: Record<string, any>) {
  if (!condition) return true;
  return condition.split(" OR ").some((clause) => {
    const name = (s: string) => s.replace(/#\w+/g, (n) => names[n]);
    const missing = clause.match(/^attribute_not_exists\((.+)\)$/);
    if (missing) return get(item, name(missing[1])) === undefined;
    const [left, right] = clause.split(" = ");
    return item !== undefined && get(item, name(left)) === values[right];
  });
}
const send = vi.fn(async (command: any) => {
  const input = command.input;
  const name = command.constructor.name;
  const names = input.ExpressionAttributeNames ?? {};
  const values = input.ExpressionAttributeValues ?? {};
  if (name === "GetCommand") return { Item: structuredClone(items.get(keyOf(input.Key))) };
  if (name === "PutCommand") {
    if (!holds(input.ConditionExpression, items.get(keyOf(input.Item)), names, values)) throw failed();
    items.set(keyOf(input.Item), structuredClone(input.Item));
    return {};
  }
  if (name === "UpdateCommand") {
    const kept = items.get(keyOf(input.Key));
    if (!holds(input.ConditionExpression, kept, names, values)) throw failed();
    const item = structuredClone(kept ?? { ...input.Key });
    const [set, remove] = String(input.UpdateExpression).replace(/^SET /, "").split(" REMOVE ");
    for (const pair of set.split(", ")) {
      const [k, v] = pair.split(" = ");
      item[names[k] ?? k] = structuredClone(values[v]);
    }
    for (const k of remove?.split(", ") ?? []) delete item[names[k] ?? k];
    items.set(keyOf(input.Key), item);
    return {};
  }
  throw new Error(`No ${name}`);
});
vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return { ...actual, DynamoDBDocumentClient: { from: () => ({ send }) } };
});
const keys = vi.fn();
vi.mock("../lambda/gifts.ts", () => ({ stripeConfig: () => keys(), giftedUntil: async () => undefined }));

const { handleNotification, registerPurchase, statusOf, PurchaseError } = await import("../lambda/appStore.ts");
const { handler: notifications } = await import("../lambda/appStoreNotifications.ts");
const { hasPlan, planRecord, saveSubscription, start } = await import("../lambda/coachPlan.ts");
const { hasCoachPlan } = await import("../lambda/coach.ts");
const { PRODUCTS, productOf } = await import("../lambda/entitlement.ts");
const { effective, shownPlan } = await import("../lambda/plan.ts");

const dir = new URL("./fixtures/storekit/", import.meta.url);
const pem = (name: string) => readFileSync(new URL(name, dir), "utf8");
const der = (name: string) => new X509Certificate(pem(name)).raw.toString("base64");
const x5c = [der("leaf.pem"), der("intermediate.pem"), der("root.pem")];
const root = new X509Certificate(pem("root.pem")).fingerprint256;
const leafKey = createPrivateKey(pem("leaf.pkcs8.key"));

function jws(payload: object, key = leafKey) {
  const head = Buffer.from(JSON.stringify({ alg: "ES256", x5c })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = sign("sha256", Buffer.from(`${head}.${body}`), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${head}.${body}.${signature}`;
}

const DAY = 86_400_000;
const t0 = new Date("2027-01-04T12:00:00Z").getTime();
const SAM = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b";
const ALEX = "0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d";
const LIFTER = "com.maxwellkendall.aicoach.pro.monthly";
const COACH = "com.maxwellkendall.aicoach.coach.yearly";

let clock = t0;
const transaction = (over: Record<string, unknown> = {}) => ({
  originalTransactionId: "2000", transactionId: `t${clock}`, productId: LIFTER, bundleId: "com.maxwellkendall.aicoach",
  environment: "Sandbox", purchaseDate: clock, expiresDate: clock + 30 * DAY, signedDate: clock, appAccountToken: SAM, ...over,
});
const renewal = (over: Record<string, unknown> = {}) => ({ originalTransactionId: "2000", autoRenewStatus: 1, signedDate: clock, ...over });

function notification(type: string, { subtype, txn = {}, info = {}, data = {}, at = clock }:
  { subtype?: string; txn?: Record<string, unknown>; info?: Record<string, unknown> | null; data?: Record<string, unknown>; at?: number } = {}) {
  return jws({
    notificationType: type, subtype, notificationUUID: `n${at}`, version: "2.0", signedDate: at,
    data: {
      bundleId: "com.maxwellkendall.aicoach", environment: "Sandbox",
      signedTransactionInfo: jws(transaction({ signedDate: at, ...txn })),
      signedRenewalInfo: info === null ? undefined : jws(renewal({ signedDate: at, ...info })), ...data,
    },
  });
}

const options = () => ({ root, environments: ["Sandbox"], now: new Date(clock) });
const notify = (signedPayload: string) => handleNotification(signedPayload, options());
const plan = (kind: "pro" | "coach" = "pro", uid = SAM) => planRecord(uid, kind);
const later = (days: number) => { clock += days * DAY; };

beforeEach(() => {
  items.clear();
  send.mockClear();
  keys.mockReset();
  clock = t0;
  vi.spyOn(console, "error").mockImplementation(() => {});
});

describe("FIT-437: the App Store's products are the two plans", () => {
  it("maps Lifter Pro to pro and Coach Pro to coach, monthly and yearly", () => {
    expect(productOf("com.maxwellkendall.aicoach.pro.monthly")).toEqual({ kind: "pro", interval: "month" });
    expect(productOf("com.maxwellkendall.aicoach.pro.yearly")).toEqual({ kind: "pro", interval: "year" });
    expect(productOf("com.maxwellkendall.aicoach.coach.monthly")).toEqual({ kind: "coach", interval: "month" });
    expect(productOf("com.maxwellkendall.aicoach.coach.yearly")).toEqual({ kind: "coach", interval: "year" });
    expect(productOf("coins")).toBeUndefined();
    expect(productOf("toString")).toBeUndefined();
    // appstore/subscriptions.json is the source of truth for the ids.
    const listed = JSON.parse(readFileSync(new URL("../../appstore/subscriptions.json", import.meta.url), "utf8"))
      .groups.flatMap((g: { products: { productId: string }[] }) => g.products.map((p) => p.productId));
    expect(Object.keys(PRODUCTS).sort()).toEqual(listed.sort());
  });

  it("Coach Pro bought in the app is the coach plan: COACHPLAN, and the coach tools", async () => {
    await notify(notification("SUBSCRIBED", { subtype: "INITIAL_BUY", txn: { productId: COACH, expiresDate: clock + 365 * DAY } }));
    expect((await plan("coach"))?.appStore).toMatchObject({ status: "active", productId: COACH, interval: "year" });
    expect(await plan("pro")).toBeUndefined();
    expect(await hasCoachPlan(SAM)).toBe(true);
    expect(await hasPlan(SAM, "pro")).toBe(false);
  });
});

describe("FIT-437: App Store Server Notifications", () => {
  it("SUBSCRIBED with the free trial: trialing, linked to the account in appAccountToken", async () => {
    const out = await notify(notification("SUBSCRIBED", { subtype: "INITIAL_BUY", txn: { offerType: 1, offerDiscountType: "FREE_TRIAL", expiresDate: clock + 14 * DAY } }));
    expect(out).toEqual({ status: 200, outcome: { saved: true, uid: SAM, kind: "pro" } });
    expect((await plan())?.appStore).toMatchObject({ originalTransactionId: "2000", status: "trialing", autoRenew: true, environment: "Sandbox" });
    expect(items.get("APPSTORETXN#2000|APPSTORETXN")).toMatchObject({ uid: SAM, GSI1PK: `USER#${SAM}` });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    expect(shownPlan(false, await plan(), new Date(clock))).toMatchObject({ status: "trialing", source: "appstore", cancelsAtEnd: false, paidTwice: false });
  });

  it("DID_RENEW, OFFER_REDEEMED and DID_CHANGE_RENEWAL_PREF keep it active, to the new period's end", async () => {
    await notify(notification("SUBSCRIBED"));
    later(30);
    await notify(notification("DID_RENEW"));
    expect((await plan())?.appStore).toMatchObject({ status: "active", expiresAt: new Date(clock + 30 * DAY).toISOString() });
    later(1);
    await notify(notification("OFFER_REDEEMED", { subtype: "UPGRADE" }));
    expect((await plan())?.appStore?.status).toBe("active");
    later(1);
    await notify(notification("DID_CHANGE_RENEWAL_PREF", { subtype: "DOWNGRADE", info: { autoRenewProductId: "com.maxwellkendall.aicoach.pro.yearly" } }));
    expect((await plan())?.appStore?.status).toBe("active");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
  });

  it("DID_CHANGE_RENEWAL_STATUS: turning auto-renew off keeps the plan to the period's end, then it's gone", async () => {
    await notify(notification("SUBSCRIBED"));
    later(3);
    await notify(notification("DID_CHANGE_RENEWAL_STATUS", { subtype: "AUTO_RENEW_DISABLED", txn: { expiresDate: t0 + 30 * DAY }, info: { autoRenewStatus: 0 } }));
    const record = await plan();
    expect(record?.appStore).toMatchObject({ status: "active", autoRenew: false });
    expect(shownPlan(true, record, new Date(clock))).toMatchObject({ status: "active", cancelsAtEnd: true, source: "appstore" });
    // Past its end with no EXPIRED yet: the date says it's over.
    expect(effective(record, new Date(t0 + 31 * DAY)).has).toBe(false);
    expect(shownPlan(true, record, new Date(t0 + 31 * DAY)).status).toBe("canceled");
  });

  it("DID_FAIL_TO_RENEW in the grace period: still Pro, as in_grace, until grace ends", async () => {
    await notify(notification("SUBSCRIBED"));
    later(30);
    await notify(notification("DID_FAIL_TO_RENEW", { subtype: "GRACE_PERIOD", txn: { expiresDate: clock }, info: { isInBillingRetryPeriod: true, gracePeriodExpiresDate: clock + 16 * DAY } }));
    const record = await plan();
    expect(record?.appStore).toMatchObject({ status: "in_grace", graceUntil: new Date(clock + 16 * DAY).toISOString() });
    expect(effective(record, new Date(clock + DAY)).has).toBe(true);
    expect(shownPlan(true, record, new Date(clock + DAY)).status).toBe("past_due");
    expect(effective(record, new Date(clock + 17 * DAY)).has).toBe(false);
  });

  it("DID_FAIL_TO_RENEW without grace: billing retry, not Pro", async () => {
    await notify(notification("SUBSCRIBED"));
    later(30);
    await notify(notification("DID_FAIL_TO_RENEW", { txn: { expiresDate: clock }, info: { isInBillingRetryPeriod: true } }));
    const record = await plan();
    expect(record?.appStore?.status).toBe("billing_retry");
    expect(effective(record, new Date(clock)).has).toBe(false);
    expect(shownPlan(true, record, new Date(clock)).status).toBe("unpaid");
    // Apple's retry succeeds: DID_RENEW (BILLING_RECOVERY) brings it back.
    later(2);
    await notify(notification("DID_RENEW", { subtype: "BILLING_RECOVERY" }));
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
  });

  it("GRACE_PERIOD_EXPIRED and EXPIRED end it", async () => {
    await notify(notification("SUBSCRIBED"));
    later(30);
    await notify(notification("DID_FAIL_TO_RENEW", { subtype: "GRACE_PERIOD", txn: { expiresDate: clock }, info: { gracePeriodExpiresDate: clock + 16 * DAY } }));
    later(16);
    await notify(notification("GRACE_PERIOD_EXPIRED", { txn: { expiresDate: t0 + 30 * DAY } }));
    expect((await plan())?.appStore?.status).toBe("billing_retry");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(false);
    later(30);
    await notify(notification("EXPIRED", { subtype: "BILLING_RETRY", txn: { expiresDate: t0 + 30 * DAY } }));
    expect((await plan())?.appStore?.status).toBe("expired");
    expect(shownPlan(true, await plan(), new Date(clock)).status).toBe("canceled");
  });

  it("REFUND and REVOKE end it at once; REFUND_REVERSED gives it back", async () => {
    await notify(notification("SUBSCRIBED"));
    later(2);
    await notify(notification("REFUND", { txn: { revocationDate: clock, revocationReason: 0 } }));
    expect((await plan())?.appStore?.status).toBe("refunded");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(false);
    later(1);
    await notify(notification("REFUND_REVERSED"));
    expect((await plan())?.appStore?.status).toBe("active");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    later(1);
    await notify(notification("REVOKE", { txn: { revocationDate: clock } }));
    expect((await plan())?.appStore?.status).toBe("revoked");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(false);
  });

  it("TEST and types it doesn't use are acknowledged and change nothing", async () => {
    expect(await notify(jws({ notificationType: "TEST", signedDate: clock, data: { bundleId: "com.maxwellkendall.aicoach", environment: "Sandbox" } })))
      .toEqual({ status: 200, outcome: { saved: false, ignored: "test" } });
    expect((await notify(notification("CONSUMPTION_REQUEST"))).status).toBe(200);
    expect((await notify(notification("PRICE_INCREASE"))).outcome.saved).toBe(false);
    expect(items.size).toBe(0);
  });

  it("an older notification arriving late doesn't undo a newer one", async () => {
    const early = notification("DID_FAIL_TO_RENEW", { at: t0 + 30 * DAY, txn: { expiresDate: t0 + 30 * DAY }, info: { isInBillingRetryPeriod: true } });
    await notify(notification("SUBSCRIBED"));
    later(32);
    await notify(notification("DID_RENEW", { subtype: "BILLING_RECOVERY" }));
    expect((await notify(early)).outcome.saved).toBe(false);
    expect((await plan())?.appStore?.status).toBe("active");
  });

  it("refuses what Apple didn't sign; ignores another app's or another environment's", async () => {
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const forged = jws({ notificationType: "SUBSCRIBED", signedDate: clock, data: { bundleId: "com.maxwellkendall.aicoach", environment: "Sandbox", signedTransactionInfo: jws(transaction()) } }, privateKey);
    expect((await notify(forged)).status).toBe(400);
    // Signed, but the transaction inside isn't.
    const inner = jws({ notificationType: "SUBSCRIBED", signedDate: clock, data: { bundleId: "com.maxwellkendall.aicoach", environment: "Sandbox", signedTransactionInfo: jws(transaction(), privateKey) } });
    expect((await notify(inner)).status).toBe(400);
    // The real check trusts only Apple's root.
    expect((await handleNotification(notification("SUBSCRIBED"), { environments: ["Sandbox"], now: new Date(clock) })).status).toBe(400);
    expect((await notify(notification("SUBSCRIBED", { data: { bundleId: "com.other.app" } }))).outcome).toMatchObject({ ignored: "another app" });
    expect((await notify(notification("SUBSCRIBED", { data: { environment: "Production" } }))).outcome).toMatchObject({ ignored: "environment" });
    expect((await handleNotification(notification("SUBSCRIBED"), { ...options(), environments: ["Production"] })).outcome).toMatchObject({ ignored: "environment" });
    expect((await notify(notification("SUBSCRIBED", { txn: { productId: "coins" } }))).status).toBe(200);
    expect(items.size).toBe(0);
  });

  it("a purchase without the account's token waits for the app to register it", async () => {
    const out = await notify(notification("SUBSCRIBED", { txn: { appAccountToken: undefined } }));
    expect(out).toEqual({ status: 200, outcome: { saved: false, ignored: "no account" } });
    await registerPurchase(SAM, jws(transaction({ appAccountToken: undefined })), undefined, options());
    later(30);
    // Linked now: the next notification finds the account without a token.
    expect((await notify(notification("DID_RENEW", { txn: { appAccountToken: undefined } }))).outcome).toMatchObject({ saved: true, uid: SAM });
  });

  it("is a POST of {signedPayload} at its URL", async () => {
    const url = async (method: string, body?: string) => (await notifications({ requestContext: { http: { method } }, body, isBase64Encoded: false } as never)) as { statusCode: number };
    expect((await url("GET")).statusCode).toBe(405);
    expect((await url("POST", "nope")).statusCode).toBe(400);
    // Apple's real root: the test chain is refused.
    expect((await url("POST", JSON.stringify({ signedPayload: notification("SUBSCRIBED") }))).statusCode).toBe(400);
  });
});

describe("FIT-437: registering the app's purchase", () => {
  it("saves it to the account at once and links the subscription", async () => {
    const out = await registerPurchase(SAM, jws(transaction()), jws(renewal({ autoRenewStatus: 0 })), options());
    expect(out).toMatchObject({ kind: "pro", plan: { status: "active", source: "appstore", cancelsAtEnd: true, interval: "month" } });
    expect(items.get("APPSTORETXN#2000|APPSTORETXN")?.uid).toBe(SAM);
    // Again (a restore on the same account) is fine.
    await expect(registerPurchase(SAM, jws(transaction()), undefined, options())).resolves.toMatchObject({ kind: "pro" });
  });

  it("refuses a subscription linked to another account, or bought by one", async () => {
    await registerPurchase(SAM, jws(transaction()), undefined, options());
    await expect(registerPurchase(ALEX, jws(transaction()), undefined, options())).rejects.toThrow(PurchaseError);
    await expect(registerPurchase(ALEX, jws(transaction()), undefined, options())).rejects.toThrow("another Barbrabell account");
    // Not linked yet, but Apple says another account bought it.
    await expect(registerPurchase(ALEX, jws(transaction({ originalTransactionId: "3000" })), undefined, options())).rejects.toThrow("another Barbrabell account");
    expect(await plan("pro", ALEX)).toBeUndefined();
    expect(items.has("APPSTORETXN#3000|APPSTORETXN")).toBe(false);
  });

  it("refuses what Apple didn't sign, another app's, or another environment's", async () => {
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    await expect(registerPurchase(SAM, jws(transaction(), privateKey), undefined, options())).rejects.toThrow("signature");
    await expect(registerPurchase(SAM, jws(transaction({ bundleId: "com.other" })), undefined, options())).rejects.toThrow("another app");
    await expect(registerPurchase(SAM, jws(transaction({ environment: "Production" })), undefined, options())).rejects.toThrow("environment");
    await expect(registerPurchase(SAM, jws(transaction({ productId: "coins" })), undefined, options())).rejects.toThrow("not a subscription");
    expect(items.size).toBe(0);
  });

  it("a stale transaction the app kept doesn't undo a newer notification", async () => {
    const stale = jws(transaction());
    await notify(notification("SUBSCRIBED"));
    later(2);
    await notify(notification("REFUND", { txn: { revocationDate: clock } }));
    const out = await registerPurchase(SAM, stale, undefined, options());
    expect(out.plan).toMatchObject({ status: "canceled", source: "appstore" });
    expect((await plan())?.appStore?.status).toBe("refunded");
  });
});

describe("FIT-437: one plan across both stores", () => {
  const stripeSub = (status: string, eventAt: number, id = "sub_1") => ({
    id, status, customer: "cus_1", cancel_at_period_end: false, metadata: { uid: SAM },
    items: { data: [{ current_period_end: 1_800_000_000, price: { lookup_key: "pro_monthly", recurring: { interval: "month" } } }] },
  });

  it("paid in both: one Pro, marked paid twice; cancelling either keeps Pro", async () => {
    await saveSubscription(stripeSub("active", 100), 100);
    await notify(notification("SUBSCRIBED"));
    let record = await plan();
    expect(effective(record, new Date(clock))).toEqual({ has: true, source: "stripe", paidTwice: true });
    expect(shownPlan(true, record, new Date(clock))).toMatchObject({ status: "active", source: "stripe", paidTwice: true });
    // Cancelled on the web: the App Store's keeps Pro.
    await saveSubscription(stripeSub("canceled", 200), 200);
    record = await plan();
    expect(record?.status).toBe("canceled");
    expect(effective(record, new Date(clock))).toEqual({ has: true, source: "appstore", paidTwice: false });
    expect(shownPlan(true, record, new Date(clock))).toMatchObject({ status: "active", source: "appstore" });
  });

  it("an App Store event never downgrades an active Stripe plan", async () => {
    await saveSubscription(stripeSub("active", 100), 100);
    await notify(notification("SUBSCRIBED"));
    later(2);
    await notify(notification("REFUND", { txn: { revocationDate: clock } }));
    const record = await plan();
    expect(record).toMatchObject({ status: "active", subscription: "sub_1", eventAt: 100, appStore: { status: "refunded" } });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    expect(shownPlan(true, record, new Date(clock))).toMatchObject({ status: "active", source: "stripe", paidTwice: false });
  });

  it("a Stripe event never downgrades an active App Store plan", async () => {
    await notify(notification("SUBSCRIBED"));
    await saveSubscription(stripeSub("active", 100), 100);
    await saveSubscription(stripeSub("canceled", 200), 200);
    // A second, ended Stripe subscription's event too (FIT-189).
    await saveSubscription(stripeSub("incomplete_expired", 300, "sub_2"), 300);
    const record = await plan();
    expect(record?.appStore).toMatchObject({ status: "active", originalTransactionId: "2000" });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
  });

  it("FIT-189 for the App Store: another subscription's lapse leaves the active one alone", async () => {
    // Two Apple IDs bought Pro for the same account.
    await notify(notification("SUBSCRIBED", { txn: { originalTransactionId: "2000" } }));
    later(1);
    await notify(notification("SUBSCRIBED", { txn: { originalTransactionId: "4000" }, info: { originalTransactionId: "4000" } }));
    later(1);
    await notify(notification("EXPIRED", { txn: { originalTransactionId: "2000", expiresDate: clock - 1 } }));
    expect((await plan())?.appStore).toMatchObject({ originalTransactionId: "4000", status: "active" });
  });

  it("the web won't sell a plan already bought in the App Store", async () => {
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    await notify(notification("SUBSCRIBED"));
    await expect(start(SAM, "month", undefined, "https://example.com", "pro")).rejects.toThrow("through the App Store");
  });
});

describe("FIT-437: the state from Apple's fields", () => {
  const txn = { originalTransactionId: "1", productId: LIFTER, bundleId: "b", environment: "Sandbox", signedDate: t0 };
  const at = new Date(t0);
  it("reads dates when the notification doesn't say", () => {
    expect(statusOf(undefined, undefined, { ...txn, expiresDate: t0 + 1 }, undefined, at)).toBe("active");
    expect(statusOf(undefined, undefined, { ...txn, expiresDate: t0 + 1, offerType: 1 }, undefined, at)).toBe("trialing");
    expect(statusOf(undefined, undefined, { ...txn, expiresDate: t0 + 1, offerType: 1, offerDiscountType: "PAY_AS_YOU_GO" }, undefined, at)).toBe("active");
    expect(statusOf(undefined, undefined, { ...txn, expiresDate: t0 - 1 }, { gracePeriodExpiresDate: t0 + 1 }, at)).toBe("in_grace");
    expect(statusOf(undefined, undefined, { ...txn, expiresDate: t0 - 1 }, { isInBillingRetryPeriod: true }, at)).toBe("billing_retry");
    expect(statusOf(undefined, undefined, { ...txn, expiresDate: t0 - 1 }, undefined, at)).toBe("expired");
    expect(statusOf(undefined, undefined, { ...txn, expiresDate: t0 + 1, revocationDate: t0 }, undefined, at)).toBe("refunded");
  });
});
