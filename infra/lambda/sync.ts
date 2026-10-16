import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";

// FIT-126: the program and logs, synced both ways. The app (and the web) push changed units; the newest
// updatedAt wins per unit. Every unit lives in the owner's partition, so deleteAccount removes it with the rest.

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export type UnitInput = { key: string; updatedAt: string; deleted: boolean; body?: string | null };
export type Unit = UnitInput & { changedAt: string };

export const MAX_UNITS = 25;
export const MAX_BODY = 100_000;
export const PAGE = 100;
const KEY = /^((plan|log)#\d{4}-\d{2}-\d{2}|goal#[0-9A-Fa-f-]{36}|profile)$/;

/** A unit the server will store, or why not. updatedAt in the future is taken as now, so a wrong clock can't win for good. */
export function checked(unit: UnitInput, now: Date): UnitInput {
  if (!KEY.test(unit.key)) throw new Error(`Not a sync key: ${unit.key}`);
  const at = Date.parse(unit.updatedAt);
  if (Number.isNaN(at)) throw new Error(`Not a time: ${unit.updatedAt}`);
  if (!unit.deleted && typeof unit.body !== "string") throw new Error(`${unit.key} has no body`);
  if ((unit.body?.length ?? 0) > MAX_BODY) throw new Error(`${unit.key} is too large`);
  const updatedAt = new Date(Math.min(at, now.getTime())).toISOString();
  return unit.deleted ? { key: unit.key, updatedAt, deleted: true } : { key: unit.key, updatedAt, deleted: false, body: unit.body };
}

export function item(uid: string, unit: UnitInput, changedAt: string) {
  return {
    PK: `USER#${uid}`,
    SK: `SYNC#${unit.key}`,
    GSI1PK: `SYNC#${uid}`,
    GSI1SK: `${changedAt}#${unit.key}`,
    ...unit,
    changedAt,
  };
}

function unit(stored: Record<string, any>): Unit {
  return { key: stored.key, updatedAt: stored.updatedAt, deleted: !!stored.deleted, body: stored.body ?? null, changedAt: stored.changedAt };
}

export async function push(uid: string, units: UnitInput[], source: string | undefined, now = new Date()) {
  if (units.length > MAX_UNITS) throw new Error(`At most ${MAX_UNITS} units per push`);
  const valid = units.map((u) => checked(u, now));
  const changedAt = now.toISOString();
  const rejected: Unit[] = [];
  for (const u of valid) {
    try {
      await db.send(
        new PutCommand({
          TableName: process.env.TABLE,
          Item: item(uid, u, changedAt),
          ConditionExpression: "attribute_not_exists(PK) OR updatedAt < :u",
          ExpressionAttributeValues: { ":u": u.updatedAt },
        }),
      );
    } catch (error: any) {
      if (error?.name !== "ConditionalCheckFailedException") throw error;
      const kept = await db.send(new GetCommand({ TableName: process.env.TABLE, Key: { PK: `USER#${uid}`, SK: `SYNC#${u.key}` }, ConsistentRead: true }));
      if (kept.Item) rejected.push(unit(kept.Item));
    }
  }
  return { uid, source: source ?? null, changedAt, rejected };
}

/** Units stored after the cursor, oldest first. The cursor is a GSI1SK: when stored, then the key. */
export async function pull(uid: string, since: string | null | undefined) {
  const out = await db.send(
    new QueryCommand({
      TableName: process.env.TABLE,
      IndexName: "GSI1",
      KeyConditionExpression: since ? "GSI1PK = :p AND GSI1SK > :s" : "GSI1PK = :p",
      ExpressionAttributeValues: since ? { ":p": `SYNC#${uid}`, ":s": since } : { ":p": `SYNC#${uid}` },
      Limit: PAGE,
    }),
  );
  const items = out.Items ?? [];
  return {
    units: items.map(unit),
    cursor: items.length ? (items[items.length - 1].GSI1SK as string) : (since ?? null),
    more: !!out.LastEvaluatedKey,
  };
}

export async function handler(event: AppSyncResolverEvent<any>) {
  const uid = (event.identity as AppSyncIdentityCognito).sub;
  switch (event.info.fieldName) {
    case "syncPush":
      return push(uid, event.arguments.units, event.arguments.source);
    case "syncPull":
      return pull(uid, event.arguments.since);
    default:
      throw new Error(`Unknown field ${event.info.fieldName}`);
  }
}
