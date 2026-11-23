import { ConditionalCheckFailedException, DynamoDBClient, TransactionCanceledException } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, TransactWriteCommand } from "@aws-sdk/lib-dynamodb";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { parseBatch, stepKeys, type Batch } from "../../shared/funnel.ts";
import type { Strategy } from "../../shared/monetization.ts";

// TKL-466: POST barbrabell.com/events, the first launch's funnel (shared/funnel.ts). No sign-in: it runs before there
// is one. Each install keeps one row with its cohort (FUNNEL#install / INSTALL) and one per step it reached
// (FUNNEL#install / STEP#key), both gone after 400 days; the day's counters (STATS#FUNNEL / day#strategy) stay.

export type FunnelStore = {
  /** The install's cohort is fixed when it sees the hero for the first time. */
  cohort(install: string, strategy: Strategy, now: Date, starts: boolean): Promise<{ day: string; strategy: Strategy } | undefined>;
  countOnce(install: string, day: string, strategy: Strategy, key: string, now: Date): Promise<void>;
};

export async function record(batch: Batch, store: FunnelStore, now = new Date()) {
  if (!batch.events.length) return;
  const keys = new Set(batch.events.flatMap(stepKeys));
  const hero = "onboarding_screen_viewed.hero";
  const cohort = await store.cohort(batch.install, batch.strategy, now, keys.has(hero));
  if (!cohort) return;
  const { day, strategy } = cohort;
  if (keys.delete(hero)) await store.countOnce(batch.install, day, strategy, hero, now);
  for (const key of keys) {
    await store.countOnce(batch.install, day, strategy, key, now);
  }
}

const MAX_BODY = 32_000;

type Request = { method: string; path: string; body: string | undefined };

type Reply = { statusCode: number; headers: Record<string, string>; body: string };

export async function handleEvents(request: Request, store: FunnelStore, now = new Date()): Promise<Reply> {
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
  await record(batch, store, now);
  return reply(204);
}

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE!;
const KEEP_SECONDS = 400 * 24 * 3600;
const expires = (now: Date) => Math.floor(now.getTime() / 1000) + KEEP_SECONDS;
const lost = (error: unknown) => error instanceof ConditionalCheckFailedException;

export const dynamoStore: FunnelStore = {
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
