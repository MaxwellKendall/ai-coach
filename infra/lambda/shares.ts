import { DeleteObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";

/**
 * FIT-107: what a share needs beyond its row. The app uploads the card it already renders, so link previews
 * (iMessage, WhatsApp) show it: this hands out a short-lived upload URL for that share's image only. And the
 * sharer can take a share down: the row and its image go, and the link says it has expired.
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});
const TABLE = process.env.TABLE!;
const BUCKET = process.env.CARDS_BUCKET!;

/** Where a share's card lives, in the bucket and on the site (CloudFront serves /cards/* from the bucket). */
export const cardKey = (id: string) => `cards/${id}.png`;

async function ownShare(id: string, uid: string) {
  if (!/^[0-9a-f]{12}$/.test(id)) throw new Error("No such share.");
  const { Item } = await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `SHARE#${id}`, SK: "META" } }));
  if (!Item || Item.uid !== uid) throw new Error("No such share.");
}

export async function handler(event: AppSyncResolverEvent<{ id: string }>) {
  const uid = (event.identity as AppSyncIdentityCognito | null)?.sub;
  if (!uid) throw new Error("Sign in to share.");
  const { id } = event.arguments;
  await ownShare(id, uid);
  switch (event.info.fieldName) {
    case "shareImageUpload":
      return getSignedUrl(s3, new PutObjectCommand({ Bucket: BUCKET, Key: cardKey(id), ContentType: "image/png" }), { expiresIn: 300 });
    case "deleteShare":
      await db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: `SHARE#${id}`, SK: "META" } }));
      await s3.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: cardKey(id) }));
      return true;
    default:
      throw new Error(`Unknown field ${event.info.fieldName}`);
  }
}
