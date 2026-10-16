import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import type { PostConfirmationTriggerEvent } from "aws-lambda";

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));

/** The PROFILE item, once. Native Apple users (FIT-138) get theirs from appleStart, which also calls this. */
export async function saveProfile(uid: string, displayName: string | undefined) {
  const now = new Date().toISOString();
  try {
    await db.send(
      new PutCommand({
        TableName: process.env.TABLE,
        Item: { PK: `USER#${uid}`, SK: "PROFILE", uid, displayName: displayName || null, units: "lb", createdAt: now, updatedAt: now },
        ConditionExpression: "attribute_not_exists(PK)",
      }),
    );
  } catch (e) {
    if ((e as Error).name !== "ConditionalCheckFailedException") throw e;
  }
}

// Creates the PROFILE item on first sign-in. Apple only shares the name the first time, so keep
// whatever we get; the app can change it later with updateProfile.
export async function handler(event: PostConfirmationTriggerEvent) {
  const attrs = event.request.userAttributes;
  await saveProfile(attrs.sub, attrs.name || attrs.given_name);
  return event;
}
