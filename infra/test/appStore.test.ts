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
const { ConditionalCheckFailedException, TransactionCanceledException } = await import("@aws-sdk/client-dynamodb");
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
    const exists = clause.match(/^attribute_exists\((.+)\)$/);
    if (exists) return get(item, name(exists[1])) !== undefined;
    const [left, right] = clause.split(" = ");
    return item !== undefined && get(item, name(left)) === values[right];
  });
}
function put(input: any) {
  if (!holds(input.ConditionExpression, items.get(keyOf(input.Item)), input.ExpressionAttributeNames ?? {}, input.ExpressionAttributeValues ?? {})) throw failed();
  items.set(keyOf(input.Item), structuredClone(input.Item));
}
function update(input: any, write = true) {
  const names = input.ExpressionAttributeNames ?? {};
  const values = input.ExpressionAttributeValues ?? {};
  const kept = items.get(keyOf(input.Key));
  if (!holds(input.ConditionExpression, kept, names, values)) throw failed();
  if (!write) return;
  const item = structuredClone(kept ?? { ...input.Key });
  const [set, remove] = String(input.UpdateExpression).replace(/^SET /, "").split(" REMOVE ");
  for (const pair of set.split(", ")) {
    const [k, v] = pair.split(" = ");
    item[names[k] ?? k] = structuredClone(values[v]);
  }
  for (const k of remove?.split(", ") ?? []) delete item[names[k] ?? k];
  items.set(keyOf(input.Key), item);
}
/** Writes that lose every race: each UpdateCommand or plan TransactWrite fails its condition while this is > 0. */
let conflicts = 0;
/** Cancellations DynamoDB makes for reasons other than a condition: the next link writes are cancelled with these. */
let linkCancels: string[][] = [];
/** Runs once, right after deleteAccount's GSI1 query. */
let afterIndexQuery: (() => Promise<unknown>) | undefined;
const send = vi.fn(async (command: any) => {
  const input = command.input;
  const name = command.constructor.name;
  if (name === "GetCommand") return { Item: structuredClone(items.get(keyOf(input.Key))) };
  if (name === "PutCommand") return put(input), {};
  if (name === "UpdateCommand") {
    if (conflicts > 0) { conflicts--; throw failed(); }
    return update(input), {};
  }
  if (name === "TransactWriteCommand") {
    if (linkCancels.length && input.TransactItems.some((t: any) => String(t.Put?.Item.PK).startsWith("APPSTORETXN#"))) {
      const codes = linkCancels.shift()!;
      throw new TransactionCanceledException({ message: "cancelled", $metadata: {}, CancellationReasons: codes.map((Code) => ({ Code })) });
    }
    // All conditions first, as DynamoDB does; none is written if any fails.
    const reasons = input.TransactItems.map((t: any) => {
      try {
        if (t.ConditionCheck) update({ ...t.ConditionCheck, UpdateExpression: "SET" }, false);
        if (t.Put) holds(t.Put.ConditionExpression, items.get(keyOf(t.Put.Item)), t.Put.ExpressionAttributeNames ?? {}, t.Put.ExpressionAttributeValues ?? {}) || (() => { throw failed(); })();
        if (t.Update) {
          if (conflicts > 0) { conflicts--; throw failed(); }
          update(t.Update, false);
        }
        return { Code: "None" };
      } catch {
        return { Code: "ConditionalCheckFailed" };
      }
    });
    if (reasons.some((r: any) => r.Code !== "None")) throw new TransactionCanceledException({ message: "cancelled", $metadata: {}, CancellationReasons: reasons });
    for (const t of input.TransactItems) {
      if (t.Put) put(t.Put);
      if (t.Update) update(t.Update);
    }
    return {};
  }
  if (name === "DeleteCommand") {
    if (!holds(input.ConditionExpression, items.get(keyOf(input.Key)), input.ExpressionAttributeNames ?? {}, input.ExpressionAttributeValues ?? {})) throw failed();
    return items.delete(keyOf(input.Key)), {};
  }
  if (name === "BatchWriteCommand") {
    for (const request of Object.values(input.RequestItems).flat() as any[]) {
      if (request.PutRequest) items.set(keyOf(request.PutRequest.Item), structuredClone(request.PutRequest.Item));
      if (request.DeleteRequest) items.delete(keyOf(request.DeleteRequest.Key));
    }
    return {};
  }
  throw new Error(`No ${name}`);
});
vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return {
    ...actual,
    DynamoDBDocumentClient: { from: () => ({ send }) },
    // deleteAccount's queries: by GSI1PK, or by PK (with begins_with on SK).
    paginateQuery: async function* (_: unknown, input: any) {
      const v = input.ExpressionAttributeValues;
      const all = [...items.values()];
      if (input.IndexName === "GSI1") {
        yield { Items: all.filter((i) => i.GSI1PK === v[":u"]) };
        // A write that lands between deleteAccount finding the account's items and deleting them.
        const hook = afterIndexQuery;
        afterIndexQuery = undefined;
        await hook?.();
      }
      else yield { Items: all.filter((i) => i.PK === v[":pk"] && (!v[":p"] || String(i.SK).startsWith(v[":p"])) && (!v[":f"] || (String(i.SK).startsWith(v[":f"]) && i.uid === v[":uid"]))) };
    },
  };
});
const cognitoSend = vi.fn(async () => ({}));
vi.mock("@aws-sdk/client-cognito-identity-provider", async (orig) => ({ ...(await orig() as object), CognitoIdentityProviderClient: class { send = cognitoSend; } }));
vi.mock("@aws-sdk/client-s3", async (orig) => ({ ...(await orig() as object), S3Client: class { send = vi.fn(async () => ({})); } }));
const keys = vi.fn();
vi.mock("../lambda/gifts.ts", () => ({ stripeConfig: () => keys(), giftedUntil: async () => undefined }));

