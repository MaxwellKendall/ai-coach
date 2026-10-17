// FIT-149: a connection link for an agent (Claude, ChatGPT…) to one account's training, until OAuth arrives.
//   AWS_PROFILE=aicoach-dev npm run mcp-token -- dev <uid suffix or full uid> [America/New_York] [claude]
//   AWS_PROFILE=aicoach-dev npm run mcp-token -- dev revoke <token>
// Prints the link once; only its hash is stored, so a lost link is revoked and a new one made.
import { randomBytes } from "node:crypto";
import { CognitoIdentityProviderClient, paginateListUsers } from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { hashToken } from "../lambda/mcp.ts";
import { stackOutputs } from "./stack.ts";

const [stage = "dev", who, tz = "America/New_York", agent = "claude"] = process.argv.slice(2);
const out = await stackOutputs(stage);
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));
const TableName = `AICoach-${stage}`;

if (who === "revoke") {
  const token = process.argv[4];
  await db.send(new UpdateCommand({ TableName, Key: { PK: `MCPTOKEN#${hashToken(token)}`, SK: "MCPTOKEN" }, UpdateExpression: "SET revoked = :t", ExpressionAttributeValues: { ":t": true } }));
  console.log("Revoked.");
  process.exit(0);
}
if (!who) throw new Error("Which account? Give the end of its id (npm run sync-status lists them).");
new Intl.DateTimeFormat("en-US", { timeZone: tz }); // throws on a bad zone

const cognito = new CognitoIdentityProviderClient({ region: out.Region });
const subs: string[] = [];
for await (const page of paginateListUsers({ client: cognito }, { UserPoolId: out.UserPoolId })) {
  for (const user of page.Users ?? []) {
    const sub = user.Attributes?.find((a) => a.Name === "sub")?.Value;
    if (sub?.endsWith(who)) subs.push(sub);
  }
}
if (subs.length !== 1) throw new Error(`${subs.length} accounts end in ${who}; give more of the id.`);

const token = randomBytes(32).toString("base64url");
await db.send(new PutCommand({
  TableName,
  Item: { PK: `MCPTOKEN#${hashToken(token)}`, SK: "MCPTOKEN", uid: subs[0], tz, agent, createdAt: new Date().toISOString() },
}));
console.log(`Connection link for …${subs[0].slice(-6)} (${agent}, ${tz}):\n${out.McpUrl.replace(/\/$/, "")}/mcp/${token}`);
