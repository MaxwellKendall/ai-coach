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
function subscribe(token: string, groupId: string,
  query = `subscription($g: ID!) { onLiveSet(groupId: $g) { ${LIVE_FIELDS} } }`, field = "onLiveSet", variables: Record<string, string> = { g: groupId }) {
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
              data: JSON.stringify({ query, variables }),
              extensions: { authorization: { host, Authorization: token } },
            },
          }),
        );
      } else if (m.type === "start_ack") resolve("ack");
      else if (m.type === "error") resolve("rejected");
      else if (m.type === "data") {
        received.push({ at: Date.now(), data: m.payload.data[field] });
        onData?.(m.payload.data[field]);
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

// FIT-114: a member shares their week; another member sees it; a non-member can't; clearing takes it away.
const days = [{ day: "2026-10-12", title: "Lower body" }, { day: "2026-10-14", title: "Upper body" }];
must(await gql(a, `mutation($g: ID!, $d: [PlannedDayInput!]!) { publishWeek(groupId: $g, weekOf: "2026-10-11", days: $d) { uid } }`, { g: groupId, d: days }), "publishWeek");
const weeksSeen = must(await gql(b, `query($g: ID!) { group(groupId: $g) { weeks { uid weekOf days { day title } } } }`, { g: groupId }), "group weeks").group.weeks;
if (weeksSeen.length !== 1 || weeksSeen[0].days[1].title !== "Upper body") throw new Error(`weeks: ${JSON.stringify(weeksSeen)}`);
if (!rejected(await gql(c, `mutation($g: ID!, $d: [PlannedDayInput!]!) { publishWeek(groupId: $g, weekOf: "2026-10-11", days: $d) { uid } }`, { g: groupId, d: days }))) throw new Error("a non-member shared a week");
must(await gql(a, `mutation($g: ID!) { clearWeek(groupId: $g) }`, { g: groupId }), "clearWeek");
const weeksAfter = must(await gql(b, `query($g: ID!) { group(groupId: $g) { weeks { uid } } }`, { g: groupId }), "group weeks").group.weeks;
if (weeksAfter.length !== 0) throw new Error("the cleared week is still shown");
pass("a member's week shows to the group, a non-member can't share one, and clearing takes it away");

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
const ai = (model: string, entitlement?: string) => gql(a, `mutation($r: AWSJSON!, $e: String) { aiMessages(request: $r, entitlement: $e) }`, {
  r: JSON.stringify({ model, max_tokens: 20, messages: [{ role: "user", content: "Reply with the word ok." }] }), e: entitlement,
});
const aUid = JSON.parse(Buffer.from(a.split(".")[1], "base64url").toString()).sub;
const useKey = { PK: `USER#${aUid}`, SK: `AIUSE#${new Date().toISOString().slice(0, 10)}` };
const used = async () => ((await db.send(new GetCommand({ TableName: "AICoach-dev", Key: useKey }))).Item?.count as number) ?? 0;
const usedBefore = await used();
// FIT-123: without Pro (none, or a forged one), each request counts against the account's free allowance.
const freeKey = { PK: `USER#${aUid}`, SK: "AIFREE" };
const free = async () => ((await db.send(new GetCommand({ TableName: "AICoach-dev", Key: freeKey }))).Item?.count as number) ?? 0;
const freeBefore = await free();
const reply = JSON.parse(must(await ai("claude-haiku-5-5"), "aiMessages").aiMessages);
if (reply.status !== 200 || reply.body.content?.[0]?.type !== "text") throw new Error(`aiMessages: ${JSON.stringify(reply)}`);
const opus = await ai("claude-opus-5-5");
if (!opus.errors?.some((e) => e.message.startsWith("Only claude-haiku"))) throw new Error(`the proxy passed on another model: ${JSON.stringify(opus)}`);
if ((await used()) !== usedBefore + 1) throw new Error(`A's AI use went from ${usedBefore} to ${await used()}, not up by 1`);
const forged = JSON.parse(must(await ai("claude-haiku-5-5", "eyJhbGciOiJFUzI1NiJ9.eyJleHBpcmVzRGF0ZSI6OTl9.c2ln"), "aiMessages").aiMessages);
if (forged.status !== 200) throw new Error(`aiMessages with a forged entitlement: ${JSON.stringify(forged)}`);
if ((await free()) !== freeBefore + 2) throw new Error(`A's free use went from ${freeBefore} to ${await free()}, not up by 2`);
pass(`aiMessages answers with Haiku (${reply.body.usage?.output_tokens} tokens), refuses other models, counts the day, and counts requests without Pro against the free allowance`);

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

// FIT-111: a program as the app sends it (SharedProgram.Shared, brief included) opens at its link.
const program = { name: "Bench 225 by Dec 1", weeks: 12, days: 3, equipment: "Full gym", goals: ["Bench 225 by Dec 1"], invite: created.inviteCode,
  phases: [{ phase: "base", from: 1, to: 3, focus: "Volume and technique", mainLifts: ["Back Squat", "Bench Press"], mainReps: 8 }],
  sampleWeek: [{ day: "Monday", title: "Squat and bench", items: ["Back Squat 4 × 8", "Bench Press 4 × 8"] }],
  brief: { phases: [{ phase: "base", focus: "Volume and technique", mainLifts: ["Back Squat", "Bench Press"], mainReps: 8, accessoryReps: 12 }] } };
const sharedProgram = must(await gql(a, `mutation($p: AWSJSON!) { createShare(kind: "program", payload: $p) { id url } }`, { p: JSON.stringify(program) }), "createShare program").createShare;
const programHtml = await (await fetch(sharedProgram.url)).text();
if (!programHtml.includes("Bench 225 by Dec 1, by Smoke") || !programHtml.includes("Weeks 1–3")) throw new Error(`program page ${sharedProgram.url}`);
const readProgram = must(await gql(c, `query($i: ID!) { share(id: $i) { kind payload } }`, { i: sharedProgram.id }), "share program").share;
if (JSON.parse(readProgram.payload).brief.phases[0].mainReps !== 8) throw new Error("program read");
pass(`a program opens at ${sharedProgram.url}, and another user can read its brief`);

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

// FIT-126: A's program syncs: a push from one client shows in another's pull and on A's subscription, a stale
// push gets the server's copy back, and nobody else can read A's units or listen for them.
const day = "plan#2026-10-16";
const unit = (body: string, updatedAt: string) => ({ key: day, updatedAt, deleted: false, body });
const syncPush = `mutation($u: [SyncUnitInput!]!, $s: String) { syncPush(units: $u, source: $s) { uid source changedAt rejected { key body } } }`;
const syncPull = `query($s: String) { syncPull(since: $s) { units { key body deleted updatedAt } cursor more } }`;
const onSync = `subscription($u: ID!) { onSync(uid: $u) { uid source changedAt } }`;
const subA = subscribe(a, "", onSync, "onSync", { u: aUid });
if ((await subA.ready) !== "ack") throw new Error("A's onSync subscription was rejected");
const subSpy = subscribe(c, "", onSync, "onSync", { u: aUid });
if ((await subSpy.ready) !== "rejected") throw new Error("C subscribed to A's sync");
const heard = subA.next(5000);
const phoneAt = new Date().toISOString();
must(await gql(a, syncPush, { u: [unit('[{"reps":5}]', phoneAt)], s: "phone" }), "syncPush");
if ((await heard).source !== "phone") throw new Error("A's subscription didn't hear the push");
const pulled = must(await gql(a, syncPull, {}), "syncPull").syncPull;
if (pulled.units.find((u: any) => u.key === day)?.body !== '[{"reps":5}]') throw new Error(`pull: ${JSON.stringify(pulled)}`);
const webAt = new Date(Date.now() + 1000).toISOString();
await new Promise((r) => setTimeout(r, 1100));
must(await gql(a, syncPush, { u: [unit('[{"reps":4}]', webAt)], s: "web" }), "syncPush web");
const stalePush = must(await gql(a, syncPush, { u: [unit('[{"reps":6}]', phoneAt)], s: "phone" }), "syncPush stale").syncPush;
if (stalePush.rejected[0]?.body !== '[{"reps":4}]') throw new Error(`stale push: ${JSON.stringify(stalePush)}`);
const after = must(await gql(a, syncPull, { s: pulled.cursor }), "syncPull since").syncPull;
if (after.units.length !== 1 || after.units[0].body !== '[{"reps":4}]') throw new Error(`pull since: ${JSON.stringify(after)}`);
if (must(await gql(c, syncPull, {}), "C syncPull").syncPull.units.length !== 0) throw new Error("C pulled units");
pass("A's program syncs: another client's pull and A's subscription see a push, a stale push gets the newer copy back, and C sees nothing");
subA.close();
subSpy.close();

// FIT-130: A coaches B. B accepts A's invite; A reads and edits B's units; C can't; the invite is single use; B ends it.
const bUidNow = JSON.parse(Buffer.from(b.split(".")[1], "base64url").toString()).sub;
const invite = must(await gql(a, `mutation { createClientInvite { code url } }`), "createClientInvite").createClientInvite;
if (!invite.url.endsWith(`/c/${invite.code}`)) throw new Error(`invite url ${invite.url}`);
if (must(await gql(b, `query($c: String!) { coachInvite(code: $c) }`, { c: invite.code }), "coachInvite").coachInvite !== "Smoke A") throw new Error("coach name");
const coachPage = await fetch(invite.url);
if (coachPage.status !== 200 || !(await coachPage.text()).includes("Train with Smoke as your coach")) throw new Error(`coach invite page ${coachPage.status}`);
must(await gql(b, `mutation($c: String!) { acceptCoach(code: $c) { uid name } }`, { c: invite.code }), "acceptCoach");
if (!(await gql(c, `mutation($c: String!) { acceptCoach(code: $c) { uid } }`, { c: invite.code })).errors?.length) throw new Error("the invite worked twice");
const clients = must(await gql(a, `query { myClients { uid name } }`), "myClients").myClients;
if (clients.length !== 1 || clients[0].uid !== bUidNow) throw new Error(`clients ${JSON.stringify(clients)}`);
must(await gql(b, `mutation($u: [SyncUnitInput!]!) { syncPush(units: $u, source: "phone") { uid } }`, { u: [unit('[{"reps":8}]', new Date().toISOString())] }), "B's own push");
const asCoach = must(await gql(a, `query($u: ID) { syncPull(uid: $u) { units { key body } } }`, { u: bUidNow }), "coach pull").syncPull;
if (asCoach.units.find((u: any) => u.key === day)?.body !== '[{"reps":8}]') throw new Error("the coach didn't see B's plan");
await new Promise((r) => setTimeout(r, 1100));
must(await gql(a, `mutation($u: [SyncUnitInput!]!, $o: ID) { syncPush(units: $u, source: "web", uid: $o) { uid } }`, { u: [unit('[{"reps":6}]', new Date().toISOString())], o: bUidNow }), "coach push");
const seenByB = must(await gql(b, `query { syncPull { units { key body } } }`), "B pull").syncPull;
if (seenByB.units.find((u: any) => u.key === day)?.body !== '[{"reps":6}]') throw new Error("B didn't get the coach's edit");
if (!(await gql(c, `query($u: ID) { syncPull(uid: $u) { units { key } } }`, { u: bUidNow })).errors?.length) throw new Error("C read B's units");
must(await gql(b, `mutation($u: ID!) { unlinkCoach(uid: $u) }`, { u: aUid }), "unlinkCoach");
if (!(await gql(a, `query($u: ID) { syncPull(uid: $u) { units { key } } }`, { u: bUidNow })).errors?.length) throw new Error("A still reads B after unlinking");
pass("A coaches B through a single-use invite (with its page): A reads and edits B's plan, C can't, and B's unlink ends A's access");

for (const [name, token] of [["smoke-a", a], ["smoke-b", b], ["smoke-c", c]] as const) {
  must(await gql(token, `mutation { deleteAccount }`), `deleteAccount ${name}`);
  try {
    await cognito.send(new AdminGetUserCommand({ UserPoolId: out.UserPoolId, Username: name }));
    throw new Error(`${name} still exists after deleteAccount`);
  } catch (e) {
    if ((e as Error).name !== "UserNotFoundException") throw e;
  }
}
const syncLeft = await db.send(new QueryCommand({ TableName: "AICoach-dev", KeyConditionExpression: "PK = :pk AND begins_with(SK, :s)",
  ExpressionAttributeValues: { ":pk": `USER#${aUid}`, ":s": "SYNC#" } }));
if (syncLeft.Items?.length) throw new Error("A's synced units survived deleteAccount");
pass("deleteAccount removes all three test users, and A's synced program");

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
