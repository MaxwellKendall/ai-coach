import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { unmarshall } from "@aws-sdk/util-dynamodb";
import type { DynamoDBStreamEvent } from "aws-lambda";
import { sendAlerts, type ApnsKey } from "./apns.ts";
import { hurts } from "../../shared/triage.ts";

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

type LogRow = { id: string; kind: string; template?: string | null; note?: string; measurements?: { metric: string; value: number }[] };

/** FIT-343: a goal's test (GoalUpdate.marker in the app): a max, reps or a timed run, not a session. */
const isTest = (r: LogRow) => r.kind === "workout" && !!r.measurements?.some((m) => m.metric === "test");

/** FIT-344: the weekly check-in's ratings, as WeeklyCheckIn.ratings names them. */
const RATINGS: [string, string][] = [["energy_1to5", "Energy"], ["stress_1to5", "Stress"], ["soreness_1to5", "Soreness"], ["adherence_1to5", "Plan"]];

/** "Energy 4 · Stress 2 · Soreness 3 · Plan 5", then what they wrote. */
export function checkInText(row: LogRow) {
  const ratings = RATINGS.flatMap(([metric, name]) => {
    const v = row.measurements?.find((m) => m.metric === metric)?.value;
    return v === undefined ? [] : [`${name} ${v}`];
  }).join(" · ");
  return [ratings, row.note?.trim()].filter(Boolean).join("\n");
}

/** "Back squat: 315 lb × 1", "Pull-up: 12 reps", "Run: 3.1 mi in 24:10". */
export function testText(row: LogRow) {
  const v = (metric: string) => row.measurements?.find((m) => m.metric === metric)?.value;
  const meters = v("distance_m"), seconds = v("duration_s"), load = v("load_lb"), reps = v("reps");
  if (meters !== undefined && seconds !== undefined) {
    const s = Math.round(seconds), clock = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    return `Run: ${(meters / 1609.344).toFixed(1)} mi in ${clock}`;
  }
  const name = (row.template ?? "").replace(/-/g, " ");
  const lift = name.charAt(0).toUpperCase() + name.slice(1);
  return load !== undefined ? `${lift}: ${load} lb × ${reps ?? 1}` : `${lift}: ${reps ?? 0} reps`;
}

/**
 * FIT-338: what a client's log change is worth telling their coach, from the day's log before and after: a note that
 * says something hurts first, then a new note, then the day's first session. Nothing for a set added to a session
 * already logged, a daily check-in's weight or sleep, or an edit that changes neither. FIT-351: the day's note (on the
 * sleep row, else the weight row, as Triage reads it) is a note too.
 * FIT-344: a weekly check-in, new or changed (pain when what they wrote says something hurts). FIT-343: a goal's new
 * test, which isn't a session.
 */
export function logNews(before: LogRow[], after: LogRow[]): { kind: "pain" | "note" | "session" | "checkin" | "test"; note?: string; session?: string } | null {
  const note = (rows: LogRow[]) => rows.find((r) => r.kind === "workout" && !r.template && (r.note ?? "").trim())?.note?.trim();
  const said = note(after);
  if (said && said !== note(before)) return { kind: hurts(said) ? "pain" : "note", note: said };
  const dayNote = (rows: LogRow[]) => [...rows.filter((r) => r.kind === "sleep"), ...rows.filter((r) => r.kind === "bodyweight")]
    .map((r) => r.note?.trim()).find(Boolean);
  const wrote = dayNote(after);
  if (wrote && wrote !== dayNote(before)) return { kind: hurts(wrote) ? "pain" : "note", note: wrote };
  const weekly = (rows: LogRow[]) => rows.find((r) => r.kind === "checkin");
  const checked = weekly(after);
  if (checked && JSON.stringify(checked) !== JSON.stringify(weekly(before))) {
    return { kind: hurts(checked.note ?? "") ? "pain" : "checkin", note: checkInText(checked) };
  }
  const tested = after.find((r) => isTest(r) && !before.some((b) => b.id === r.id));
  if (tested) return { kind: "test", note: testText(tested) };
  const lifted = (rows: LogRow[]) => rows.some((r) => r.kind === "workout" && !!r.template && !isTest(r));
  if (lifted(after) && !lifted(before)) {
    return { kind: "session", session: after.find((r) => r.kind === "workout" && r.template && !isTest(r) && r.note)?.note };
  }
  return null;
}

/** FIT-338: "Mike logged Lower A", "Mike: Knee's sore on squats.", "Mike replied on Sunday's session". */
export function coachText(client: string, news: { kind: "pain" | "note" | "session" | "reply" | "checkin" | "test"; note?: string; session?: string; day?: string }) {
  const clip = (text: string) => (text.length > 180 ? `${text.slice(0, 177)}…` : text);
  switch (news.kind) {
    case "pain": return { title: `${client} says something hurts`, body: clip(news.note ?? "") };
    case "note": return { title: `${client} left a note`, body: clip(news.note ?? "") };
    case "session": return { title: `${client} logged ${news.session ?? "a session"}`, body: "Open their day to see the sets." };
    case "checkin": return { title: `${client} checked in`, body: clip(news.note ?? "") };
    case "test": return { title: `${client} recorded a test`, body: clip(news.note ?? "") };
    case "reply": {
      const [y, m, d] = (news.day ?? "").split("-").map(Number);
      const weekday = new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });
      return { title: `${client} replied on ${weekday}`, body: clip(news.note ?? "") };
    }
  }
}

/** FIT-338: tell each of a client's coaches, on every device they have, opening that client's day. */
async function tellCoaches(owner: string, day: string, news: Parameters<typeof coachText>[1]) {
  const links = await query(`USER#${owner}`, "COACH#");
  for (const link of links) {
    const coach = link.coachUid as string;
    const devices = await query(`USER#${coach}`, "DEVICE#");
    if (devices.length === 0) continue;
    const client = (await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `USER#${coach}`, SK: `CLIENT#${owner}` } }))).Item;
    const name = ((client?.clientName as string | undefined) ?? "Your client").split(" ")[0];
    await notify(devices, coachText(name, news), { kind: "client", client: owner, day });
  }
}

async function replied(comment: { owner: string; by: string; byName?: string | null; day: string; text: string }) {
  // FIT-338: the client's own words go to their coach.
  if (comment.by === comment.owner) return tellCoaches(comment.owner, comment.day, { kind: "reply", note: comment.text, day: comment.day });
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
    if (String(image.Keys?.SK?.S ?? "").startsWith("SYNC#log#")) {
      // FIT-338: what the client logged themselves (a coach's correction has a by) may be news for their coach.
      const unit = unmarshall(image.NewImage as never) as { PK: string; key: string; by?: string; body?: string; deleted?: boolean };
      const owner = unit.PK.slice("USER#".length);
      if ((unit.by && unit.by !== owner) || unit.deleted) continue;
      const old = image.OldImage ? (unmarshall(image.OldImage as never) as { body?: string }) : undefined;
      const rows = (body?: string): LogRow[] => { try { return body ? JSON.parse(body) : []; } catch { return []; } };
      const news = logNews(rows(old?.body), rows(unit.body));
      if (news) await tellCoaches(owner, unit.key.slice("log#".length), news);
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
