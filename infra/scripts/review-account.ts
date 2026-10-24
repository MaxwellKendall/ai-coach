// FIT-229: App Review's account. Reviewers can't use the author's Apple ID (two-factor), so they use the app's
// Sign in with email with the account this makes: the Cognito user with a permanent password, its profile, and its
// link to the coach, so it opens on a coached Today once the coach has written its week (in Claude: propose_week for
// "App Review", then apply). Reviewers often test Delete Account, so run it again before each submission: it makes
// the account again if it's gone, and otherwise leaves it as it is.
//
//   AWS_PROFILE=aicoach-dev npm run review-account -- prod COACH_UID [EMAIL]
//   AWS_PROFILE=aicoach-dev npm run review-account -- prod COACH_UID [EMAIL] --new-password
//   AWS_PROFILE=aicoach-dev npm run review-account -- prod COACH_UID demo@barbrabell.com --name=Alex
//
// A new account, or --new-password, gets a new password, printed once for the review notes. --name names the client
// (default "App Review"), so a second account, such as one for recording onboarding, isn't confused with it.
import { randomBytes } from "node:crypto";
import {
  AdminCreateUserCommand,
  AdminGetUserCommand,
  AdminSetUserPasswordCommand,
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { stackOutputs } from "./stack.ts";

const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const [stage, coachUid, email = "review@barbrabell.com"] = args;
if (!stage || !coachUid) throw new Error("Usage: npm run review-account -- STAGE COACH_UID [EMAIL] [--new-password]");
const newPassword = process.argv.includes("--new-password");

const NAME = process.argv.find((a) => a.startsWith("--name="))?.slice("--name=".length) || "App Review";
const out = await stackOutputs(stage);
const cognito = new CognitoIdentityProviderClient({ region: out.Region });
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));
const TABLE = `AICoach-${stage}`;
const username = email.toLowerCase();

/** Easy to type from the notes, and meets Cognito's default policy: upper, lower, digit, symbol, 8+. */
const password = () => `Review-${randomBytes(3).toString("hex")}-${randomBytes(3).toString("hex")}!`;

async function existing() {
  try {
    const user = await cognito.send(new AdminGetUserCommand({ UserPoolId: out.UserPoolId, Username: username }));
    return user.UserAttributes?.find((a) => a.Name === "sub")?.Value;
  } catch (e) {
    if ((e as Error).name === "UserNotFoundException") return undefined;
    throw e;
  }
}

const { Item: coachProfile } = await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `USER#${coachUid}`, SK: "PROFILE" } }));
if (!coachProfile) throw new Error(`No coach ${coachUid} on ${stage}.`);
const { Item: plan } = await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `USER#${coachUid}`, SK: "COACHPLAN" } }));
if (!["active", "trialing", "past_due"].includes(plan?.status)) console.warn(`Warning: the coach has no active coach plan, so coach tools are off.`);

let uid = await existing();
const isNew = !uid;
if (!uid) {
  // preSignUp allows admin-made users; MessageAction SUPPRESS sends no invitation email.
  const made = await cognito.send(new AdminCreateUserCommand({
    UserPoolId: out.UserPoolId,
    Username: username,
    MessageAction: "SUPPRESS",
    UserAttributes: [{ Name: "email", Value: username }, { Name: "email_verified", Value: "true" }, { Name: "name", Value: NAME }],
  }));
  uid = made.User?.Attributes?.find((a) => a.Name === "sub")?.Value;
  if (!uid) throw new Error("Cognito made the user without a sub.");
}
// Permanent, so the first sign-in isn't asked to change it.
const printed = isNew || newPassword ? password() : undefined;
if (printed) await cognito.send(new AdminSetUserPasswordCommand({ UserPoolId: out.UserPoolId, Username: username, Password: printed, Permanent: true }));

// The same PROFILE item postConfirmation writes, which an admin-made user never triggers.
const now = new Date().toISOString();
await db.send(new PutCommand({
  TableName: TABLE,
  Item: { PK: `USER#${uid}`, SK: "PROFILE", uid, displayName: NAME, units: "lb", createdAt: now, updatedAt: now },
  ConditionExpression: "attribute_not_exists(PK)",
})).catch((e) => { if ((e as Error).name !== "ConditionalCheckFailedException") throw e; });

// The coach link both ways, as accepting an invite writes it.
const coachName = (coachProfile.displayName as string | undefined) ?? null;
await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${uid}`, SK: `COACH#${coachUid}`, coachUid, coachName, since: now } }));
await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${coachUid}`, SK: `CLIENT#${uid}`, clientUid: uid, clientName: NAME, since: now } }));

console.log(`${NAME} on ${stage}: ${username} (uid ${uid}), coached by ${coachName ?? coachUid}.`);
console.log(printed ? `Password: ${printed}` : "Password unchanged (pass --new-password for a new one).");
console.log(`Next: write its week as the coach (propose_week for "${NAME}", then apply).`);
