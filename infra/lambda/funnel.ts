import { ConditionalCheckFailedException, DynamoDBClient, TransactionCanceledException } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, TransactWriteCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { PURCHASE_EVENTS, parseBatch, stepKeys, type Batch, type FunnelEvent } from "../../shared/funnel.ts";
import type { Strategy } from "../../shared/monetization.ts";
import { APPLE_ROOT_G3, app, productOf, verifyJWS } from "./entitlement.ts";

// TKL-466: POST barbrabell.com/events, the first launch's funnel (shared/funnel.ts). No sign-in: it runs before there
// is one. Each install keeps one row with its cohort (FUNNEL#install / INSTALL) and one per step it reached
// (FUNNEL#install / STEP#key), both gone after 400 days; the day's counters (STATS#FUNNEL / day#strategy) stay.
//
// Anyone can post here, so two things keep the counts honest and the writes bounded:
// - A purchase or trial counts only from Apple's signed transaction (verifyJWS, as the App Store plan code checks
//   them), classified and named from the transaction; each subscription (originalTransactionId) belongs to the first
//   install that sends it (FUNNEL#TXN#id), so a real one replayed from made-up installs counts once.
// - Each minute takes at most MAX_KEYS_PER_MINUTE step writes across everyone (FUNNEL#LIMIT / minute); past it, 429,
//   and the app keeps its queue and sends again later. The account's 10 concurrent Lambdas rule out reserving any.

/** What Apple's transaction says, for the funnel. */
export type Purchase = { original: string; product: string; trial: boolean };
export type Verify = (jws: string, now: Date) => Purchase | undefined;

/** Apple-signed, this app's, one of our subscriptions, in this stage's environments and not refunded. */
export function appleVerifier(environments: string[], root = APPLE_ROOT_G3): Verify {
  return (jws, now) => {
    const verified = verifyJWS(jws, now, root);
    if (!verified.ok) return undefined;
    const t = verified.payload;
    const product = productOf(t.productId);
    if (t.bundleId !== app.bundleId || !environments.includes(t.environment) || !product || !t.originalTransactionId || t.revocationDate) return undefined;
    // As appStore.ts statusOf reads a trial.
    const trial = t.offerDiscountType === "FREE_TRIAL" || (t.offerType === 1 && t.offerDiscountType === undefined);
    return {
      original: String(t.originalTransactionId),
      product: `${product.kind === "pro" ? "lifter" : "coach"}_${product.interval === "year" ? "yearly" : "monthly"}`,
      trial,
    };
  };
}

/** About 25 full first launches a minute: far above launch traffic, and a few dollars a day at worst. */
export const MAX_KEYS_PER_MINUTE = 1000;

export type FunnelStore = {
  /** Takes `cost` step writes from this minute's budget; false once it's spent. */
  admit(now: Date, cost: number): Promise<boolean>;
  /** Whether the subscription is this install's: the first install to send it keeps it. */
  claim(original: string, install: string, now: Date): Promise<boolean>;
  /** The install's cohort is fixed when it sees the hero for the first time. */
  cohort(install: string, strategy: Strategy, now: Date, starts: boolean): Promise<{ day: string; strategy: Strategy } | undefined>;
  countOnce(install: string, day: string, strategy: Strategy, key: string, now: Date): Promise<void>;
};

/** Counts the batch; false when this minute's budget is spent (nothing written). */
export async function record(batch: Batch, store: FunnelStore, now = new Date(), verify: Verify = defaultVerify()): Promise<boolean> {
  const others: FunnelEvent[] = [];
  const purchases: Purchase[] = [];
  for (const event of batch.events) {
    if (!(PURCHASE_EVENTS as readonly string[]).includes(event.name)) others.push(event);
    else if (event.jws) {
      const purchase = verify(event.jws, now);
      if (purchase) purchases.push(purchase);
    }
  }
  const counted = (purchase: Purchase): FunnelEvent => ({ name: purchase.trial ? "trial_started" : "purchase_completed", detail: purchase.product });
  const cost = new Set([...others, ...purchases.map(counted)].flatMap(stepKeys)).size;
  if (!cost) return true;
  if (!(await store.admit(now, cost))) return false;
  const hero = "onboarding_screen_viewed.hero";
  const cohort = await store.cohort(batch.install, batch.strategy, now, others.some((e) => stepKeys(e).includes(hero)));
  if (!cohort) return true;
  const { day, strategy } = cohort;
  // Another install's subscription counts nothing here.
  const mine: Purchase[] = [];
  for (const purchase of purchases) if (await store.claim(purchase.original, batch.install, now)) mine.push(purchase);
  const keys = new Set([...others, ...mine.map(counted)].flatMap(stepKeys));
  if (keys.delete(hero)) await store.countOnce(batch.install, day, strategy, hero, now);
  for (const key of keys) {
    await store.countOnce(batch.install, day, strategy, key, now);
  }
  return true;
}

