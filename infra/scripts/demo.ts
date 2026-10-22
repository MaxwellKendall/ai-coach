// FIT-221: demo accounts on dev for recording the coach video: one coach and 3 clients with 3 weeks of realistic
// training, Mon/Wed/Fri. Mike is the flagged one: his squat has stalled at 245 for three weeks, his last set went to
// RPE 9, and his last session's note says his knee is sore, unanswered. Sara is on a roll; Jen missed one session.
// This week and next are planned, so "Rebuild next week" in Claude has a week to change. Mike and Sara check in most
// mornings (FIT-223); Mike's check-in yesterday says the knee kept him up.
//
//   AWS_PROFILE=aicoach-dev npm run demo -- seed [--coach ACCOUNT] [--client ACCOUNT]
//   AWS_PROFILE=aicoach-dev npm run demo -- who EMAIL
//   AWS_PROFILE=aicoach-dev npm run demo -- delete
//
// Without options every account is a dev test user (the dashboard's dev server can use the coach's session, written
// to web/public/session.json). To record Claude and a phone, first sign in on dev once with the accounts you'll record
// with, then pass them: --coach is the coach you'll connect Claude as, and --client becomes Mike, on the phone. Their
// own sync units on these days are replaced, and a coach without a plan is given an active one (no Stripe). Re-run
// seed before each take: it rewrites the same days from today.
//
// ACCOUNT is an email, google:EMAIL or apple:EMAIL, or a uid. One email can be two accounts, Apple's and Google's,
// when they aren't linked (FIT-137): then say which, e.g. --coach google:me@gmail.com --client apple:me@gmail.com.
// who lists an email's accounts.
import { ListUsersCommand } from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { item } from "../lambda/sync.ts";
import { addDays, dailyRows, encode, logRows, type DailyInput, mergeProfile, sessionRows, type ExerciseInput, type PlanRow } from "../lambda/training.ts";
import { cognito, gql, must, out, signIn } from "./dev.ts";

const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));
const TABLE = "AICoach-dev";
const args = process.argv.slice(2);
const option = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const uidOf = (token: string) => JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString()).sub as string;

const PROVIDERS: Record<string, string> = { Google: "google", SignInWithApple: "apple" };

/** The dev accounts with an email, and how each signs in: google, apple, or the provider each one is linked to. */
async function accounts(email: string) {
  const { Users = [] } = await cognito.send(new ListUsersCommand({ UserPoolId: out.UserPoolId, Filter: `email = "${email}"` }));
  return Users.map((u) => {
    const attr = (n: string) => u.Attributes?.find((a) => a.Name === n)?.Value;
    // A federated user is named Provider_id; a linked one lists its providers in identities.
    const linked = (JSON.parse(attr("identities") ?? "[]") as { providerName: string }[]).map((i) => i.providerName);
    const via = [...new Set([u.Username!.split("_")[0], ...linked])].map((p) => PROVIDERS[p]).filter(Boolean);
    return { uid: attr("sub")!, via };
  });
}

/** The uid an ACCOUNT names: a uid, an email with one account, or google:EMAIL / apple:EMAIL. */
async function uidFor(spec: string) {
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(spec)) return spec;
  const [, provider, email] = /^(?:(google|apple):)?(.+)$/i.exec(spec)!;
  const all = await accounts(email);
  if (!all.length) throw new Error(`No dev account with ${email}. Sign in on dev.barbrabell.com/app with it first.`);
  const found = provider ? all.filter((a) => a.via.includes(provider.toLowerCase())) : all;
  if (found.length === 1) return found[0].uid;
  const list = all.map((a) => `  ${a.via.join("+") || "?"}:${email}  ${a.uid}`).join("\n");
  throw new Error(found.length
    ? `${email} is ${all.length} dev accounts. Pass google:${email}, apple:${email} or a uid:\n${list}`
    : `No ${provider} sign-in for ${email} on dev. Its accounts:\n${list}`);
}

/** A dev account: an existing one (signed in on dev before), or a test user. */
async function account(spec: string | undefined, testUser: string, name: string) {
  if (spec) {
    const uid = await uidFor(spec);
    const { Item } = await db.send(new GetCommand({ TableName: TABLE, Key: { PK: `USER#${uid}`, SK: "PROFILE" } }));
    return { uid, name: (Item?.displayName as string | undefined) ?? spec.replace(/^(google|apple):/i, "") };
  }
  const token = await signIn(testUser);
  must(await gql(token, `mutation($n: String!) { updateProfile(displayName: $n) { uid } }`, { n: name }), `${testUser} profile`);
  return { uid: uidOf(token), name, token };
}

