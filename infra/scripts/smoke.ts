// FIT-56 integration smoke test against a deployed dev stack:
// A and B create and join a group, A publishes a live set, B's subscription receives it,
// and non-member C is rejected. Then all three delete their accounts (exercises deleteAccount).
//   AWS_PROFILE=aicoach-dev npm run smoke
import { AdminGetUserCommand } from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { cognito, gql, must, out, rejected, signIn } from "./dev.ts";

const LIVE_FIELDS = "groupId uid workout exercise setIndex setCount loadLb reps seconds rpe state startedAt updatedAt";

/** AppSync real-time protocol over WebSocket. Resolves once the subscription is acknowledged or rejected. */
function subscribe(token: string, groupId: string) {
  const host = new URL(out.GraphqlUrl).host;
  const header = Buffer.from(JSON.stringify({ host, Authorization: token })).toString("base64");
  const url = `wss://${host.replace("appsync-api", "appsync-realtime-api")}/graphql?header=${header}&payload=e30=`;
  const ws = new WebSocket(url, ["graphql-ws"]);
  const received: { at: number; data: any }[] = [];
  let onData: ((d: any) => void) | undefined;
  const ready = new Promise<"ack" | "rejected">((resolve, reject) => {
    ws.onopen = () => ws.send(JSON.stringify({ type: "connection_init" }));
    ws.onerror = (e) => reject(e);
    ws.onmessage = (msg) => {
      const m = JSON.parse(String(msg.data));
      if (m.type === "connection_ack") {
        ws.send(
          JSON.stringify({
            id: "1",
            type: "start",
            payload: {
              data: JSON.stringify({ query: `subscription($g: ID!) { onLiveSet(groupId: $g) { ${LIVE_FIELDS} } }`, variables: { g: groupId } }),
              extensions: { authorization: { host, Authorization: token } },
            },
          }),
        );
      } else if (m.type === "start_ack") resolve("ack");
      else if (m.type === "error") resolve("rejected");
      else if (m.type === "data") {
        received.push({ at: Date.now(), data: m.payload.data.onLiveSet });
        onData?.(m.payload.data.onLiveSet);
      }
    };
  });
  const next = (timeoutMs: number) =>
    new Promise<any>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("timed out waiting for live set")), timeoutMs);
      onData = (d) => {
        clearTimeout(t);
        resolve(d);
      };
    });
  return { ready, next, received, close: () => ws.close() };
}

const results: string[] = [];
const pass = (s: string) => {
  results.push(`PASS ${s}`);
  console.log(`PASS ${s}`);
};

const [a, b, c] = await Promise.all(["smoke-a", "smoke-b", "smoke-c"].map(signIn));
// FIT-110: today's flywheel counts before this run, to check what it adds.
const statsKey = { PK: "STATS#SHARES", SK: new Date().toISOString().slice(0, 10) };
const stats = async () => ((await DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }))
  .send(new GetCommand({ TableName: "AICoach-dev", Key: statsKey }))).Item ?? {}) as Record<string, number>;
const statsBefore = await stats();
must(await gql(a, `mutation { updateProfile(displayName: "Smoke A") { uid } }`), "A profile");
must(await gql(b, `mutation { updateProfile(displayName: "Smoke B") { uid } }`), "B profile");

const created = must(await gql(a, `mutation { createGroup(name: "Smoke group") { groupId inviteCode } }`), "createGroup").createGroup;
const groupId = created.groupId as string;
must(await gql(b, `mutation($c: String!) { joinGroup(inviteCode: $c) { groupId } }`, { c: created.inviteCode }), "joinGroup");
const group = must(await gql(b, `query($g: ID!) { group(groupId: $g) { members { uid displayName } } }`, { g: groupId }), "group").group;
if (group.members.length !== 2) throw new Error(`expected 2 members, got ${group.members.length}`);
pass("A creates a group, B joins with the invite code and sees 2 members");

