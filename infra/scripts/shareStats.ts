/**
 * FIT-110: the sharing flywheel by week: shares made → page views → joins, by kind.
 *   AWS_PROFILE=aicoach-dev npm run share-stats -- [dev|prod] [weeks, default 4]
 */
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";

const stage = process.argv[2] ?? "dev";
const weeks = Number(process.argv[3] ?? 4);
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: "us-east-1" }));

/** The Monday a day is in, as "2026-10-05". */
export const monday = (day: string) => {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
};

const since = monday(new Date(Date.now() - (weeks - 1) * 7 * 86_400_000).toISOString().slice(0, 10));
const { Items = [] } = await db.send(new QueryCommand({
  TableName: `AICoach-${stage}`,
  KeyConditionExpression: "PK = :pk AND SK >= :since",
  ExpressionAttributeValues: { ":pk": "STATS#SHARES", ":since": since },
}));

const byWeek = new Map<string, Record<string, number>>();
for (const item of Items) {
  const week = byWeek.get(monday(item.SK)) ?? {};
  for (const [field, value] of Object.entries(item)) if (typeof value === "number") week[field] = (week[field] ?? 0) + value;
  byWeek.set(monday(item.SK), week);
}

const kinds = [["w", "win"], ["r", "recap"], ["s", "session"], ["p", "program"]] as const;
const cell = (n = 0) => String(n).padStart(6);
console.log(`AICoach-${stage}, weeks from ${since}\n`);
console.log(`${"week".padEnd(10)} ${"kind".padEnd(8)} ${"shared".padStart(6)} ${"views".padStart(6)}`);
for (const [week, n] of [...byWeek].sort(([a], [b]) => a.localeCompare(b))) {
  for (const [short, kind] of kinds) {
    if (n[`made_${kind}`] || n[`view_${short}`]) console.log(`${week.padEnd(10)} ${kind.padEnd(8)} ${cell(n[`made_${kind}`])} ${cell(n[`view_${short}`])}`);
  }
  const joins = (n.members ?? 0) - (n.groups ?? 0);
  console.log(`${week.padEnd(10)} ${"invite".padEnd(8)} ${"".padStart(6)} ${cell(n.view_join)}   → ${joins} joined a group (${n.groups ?? 0} groups started)\n`);
}
if (byWeek.size === 0) console.log("Nothing shared yet.");
