/**
 * FIT-209: are Claude-written sessions kept? Every day an agent's apply wrote, by the week it was written: for clients
 * or their own, kept as written, edited after, removed or undone, and logged.
 *   AWS_PROFILE=aicoach-dev npm run program-stats -- [dev|prod] [weeks, default 4]
 */
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { BatchGetCommand, DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { tally, type Written } from "../lambda/programStats.ts";

/** The Monday a day is in, as shareStats.ts reckons weeks (importing it would run that script). */
const monday = (day: string) => {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
};

const stage = process.argv[2] ?? "dev";
const weeks = Number(process.argv[3] ?? 4);
const TABLE = `AICoach-${stage}`;
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: "us-east-1" }));
const since = monday(new Date(Date.now() - (weeks - 1) * 7 * 86_400_000).toISOString().slice(0, 10));

// A scan is fine at the pilot's size; a GSI if it ever isn't.
const written: Written[] = [];
let start: Record<string, any> | undefined;
do {
  const out = await db.send(new ScanCommand({
    TableName: TABLE, FilterExpression: "begins_with(SK, :w) AND #at >= :since",
    ExpressionAttributeNames: { "#at": "at" }, ExpressionAttributeValues: { ":w": "MCP#written#", ":since": since }, ExclusiveStartKey: start,
  }));
  written.push(...((out.Items ?? []) as Written[]));
  start = out.LastEvaluatedKey;
} while (start);

const keys = written.flatMap((w) => [`plan#${w.day}`, `log#${w.day}`].map((k) => ({ PK: `USER#${w.owner}`, SK: `SYNC#${k}` })));
const found = new Map<string, Record<string, any>>();
for (let i = 0; i < keys.length; i += 100) {
  const out = await db.send(new BatchGetCommand({ RequestItems: { [TABLE]: { Keys: keys.slice(i, i + 100) } } }));
  for (const item of out.Responses?.[TABLE] ?? []) if (!item.deleted) found.set(`${item.PK}|${item.SK}`, item);
}

const byWeek = new Map<string, Parameters<typeof tally>[0]>();
for (const w of written) {
  const plan = found.get(`USER#${w.owner}|SYNC#plan#${w.day}`)?.body as string | undefined;
  const log = found.get(`USER#${w.owner}|SYNC#log#${w.day}`)?.body as string | undefined;
  const logged = !!log && (JSON.parse(log) as { kind: string }[]).some((r) => r.kind === "workout");
  const week = monday(w.at.slice(0, 10));
  byWeek.set(week, [...(byWeek.get(week) ?? []), { written: w, plan, logged }]);
}

console.log(`Claude-written sessions on ${stage}, by the week they were written:`);
console.log("week        written  clients  kept  edited  removed  undone  logged");
for (const week of [...byWeek.keys()].sort()) {
  const t = tally(byWeek.get(week)!);
  const pct = (n: number) => `${n} (${Math.round((100 * n) / t.written)}%)`;
  console.log(`${week}  ${String(t.written).padStart(7)}  ${String(t.forClients).padStart(7)}  ${pct(t.kept)}  ${pct(t.edited)}  ${pct(t.removed)}  ${pct(t.undone)}  ${pct(t.logged)}`);
}
if (!byWeek.size) console.log("None yet.");