const { handleNotification, registerPurchase, statusOf, PurchaseError } = await import("../lambda/appStore.ts");
const { handler: notifications } = await import("../lambda/appStoreNotifications.ts");
const { hasPlan, planRecord, saveSubscription, start } = await import("../lambda/coachPlan.ts");
const { hasCoachPlan } = await import("../lambda/coach.ts");
const { handler: deleteAccount } = await import("../lambda/deleteAccount.ts");
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
/** One App Store subscription's state in the plan. */
const apple = async (otid = "2000", kind: "pro" | "coach" = "pro", uid = SAM) => (await planRecord(uid, kind))?.appStores?.[otid];

beforeEach(() => {
  items.clear();
  conflicts = 0;
  linkCancels = [];
  afterIndexQuery = undefined;
  send.mockClear();
  cognitoSend.mockClear();
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
    expect((await apple("2000", "coach"))).toMatchObject({ status: "active", productId: COACH, interval: "year" });
    expect(await plan("pro")).toBeUndefined();
    expect(await hasCoachPlan(SAM)).toBe(true);
    expect(await hasPlan(SAM, "pro")).toBe(false);
  });
});

describe("FIT-437: App Store Server Notifications", () => {
  it("SUBSCRIBED with the free trial: trialing, linked to the account in appAccountToken", async () => {
    const out = await notify(notification("SUBSCRIBED", { subtype: "INITIAL_BUY", txn: { offerType: 1, offerDiscountType: "FREE_TRIAL", expiresDate: clock + 14 * DAY } }));
    expect(out).toEqual({ status: 200, outcome: { saved: true, uid: SAM, kind: "pro" } });
    expect((await apple())).toMatchObject({ originalTransactionId: "2000", status: "trialing", autoRenew: true, environment: "Sandbox" });
    expect(items.get("APPSTORETXN#2000|APPSTORETXN")).toMatchObject({ uid: SAM, GSI1PK: `USER#${SAM}` });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    expect(shownPlan(false, await plan(), new Date(clock))).toMatchObject({ status: "trialing", source: "appstore", cancelsAtEnd: false, paidTwice: false });
  });

  it("DID_RENEW, OFFER_REDEEMED and DID_CHANGE_RENEWAL_PREF keep it active, to the new period's end", async () => {
    await notify(notification("SUBSCRIBED"));
    later(30);
    await notify(notification("DID_RENEW"));
    expect((await apple())).toMatchObject({ status: "active", expiresAt: new Date(clock + 30 * DAY).toISOString() });
    later(1);
    await notify(notification("OFFER_REDEEMED", { subtype: "UPGRADE" }));
    expect((await apple())?.status).toBe("active");
    later(1);
    await notify(notification("DID_CHANGE_RENEWAL_PREF", { subtype: "DOWNGRADE", info: { autoRenewProductId: "com.maxwellkendall.aicoach.pro.yearly" } }));
    expect((await apple())?.status).toBe("active");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
  });

  it("DID_CHANGE_RENEWAL_STATUS: turning auto-renew off keeps the plan to the period's end, then it's gone", async () => {
    await notify(notification("SUBSCRIBED"));
    later(3);
    await notify(notification("DID_CHANGE_RENEWAL_STATUS", { subtype: "AUTO_RENEW_DISABLED", txn: { expiresDate: t0 + 30 * DAY }, info: { autoRenewStatus: 0 } }));
    const record = await plan();
    expect(record?.appStores?.["2000"]).toMatchObject({ status: "active", autoRenew: false });
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
    expect(record?.appStores?.["2000"]).toMatchObject({ status: "in_grace", graceUntil: new Date(clock + 16 * DAY).toISOString() });
    expect(effective(record, new Date(clock + DAY)).has).toBe(true);
    expect(shownPlan(true, record, new Date(clock + DAY)).status).toBe("past_due");
    expect(effective(record, new Date(clock + 17 * DAY)).has).toBe(false);
  });

  it("DID_FAIL_TO_RENEW without grace: billing retry, not Pro", async () => {
    await notify(notification("SUBSCRIBED"));
    later(30);
    await notify(notification("DID_FAIL_TO_RENEW", { txn: { expiresDate: clock }, info: { isInBillingRetryPeriod: true } }));
    const record = await plan();
    expect(record?.appStores?.["2000"]?.status).toBe("billing_retry");
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
    expect((await apple())?.status).toBe("billing_retry");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(false);
    later(30);
    await notify(notification("EXPIRED", { subtype: "BILLING_RETRY", txn: { expiresDate: t0 + 30 * DAY } }));
    expect((await apple())?.status).toBe("expired");
    expect(shownPlan(true, await plan(), new Date(clock)).status).toBe("canceled");
  });

  it("REFUND and REVOKE end it at once; REFUND_REVERSED gives it back", async () => {
    await notify(notification("SUBSCRIBED"));
    later(2);
    await notify(notification("REFUND", { txn: { revocationDate: clock, revocationReason: 0 } }));
    expect((await apple())?.status).toBe("refunded");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(false);
    later(1);
    await notify(notification("REFUND_REVERSED"));
    expect((await apple())?.status).toBe("active");
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    later(1);
    await notify(notification("REVOKE", { txn: { revocationDate: clock } }));
    expect((await apple())?.status).toBe("revoked");
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
    expect((await apple())?.status).toBe("active");
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
    expect((await apple())?.status).toBe("refunded");
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
    expect(record).toMatchObject({ status: "active", subscription: "sub_1", eventAt: 100, appStores: { "2000": { status: "refunded" } } });
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
    expect(record?.appStores?.["2000"]).toMatchObject({ status: "active", originalTransactionId: "2000" });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
  });

  it("FIT-189 for the App Store: another subscription's lapse leaves the active one alone", async () => {
    // Two Apple IDs bought Pro for the same account.
    await notify(notification("SUBSCRIBED", { txn: { originalTransactionId: "2000" } }));
    later(1);
    await notify(notification("SUBSCRIBED", { txn: { originalTransactionId: "4000" }, info: { originalTransactionId: "4000" } }));
    expect(effective(await plan(), new Date(clock))).toEqual({ has: true, source: "appstore", paidTwice: true });
    later(1);
    await notify(notification("EXPIRED", { txn: { originalTransactionId: "2000", expiresDate: clock - 1 } }));
    expect(await apple("4000")).toMatchObject({ status: "active" });
    expect(await apple("2000")).toMatchObject({ status: "expired" });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
  });

  it("review: a newer subscription ending doesn't take Pro from an older one still paid (each kept apart)", async () => {
    // A year bought on one Apple ID, then a month on another for the same account.
    await notify(notification("SUBSCRIBED", { txn: { productId: "com.maxwellkendall.aicoach.pro.yearly", expiresDate: t0 + 365 * DAY } }));
    later(10);
    await notify(notification("SUBSCRIBED", { txn: { originalTransactionId: "4000" }, info: { originalTransactionId: "4000" } }));
    later(2);
    await notify(notification("REFUND", { txn: { originalTransactionId: "4000", revocationDate: clock }, info: { originalTransactionId: "4000" } }));
    expect(await apple("4000")).toMatchObject({ status: "refunded" });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    // The month would have ended by now anyway; the year still has Pro, and is what Billing shows.
    later(60);
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    expect(shownPlan(true, await plan(), new Date(clock))).toMatchObject({ status: "active", interval: "year", source: "appstore", paidTwice: false });
    expect(await hasPlan(SAM, "pro", new Date(t0 + 366 * DAY))).toBe(false);
  });

  it("the web won't sell a plan already bought in the App Store", async () => {
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    await notify(notification("SUBSCRIBED"));
    await expect(start(SAM, "month", undefined, "https://example.com", "pro")).rejects.toThrow("through the App Store");
  });
});