// ---- The training ----

type Week = (w: number) => ExerciseInput[];
type Client = {
  testUser: string; name: string; age: number; weight: number; style: string;
  days: Record<number, { title: string; lifts: Week }>;
  /** RPE and the note for a logged session, or undefined when it was missed. `last` is the latest day before today. */
  logged: (w: number, weekday: number, last: boolean) => { rpe: number; note?: string; effort: number } | undefined;
  /** Changes to a logged session's sets, as the client actually did them. */
  actual?: (w: number, weekday: number, rows: ReturnType<typeof logRows>) => void;
  /** FIT-223: the morning check-in `daysAgo` days back (1–6), as the app's Check In saves it. */
  checkIn?: (daysAgo: number) => DailyInput | undefined;
};

const lb = (start: number, step: number, w: number) => start + step * w;
const WEEKS = 3; // logged weeks before this one; Mike's go one further back, so his stall has a best before it

const mike: Client = {
  testUser: "demo-mike", name: "Mike Torres", age: 34, weight: 196, style: "powerbuilding",
  days: {
    1: { title: "Squat and push", lifts: (w) => [
      { exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 245, main: true },
      { exercise: "Bench Press", sets: 4, reps: 6, weight_lb: lb(185, 5, w) },
      { exercise: "Dumbbell Lunges", sets: 3, reps: 10, weight_lb_per_hand: 40 },
    ] },
    3: { title: "Hinge and pull", lifts: (w) => [
      { exercise: "Deadlift", sets: 3, reps: 5, weight_lb: lb(295, 10, w), main: true },
      { exercise: "Pull-up", sets: 4, reps: 8 },
      { exercise: "Bent Over Barbell Row", sets: 3, reps: 8, weight_lb: lb(155, 5, w) },
    ] },
    5: { title: "Squat volume and press", lifts: (w) => [
      { exercise: "Back Squat", sets: 3, reps: 8, weight_lb: 205 },
      { exercise: "Standing Military Press", sets: 4, reps: 6, weight_lb: lb(105, 5, w), main: true },
      { exercise: "Plank", sets: 3, seconds: 45 },
    ] },
  },
  // The dashboard flags a note from the last 7 days that the coach hasn't answered, so the knee is the latest session.
  logged: (w, day, last) => {
    if (last) return { rpe: 8, effort: 4, note: "Left knee is sore, worse on squats this week. Felt it on the stairs after." };
    if (w === -2 && day === 1) return { rpe: 8, effort: 4, note: "Squat felt heavy again, couldn't get the 5th rep fast." };
    return { rpe: 7, effort: 3 };
  },
  checkIn: (n) => ({ weight_lb: Math.round((195.4 + 0.2 * n) * 10) / 10, sleep_hours: n === 1 ? 5 : 7, note: n === 1 ? "Slept badly, the knee kept me up." : undefined }),
  // The stall: every week since the first, the last set of 245 goes to RPE 9.
  actual: (w, day, rows) => {
    if (day !== 1 || w === -WEEKS - 1) return;
    const squats = rows.filter((r) => r.template === "back-squat");
    squats.at(-1)!.measurements = squats.at(-1)!.measurements.map((m) => (m.metric === "rpe" ? { ...m, value: 9 } : m));
  },
};

const sara: Client = {
  testUser: "demo-sara", name: "Sara Kim", age: 29, weight: 142, style: "powerlifting",
  days: {
    1: { title: "Squat", lifts: (w) => [
      { exercise: "Back Squat", sets: 5, reps: 3, weight_lb: lb(175, 5, w), main: true },
      { exercise: "Romanian Deadlift", sets: 3, reps: 8, weight_lb: lb(115, 5, w) },
      { exercise: "Plank", sets: 3, seconds: 40 },
    ] },
    3: { title: "Bench", lifts: (w) => [
      { exercise: "Bench Press", sets: 5, reps: 3, weight_lb: lb(110, 5, w), main: true },
      { exercise: "Dumbbell Row (Single-Arm)", sets: 3, reps: 10, weight_lb_per_hand: 35 },
      { exercise: "Standing Military Press", sets: 3, reps: 8, weight_lb: 65 },
    ] },
    5: { title: "Deadlift", lifts: (w) => [
      { exercise: "Deadlift", sets: 4, reps: 3, weight_lb: lb(215, 10, w), main: true },
      { exercise: "Pull-up", sets: 3, reps: 5 },
      { exercise: "Dumbbell Lunges", sets: 3, reps: 10, weight_lb_per_hand: 25 },
    ] },
  },
  // Her note is older than a week, so it doesn't flag her.
  logged: (w, day) => (w === -2 && day === 3 ? { rpe: 8, effort: 4, note: "New bench PR! Meet prep feels on track." } : { rpe: 7, effort: 3 }),
  checkIn: (n) => (n % 2 ? undefined : { weight_lb: 142, sleep_hours: 8 }),
};