const publish = `mutation($g: ID!, $s: AWSDateTime!) {
  publishLiveSet(groupId: $g, workout: "Push day", exercise: "Bench press", setIndex: 3, setCount: 5, loadLb: 185, reps: 5, state: "working", startedAt: $s) { ${LIVE_FIELDS} }
}`;
const startedAt = new Date().toISOString();
// Live sharing is on by default (2026-10-05); a member who turns it off publishes nothing.
must(await gql(a, `mutation($g: ID!) { setShareLive(groupId: $g, shareLive: false) { shareLive } }`, { g: groupId }), "setShareLive off");
if (!rejected(await gql(a, publish, { g: groupId, s: startedAt }))) throw new Error("publishLiveSet allowed with shareLive=false");
pass("publishLiveSet is rejected once a member turns live sharing off");
must(await gql(a, `mutation($g: ID!) { setShareLive(groupId: $g, shareLive: true) { shareLive } }`, { g: groupId }), "setShareLive");

const subB = subscribe(b, groupId);
if ((await subB.ready) !== "ack") throw new Error("B's subscription was rejected");
const subC = subscribe(c, groupId);
if ((await subC.ready) !== "rejected") throw new Error("C (non-member) was allowed to subscribe");
pass("non-member C can't subscribe to the group");

const waiting = subB.next(5000);
const sentAt = Date.now();
must(await gql(a, publish, { g: groupId, s: startedAt }), "publishLiveSet");
const got = await waiting;
const latency = Date.now() - sentAt;
if (got.exercise !== "Bench press" || got.loadLb !== 185) throw new Error(`unexpected payload ${JSON.stringify(got)}`);
pass(`B receives A's live set in ${latency} ms (round trip including the mutation)`);

if (!rejected(await gql(c, `query($g: ID!) { group(groupId: $g) { name } }`, { g: groupId }))) throw new Error("C read the group");
if (!rejected(await gql(c, `mutation($g: ID!) { postFeed(groupId: $g, kind: "win") { id } }`, { g: groupId }))) throw new Error("C wrote to the group");
pass("non-member C can't read or write the group");

subB.close();
subC.close();

// FIT-58/59: creator-only invite revocation and member removal.
if (!rejected(await gql(b, `mutation($g: ID!) { rotateInvite(groupId: $g) }`, { g: groupId }))) throw new Error("B rotated A's invite");
const newCode = must(await gql(a, `mutation($g: ID!) { rotateInvite(groupId: $g) }`, { g: groupId }), "rotateInvite").rotateInvite as string;
const stale = await gql(c, `mutation($c: String!) { joinGroup(inviteCode: $c) { groupId } }`, { c: created.inviteCode });
if (!stale.errors?.length) throw new Error("the revoked invite code still joins");
created.inviteCode = newCode;
pass("only the creator can revoke the invite; the old code stops working");
if (!rejected(await gql(b, `mutation($g: ID!, $u: ID!) { removeMember(groupId: $g, uid: $u) }`, { g: groupId, u: "anyone" }))) throw new Error("B removed a member");
const bUid = JSON.parse(Buffer.from(b.split(".")[1], "base64url").toString()).sub;
must(await gql(a, `mutation($g: ID!, $u: ID!) { removeMember(groupId: $g, uid: $u) }`, { g: groupId, u: bUid }), "removeMember");
if (!rejected(await gql(b, `query($g: ID!) { group(groupId: $g) { name } }`, { g: groupId }))) throw new Error("B can still read after removal");
pass("only the creator can remove a member, who then loses access");

const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));

// FIT-102: the Claude proxy answers with Haiku, refuses any other model, and counts the user's day.
const ai = (model: string) => gql(a, `mutation($r: AWSJSON!) { aiMessages(request: $r) }`, {
  r: JSON.stringify({ model, max_tokens: 20, messages: [{ role: "user", content: "Reply with the word ok." }] }),
});
const aUid = JSON.parse(Buffer.from(a.split(".")[1], "base64url").toString()).sub;
const useKey = { PK: `USER#${aUid}`, SK: `AIUSE#${new Date().toISOString().slice(0, 10)}` };
const used = async () => ((await db.send(new GetCommand({ TableName: "AICoach-dev", Key: useKey }))).Item?.count as number) ?? 0;
const usedBefore = await used();
const reply = JSON.parse(must(await ai("claude-haiku-5-5"), "aiMessages").aiMessages);
if (reply.status !== 200 || reply.body.content?.[0]?.type !== "text") throw new Error(`aiMessages: ${JSON.stringify(reply)}`);
const opus = await ai("claude-opus-5-5");
if (!opus.errors?.some((e) => e.message.startsWith("Only claude-haiku"))) throw new Error(`the proxy passed on another model: ${JSON.stringify(opus)}`);
if ((await used()) !== usedBefore + 1) throw new Error(`A's AI use went from ${usedBefore} to ${await used()}, not up by 1`);
pass(`aiMessages answers with Haiku (${reply.body.usage?.output_tokens} tokens), refuses other models, and counts the day`);

