import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type { DynamoDBStreamEvent } from "aws-lambda";

/**
 * FIT-110: counts what the flywheel makes, by day, from the table's stream: shares made of each kind, groups
 * created and members added. Joins are members added less groups created (the creator is a member too).
 * Page views are counted by the share pages themselves.
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE!;

/** What one new item adds to the day's counts. */
export function counted(pk: string, sk: string, kind?: string): string | undefined {
  if (pk.startsWith("SHARE#") && sk === "META" && kind) return `made_${kind}`;
  if (pk.startsWith("GROUP#") && sk === "META") return "groups";
  if (pk.startsWith("GROUP#") && sk.startsWith("MEMBER#")) return "members";
  return undefined;
}

export async function handler(event: DynamoDBStreamEvent) {
  const adds = new Map<string, number>();
  for (const record of event.Records) {
    const keys = record.dynamodb?.Keys;
    const field = counted(keys?.PK?.S ?? "", keys?.SK?.S ?? "", record.dynamodb?.NewImage?.kind?.S);
    if (field) adds.set(field, (adds.get(field) ?? 0) + 1);
  }
  if (adds.size === 0) return;
  const fields = [...adds.keys()];
  await db.send(new UpdateCommand({
    TableName: TABLE,
    Key: { PK: "STATS#SHARES", SK: new Date().toISOString().slice(0, 10) },
    UpdateExpression: `ADD ${fields.map((_, i) => `#f${i} :v${i}`).join(", ")}`,
    ExpressionAttributeNames: Object.fromEntries(fields.map((f, i) => [`#f${i}`, f])),
    ExpressionAttributeValues: Object.fromEntries(fields.map((f, i) => [`:v${i}`, adds.get(f)!])),
  }));
}