const jen: Client = {
  testUser: "demo-jen", name: "Jen Alvarez", age: 41, weight: 158, style: "functional",
  days: {
    1: { title: "Lower body", lifts: (w) => [
      { exercise: "Goblet Squat", sets: 3, reps: 10, weight_lb: lb(45, 5, w), main: true },
      { exercise: "Hip Thrust", sets: 3, reps: 10, weight_lb: lb(135, 10, w) },
      { exercise: "Plank", sets: 3, seconds: 30 },
    ] },
    3: { title: "Upper body", lifts: (w) => [
      { exercise: "Dumbbell Bench Press", sets: 3, reps: 10, weight_lb_per_hand: 30 },
      { exercise: "Wide-Grip Lat Pulldown", sets: 3, reps: 10, weight_lb: lb(80, 5, w), main: true },
      { exercise: "Dumbbell Shoulder Press", sets: 3, reps: 10, weight_lb_per_hand: 20 },
    ] },
    5: { title: "Full body", lifts: (w) => [
      { exercise: "Romanian Deadlift", sets: 3, reps: 10, weight_lb: lb(85, 5, w), main: true },
      { exercise: "Dumbbell Row (Single-Arm)", sets: 3, reps: 10, weight_lb_per_hand: 30 },
      { exercise: "Farmer Carry", sets: 3, seconds: 40 },
    ] },
  },
  // One session missed last week (two would flag her).
  logged: (w, day) => (w === -1 && day === 3 ? undefined : { rpe: 7, effort: 3 }),
};

const key = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const today = key(new Date());
const sunday = addDays(today, -new Date(`${today}T12:00:00Z`).getUTCDay());
/** Epoch seconds at a local time on a day. */
const at = (day: string, hour: number) => new Date(`${day}T${String(hour).padStart(2, "0")}:00:00`).getTime() / 1000;

/** The client's sync units: profile, every planned day from their first week through next week, and what they logged. */
function units(client: Client, first: number) {
  const out = new Map<string, string>();
  const start = addDays(sunday, 7 * first + 1);
  out.set("profile", encode({
    ...mergeProfile(undefined, { age: client.age, weight_lb: client.weight, training_days: ["Mon", "Wed", "Fri"], session_minutes: 60, style: client.style }),
    programStart: at(start, 0),
  }));
  const days = Object.keys(client.days).map(Number);
  const last = [0, -1].flatMap((w) => days.map((d) => addDays(sunday, 7 * w + d))).filter((d) => d < today).sort().at(-1);
  for (let w = first; w <= 1; w++) {
    for (const [weekday, session] of Object.entries(client.days).map(([d, s]) => [Number(d), s] as const)) {
      const day = addDays(sunday, 7 * w + weekday);
      const plan: PlanRow[] = sessionRows([], session.title, session.lifts(w - first), at(day, 7), "Written by the coach");
      out.set(`plan#${day}`, encode(plan));
      const done = day < today ? client.logged(w, weekday, day === last) : undefined;
      if (!done) continue;
      const rows = logRows(plan, at(day, 7) + 3600, { as_planned: true, rpe: done.rpe, note: done.note, effort: done.effort });
      client.actual?.(w, weekday, rows);
      out.set(`log#${day}`, encode(rows));
    }
  }
  for (let n = 6; n >= 1; n--) {
    const day = addDays(today, -n), input = client.checkIn?.(n);
    if (!input) continue;
    const log = out.has(`log#${day}`) ? JSON.parse(out.get(`log#${day}`)!) : [];
    out.set(`log#${day}`, encode(dailyRows(log, input, () => at(day, 6))));
  }
  return out;
}