// FIT-105/58: a saved win opens at its link, and the group's invite has a page.
const win = { kind: "pr", date: "2026-10-08", metric: "Bench Press", unit: "lb", value: 205, previous: 190, trend: [190, 205], showNumbers: true, style: "dark" };
const shared = must(await gql(a, `mutation($p: AWSJSON!) { createShare(kind: "win", payload: $p) { id url } }`, { p: JSON.stringify(win) }), "createShare").createShare;
const winPage = await fetch(shared.url);
const winHtml = await winPage.text();
if (winPage.status !== 200 || !winHtml.includes("Smoke set a bench press best")) throw new Error(`win page ${shared.url}: ${winPage.status}`);
const invitePage = await fetch(`${new URL(shared.url).origin}/join/${created.inviteCode}`);
if (invitePage.status !== 200 || !(await invitePage.text()).includes("Join Smoke group")) throw new Error(`invite page: ${invitePage.status}`);
pass(`a shared win opens at ${shared.url}, and the invite page shows the group`);

// FIT-107: the card uploads for link previews, and a share can be taken down.
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64");
const upload = must(await gql(a, `mutation($i: ID!) { shareImageUpload(id: $i) }`, { i: shared.id }), "shareImageUpload").shareImageUpload;
const put = await fetch(upload, { method: "PUT", headers: { "content-type": "image/png" }, body: png });
if (put.status !== 200) throw new Error(`card upload: ${put.status}`);
const cardUrl = `${new URL(shared.url).origin}/cards/${shared.id}.png`;
const card = await fetch(cardUrl);
if (card.status !== 200 || card.headers.get("content-type") !== "image/png") throw new Error(`card: ${card.status} ${card.headers.get("content-type")}`);
if (!winHtml.includes(`<meta property="og:image" content="${cardUrl}">`)) throw new Error("the win page doesn't preview its card");
if (!(await gql(b, `mutation($i: ID!) { shareImageUpload(id: $i) }`, { i: shared.id })).errors?.length) throw new Error("B got an upload URL for A's share");
const other = must(await gql(a, `mutation($p: AWSJSON!) { createShare(kind: "win", payload: $p) { id url } }`, { p: JSON.stringify(win) }), "createShare").createShare;
must(await gql(a, `mutation($i: ID!) { deleteShare(id: $i) }`, { i: other.id }), "deleteShare");
if ((await fetch(other.url)).status !== 404) throw new Error("a deleted share's page still opens");
pass("the card uploads and previews the page; only the sharer can upload it; a deleted share's link expires");

// FIT-108: a recap as the app sends it (Recap.payload) opens at its link.
const recap = { week: 6, weeks: 12, phase: "build", sessions: { done: 3, planned: 3 }, bests: 2, showNumbers: true,
  lifts: [{ metric: "Bench press", from: 190, to: 205, unit: "lb" }] };
const sharedRecap = must(await gql(a, `mutation($p: AWSJSON!) { createShare(kind: "recap", payload: $p) { url } }`, { p: JSON.stringify(recap) }), "createShare recap").createShare;
const recapPage = await fetch(sharedRecap.url);
const recapHtml = await recapPage.text();
if (recapPage.status !== 200 || !recapHtml.includes("Smoke&#39;s week 6 of 12") || !recapHtml.includes("+15 lb")) throw new Error(`recap page ${sharedRecap.url}: ${recapPage.status}`);
pass(`a weekly recap opens at ${sharedRecap.url}`);

// FIT-113: a session as the app sends it (SharedSession.Shared): its page, its calendar file, and another user reading it.
const session = { title: "Lower body", date: "2026-10-15", time: "6:00\u202fAM", minutes: 50, invite: created.inviteCode,
  exercises: [{ exercise: "back-squat", name: "Back Squat", sets: 4, reps: 5 }, { exercise: "plank", name: "Plank", sets: 3, seconds: 45 }] };
