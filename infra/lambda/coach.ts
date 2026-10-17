import { randomBytes } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, QueryCommand, TransactWriteCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";

// FIT-130: coaches and their clients. A coach (any account) makes an invite link; the client opens it in the app and
// allows it. The link is two items, one in each partition (USER#client COACH#coach, USER#coach CLIENT#client), so
// either side sees it and either can end it at once. A linked coach reads and edits the client's synced program
// (sync.ts asks `isCoachOf`), and the client has Pro while linked (free during the beta, author 2026-10-16).

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;

/** Codes like gifts' (no 0, 1, I or O), 10 long. */
export const ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
export const INVITE_DAYS = 14;

export function newCode(bytes = randomBytes(10)) {
  return [...bytes].map((b) => ALPHABET[b % 32]).join("");
}

export function readCode(input: string): string | undefined {
  const code = input.trim().toUpperCase().replace(/[-\s]/g, "");
  return code.length === 10 && [...code].every((c) => ALPHABET.includes(c)) ? code : undefined;
}

export class CoachError extends Error {}

export type Person = { uid: string; name: string | null; since: string };

async function nameOf(uid: string, claims?: Record<string, unknown>) {
  const fromToken = typeof claims?.name === "string" && claims.name.trim() ? claims.name.trim() : undefined;
  if (fromToken) return fromToken;
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${uid}`, SK: "PROFILE" } }));
  return (Item?.displayName as string | undefined) ?? null;
}

export async function isCoachOf(coach: string, client: string) {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${client}`, SK: `COACH#${coach}` }, ConsistentRead: true }));
  return !!Item;
}

/** Whether an account has a coach: the client's Pro while linked (FIT-130). */
export async function coached(uid: string) {
  const { Items } = await db.send(new QueryCommand({
    TableName: TABLE(),
    KeyConditionExpression: "PK = :pk AND begins_with(SK, :c)",
    ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":c": "COACH#" },
    Limit: 1,
  }));
  return (Items?.length ?? 0) > 0;
}

/** Whether an account coaches anyone: Claude for program design is theirs during the coach beta (FIT-141). */
export async function coaching(uid: string) {
  const { Items } = await db.send(new QueryCommand({
    TableName: TABLE(),
    KeyConditionExpression: "PK = :pk AND begins_with(SK, :c)",
    ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":c": "CLIENT#" },
    Limit: 1,
  }));
  return (Items?.length ?? 0) > 0;
}

export async function createInvite(coach: string, claims: Record<string, unknown> | undefined, now = new Date()) {
  const code = newCode();
  await db.send(new TransactWriteCommand({
    TransactItems: [{
      Put: {
        TableName: TABLE(),
        Item: {
          PK: `COACHINVITE#${code}`, SK: "META", coachUid: coach, coachName: await nameOf(coach, claims),
          createdAt: now.toISOString(), expiresAt: Math.floor(now.getTime() / 1000) + INVITE_DAYS * 86_400,
        },
        ConditionExpression: "attribute_not_exists(PK)",
      },
    }],
  }));
  return { code, url: `${process.env.SHARE_ORIGIN}/c/${code}` };
}

async function invite(code: string, now: Date) {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `COACHINVITE#${code}`, SK: "META" }, ConsistentRead: true }));
  // TTL deletes late, so the expiry is checked here too.
  return Item && Item.expiresAt > now.getTime() / 1000 ? Item : undefined;
}

/** The coach's name on an invite, for the app to ask "Let Sam coach you?"; null when it's used up or expired. */
export async function inviteName(input: string, now = new Date()) {
  const code = readCode(input);
  if (!code) return null;
  const found = await invite(code, now);
  return found ? ((found.coachName as string | null) ?? "Your coach") : null;
}

export async function accept(client: string, input: string, claims: Record<string, unknown> | undefined, now = new Date()): Promise<Person> {
  const code = readCode(input);
  const found = code && (await invite(code, now));
  if (!code || !found) throw new CoachError("This invite has been used or has expired. Ask your coach for a new link.");
  const coach = found.coachUid as string;
  if (coach === client) throw new CoachError("That's your own invite. Send it to the person you coach.");
  const since = now.toISOString();
  const coachName = (found.coachName as string | null) ?? null;
  await db.send(new TransactWriteCommand({
    TransactItems: [
      { Put: { TableName: TABLE(), Item: { PK: `USER#${client}`, SK: `COACH#${coach}`, coachUid: coach, coachName, since } } },
      { Put: { TableName: TABLE(), Item: { PK: `USER#${coach}`, SK: `CLIENT#${client}`, clientUid: client, clientName: await nameOf(client, claims), since } } },
      // Single use: the link is for one client.
      { Delete: { TableName: TABLE(), Key: { PK: `COACHINVITE#${code}`, SK: "META" }, ConditionExpression: "attribute_exists(PK)" } },
    ],
  }));
  return { uid: coach, name: coachName, since };
}

