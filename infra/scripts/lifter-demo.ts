// TKL-749: lifter@barbrabell.com, Jordan, for the App Review demo's Lifter Pro chapter: training themselves (no coach),
// on Lifter Pro with no store behind it, three weeks logged and this week and next planned (lifterDemo.ts). Sign in
// with email on the phone, then Program › Plan my next week has the AI design next week.
//
//   AWS_PROFILE=aicoach-dev npm run lifter-demo -- dev
//   AWS_PROFILE=aicoach-dev npm run lifter-demo -- prod --new-password
//
// Run it again to bring the weeks up to today: it starts Jordan's training over, so what's logged since goes, and it
// ends any coach link the account picked up. A new password goes in infra/.demo-accounts.STAGE and is never printed.
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { at, sunday, WEEKS } from "../lambda/demoClients.ts";
import { item } from "../lambda/sync.ts";
import { addDays } from "../lambda/training.ts";
import { demoAccounts } from "./demoAccount.ts";
import { demoProPlan, jordan, LIFTER_EMAIL, lifterUnits } from "./lifterDemo.ts";
import { stackOutputs } from "./stack.ts";

const [stage] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
if (!stage) throw new Error("Usage: npm run lifter-demo -- STAGE [--new-password]");
const newPassword = process.argv.includes("--new-password");

const out = await stackOutputs(stage);
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));
const now = new Date().toISOString();
const since = new Date(at(addDays(sunday, -7 * (WEEKS + 1)), 9) * 1000).toISOString();
const { account, save, TABLE } = demoAccounts({ stage, region: out.Region, userPoolId: out.UserPoolId, db, newPassword, since, now });

const uid = await account(LIFTER_EMAIL, jordan.name);
const mine = async (prefix: string) => (await db.send(new QueryCommand({
  TableName: TABLE, KeyConditionExpression: "PK = :pk AND begins_with(SK, :s)", ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":s": prefix },
}))).Items ?? [];

// Solo: no coach, so the app designs the weeks (a coach's weeks are never redesigned).
for (const link of await mine("COACH#")) {
  const coach = String(link.SK).slice("COACH#".length);
  await db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: link.PK, SK: link.SK } }));
  await db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: `USER#${coach}`, SK: `CLIENT#${uid}` } }));
}

const bodies = lifterUnits();
for (const old of await mine("SYNC#")) if (!bodies.has(old.key)) await db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: old.PK, SK: old.SK } }));
for (const [key, body] of bodies) await db.send(new PutCommand({ TableName: TABLE, Item: item(uid, { key, updatedAt: now, deleted: false, body }, now) }));
await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${uid}`, ...demoProPlan() } }));

save();
console.log(`${jordan.name} on ${stage}: ${LIFTER_EMAIL} (uid ${uid}), on Lifter Pro (no store), no coach, ${WEEKS} weeks logged.`);
console.log(`Password: infra/.demo-accounts.${stage}`);