const sharedSession = must(await gql(a, `mutation($p: AWSJSON!) { createShare(kind: "session", payload: $p) { id url } }`, { p: JSON.stringify(session) }), "createShare session").createShare;
if (!sharedSession.url.includes("/s/")) throw new Error(`session link ${sharedSession.url}`);
const sessionHtml = await (await fetch(sharedSession.url)).text();
if (!sessionHtml.includes("Train with Smoke: Lower body") || !sessionHtml.includes("4 × 5")) throw new Error("session page");
const ics = await fetch(`${sharedSession.url}.ics`);
if (!(await ics.text()).includes("DTSTART;VALUE=DATE:20261015")) throw new Error("session calendar file");
const read = must(await gql(c, `query($i: ID!) { share(id: $i) { kind name payload } }`, { i: sharedSession.id }), "share").share;
if (read.kind !== "session" || JSON.parse(read.payload).exercises[0].exercise !== "back-squat") throw new Error(`share read: ${JSON.stringify(read)}`);
const aasa = await (await fetch(`${new URL(sharedSession.url).origin}/.well-known/apple-app-site-association`)).json();
if (!JSON.stringify(aasa).includes("/s/*")) throw new Error("Apple's file doesn't open sessions in the app");
pass(`a session opens at ${sharedSession.url}, with its calendar file; another user can read it; the app claims /s/*`);

// FIT-110: a page view counts at once; shares made and joins come through the table's stream.
const viewsBefore = (await stats()).view_w ?? 0;
if ((await fetch(`${new URL(shared.url).origin}/v/w`)).status !== 204) throw new Error("view count");
if (((await stats()).view_w ?? 0) !== viewsBefore + 1) throw new Error("the win page's view wasn't counted");
const countStart = Date.now();
let counts = await stats();
const grew = (n: Record<string, number>) => (n.made_win ?? 0) > (statsBefore.made_win ?? 0) && (n.made_session ?? 0) > (statsBefore.made_session ?? 0)
  && (n.members ?? 0) - (n.groups ?? 0) > (statsBefore.members ?? 0) - (statsBefore.groups ?? 0);
while (!grew(counts)) {
  if (Date.now() - countStart > 60_000) throw new Error(`share counts didn't grow: ${JSON.stringify({ statsBefore, counts })}`);
  await new Promise((r) => setTimeout(r, 2000));
  counts = await stats();
}
pass(`views, shares made and joins are counted (${((Date.now() - countStart) / 1000).toFixed(1)} s for the stream)`);

for (const [name, token] of [["smoke-a", a], ["smoke-b", b], ["smoke-c", c]] as const) {
  must(await gql(token, `mutation { deleteAccount }`), `deleteAccount ${name}`);
  try {
    await cognito.send(new AdminGetUserCommand({ UserPoolId: out.UserPoolId, Username: name }));
    throw new Error(`${name} still exists after deleteAccount`);
  } catch (e) {
    if ((e as Error).name !== "UserNotFoundException") throw e;
  }
}
pass("deleteAccount removes all three test users");

// FIT-61: the stream-triggered cleanup removes the now-empty group and its invite.
const leftovers = async () => {
  const group = await db.send(new QueryCommand({ TableName: "AICoach-dev", KeyConditionExpression: "PK = :pk", ExpressionAttributeValues: { ":pk": `GROUP#${groupId}` } }));
  const invite = await db.send(new GetCommand({ TableName: "AICoach-dev", Key: { PK: `INVITE#${created.inviteCode}`, SK: "META" } }));
  return (group.Items?.length ?? 0) + (invite.Item ? 1 : 0);
};
const cleanupStart = Date.now();
while ((await leftovers()) > 0) {
  if (Date.now() - cleanupStart > 60_000) throw new Error(`group ${groupId} still has items 60 s after its last member left`);
  await new Promise((r) => setTimeout(r, 2000));
}
pass(`the empty group and its invite are deleted (${((Date.now() - cleanupStart) / 1000).toFixed(1)} s)`);

console.log(`\n${results.length} checks passed against AICoach-dev`);
