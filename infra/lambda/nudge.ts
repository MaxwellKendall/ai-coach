import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { dayIn, notify } from "./push.ts";

// FIT-220: the evening of a planned day with nothing logged, a coached client gets "Log today's session?". It runs each
// hour and nudges the devices where it's NUDGE_HOUR; registerDevice lists a device under GSI1 NUDGE once the app sends
// its time zone, and takes it off when the client turns nudges off.

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE!;

export const NUDGE_HOUR = 19;

/** The hour (0-23) at that moment in a time zone, or undefined for a zone that isn't one. */
export function localHour(at: Date, tz: string) {
  try {
    return Number(new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", hourCycle: "h23" }).format(at));
  } catch {
    return undefined;
  }
}

type Row = { kind?: string; slot?: string };
const rows = (body: string | undefined): Row[] => {
  try {
    return body ? JSON.parse(body) : [];
  } catch {
    return [];
  }
};

/** The day's planned session's name when it's planned and nothing is logged yet; undefined on a rest day or once logged. */
export function missed(planBody: string | undefined, logBody: string | undefined) {
  const planned = rows(planBody).filter((r) => r.kind === "workout");
  if (planned.length === 0 || rows(logBody).some((r) => r.kind === "workout")) return undefined;
  return planned.find((r) => r.slot)?.slot ?? "Today's session";
}

export function nudgeText(session: string) {
  return { title: "Log today's session?", body: `${session} is planned for today. Your coach sees it once it's logged.` };
}

async function devicesToNudge() {
  const out: Record<string, any>[] = [];
  let start: Record<string, any> | undefined;
  do {
    const page = await db.send(new QueryCommand({
      TableName: TABLE, IndexName: "GSI1", KeyConditionExpression: "GSI1PK = :p", ExpressionAttributeValues: { ":p": "NUDGE" }, ExclusiveStartKey: start,
    }));
    out.push(...(page.Items ?? []));
    start = page.LastEvaluatedKey;
  } while (start);
  return out;
}

const body = async (uid: string, key: string) => {
  const item = (await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `USER#${uid}`, SK: `SYNC#${key}` } }))).Item;
  return item && !item.deleted ? (item.body as string | undefined) : undefined;
};

/** At most one a day: the first to write USER#uid NUDGE#day sends it. */
async function claim(uid: string, day: string, now: Date) {
  try {
    await db.send(new PutCommand({
      TableName: TABLE,
      Item: { PK: `USER#${uid}`, SK: `NUDGE#${day}`, expiresAt: Math.floor(now.getTime() / 1000) + 2 * 86_400 },
      ConditionExpression: "attribute_not_exists(PK)",
    }));
    return true;
  } catch (error: any) {
    if (error?.name === "ConditionalCheckFailedException") return false;
    throw error;
  }
}

export async function nudge(now: Date) {
  const byUser = new Map<string, Record<string, any>[]>();
  for (const device of await devicesToNudge()) {
    if (localHour(now, device.tz) !== NUDGE_HOUR) continue;
    const uid = String(device.PK).slice("USER#".length);
    byUser.set(uid, [...(byUser.get(uid) ?? []), device]);
  }
  for (const [uid, devices] of byUser) {
    const coached = await db.send(new QueryCommand({
      TableName: TABLE, KeyConditionExpression: "PK = :p AND begins_with(SK, :c)", ExpressionAttributeValues: { ":p": `USER#${uid}`, ":c": "COACH#" }, Limit: 1,
    }));
    if (!coached.Items?.length) continue;
    const today = dayIn(now, devices[0].tz);
    const session = missed(await body(uid, `plan#${today}`), await body(uid, `log#${today}`));
    if (!session || !(await claim(uid, today, now))) continue;
    await notify(devices, nudgeText(session), { kind: "nudge", day: today });
  }
}

export async function handler() {
  await nudge(new Date());
}
