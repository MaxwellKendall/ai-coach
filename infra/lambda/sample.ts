import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { mike, units, WEEKS } from "./demoClients.ts";
import { item } from "./sync.ts";

// FIT-240: a coach can't see what Barbrabell does before paying for it, so every new coach gets one sample client:
// FIT-221's Mike, with a program, goals, a stalled squat and a sore knee in his latest note. The coach tools and the
// dashboard work on him without the coach plan; inviting and coaching real clients still need it. He has no sign-in,
// like the review account's clients (FIT-236), so nothing he's sent ever reaches a phone.

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;

/** A sample client's uid starts with this; a real account's is a Cognito sub, so it never does. */
export const SAMPLE = "sample-";
export const isSample = (uid: string) => uid.startsWith(SAMPLE);
export const SAMPLE_NAME = `${mike.name} (sample)`;

/**
 * Makes the coach's sample client the first time, from `today` (YYYY-MM-DD): three weeks logged, this week and next
 * planned. A SAMPLE item in the coach's partition marks it made, so one the coach removed doesn't come back.
 * Whether it made one now.
 */
export async function ensureSample(coach: string, today: string) {
  const now = new Date().toISOString();
  try {
    await db.send(new PutCommand({
      TableName: TABLE(), Item: { PK: `USER#${coach}`, SK: "SAMPLE", createdAt: now }, ConditionExpression: "attribute_not_exists(PK)",
    }));
  } catch (e) {
    if ((e as Error).name === "ConditionalCheckFailedException") return false;
    throw e;
  }
  const uid = `${SAMPLE}mike-${coach}`;
  const bodies = units(mike, -WEEKS - 1, true, today);
  await Promise.all([
    db.send(new PutCommand({ TableName: TABLE(), Item: { PK: `USER#${uid}`, SK: "PROFILE", uid, displayName: mike.name, units: "lb", sample: true, createdAt: now, updatedAt: now } })),
    ...[...bodies].map(([key, body]) => db.send(new PutCommand({ TableName: TABLE(), Item: item(uid, { key, updatedAt: now, deleted: false, body }, now) }))),
  ]);
  // The link last, so the coach never lists a client whose weeks aren't there yet.
  await Promise.all([
    db.send(new PutCommand({ TableName: TABLE(), Item: { PK: `USER#${uid}`, SK: `COACH#${coach}`, coachUid: coach, coachName: null, since: now } })),
    db.send(new PutCommand({ TableName: TABLE(), Item: { PK: `USER#${coach}`, SK: `CLIENT#${uid}`, clientUid: uid, clientName: SAMPLE_NAME, since: now } })),
  ]);
  return true;
}
