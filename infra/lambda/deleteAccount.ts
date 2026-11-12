import { ConditionalCheckFailedException, DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { BatchWriteCommand, DeleteCommand, DynamoDBDocumentClient, paginateQuery } from "@aws-sdk/lib-dynamodb";
import { AdminDeleteUserCommand, CognitoIdentityProviderClient } from "@aws-sdk/client-cognito-identity-provider";
import { DeleteObjectsCommand, S3Client } from "@aws-sdk/client-s3";
import type { AppSyncResolverEvent, AppSyncIdentityCognito } from "aws-lambda";
import { deletedAccountKey } from "./plan.ts";

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const cognito = new CognitoIdentityProviderClient({});
const s3 = new S3Client({});
const TABLE = process.env.TABLE!;

type Key = { PK: string; SK: string };

async function queryKeys(input: Record<string, unknown>) {
  const keys: (Key & Record<string, unknown>)[] = [];
  for await (const page of paginateQuery({ client: db }, { TableName: TABLE, ...input } as never)) {
    for (const item of page.Items ?? []) keys.push(item as Key);
  }
  return keys;
}

/** Every item the user owns: their USER# partition, what they shared (FIT-105), and their items in each group. */
export async function itemsToDelete(uid: string) {
  const indexed = await queryKeys({
    IndexName: "GSI1",
    KeyConditionExpression: "GSI1PK = :u",
    ExpressionAttributeValues: { ":u": `USER#${uid}` },
  });
  const memberships = indexed.filter((i) => String(i.GSI1SK).startsWith("GROUP#"));
  const shares = indexed.filter((i) => String(i.GSI1SK).startsWith("SHARE#"));
  // FIT-437: their App Store subscriptions' links, so a new account can restore them (appStore.ts, deleted accounts).
  const purchases = indexed.filter((i) => String(i.GSI1SK).startsWith("APPSTORETXN#"));
  const own = await queryKeys({
    KeyConditionExpression: "PK = :pk",
    ExpressionAttributeValues: { ":pk": `USER#${uid}` },
  });
  const perGroup = await Promise.all(
    memberships.map(async (m) => {
      const pk = m.PK;
      const progress = await queryKeys({
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :p)",
        ExpressionAttributeValues: { ":pk": pk, ":p": `PROGRESS#${uid}#` },
      });
      const feed = await queryKeys({
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :f)",
        FilterExpression: "#uid = :uid",
        ExpressionAttributeNames: { "#uid": "uid" },
        ExpressionAttributeValues: { ":pk": pk, ":f": "FEED#", ":uid": uid },
      });
      return [{ PK: pk, SK: `MEMBER#${uid}` }, { PK: pk, SK: `LIVE#${uid}` }, { PK: pk, SK: `WEEK#${uid}` }, ...progress, ...feed];
    }),
  );
  // FIT-130: a coach link has an item in the other person's partition too.
  const links = own.flatMap((i) => {
    const sk = String(i.SK);
    if (sk.startsWith("COACH#")) return [{ PK: `USER#${sk.slice(6)}`, SK: `CLIENT#${uid}` }];
    if (sk.startsWith("CLIENT#")) return [{ PK: `USER#${sk.slice(7)}`, SK: `COACH#${uid}` }];
    return [];
  });
  return [...own, ...shares, ...purchases, ...perGroup.flat(), ...links].map(({ PK, SK }) => ({ PK, SK }));
}

// App Store 5.1.1(v): in-app account deletion removes the account and the data tied to it.
async function batchWrite(requests: unknown[]) {
  for (let i = 0; i < requests.length; i += 25) {
    let pending: Record<string, unknown[]> | undefined = { [TABLE]: requests.slice(i, i + 25) };
    while (pending && Object.keys(pending).length > 0) {
      const out = await db.send(new BatchWriteCommand({ RequestItems: pending as never }));
      pending = out.UnprocessedItems as Record<string, unknown[]> | undefined;
    }
  }
}

/**
 * FIT-437: the marker that the account is gone, written before anything is deleted, so an App Store notification
 * racing the deletion can't link the account's subscription or save its plan again. Only the opaque uid and a date.
 */
export const deletedMarker = (uid: string, now = new Date()) => ({ ...deletedAccountKey(uid), deletedAt: now.toISOString() });

export async function handler(event: AppSyncResolverEvent<Record<string, never>>) {
  const identity = event.identity as AppSyncIdentityCognito;
  await batchWrite([{ PutRequest: { Item: deletedMarker(identity.sub) } }]);
  const keys = await itemsToDelete(identity.sub);
  const isLink = (k: Key) => k.PK.startsWith("APPSTORETXN#");
  await batchWrite(keys.filter((k) => !isLink(k)).map((Key) => ({ DeleteRequest: { Key } })));
  // FIT-437: a link can be taken over by another account between finding it and deleting it (appStore.ts, link), and
  // BatchWrite can't hold a condition: each is deleted only while it's still this account's.
  for (const Key of keys.filter(isLink)) {
    try {
      await db.send(new DeleteCommand({
        TableName: TABLE, Key, ConditionExpression: "#uid = :uid",
        ExpressionAttributeNames: { "#uid": "uid" }, ExpressionAttributeValues: { ":uid": identity.sub },
      }));
    } catch (error) {
      if (!(error instanceof ConditionalCheckFailedException)) throw error;
    }
  }
  // FIT-107: the images of what they shared.
  const cards = keys.filter((k) => k.PK.startsWith("SHARE#")).map((k) => ({ Key: `cards/${k.PK.slice(6)}.png` }));
  for (let i = 0; i < cards.length; i += 1000) {
    await s3.send(new DeleteObjectsCommand({ Bucket: process.env.CARDS_BUCKET, Delete: { Objects: cards.slice(i, i + 1000), Quiet: true } }));
  }
  await cognito.send(new AdminDeleteUserCommand({ UserPoolId: process.env.USER_POOL_ID, Username: identity.username }));
  return true;
}
