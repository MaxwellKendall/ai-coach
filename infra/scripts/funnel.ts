// TKL-466: the first launch's funnel per monetization strategy (shared/funnel.ts), against the 11% benchmark.
//   AWS_PROFILE=aicoach-dev npm run funnel -- prod            the last 30 days of first launches
//   AWS_PROFILE=aicoach-dev npm run funnel -- prod 2026-12-01 first launches since that day
// Each install counts on the day it first launched, so a cohort's later purchases land on its own day.
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { funnelReport, type FunnelRow } from "../../shared/funnel.ts";
import { isStrategy } from "../../shared/monetization.ts";
import { stackOutputs } from "./stack.ts";

const [stage, since = new Date(Date.now() - 30 * 86_400_000).toISOString().slice(0, 10)] = process.argv.slice(2);
if (!stage || !/^\d{4}-\d{2}-\d{2}$/.test(since)) throw new Error("Usage: npm run funnel -- STAGE [YYYY-MM-DD]");
const out = await stackOutputs(stage);
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));
const rows: FunnelRow[] = [];
let start: Record<string, unknown> | undefined;
do {
  const page = await db.send(new QueryCommand({
    TableName: `AICoach-${stage}`,
    KeyConditionExpression: "PK = :pk AND SK >= :since",
    ExpressionAttributeValues: { ":pk": "STATS#FUNNEL", ":since": since },
    ExclusiveStartKey: start,
  }));
  for (const { PK, SK, day, strategy, ...counts } of page.Items ?? []) {
    if (isStrategy(strategy)) rows.push({ day: day as string, strategy, counts: counts as Record<string, number> });
  }
  start = page.LastEvaluatedKey;
} while (start);
console.log(`${stage}: first launches since ${since}\n`);
console.log(funnelReport(rows).text);
