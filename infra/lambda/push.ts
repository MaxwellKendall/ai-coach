import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { unmarshall } from "@aws-sdk/util-dynamodb";
import type { DynamoDBStreamEvent } from "aws-lambda";
import { sendAlerts, type ApnsKey } from "./apns.ts";

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const secrets = new SecretsManagerClient({});
const TABLE = process.env.TABLE!;
let apnsKey: ApnsKey | undefined;

type Live = { groupId: string; uid: string; workout?: string; exercise?: string; state: string; startedAt: string };

/**
 * A LIVE item is overwritten every set, so a new session can arrive as INSERT or MODIFY.
 * It's a new session when there was no previous item or startedAt changed.
 */
export function startsSession(oldItem: Live | undefined, newItem: Live) {
  if (newItem.state === "done") return false;
  return !oldItem || oldItem.startedAt !== newItem.startedAt;
}

/** Titled with the group's name, so someone in several groups knows which one. */
export function alertText(name: string | undefined, live: Live, groupName?: string) {
  return { title: groupName ?? "Live now", body: `${name ?? "Someone"} started ${live.workout ?? live.exercise ?? "a workout"}` };
}

async function query(pk: string, prefix: string) {
  const out = await db.send(
    new QueryCommand({
      TableName: TABLE,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :p)",
      ExpressionAttributeValues: { ":pk": pk, ":p": prefix },
    }),
  );
  return out.Items ?? [];
}

/** FIT-132: "Sam replied on Wednesday's session", with the reply. */
export function replyText(byName: string | null | undefined, day: string, text: string) {
  const [y, m, d] = day.split("-").map(Number);
  const weekday = new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });
  return { title: `${byName ?? "Your coach"} replied on ${weekday}'s session`, body: text.length > 180 ? `${text.slice(0, 177)}…` : text };
}

async function key() {
  apnsKey ??= JSON.parse((await secrets.send(new GetSecretValueCommand({ SecretId: process.env.APNS_SECRET }))).SecretString!);
  return apnsKey!;
}

/** Sends one alert to each device, and forgets the ones APNs says are gone (410: uninstalled, or the token expired). */
export async function notify(devices: Record<string, any>[], alert: { title: string; body: string }, data: Record<string, string>) {
  if (devices.length === 0) return;
  const statuses = await sendAlerts(process.env.APNS_HOST!, await key(), devices.map((d) => d.token as string), alert, data);
  const dead = devices.filter((d) => statuses.get(d.token) === 410);
  await Promise.all(dead.map((d) => db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: d.PK, SK: d.SK } }))));
}

async function replied(comment: { owner: string; by: string; byName?: string | null; day: string; text: string }) {
  // Only a coach's reply goes to the client's phone; the client's own words are on it already.
  if (comment.by === comment.owner) return;
  await notify(await query(`USER#${comment.owner}`, "DEVICE#"), replyText(comment.byName, comment.day, comment.text), { kind: "reply", day: comment.day });
}

/** FIT-131: "Sam sent you a 4-week program". */
export function offerText(coachName: string | null | undefined, weeks: number, note: string) {
  return { title: `${coachName ?? "Your coach"} sent you a ${weeks}-week program`, body: note || "Open the app to see it and start." };
}

async function offered(offer: { owner: string; coachName?: string | null; weeks: number; note: string }) {
  await notify(await query(`USER#${offer.owner}`, "DEVICE#"), offerText(offer.coachName, offer.weeks, offer.note), { kind: "offer", offer: "1" });
}

/** The calendar day (YYYY-MM-DD) at that moment in a time zone. Unknown, it's the earliest day anywhere (UTC-12). */
export function dayIn(at: Date, tz: string | undefined) {
  try {
    return at.toLocaleDateString("en-CA", { timeZone: tz ?? "Etc/GMT+12" });
  } catch {
    return at.toLocaleDateString("en-CA", { timeZone: "Etc/GMT+12" });
  }
}

/** FIT-220: several edits within this long make one push. */
export const WEEK_WINDOW_MS = 10 * 60_000;

