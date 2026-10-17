import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { BatchGetCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import { CoachError, isCoachOf } from "./coach.ts";
import { push, type UnitInput } from "./sync.ts";

// FIT-131: a coach sends a client a program: a template week repeated for some weeks from a start day, with a note.
// It waits in the client's partition as an offer until the client answers in the app (author, 2026-10-16: the client
// accepts). Start writes it into their synced plan (FIT-126) from the start day: each day's workouts are the coach's,
// pinned and marked "From Sam" so the app's planner leaves the week alone; cooking and groceries stay; days already
// trained are kept. The coach sees each offer's state.

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
export const MAX_WEEKS = 16;

export type Measurement = { metric: string; value: number; unit: string };
export type TemplateRow = { template: string; targets: Measurement[]; note?: string; group?: number | null; main?: boolean };
/** weekday: 0 = Sunday … 6 = Saturday, as the app's weeks run (FIT-82). */
export type TemplateDay = { weekday: number; slot: string; rows: TemplateRow[] };
export type Offer = {
  id: string; coachUid: string; coachName: string | null; note: string; start: string; weeks: number;
  days: string; addPerWeek: number; status: "sent" | "started" | "declined"; createdAt: string; answeredAt?: string;
};

export function checkDays(json: string): TemplateDay[] {
  let days: TemplateDay[];
  try {
    days = JSON.parse(json);
  } catch {
    throw new CoachError("The program couldn't be read.");
  }
  if (!Array.isArray(days) || days.length === 0) throw new CoachError("Add at least one session to the week.");
  const seen = new Set<number>();
  for (const d of days) {
    if (!Number.isInteger(d.weekday) || d.weekday < 0 || d.weekday > 6 || seen.has(d.weekday)) throw new CoachError("Each day once, Sunday to Saturday.");
    seen.add(d.weekday);
    if (typeof d.slot !== "string" || !Array.isArray(d.rows) || d.rows.length === 0 || d.rows.length > 30) throw new CoachError("Each session needs exercises.");
    for (const r of d.rows) {
      if (typeof r.template !== "string" || !Array.isArray(r.targets)) throw new CoachError("An exercise couldn't be read.");
    }
  }
  return days;
}

const addDays = (day: string, n: number) => {
  const [y, m, d] = day.split("-").map(Number);
  const date = new Date(Date.UTC(y, m - 1, d + n));
  return date.toISOString().slice(0, 10);
};
const weekdayOf = (day: string) => new Date(`${day}T00:00:00Z`).getUTCDay();

/** Every session the offer plans: its day, and its rows with this week's loads (main lifts up `addPerWeek` lb a week). */
export function expand(offer: Pick<Offer, "start" | "weeks" | "addPerWeek">, days: TemplateDay[]) {
  const sunday = addDays(offer.start, -weekdayOf(offer.start));
  const out: { day: string; slot: string; rows: TemplateRow[] }[] = [];
  for (let w = 0; w < offer.weeks; w++) {
    for (const d of [...days].sort((a, b) => a.weekday - b.weekday)) {
      const day = addDays(sunday, 7 * w + d.weekday);
      if (day < offer.start) continue;
      const rows = d.rows.map((r) => ({
        ...r,
        targets: r.targets.map((t) => (r.main && offer.addPerWeek && (t.metric === "load_lb" || t.metric === "load_lb_hand") && r.note !== "warm-up"
          ? { ...t, value: t.value + offer.addPerWeek * w } : t)),
      }));
      out.push({ day, slot: d.slot, rows });
    }
  }
  return out;
}

/** The plan rows for a day: the coach's session at the client's workout time (local), then what else was planned that day. */
export function dayRows(day: string, slot: string, rows: TemplateRow[], coachName: string | null, minutes: number, offsetMinutes: number,
                        others: Record<string, unknown>[]) {
  const [y, m, d] = day.split("-").map(Number);
  // Local midnight is UTC midnight minus the client's offset from UTC.
  const start = Date.UTC(y, m - 1, d) / 1000 - offsetMinutes * 60 + minutes * 60;
  const reason = `From ${coachName ?? "your coach"}`;
  const workouts = rows.map((r, i) => ({
    id: randomUUID(), kind: "workout", at: start + i, slot, template: r.template, targets: r.targets, note: r.note ?? "",
    adjustedReason: reason, ...(r.group != null ? { group: r.group } : {}), main: !!r.main, pinned: true,
  }));
  return [...workouts, ...others];
}

export async function send(coach: string, coachName: string | null, client: string, start: string, weeks: number, note: string,
                           daysJson: string, addPerWeek: number, now = new Date()): Promise<Offer> {
  if (!(await isCoachOf(coach, client))) throw new CoachError("You don't coach this person.");
  if (!DAY.test(start)) throw new CoachError("Pick a start day.");
  if (!Number.isInteger(weeks) || weeks < 1 || weeks > MAX_WEEKS) throw new CoachError(`From 1 to ${MAX_WEEKS} weeks.`);
  if (note.length > 500) throw new CoachError("The note is too long (500 characters).");
  if (!(addPerWeek >= 0 && addPerWeek <= 20)) throw new CoachError("Up to 20 lb a week.");
  checkDays(daysJson);
  const offer: Offer = {
    id: randomUUID(), coachUid: coach, coachName, note: note.trim(), start, weeks, days: daysJson, addPerWeek,
    status: "sent", createdAt: now.toISOString(),
  };
  await db.send(new PutCommand({ TableName: TABLE(), Item: { PK: `USER#${client}`, SK: `OFFER#${offer.id}`, owner: client, ...offer } }));
  return offer;
}

export async function offers(caller: string, client?: string): Promise<Offer[]> {
  const owner = client ?? caller;
  if (owner !== caller && !(await isCoachOf(caller, owner))) throw new CoachError("You don't coach this person.");
  const { Items = [] } = await db.send(new QueryCommand({
    TableName: TABLE(),
    KeyConditionExpression: "PK = :pk AND begins_with(SK, :o)",
    ExpressionAttributeValues: { ":pk": `USER#${owner}`, ":o": "OFFER#" },
  }));
  // A coach sees only their own offers to this client.
  return (Items as Offer[]).filter((o) => owner === caller || o.coachUid === caller)
    .map(({ id, coachUid, coachName, note, start, weeks, days, addPerWeek, status, createdAt, answeredAt }) =>
      ({ id, coachUid, coachName, note, start, weeks, days, addPerWeek, status, createdAt, answeredAt }))
    .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1));
}

