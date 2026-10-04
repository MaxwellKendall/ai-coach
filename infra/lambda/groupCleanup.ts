import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { BatchWriteCommand, DynamoDBDocumentClient, paginateQuery } from "@aws-sdk/lib-dynamodb";
import type { DynamoDBStreamEvent } from "aws-lambda";

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE!;

type Key = { PK: string; SK: string };
type Item = Key & Record<string, unknown>;

/**
 * FIT-61: once a group has no members, nothing in it belongs to anyone, so remove the whole
 * partition and its invite. Returns the keys to delete, or nothing while a member remains.
 */
export function orphanedKeys(groupItems: Item[]): Key[] {
  if (groupItems.some((i) => i.SK.startsWith("MEMBER#"))) return [];
  const meta = groupItems.find((i) => i.SK === "META");
  const invite = typeof meta?.inviteCode === "string" ? [{ PK: `INVITE#${meta.inviteCode}`, SK: "META" }] : [];
  return [...groupItems.map(({ PK, SK }) => ({ PK, SK })), ...invite];
}

async function groupItems(pk: string) {
  const items: Item[] = [];
  const pages = paginateQuery(
    { client: db },
    { TableName: TABLE, KeyConditionExpression: "PK = :pk", ExpressionAttributeValues: { ":pk": pk }, ConsistentRead: true },
  );
  for await (const page of pages) items.push(...((page.Items ?? []) as Item[]));
  return items;
}

/**
 * Runs on every removed MEMBER# item, whichever path removed it (leaveGroup, removeMember, or
 * deleteAccount), so the cleanup lives in one place.
 */
export async function handler(event: DynamoDBStreamEvent) {
  const groups = new Set(event.Records.map((r) => r.dynamodb?.Keys?.PK?.S).filter((pk): pk is string => !!pk));
  for (const pk of groups) {
    const keys = orphanedKeys(await groupItems(pk));
    for (let i = 0; i < keys.length; i += 25) {
      let pending: Record<string, unknown[]> | undefined = {
        [TABLE]: keys.slice(i, i + 25).map((Key) => ({ DeleteRequest: { Key } })),
      };
      while (pending && Object.keys(pending).length > 0) {
        const out = await db.send(new BatchWriteCommand({ RequestItems: pending as never }));
        pending = out.UnprocessedItems as Record<string, unknown[]> | undefined;
      }
    }
  }
}
