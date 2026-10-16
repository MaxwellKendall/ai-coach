// FIT-126: what each account on a stage has synced, for checking a phone's first sync.
//   AWS_PROFILE=aicoach-dev npm run sync-status [dev|prod]
import { CognitoIdentityProviderClient, paginateListUsers } from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, paginateScan } from "@aws-sdk/lib-dynamodb";
import { stackOutputs } from "./stack.ts";

const stage = process.argv[2] ?? "dev";
const out = await stackOutputs(stage);
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));
const units = new Map<string, { count: number; last: string }>();
for await (const page of paginateScan({ client: db }, {
  TableName: `AICoach-${stage}`,
  FilterExpression: "begins_with(SK, :s)",
  ExpressionAttributeValues: { ":s": "SYNC#" },
  ProjectionExpression: "PK, changedAt",
})) {
  for (const item of page.Items ?? []) {
    const u = units.get(item.PK) ?? { count: 0, last: "" };
    units.set(item.PK, { count: u.count + 1, last: item.changedAt > u.last ? item.changedAt : u.last });
  }
}
const cognito = new CognitoIdentityProviderClient({ region: out.Region });
for await (const page of paginateListUsers({ client: cognito }, { UserPoolId: out.UserPoolId })) {
  for (const user of page.Users ?? []) {
    const sub = user.Attributes?.find((a) => a.Name === "sub")?.Value;
    const u = units.get(`USER#${sub}`);
    // Provider and a short id only: no names or emails in the terminal.
    console.log(`${user.Username?.split("_")[0]} …${sub?.slice(-6)}  units: ${u?.count ?? 0}${u ? `  last: ${u.last}` : ""}`);
  }
}