/** The client answers. Start writes the program into their synced plan; either way the coach sees the answer. */
export async function answer(client: string, id: string, start: boolean, offsetMinutes: number, now = new Date()): Promise<Offer> {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${client}`, SK: `OFFER#${id}` }, ConsistentRead: true }));
  const offer = Item as (Offer & { PK: string }) | undefined;
  if (!offer) throw new CoachError("This program isn't here any more.");
  if (offer.status !== "sent") throw new CoachError("You've already answered this program.");
  if (start) await write(client, offer, offsetMinutes, now);
  const status = start ? "started" : "declined";
  await db.send(new UpdateCommand({
    TableName: TABLE(), Key: { PK: `USER#${client}`, SK: `OFFER#${id}` },
    UpdateExpression: "SET #s = :s, answeredAt = :a", ExpressionAttributeNames: { "#s": "status" },
    ExpressionAttributeValues: { ":s": status, ":a": now.toISOString() },
  }));
  return { ...offer, status, answeredAt: now.toISOString() };
}

async function unitsFor(client: string, keys: string[]) {
  const found = new Map<string, Record<string, unknown>>();
  for (let i = 0; i < keys.length; i += 100) {
    const out = await db.send(new BatchGetCommand({
      RequestItems: { [TABLE()]: { Keys: keys.slice(i, i + 100).map((k) => ({ PK: `USER#${client}`, SK: `SYNC#${k}` })) } },
    }));
    for (const item of out.Responses?.[TABLE()] ?? []) found.set(item.key as string, item);
  }
  return found;
}

/** Writes the offer's sessions into the client's plan units, replacing their workouts from the start day to the end. */
async function write(client: string, offer: Offer, offsetMinutes: number, now: Date) {
  const sessions = expand(offer, checkDays(offer.days));
  const end = addDays(offer.start, offer.weeks * 7 + 6 - weekdayOf(offer.start));
  const allDays: string[] = [];
  for (let d = offer.start; d <= end; d = addDays(d, 1)) allDays.push(d);
  const existing = await unitsFor(client, ["profile", ...allDays.flatMap((d) => [`plan#${d}`, `log#${d}`])]);
  const profileBody = existing.get("profile")?.body as string | undefined;
  const minutes = profileBody ? (JSON.parse(profileBody).workoutTime ?? 420) : 420;
  const byDay = new Map(sessions.map((s) => [s.day, s]));
  const units: UnitInput[] = [];
  for (const day of allDays) {
    const logged = existing.get(`log#${day}`);
    if (logged?.body && (JSON.parse(logged.body as string) as { kind: string }[]).some((r) => r.kind === "workout")) continue;
    const planned = existing.get(`plan#${day}`);
    const rows: Record<string, unknown>[] = planned?.body ? JSON.parse(planned.body as string) : [];
    const others = rows.filter((r) => r.kind !== "workout");
    const session = byDay.get(day);
    if (!session && rows.length === others.length) continue;
    const body = session ? dayRows(day, session.slot, session.rows, offer.coachName, minutes, offsetMinutes, others) : others;
    units.push({ key: `plan#${day}`, updatedAt: now.toISOString(), deleted: body.length === 0, body: body.length ? JSON.stringify(body) : undefined });
  }
  for (let i = 0; i < units.length; i += 25) await push(client, units.slice(i, i + 25), "coach", now);
}

export async function handler(event: AppSyncResolverEvent<Record<string, any>>) {
  const identity = event.identity as AppSyncIdentityCognito;
  const me = identity.sub;
  const a = event.arguments;
  switch (event.info.fieldName) {
    case "sendProgram": {
      const name = typeof identity.claims?.name === "string" ? identity.claims.name : null;
      const profile = name ? undefined : (await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${me}`, SK: "PROFILE" } }))).Item;
      // AppSync hands an AWSJSON argument to Lambda already parsed.
      const days = typeof a.days === "string" ? a.days : JSON.stringify(a.days);
      return send(me, name ?? (profile?.displayName as string | undefined) ?? null, a.uid, a.start, a.weeks, a.note ?? "", days, a.addPerWeek ?? 0);
    }
    case "programOffers": return offers(me, a.uid ?? undefined);
    case "answerProgram": return answer(me, a.id, a.start, a.offsetMinutes ?? 0);
    default: throw new Error(`Unknown field ${event.info.fieldName}`);
  }
}
