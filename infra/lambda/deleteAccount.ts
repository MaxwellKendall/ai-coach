import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { BatchWriteCommand, DynamoDBDocumentClient, paginateQuery } from "@aws-sdk/lib-dynamodb";
import { AdminDeleteUserCommand, CognitoIdentityProviderClient } from "@aws-sdk/client-cognito-identity-provider";
import type { AppSyncResolverEvent, AppSyncIdentityCognito } from "aws-lambda";

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const cognito = new CognitoIdentityProviderClient({});
const TABLE = process.env.TABLE!;

type Key = { PK: string; SK: string };

async function queryKeys(input: Record<string, unknown>) {
  const keys: (Key & Record<string, unknown>)[] = [];
  for await (const page of paginateQuery({ client: db }, { TableName: TABLE, ...input } as never)) {
    for (const item of page.Items ?? []) keys.push(item as Key);
  }
  return keys;
}

/** Every item the user owns: their USER# partition, and their items in each group they belong to. */
export async function itemsToDelete(uid: string) {
  const memberships = await queryKeys({
    IndexName: "GSI1",
    KeyConditionExpression: "GSI1PK = :u",
    ExpressionAttributeValues: { ":u": `USER#${uid}` },
  });
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
      return [{ PK: pk, SK: `MEMBER#${uid}` }, { PK: pk, SK: `LIVE#${uid}` }, ...progress, ...feed];
    }),
  );
  return [...own, ...perGroup.flat()].map(({ PK, SK }) => ({ PK, SK }));
}

// App Store 5.1.1(v): in-app account deletion removes the account and the data tied to it.
export async function handler(event: AppSyncResolverEvent<Record<string, never>>) {
  const identity = event.identity as AppSyncIdentityCognito;
  const keys = await itemsToDelete(identity.sub);
  for (let i = 0; i < keys.length; i += 25) {
    let pending: Record<string, unknown[]> | undefined = {
      [TABLE]: keys.slice(i, i + 25).map((Key) => ({ DeleteRequest: { Key } })),
    };
    while (pending && Object.keys(pending).length > 0) {
      const out = await db.send(new BatchWriteCommand({ RequestItems: pending as never }));
      pending = out.UnprocessedItems as Record<string, unknown[]> | undefined;
    }
  }
  await cognito.send(new AdminDeleteUserCommand({ UserPoolId: process.env.USER_POOL_ID, Username: identity.username }));
  return true;
}
