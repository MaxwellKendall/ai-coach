// FIT-328: accounts for testing the whole flow. coach@barbrabell.com has an active coach plan with no Stripe behind it
// and ten clients (demoRoster.ts). client@barbrabell.com is one of them, Sam, and signs in on the phone. Both use Sign in
// with email (FIT-229). The other nine have no sign-in, like the review account's clients (FIT-236).
//
//   AWS_PROFILE=aicoach-dev npm run coach-demo -- dev
//   AWS_PROFILE=aicoach-dev npm run coach-demo -- prod --new-password
//
// Run it again to bring the weeks up to today. It starts every client over, Sam included: what's logged since goes.
// A new password goes in infra/.demo-accounts.STAGE, which git ignores, and is never printed.
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import {
  AdminCreateUserCommand,
  AdminGetUserCommand,
  AdminSetUserPasswordCommand,
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { at, sunday, units, WEEKS, type Client } from "../lambda/demoClients.ts";
import { item } from "../lambda/sync.ts";
import { addDays } from "../lambda/training.ts";
import { noSignIn, sam } from "./demoRoster.ts";
import { stackOutputs } from "./stack.ts";

const [stage] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
if (!stage) throw new Error("Usage: npm run coach-demo -- STAGE [--new-password]");
const newPassword = process.argv.includes("--new-password");

const out = await stackOutputs(stage);
const cognito = new CognitoIdentityProviderClient({ region: out.Region });
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));
const TABLE = `AICoach-${stage}`;
const COACH_NAME = "Dana Reyes";
const now = new Date().toISOString();
const since = new Date(at(addDays(sunday, -7 * (WEEKS + 1)), 9) * 1000).toISOString();

const file = new URL(`../.demo-accounts.${stage}`, import.meta.url);
const saved = new Map(existsSync(file) ? readFileSync(file, "utf8").trim().split("\n").map((l) => l.split(" ") as [string, string]) : []);

/** The account's uid: made with a permanent password if it's new, so the first sign-in isn't asked to change it. */
async function account(email: string, name: string) {
  let uid: string | undefined;
  try {
    const user = await cognito.send(new AdminGetUserCommand({ UserPoolId: out.UserPoolId, Username: email }));
    uid = user.UserAttributes?.find((a) => a.Name === "sub")?.Value;
  } catch (e) {
    if ((e as Error).name !== "UserNotFoundException") throw e;
  }
  const isNew = !uid;
  if (!uid) {
    // preSignUp allows admin-made users; MessageAction SUPPRESS sends no invitation email.
    const made = await cognito.send(new AdminCreateUserCommand({
      UserPoolId: out.UserPoolId,
      Username: email,
      MessageAction: "SUPPRESS",
      UserAttributes: [{ Name: "email", Value: email }, { Name: "email_verified", Value: "true" }, { Name: "name", Value: name }],
    }));
    uid = made.User?.Attributes?.find((a) => a.Name === "sub")?.Value;
    if (!uid) throw new Error("Cognito made the user without a sub.");
  }
  if (isNew || newPassword) {
    const password = `Demo-${randomBytes(3).toString("hex")}-${randomBytes(3).toString("hex")}!`;
    await cognito.send(new AdminSetUserPasswordCommand({ UserPoolId: out.UserPoolId, Username: email, Password: password, Permanent: true }));
    saved.set(email, password);
  }
  // The same PROFILE item postConfirmation writes, which an admin-made user never triggers.
  await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${uid}`, SK: "PROFILE", uid, displayName: name, units: "lb", createdAt: since, updatedAt: now } }));
  return uid;
}

/** The client's weeks, replacing what they had, and the coach link both ways, as accepting an invite writes it. */
async function coached(coach: string, uid: string, client: Client, first: number) {
  const bodies = units(client, first, true);
  const { Items = [] } = await db.send(new QueryCommand({
    TableName: TABLE, KeyConditionExpression: "PK = :pk AND begins_with(SK, :s)", ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":s": "SYNC#" },
  }));
  for (const old of Items) if (!bodies.has(old.key)) await db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: old.PK, SK: old.SK } }));
  for (const [key, body] of bodies) await db.send(new PutCommand({ TableName: TABLE, Item: item(uid, { key, updatedAt: now, deleted: false, body }, now) }));
  await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${uid}`, SK: `COACH#${coach}`, coachUid: coach, coachName: COACH_NAME, since } }));
  await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${coach}`, SK: `CLIENT#${uid}`, clientUid: uid, clientName: client.name, since } }));
}

const coach = await account("coach@barbrabell.com", COACH_NAME);
await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${coach}`, SK: "COACHPLAN", status: "active", interval: "month", renews: new Date(Date.now() + 90 * 86_400_000).toISOString(), cancelsAtEnd: false, demo: true } }));
// Marked as made, so clearing the roster to test the first invite doesn't add FIT-240's sample client.
await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${coach}`, SK: "SAMPLE", createdAt: now } }));

const client = await account("client@barbrabell.com", sam.name);
await coached(coach, client, sam, -WEEKS);
for (const [c, first] of noSignIn) {
  const uid = `${c.testUser}-for-${coach}`;
  await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${uid}`, SK: "PROFILE", uid, displayName: c.name, units: "lb", createdAt: since, updatedAt: now } }));
  await coached(coach, uid, c, first);
}

writeFileSync(file, [...saved].map(([email, password]) => `${email} ${password}`).join("\n") + "\n", { mode: 0o600 });
console.log(`${COACH_NAME} on ${stage}: coach@barbrabell.com (uid ${coach}), on an active coach plan, with ${noSignIn.length + 1} clients.`);
console.log(`${sam.name} on ${stage}: client@barbrabell.com (uid ${client}).`);
console.log(`Passwords: infra/.demo-accounts.${stage}`);