describe("FIT-437 review: renewal extensions and refunds of past periods", () => {
  it("RENEWAL_EXTENDED moves the end: still Pro past the original expiration, until the new one", async () => {
    await notify(notification("SUBSCRIBED", { txn: { transactionId: "t1" } }));
    later(10);
    const out = await notify(notification("RENEWAL_EXTENDED", { txn: { transactionId: "t1", purchaseDate: t0, expiresDate: t0 + 37 * DAY } }));
    expect(out.outcome).toMatchObject({ saved: true });
    expect(await apple()).toMatchObject({ status: "active", expiresAt: new Date(t0 + 37 * DAY).toISOString() });
    expect(await hasPlan(SAM, "pro", new Date(t0 + 33 * DAY))).toBe(true);
    expect(await hasPlan(SAM, "pro", new Date(t0 + 38 * DAY))).toBe(false);
  });

  it("a refund of an earlier period leaves the period paid for now", async () => {
    await notify(notification("SUBSCRIBED", { txn: { transactionId: "A" } }));
    later(30);
    await notify(notification("DID_RENEW", { txn: { transactionId: "B" } }));
    later(5);
    // Apple's REFUND carries the refunded transaction: A, with a newer signedDate than B's renewal.
    const refundA = { transactionId: "A", purchaseDate: t0, expiresDate: t0 + 30 * DAY, revocationDate: clock };
    expect((await notify(notification("REFUND", { txn: refundA }))).outcome).toMatchObject({ saved: false, ignored: "older than the state kept" });
    expect(await apple()).toMatchObject({ status: "active", transactionId: "B" });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    // Its reversal (A's dates are past) doesn't end B either.
    later(1);
    await notify(notification("REFUND_REVERSED", { txn: { transactionId: "A", purchaseDate: t0, expiresDate: t0 + 30 * DAY } }));
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(true);
    // A refund of B, the current period, ends it.
    later(1);
    await notify(notification("REFUND", { txn: { transactionId: "B", purchaseDate: t0 + 30 * DAY, revocationDate: clock } }));
    expect(await apple()).toMatchObject({ status: "refunded", transactionId: "B" });
    expect(await hasPlan(SAM, "pro", new Date(clock))).toBe(false);
  });
});