// Two purchase events with Apple's certificate chain each are about 10 KB.
const MAX_BODY = 64_000;

type Request = { method: string; path: string; body: string | undefined };

type Reply = { statusCode: number; headers: Record<string, string>; body: string };

export async function handleEvents(request: Request, store: FunnelStore, now = new Date(), verify: Verify = defaultVerify()): Promise<Reply> {
  const reply = (statusCode: number): Reply => ({ statusCode, headers: { "cache-control": "no-store" }, body: "" });
  if (request.path !== "/events") return reply(404);
  if (request.method !== "POST") return reply(405);
  if ((request.body?.length ?? 0) > MAX_BODY) return reply(413);
  let batch: Batch | undefined;
  try {
    batch = parseBatch(JSON.parse(request.body ?? ""));
  } catch {
    return reply(400);
  }
  if (!batch) return reply(400);
  return reply((await record(batch, store, now, verify)) ? 204 : 429);
}

/** APPSTORE_ENVIRONMENTS: prod counts Production only (TestFlight's and App Review's Sandbox purchases aren't revenue). */
const defaultVerify = () => appleVerifier((process.env.APPSTORE_ENVIRONMENTS ?? "Production").split(",").map((e) => e.trim()).filter(Boolean));

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE!;
const KEEP_SECONDS = 400 * 24 * 3600;
const expires = (now: Date) => Math.floor(now.getTime() / 1000) + KEEP_SECONDS;
const lost = (error: unknown) => error instanceof ConditionalCheckFailedException;

export const dynamoStore: FunnelStore = {
  async admit(now, cost) {
    try {
      await db.send(new UpdateCommand({
        TableName: TABLE,
        Key: { PK: "FUNNEL#LIMIT", SK: now.toISOString().slice(0, 16) },
        UpdateExpression: "ADD #n :cost SET expiresAt = :exp",
        ConditionExpression: "attribute_not_exists(#n) OR #n < :max",
        ExpressionAttributeNames: { "#n": "keys" },
        ExpressionAttributeValues: { ":cost": cost, ":max": MAX_KEYS_PER_MINUTE, ":exp": Math.floor(now.getTime() / 1000) + 3600 },
      }));
      return true;
    } catch (error) {
      if (lost(error)) return false;
      throw error;
    }
  },
  async claim(original, install, now) {
    try {
      await db.send(new PutCommand({
        TableName: TABLE,
        Item: { PK: `FUNNEL#TXN#${original}`, SK: "INSTALL", install, expiresAt: expires(now) },
        ConditionExpression: "attribute_not_exists(PK) OR #i = :me",
        ExpressionAttributeNames: { "#i": "install" },
        ExpressionAttributeValues: { ":me": install },
      }));
      return true;
    } catch (error) {
      if (lost(error)) return false;
      throw error;
    }
  },
  async cohort(install, strategy, now, starts) {
    const Key = { PK: `FUNNEL#${install}`, SK: "INSTALL" };
    if (starts) {
      const mine = { day: now.toISOString().slice(0, 10), strategy };
      try {
        await db.send(new PutCommand({
          TableName: TABLE, Item: { ...Key, ...mine, expiresAt: expires(now) }, ConditionExpression: "attribute_not_exists(PK)",
        }));
        return mine;
      } catch (error) {
        if (!lost(error)) throw error;
      }
    }
    const { Item } = await db.send(new GetCommand({ TableName: TABLE, Key, ConsistentRead: true }));
    if (Item) return { day: Item.day as string, strategy: Item.strategy as Strategy };
  },
  async countOnce(install, day, strategy, key, now) {
    try {
      await db.send(new TransactWriteCommand({
        TransactItems: [
          { Put: {
            TableName: TABLE,
            Item: { PK: `FUNNEL#${install}`, SK: `STEP#${key}`, expiresAt: expires(now) },
            ConditionExpression: "attribute_not_exists(PK)",
          } },
          { Update: {
            TableName: TABLE,
            Key: { PK: "STATS#FUNNEL", SK: `${day}#${strategy}` },
            UpdateExpression: "ADD #k :one SET #d = :day, #s = :strategy",
            ExpressionAttributeNames: { "#k": key, "#d": "day", "#s": "strategy" },
            ExpressionAttributeValues: { ":one": 1, ":day": day, ":strategy": strategy },
          } },
        ],
      }));
    } catch (error) {
      if (!(error instanceof TransactionCanceledException) ||
          error.CancellationReasons?.[0]?.Code !== "ConditionalCheckFailed") throw error;
    }
  },
};

export async function handler(event: LambdaFunctionURLEvent): Promise<LambdaFunctionURLResult> {
  const body = event.body && event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf8") : event.body;
  try {
    return await handleEvents({ method: event.requestContext.http.method, path: event.rawPath, body }, dynamoStore);
  } catch (error) {
    console.error(error);
    return { statusCode: 500, headers: { "cache-control": "no-store" }, body: "" };
  }
}