async function list(uid: string, prefix: "COACH#" | "CLIENT#"): Promise<Person[]> {
  const { Items } = await db.send(new QueryCommand({
    TableName: TABLE(),
    KeyConditionExpression: "PK = :pk AND begins_with(SK, :p)",
    ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":p": prefix },
  }));
  return (Items ?? []).map((i) => prefix === "COACH#"
    ? { uid: i.coachUid, name: i.coachName ?? null, since: i.since }
    : { uid: i.clientUid, name: i.clientName ?? null, since: i.since });
}

/** Ends a link from either side: both items go, so the coach's access ends at once. */
export async function unlink(coach: string, client: string) {
  await Promise.all([
    db.send(new DeleteCommand({ TableName: TABLE(), Key: { PK: `USER#${client}`, SK: `COACH#${coach}` } })),
    db.send(new DeleteCommand({ TableName: TABLE(), Key: { PK: `USER#${coach}`, SK: `CLIENT#${client}` } })),
  ]);
  return true;
}

// FIT-132: replies on a session, one thread per logged day, in the client's partition (so they go with the account).
export type Comment = { day: string; at: string; by: string; byName: string | null; text: string };
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** The account a thread is in: the caller's own, or a client's when the caller is their coach. */
async function threadOwner(caller: string, asked?: string) {
  if (!asked || asked === caller) return caller;
  if (await isCoachOf(caller, asked)) return asked;
  throw new CoachError("You don't coach this person.");
}

export async function postComment(caller: string, claims: Record<string, unknown> | undefined, uid: string | undefined,
                                  day: string, text: string, now = new Date()): Promise<Comment> {
  const owner = await threadOwner(caller, uid);
  const body = text.trim();
  if (!DAY.test(day)) throw new CoachError("Not a day.");
  if (!body) throw new CoachError("Write something first.");
  if (body.length > 1000) throw new CoachError("That's too long for a reply (1,000 characters).");
  const comment: Comment = { day, at: now.toISOString(), by: caller, byName: await nameOf(caller, claims), text: body };
  await db.send(new TransactWriteCommand({
    TransactItems: [{ Put: { TableName: TABLE(), Item: { PK: `USER#${owner}`, SK: `COMMENT#${day}#${comment.at}#${caller}`, owner, ...comment } } }],
  }));
  return comment;
}

/** A day's thread, or every thread on the account, oldest first. */
export async function comments(caller: string, uid: string | undefined, day?: string): Promise<Comment[]> {
  const owner = await threadOwner(caller, uid);
  if (day && !DAY.test(day)) throw new CoachError("Not a day.");
  const { Items } = await db.send(new QueryCommand({
    TableName: TABLE(),
    KeyConditionExpression: "PK = :pk AND begins_with(SK, :p)",
    ExpressionAttributeValues: { ":pk": `USER#${owner}`, ":p": day ? `COMMENT#${day}#` : "COMMENT#" },
  }));
  return (Items ?? []).map((i) => ({ day: i.day, at: i.at, by: i.by, byName: i.byName ?? null, text: i.text }));
}

export async function handler(event: AppSyncResolverEvent<Record<string, string>>) {
  const identity = event.identity as AppSyncIdentityCognito;
  const me = identity.sub;
  const args = event.arguments;
  try {
    switch (event.info.fieldName) {
      case "createClientInvite": return await createInvite(me, identity.claims);
      case "coachInvite": return await inviteName(args.code);
      case "acceptCoach": return await accept(me, args.code, identity.claims);
      case "myCoaches": return await list(me, "COACH#");
      case "myClients": return await list(me, "CLIENT#");
      case "unlinkCoach": return await unlink(args.uid, me);
      case "removeClient": return await unlink(me, args.uid);
      case "postComment": return await postComment(me, identity.claims, args.uid, args.day, args.text);
      case "comments": return await comments(me, args.uid, args.day);
      default: throw new Error(`Unknown field ${event.info.fieldName}`);
    }
  } catch (e) {
    // AppSync shows a thrown error's message to the app, as FIT-122's gifts do.
    if (e instanceof CoachError) throw e;
    if ((e as Error).name === "TransactionCanceledException") {
      throw new CoachError("This invite has been used or has expired. Ask your coach for a new link.");
    }
    throw e;
  }
}
