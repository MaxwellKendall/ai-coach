/**
 * FIT-210: coach retention. Each coach (anyone with a real client or the coach plan): their signup, plan, clients,
 * clients logging this week, and whether they were active at 30, 60 and 90 days; then each mark's share.
 *   AWS_PROFILE=aicoach-dev npm run coach-stats -- [dev|prod]
 */
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, QueryCommand, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { coachRow, DAYS, realClient, retention, type CoachFacts } from "../lambda/coachStats.ts";

const stage = process.argv[2] ?? "dev";
const TABLE = `AICoach-${stage}`;
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: "us-east-1" }));
const HAS_PLAN = ["active", "trialing", "past_due"]; // coachPlan.ts's
const today = new Date().toISOString().slice(0, 10);

// A scan is fine at the pilot's size: the coach links and the coach plans.
const links: Record<string, any>[] = [];
const plans = new Map<string, string>();
let start: Record<string, any> | undefined;
do {
  const out = await db.send(new ScanCommand({
    TableName: TABLE, FilterExpression: "begins_with(SK, :c) OR SK = :p",
    ExpressionAttributeValues: { ":c": "CLIENT#", ":p": "COACHPLAN" }, ExclusiveStartKey: start,
  }));
  for (const item of out.Items ?? []) {
    const coach = String(item.PK).slice("USER#".length);
    if (item.SK === "COACHPLAN") plans.set(coach, item.status);
    else if (realClient(item.clientUid)) links.push({ coach, ...item });
  }
  start = out.LastEvaluatedKey;
} while (start);

/** A client's logged workout days, and the days their coach wrote to their account. */
async function facts(client: string, coach: string) {
  const logged: string[] = [], coachWrote: string[] = [];
  let from: Record<string, any> | undefined;
  do {
    const out = await db.send(new QueryCommand({
      TableName: TABLE, KeyConditionExpression: "PK = :p AND begins_with(SK, :s)",
      ExpressionAttributeValues: { ":p": `USER#${client}`, ":s": "SYNC#" }, ExclusiveStartKey: from,
    }));
    for (const item of out.Items ?? []) {
      if (item.by === coach && item.changedAt) coachWrote.push(String(item.changedAt).slice(0, 10));
      if (String(item.key).startsWith("log#") && !item.deleted && item.body && (JSON.parse(item.body) as { kind: string }[]).some((r) => r.kind === "workout")) {
        logged.push(String(item.key).slice("log#".length));
      }
    }
    from = out.LastEvaluatedKey;
  } while (from);
  return { logged, coachWrote };
}

const coaches = new Set([...links.map((l) => l.coach), ...plans.keys()]);
const rows = [];
for (const coach of coaches) {
  const theirs = links.filter((l) => l.coach === coach);
  const clients = await Promise.all(theirs.map(async (l) => ({ uid: l.clientUid, since: String(l.since).slice(0, 10), ...(await facts(l.clientUid, coach)) })));
  const first = theirs.map((l) => String(l.since).slice(0, 10)).sort()[0];
  const profile = first ? undefined : (await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `USER#${coach}`, SK: "PROFILE" } }))).Item;
  const signup = first ?? String(profile?.createdAt ?? today).slice(0, 10);
  const f: CoachFacts = { coach, signup, paid: HAS_PLAN.includes(plans.get(coach) ?? ""), clients };
  rows.push(coachRow(f, today));
}

const mark = (v: boolean | undefined) => (v === undefined ? "  –" : v ? "yes" : " no");
console.log(`Coaches on ${stage}, ${today}:`);
console.log("coach     signup      plan  clients  logging  30d  60d  90d");
for (const r of rows.sort((a, b) => a.signup.localeCompare(b.signup))) {
  console.log(`…${r.coach.slice(-6)}  ${r.signup}  ${r.paid ? " yes" : "  no"}  ${String(r.clients).padStart(7)}  ${String(r.loggingNow).padStart(7)}  ${DAYS.map((n) => mark(r.active[n])).join("  ")}`);
}
if (!rows.length) console.log("None yet.");
const kept = retention(rows);
console.log(`\nActive at ${DAYS.map((n) => `${n} days: ${kept[n].active} of ${kept[n].due}`).join(" · ")} (of the coaches old enough for each).`);
