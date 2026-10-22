import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import { canCoach } from "./coach.ts";

// FIT-126: the program and logs, synced both ways. The app (and the web) push changed units; the newest
// updatedAt wins per unit. Every unit lives in the owner's partition, so deleteAccount removes it with the rest.

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export type UnitInput = { key: string; updatedAt: string; deleted: boolean; body?: string | null };
export type Unit = UnitInput & { changedAt: string };

export const MAX_UNITS = 25;
export const MAX_BODY = 100_000;
export const PAGE = 100;
// FIT-173: template#slug is an exercise the user made (SyncUnits.TemplateBody).
const KEY = /^((plan|log)#\d{4}-\d{2}-\d{2}|goal#[0-9A-Fa-f-]{36}|template#[a-z0-9]+(-[a-z0-9]+)*|profile)$/;

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

// by: who wrote it, when it isn't the owner (FIT-220: a coach's change to the plan is pushed to the client).
export function item(uid: string, unit: UnitInput, changedAt: string, by = uid) {
  return {
    PK: `USER#${uid}`,
    SK: `SYNC#${unit.key}`,
    GSI1PK: `SYNC#${uid}`,
    GSI1SK: `${changedAt}#${unit.key}`,
    ...unit,
    changedAt,
    ...(by !== uid ? { by } : {}),
  };
}

function unit(stored: Record<string, any>): Unit {
  return { key: stored.key, updatedAt: stored.updatedAt, deleted: !!stored.deleted, body: stored.body ?? null, changedAt: stored.changedAt };
}

export async function push(uid: string, units: UnitInput[], source: string | undefined, now = new Date(), by = uid) {
  if (units.length > MAX_UNITS) throw new Error(`At most ${MAX_UNITS} units per push`);
  const valid = units.map((u) => checked(u, now));
  const changedAt = now.toISOString();
  const rejected: Unit[] = [];
  for (const u of valid) {
    try {
      await db.send(
        new PutCommand({
          TableName: process.env.TABLE,
          Item: item(uid, u, changedAt, by),
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

/** Whose units a call is about: the caller's own, or (FIT-130) a client's when the caller is their linked coach. */
export async function owner(caller: string, asked: string | null | undefined) {
  if (!asked || asked === caller) return caller;
  if (await canCoach(caller, asked)) return asked;
  throw new Error("Unauthorized: not this person's coach");
}

/** A coach changes the client's plan and (FIT-200) corrects what they logged, never their goals or their profile. */
export function coachMayWrite(units: UnitInput[]) {
  if (units.some((u) => !u.key.startsWith("plan#") && !u.key.startsWith("log#"))) {
    throw new Error("Unauthorized: a coach changes only the plan and the logs");
  }
}

export async function handler(event: AppSyncResolverEvent<any>) {
  const caller = (event.identity as AppSyncIdentityCognito).sub;
  const uid = await owner(caller, event.arguments.uid);
  switch (event.info.fieldName) {
    case "syncPush":
      if (uid !== caller) coachMayWrite(event.arguments.units);
      return push(uid, event.arguments.units, event.arguments.source, new Date(), caller);
    case "syncPull":
      return pull(uid, event.arguments.since);
    default:
      throw new Error(`Unknown field ${event.info.fieldName}`);
  }
}
