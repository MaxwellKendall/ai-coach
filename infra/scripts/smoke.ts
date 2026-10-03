// FIT-56 integration smoke test against a deployed dev stack:
// A and B create and join a group, A publishes a live set, B's subscription receives it,
// and non-member C is rejected. Then all three delete their accounts (exercises deleteAccount).
//   AWS_PROFILE=aicoach-dev npm run smoke
import { randomBytes } from "node:crypto";
import {
  AdminCreateUserCommand,
  AdminGetUserCommand,
  AdminInitiateAuthCommand,
  AdminSetUserPasswordCommand,
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import { stackOutputs } from "./stack.ts";

const out = await stackOutputs("dev");
if (!out.TestClientId) throw new Error("No TestClientId output: the smoke test only runs against dev.");
const cognito = new CognitoIdentityProviderClient({ region: out.Region });

async function signIn(username: string) {
  const password = `Smoke-${randomBytes(12).toString("hex")}!`;
  try {
    await cognito.send(new AdminCreateUserCommand({ UserPoolId: out.UserPoolId, Username: username, MessageAction: "SUPPRESS" }));
  } catch (e) {
    if ((e as Error).name !== "UsernameExistsException") throw e;
  }
  await cognito.send(new AdminSetUserPasswordCommand({ UserPoolId: out.UserPoolId, Username: username, Password: password, Permanent: true }));
  const auth = await cognito.send(
    new AdminInitiateAuthCommand({
      UserPoolId: out.UserPoolId,
      ClientId: out.TestClientId,
      AuthFlow: "ADMIN_USER_PASSWORD_AUTH",
      AuthParameters: { USERNAME: username, PASSWORD: password },
    }),
  );
  return auth.AuthenticationResult!.IdToken!;
}

type Gql = { data?: Record<string, any>; errors?: { message: string; errorType?: string }[] };
async function gql(token: string, query: string, variables: Record<string, unknown> = {}): Promise<Gql> {
  const res = await fetch(out.GraphqlUrl, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: token },
    body: JSON.stringify({ query, variables }),
  });
  return res.json() as Promise<Gql>;
}
const must = (r: Gql, what: string) => {
  if (r.errors?.length) throw new Error(`${what}: ${JSON.stringify(r.errors)}`);
  return r.data!;
};
const rejected = (r: Gql) => Boolean(r.errors?.some((e) => /unauthori[sz]ed/i.test(`${e.errorType} ${e.message}`)));

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

console.log(`\n${results.length} checks passed against AICoach-dev`);