describe("FIT-437 review: a notification is acknowledged only once saved", () => {
  it("reads the plan consistently before each conditional write, and retries a lost race", async () => {
    await notify(notification("SUBSCRIBED"));
    later(30);
    send.mockClear();
    conflicts = 1;
    expect((await notify(notification("DID_RENEW"))).outcome).toMatchObject({ saved: true });
    const reads = send.mock.calls.map(([c]: any) => c.input).filter((i: any) => i.Key?.SK === "PROPLAN" && !i.TransactItems);
    expect(reads.length).toBe(2);
    expect(reads.every((i: any) => i.ConsistentRead === true)).toBe(true);
  });

  it("a write that loses every attempt is a 500, so Apple sends it again; nothing half-saved", async () => {
    await notify(notification("SUBSCRIBED"));
    later(2);
    conflicts = 100;
    const out = await notify(notification("REFUND", { txn: { revocationDate: clock } }));
    expect(out).toMatchObject({ status: 500, outcome: { saved: false, ignored: "not saved" } });
    expect((await apple())?.status).toBe("active");
    // Apple's retry lands.
    conflicts = 0;
    expect((await notify(notification("REFUND", { txn: { revocationDate: clock } }))).status).toBe(200);
    expect((await apple())?.status).toBe("refunded");
  });

  it("Stripe's events throw too (the webhook answers 5xx and Stripe retries)", async () => {
    const { SaveError } = await import("../lambda/coachPlan.ts");
    conflicts = 100;
    const sub = { id: "sub_1", status: "active", customer: "cus_1", metadata: { uid: SAM }, items: { data: [{ price: { lookup_key: "pro_monthly" } }] } };
    await expect(saveSubscription(sub, 100)).rejects.toThrow(SaveError);
  });
});