/** FIT-220: the first changed day from today on, which the push opens; past days aren't news. */
export function firstUpcoming(days: string[], today: string) {
  return days.filter((d) => d >= today).sort()[0];
}

/** FIT-220: "Sam updated your week". */
export function weekText(coachName: string | null | undefined, day: string, today: string) {
  const [y, m, d] = day.split("-").map(Number);
  const weekday = new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });
  return { title: `${coachName ?? "Your coach"} updated your week`, body: day === today ? "Today's session changed. Take a look before you start." : `See what changed, starting ${weekday}.` };
}

/** True for the first coach change in WEEK_WINDOW_MS; the rest of the window's changes ride on that push. */
async function claimWeekPush(owner: string, now: Date) {
  try {
    await db.send(new PutCommand({
      TableName: TABLE,
      Item: { PK: `USER#${owner}`, SK: "NOTIFY#week", sentAt: now.toISOString(), expiresAt: Math.floor(now.getTime() / 1000) + 86_400 },
      ConditionExpression: "attribute_not_exists(PK) OR sentAt < :cutoff",
      ExpressionAttributeValues: { ":cutoff": new Date(now.getTime() - WEEK_WINDOW_MS).toISOString() },
    }));
    return true;
  } catch (error: any) {
    if (error?.name === "ConditionalCheckFailedException") return false;
    throw error;
  }
}

/** FIT-220: a coach changed the client's plan days, from the dashboard or from Claude (sync.ts stores who, as by). */
async function weekChanged(owner: string, coach: string, days: string[], now: Date) {
  const devices = await query(`USER#${owner}`, "DEVICE#");
  if (devices.length === 0) return;
  const today = dayIn(now, devices.find((d) => d.tz)?.tz);
  const day = firstUpcoming(days, today);
  if (!day) return;
  const link = (await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `USER#${owner}`, SK: `COACH#${coach}` } }))).Item;
  if (!link) return;
  if (!(await claimWeekPush(owner, now))) return;
  await notify(devices, weekText(link.coachName, day, today), { kind: "plan", day });
}

export async function handler(event: DynamoDBStreamEvent) {
  // FIT-220: a batch's plan changes, by client and coach, so one apply of a week is one push.
  const changed = new Map<string, { owner: string; coach: string; days: string[] }>();
  for (const record of event.Records) {
    const image = record.dynamodb;
    if (!image?.NewImage) continue;
    if (String(image.Keys?.SK?.S ?? "").startsWith("SYNC#plan#")) {
      const unit = unmarshall(image.NewImage as never) as { PK: string; key: string; by?: string };
      const owner = unit.PK.slice("USER#".length);
      if (!unit.by || unit.by === owner) continue;
      const entry = changed.get(`${owner}#${unit.by}`) ?? { owner, coach: unit.by, days: [] };
      entry.days.push(unit.key.slice("plan#".length));
      changed.set(`${owner}#${unit.by}`, entry);
      continue;
    }
    if (String(image.Keys?.SK?.S ?? "").startsWith("COMMENT#")) {
      // FIT-200: an edited reply isn't news.
      if (record.eventName === "INSERT") await replied(unmarshall(image.NewImage as never) as never);
      continue;
    }
    if (String(image.Keys?.SK?.S ?? "").startsWith("OFFER#")) {
      await offered(unmarshall(image.NewImage as never) as never);
      continue;
    }
    const live = unmarshall(image.NewImage as never) as Live;
    const old = image.OldImage ? (unmarshall(image.OldImage as never) as Live) : undefined;
    if (!startsSession(old, live)) continue;

    const members = await query(`GROUP#${live.groupId}`, "MEMBER#");
    const starter = members.find((m) => m.uid === live.uid);
    const others = members.filter((m) => m.uid !== live.uid);
    const devices = (await Promise.all(others.map((m) => query(`USER#${m.uid}`, "DEVICE#")))).flat();
    await notify(devices, alertText(starter?.displayName, live, starter?.groupName), { groupId: live.groupId });
  }
  for (const { owner, coach, days } of changed.values()) await weekChanged(owner, coach, days, new Date());
}
