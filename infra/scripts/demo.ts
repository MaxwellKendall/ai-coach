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
import { addDays } from "../lambda/training.ts";
import { at, jen, mike, sara, sunday, units, WEEKS } from "../lambda/demoClients.ts";
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