describe("FIT-437 review: deleting the account releases its App Store subscriptions", () => {
  const remove = (uid: string) => deleteAccount({ identity: { sub: uid, username: uid } } as never);
  const ownItems = (uid: string) => [...items.values()].filter((i) => i.PK === `USER#${uid}` || i.uid === uid || i.GSI1PK === `USER#${uid}`);

  it("a notification after deletion is dropped, not saved under the deleted account; a new account restores it; renewals follow", async () => {
    await notify(notification("SUBSCRIBED"));
    await remove(SAM);
    expect(ownItems(SAM)).toEqual([]);
    expect(cognitoSend).toHaveBeenCalled();
    later(30);
    expect(await notify(notification("DID_RENEW"))).toEqual({ status: 200, outcome: { saved: false, ignored: "account deleted" } });
    expect(ownItems(SAM)).toEqual([]);
    expect(items.has("APPSTORETXN#2000|APPSTORETXN")).toBe(false);
    // Restored in the app while signed in as a new account: Apple's transaction still says SAM.
    const out = await registerPurchase(ALEX, jws(transaction()), undefined, options());
    expect(out).toMatchObject({ kind: "pro", plan: { status: "active", source: "appstore" } });
    expect(items.get("APPSTORETXN#2000|APPSTORETXN")?.uid).toBe(ALEX);
    later(30);
    expect((await notify(notification("DID_RENEW"))).outcome).toMatchObject({ saved: true, uid: ALEX });
    expect(await hasPlan(ALEX, "pro", new Date(clock))).toBe(true);
    expect(ownItems(SAM)).toEqual([]);
  });

  it("a purchase never linked before the deletion is released too", async () => {
    await remove(SAM);
    expect((await notify(notification("SUBSCRIBED"))).outcome).toMatchObject({ saved: false, ignored: "account deleted" });
    expect(ownItems(SAM)).toEqual([]);
    await expect(registerPurchase(ALEX, jws(transaction()), undefined, options())).resolves.toMatchObject({ kind: "pro" });
  });

  it("a notification racing the deletion (link read before it went) doesn't bring the plan back", async () => {
    await notify(notification("SUBSCRIBED"));
    // The marker is written first; the link is still there for a moment.
    items.set(`DELETEDACCOUNT#${SAM}|DELETEDACCOUNT`, { PK: `DELETEDACCOUNT#${SAM}`, SK: "DELETEDACCOUNT" });
    items.delete(`USER#${SAM}|PROPLAN`);
    later(30);
    expect((await notify(notification("DID_RENEW"))).outcome).toMatchObject({ saved: false, ignored: "account deleted" });
    expect(items.has(`USER#${SAM}|PROPLAN`)).toBe(false);
  });

  it("a live account's subscription is still refused to another", async () => {
    await notify(notification("SUBSCRIBED", { txn: { originalTransactionId: "5000" }, info: { originalTransactionId: "5000" } }));
    items.delete("APPSTORETXN#5000|APPSTORETXN");
    await expect(registerPurchase(ALEX, jws(transaction({ originalTransactionId: "5000" })), undefined, options())).rejects.toThrow("another Barbrabell account");
  });
});

