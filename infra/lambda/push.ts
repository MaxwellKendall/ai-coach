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

export function alertText(name: string | undefined, live: Live) {
  return { title: "Live now", body: `${name ?? "Someone"} started ${live.workout ?? live.exercise ?? "a workout"}` };
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

export async function handler(event: DynamoDBStreamEvent) {
  for (const record of event.Records) {
    const image = record.dynamodb;
    if (!image?.NewImage) continue;
    const live = unmarshall(image.NewImage as never) as Live;
    const old = image.OldImage ? (unmarshall(image.OldImage as never) as Live) : undefined;
    if (!startsSession(old, live)) continue;

    const members = await query(`GROUP#${live.groupId}`, "MEMBER#");
    const starter = members.find((m) => m.uid === live.uid);
    const others = members.filter((m) => m.uid !== live.uid);
    const devices = (await Promise.all(others.map((m) => query(`USER#${m.uid}`, "DEVICE#")))).flat();
    if (devices.length === 0) continue;

    apnsKey ??= JSON.parse((await secrets.send(new GetSecretValueCommand({ SecretId: process.env.APNS_SECRET }))).SecretString!);
    const statuses = await sendAlerts(
      process.env.APNS_HOST!,
      apnsKey!,
      devices.map((d) => d.token as string),
      alertText(starter?.displayName, live),
      { groupId: live.groupId },
    );
    // 410: the app was uninstalled or the token expired, so it will never work again.
    const dead = devices.filter((d) => statuses.get(d.token) === 410);
    await Promise.all(dead.map((d) => db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: d.PK, SK: d.SK } }))));
  }
}
