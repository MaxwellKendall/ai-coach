import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { readProgram, readRecap, readSession, readWin, route, type Site, type Store } from "./sharePages.ts";

/**
 * FIT-105: the share pages on the web, behind CloudFront (which turns join.{domain}/CODE into /join/CODE).
 * Reads what the app saved with createShare (SHARE#id) and the group invites (INVITE#code).
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE!;

const site: Site = {
  appName: "Rep & Recipe",
  origin: process.env.SHARE_ORIGIN!,
  appStoreUrl: process.env.APP_STORE_URL || undefined,
  appId: process.env.APP_ID!,
};

const first = (name: unknown) => (typeof name === "string" && name.trim() ? name.trim().split(/\s+/)[0] : undefined);

async function shared(id: string, kind: string) {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `SHARE#${id}`, SK: "META" } }));
  if (!Item || Item.kind !== kind) return undefined;
  return { payload: JSON.parse(Item.payload as string) as unknown, name: (Item.name as string) || "A friend" };
}

export const store: Store = {
  async win(id) {
    const s = await shared(id, "win");
    return s && readWin(s.payload, s.name);
  },
  async recap(id) {
    const s = await shared(id, "recap");
    return s && readRecap(s.payload, s.name);
  },
  async program(id) {
    const s = await shared(id, "program");
    return s && readProgram(s.payload, s.name);
  },
  async session(id) {
    const s = await shared(id, "session");
    return s && readSession(s.payload, s.name);
  },
  async invite(code) {
    const { Item } = await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `INVITE#${code}`, SK: "META" } }));
    if (!Item) return undefined;
    const { Items = [] } = await db.send(new QueryCommand({
      TableName: TABLE,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :m)",
      ExpressionAttributeValues: { ":pk": `GROUP#${Item.groupId}`, ":m": "MEMBER#" },
    }));
    const creator = Items.find((m) => m.uid === Item.createdBy);
    // Only first names (the page shows initials), and no activity: anyone with the code can open the page.
    return {
      group: Item.groupName as string,
      by: first(creator?.displayName) ?? "A friend",
      members: Items.map((m) => first(m.displayName) ?? "?"),
      recent: [],
    };
  },
};

export async function handler(event: LambdaFunctionURLEvent): Promise<LambdaFunctionURLResult> {
  try {
    const page = await route(event.rawPath, store, site);
    return {
      statusCode: page.status,
      headers: {
        "content-type": page.type,
        // A shared item can be taken down, so pages are only kept for a few minutes.
        "cache-control": page.status === 200 ? "public, max-age=300" : "public, max-age=60",
        "x-content-type-options": "nosniff",
        "referrer-policy": "strict-origin-when-cross-origin",
      },
      body: page.body,
    };
  } catch (error) {
    console.error(error);
    return { statusCode: 500, headers: { "content-type": "text/plain" }, body: "Something went wrong." };
  }
}