describe("FIT-437 review: a link left over by a deletion, and link writes DynamoDB cancels", () => {
  const remove = (uid: string) => deleteAccount({ identity: { sub: uid, username: uid } } as never);
  const linkItem = () => items.get("APPSTORETXN#2000|APPSTORETXN");

  it("a link GSI1 missed during the deletion doesn't keep the subscription from a new account", async () => {
    await notify(notification("SUBSCRIBED"));
    const leftover = structuredClone(linkItem());
    await remove(SAM);
    // GSI1 is eventually consistent: the link written just before the marker wasn't found, so it survived.
    items.set("APPSTORETXN#2000|APPSTORETXN", leftover!);
    later(30);
    expect((await notify(notification("DID_RENEW"))).outcome).toMatchObject({ saved: false, ignored: "account deleted" });
    const out = await registerPurchase(ALEX, jws(transaction()), undefined, options());
    expect(out).toMatchObject({ kind: "pro", plan: { status: "active", source: "appstore" } });
    expect(linkItem()).toMatchObject({ uid: ALEX, GSI1PK: `USER#${ALEX}` });
    later(30);
    expect((await notify(notification("DID_RENEW"))).outcome).toMatchObject({ saved: true, uid: ALEX });
  });

  it("a link taken over after the deletion found it isn't deleted with the old account", async () => {
    await notify(notification("SUBSCRIBED"));
    // A leftover link (a deletion GSI1 missed) is taken over by ALEX just as SAM's second deletion attempt collects it.
    items.set(`DELETEDACCOUNT#${SAM}|DELETEDACCOUNT`, { PK: `DELETEDACCOUNT#${SAM}`, SK: "DELETEDACCOUNT" });
    afterIndexQuery = () => registerPurchase(ALEX, jws(transaction()), undefined, options());
    await remove(SAM);
    expect(afterIndexQuery).toBeUndefined();
    expect(linkItem()).toMatchObject({ uid: ALEX, GSI1PK: `USER#${ALEX}` });
    later(30);
    expect((await notify(notification("DID_RENEW"))).outcome).toMatchObject({ saved: true, uid: ALEX });
    expect(await hasPlan(ALEX, "pro", new Date(clock))).toBe(true);
  });

  it("the takeover needs the old owner's deletion marker: a live owner's link is never taken", async () => {
    await notify(notification("SUBSCRIBED"));
    // Another account's restore must not take it, even with a token that isn't SAM's.
    await expect(registerPurchase(ALEX, jws(transaction({ appAccountToken: ALEX })), undefined, options())).rejects.toThrow("another Barbrabell account");
    expect(linkItem()?.uid).toBe(SAM);
  });

  it("a cancellation for a transaction conflict or throttling is retried, not read as a deleted account", async () => {
    linkCancels = [["None", "TransactionConflict"], ["ThrottlingError", "None"]];
    expect(await notify(notification("SUBSCRIBED"))).toEqual({ status: 200, outcome: { saved: true, uid: SAM, kind: "pro" } });
    expect(linkItem()?.uid).toBe(SAM);
  });

  it("a link write cancelled every time is a 500, so Apple sends it again; nothing reported as deleted", async () => {
    linkCancels = Array.from({ length: 5 }, () => ["None", "TransactionConflict"]);
    expect(await notify(notification("SUBSCRIBED"))).toMatchObject({ status: 500, outcome: { saved: false, ignored: "not saved" } });
    expect(linkItem()).toBeUndefined();
    expect(await plan()).toBeUndefined();
    // Apple's retry goes through.
    expect((await notify(notification("SUBSCRIBED"))).outcome).toMatchObject({ saved: true, uid: SAM });
  });

  it("registration fails (and can be tried again) when the link write keeps being cancelled", async () => {
    linkCancels = Array.from({ length: 5 }, () => ["None", "ProvisionedThroughputExceeded"]);
    await expect(registerPurchase(SAM, jws(transaction()), undefined, options())).rejects.toThrow("try again");
    await expect(registerPurchase(SAM, jws(transaction()), undefined, options())).resolves.toMatchObject({ kind: "pro" });
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
