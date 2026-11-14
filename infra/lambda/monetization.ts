import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { monetizationOf, switched, type Monetization, type Strategy } from "../../shared/monetization.ts";
import type { Page } from "./sharePages.ts";

// FIT-454: the monetization switch (shared/monetization.ts), one row in the table.

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const KEY = { PK: "CONFIG", SK: "MONETIZATION" };

export async function readMonetization(): Promise<Monetization> {
  const { Item } = await db.send(new GetCommand({ TableName: process.env.TABLE!, Key: KEY }));
  return monetizationOf(Item);
}

export async function setMonetization(strategy: Strategy, now = new Date()): Promise<Monetization> {
  const next = switched(await readMonetization(), strategy, now);
  await db.send(new PutCommand({ TableName: process.env.TABLE!, Item: { ...KEY, ...next, updatedAt: now.toISOString() } }));
  return next;
}

/** barbrabell.com/monetization.json, read by the app at launch, signed in or not. CloudFront keeps it 5 minutes. */
export async function monetizationRoute(path: string, read: () => Promise<Monetization> = readMonetization): Promise<Page | undefined> {
  if (path !== "/monetization.json") return undefined;
  return { status: 200, type: "application/json", body: JSON.stringify(await read()) };
}