async function put(uid: string, bodies: Map<string, string>, testUser: boolean) {
  const now = new Date().toISOString();
  // A demo account's days from an earlier seed, outside this one's weeks, are deleted so every take starts the same.
  // Accounts passed by email keep everything else they have.
  if (testUser) {
    const { Items = [] } = await db.send(new QueryCommand({
      TableName: TABLE, KeyConditionExpression: "PK = :pk AND begins_with(SK, :s)", ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":s": "SYNC#" },
    }));
    for (const old of Items) if (!bodies.has(old.key)) await db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: old.PK, SK: old.SK } }));
  }
  for (const [k, body] of bodies) {
    await db.send(new PutCommand({ TableName: TABLE, Item: item(uid, { key: k, updatedAt: now, deleted: false, body }, now) }));
  }
}

async function link(coach: { uid: string; name: string }, client: { uid: string; name: string }) {
  const since = new Date(at(addDays(sunday, -7 * (WEEKS + 1)), 9) * 1000).toISOString();
  await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${client.uid}`, SK: `COACH#${coach.uid}`, coachUid: coach.uid, coachName: coach.name, since } }));
  await db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${coach.uid}`, SK: `CLIENT#${client.uid}`, clientUid: client.uid, clientName: client.name, since } }));
}

const [command] = args;
if (command === "seed") {
  const coach = await account(option("--coach"), "demo-coach", "Coach Alex");
  // FIT-148: coaching needs the plan. A demo coach without one gets an active month, with no Stripe behind it.
  const plan = { PK: `USER#${coach.uid}`, SK: "COACHPLAN" };
  const { Item: current } = await db.send(new GetCommand({ TableName: TABLE, Key: plan }));
  if (!["active", "trialing", "past_due"].includes(current?.status)) {
    await db.send(new PutCommand({ TableName: TABLE, Item: { ...plan, status: "active", interval: "month", renews: new Date(Date.now() + 30 * 86_400_000).toISOString(), cancelsAtEnd: false, demo: true } }));
  }
  for (const [client, first, email] of [[mike, -WEEKS - 1, option("--client")], [sara, -WEEKS, undefined], [jen, -WEEKS, undefined]] as const) {
    const who = await account(email, client.testUser, client.name);
    if (who.uid === coach.uid) throw new Error("--coach and --client are the same account; a coach can't coach themselves.");
    await put(who.uid, units(client, first), !email);
    await link(coach, who);
    console.log(`${who.name}: ${first === -WEEKS - 1 ? WEEKS + 1 : WEEKS} weeks logged, this week and next planned, coached by ${coach.name}.`);
  }
  if ("token" in coach && coach.token) {
    const { mkdirSync, writeFileSync } = await import("node:fs");
    mkdirSync(new URL("../../web/public/", import.meta.url), { recursive: true });
    writeFileSync(new URL("../../web/public/session.json", import.meta.url), JSON.stringify({ id: coach.token, refresh: "", expiresAt: Date.now() + 55 * 60_000 }));
    console.log(`The dashboard's dev server (npm --prefix ../web run dev) is signed in as ${coach.name}.`);
  }
} else if (command === "delete") {
  for (const testUser of ["demo-mike", "demo-sara", "demo-jen", "demo-coach"]) {
    const token = await signIn(testUser);
    const uid = uidOf(token);
    // The coach's half of each link is in the coach's partition, which deleting the client doesn't reach.
    const { Items = [] } = await db.send(new QueryCommand({
      TableName: TABLE, KeyConditionExpression: "PK = :pk AND begins_with(SK, :c)", ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":c": "COACH#" },
    }));
    for (const l of Items) await db.send(new DeleteCommand({ TableName: TABLE, Key: { PK: `USER#${l.coachUid}`, SK: `CLIENT#${uid}` } }));
    must(await gql(token, `mutation { deleteAccount }`), `delete ${testUser}`);
    console.log(`Deleted ${testUser}.`);
  }
  console.log("Accounts passed with --coach or --client keep their seeded days; seed again or clear them in the app.");
} else if (command === "who" && args[1]) {
  for (const a of await accounts(args[1])) console.log(`${a.via.join("+") || "?"}:${args[1]}  ${a.uid}`);
} else {
  console.log("usage: npm run demo -- seed [--coach ACCOUNT] [--client ACCOUNT] | who EMAIL | delete");
}

