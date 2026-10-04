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
if (!rejected(await gql(a, publish, { g: groupId, s: startedAt }))) throw new Error("publishLiveSet allowed with shareLive=false");
pass("publishLiveSet is rejected until the member opts in to live sharing");
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
const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: out.Region }));
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
