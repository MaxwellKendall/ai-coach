import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
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

async function replied(comment: { owner: string; by: string; byName?: string | null; day: string; text: string }) {
  // Only a coach's reply goes to the client's phone; the client's own words are on it already.
  if (comment.by === comment.owner) return;
  const devices = await query(`USER#${comment.owner}`, "DEVICE#");
  if (devices.length === 0) return;
  const statuses = await sendAlerts(process.env.APNS_HOST!, await key(), devices.map((d) => d.token as string),
    replyText(comment.byName, comment.day, comment.text), { day: comment.day });
  const dead = devices.filter((d) => statuses.get(d.token) === 410);
  await Promise.all(dead.map((d) => db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: d.PK, SK: d.SK } }))));
}

/** FIT-131: "Sam sent you a 4-week program". */
export function offerText(coachName: string | null | undefined, weeks: number, note: string) {
  return { title: `${coachName ?? "Your coach"} sent you a ${weeks}-week program`, body: note || "Open the app to see it and start." };
}

async function offered(offer: { owner: string; coachName?: string | null; weeks: number; note: string }) {
  const devices = await query(`USER#${offer.owner}`, "DEVICE#");
  if (devices.length === 0) return;
  const statuses = await sendAlerts(process.env.APNS_HOST!, await key(), devices.map((d) => d.token as string),
    offerText(offer.coachName, offer.weeks, offer.note), { offer: "1" });
  const dead = devices.filter((d) => statuses.get(d.token) === 410);
  await Promise.all(dead.map((d) => db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: d.PK, SK: d.SK } }))));
}

export async function handler(event: DynamoDBStreamEvent) {
  for (const record of event.Records) {
    const image = record.dynamodb;
    if (!image?.NewImage) continue;
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
    if (devices.length === 0) continue;

    const statuses = await sendAlerts(
      process.env.APNS_HOST!,
      await key(),
      devices.map((d) => d.token as string),
      alertText(starter?.displayName, live, starter?.groupName),
      { groupId: live.groupId },
    );
    // 410: the app was uninstalled or the token expired, so it will never work again.
    const dead = devices.filter((d) => statuses.get(d.token) === 410);
    await Promise.all(dead.map((d) => db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: d.PK, SK: d.SK } }))));
  }
}
