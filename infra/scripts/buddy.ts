// Dev-only second member for trying groups on one simulator (FIT-16/53):
//   AWS_PROFILE=aicoach-dev npm run buddy -- join CODE      join, share progress, post a milestone
//   AWS_PROFILE=aicoach-dev npm run buddy -- live GROUPID   opt in to live sharing and log a workout, a set every few seconds
//   AWS_PROFILE=aicoach-dev npm run buddy -- program        sync a sample week (FIT-126) and write a session for the dashboard's
//                                                       dev server to web/public/session.json (FIT-127; gitignored)
//   AWS_PROFILE=aicoach-dev npm run buddy -- coach          FIT-130: Test Buddy coaches a second test account, Test Client, which
//                                                       accepts the invite and syncs a sample week
//   AWS_PROFILE=aicoach-dev npm run buddy -- delete         delete the buddy's account (and with it its group items)
import { gql, must, signIn } from "./dev.ts";

const [command, arg] = process.argv.slice(2);
const token = await signIn("smoke-buddy");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

if (command === "join") {
  must(await gql(token, `mutation { updateProfile(displayName: "Test Buddy") { uid } }`), "profile");
  const group = must(await gql(token, `mutation($c: String!) { joinGroup(inviteCode: $c) { groupId name } }`, { c: arg }), "join").joinGroup;
  const detail = must(await gql(token, `query($g: ID!) { group(groupId: $g) { goals { goalId } } }`, { g: group.groupId }), "group").group;
  for (const goal of detail.goals) {
    must(
      await gql(
        token,
        `mutation($g: ID!, $goal: ID!) {
          publishProgress(groupId: $g, goalId: $goal, baseline: 212, value: 207.6, pct: 44, onPace: true) {
            groupId uid goalId baseline value pct onPace updatedAt
          }
        }`,
        { g: group.groupId, goal: goal.goalId },
      ),
      "progress",
    );
    must(
      await gql(
        token,
        `mutation($g: ID!, $m: AWSJSON) { postFeed(groupId: $g, kind: "milestone", measurements: $m) { groupId id uid kind measurements createdAt } }`,
        { g: group.groupId, m: JSON.stringify({ pct: 25, goalId: goal.goalId }) },
      ),
      "feed",
    );
  }
  console.log(`Test Buddy joined ${group.name} (${group.groupId}), shared 44% and posted a 25% milestone.`);
} else if (command === "live") {
  const fields = "groupId uid workout exercise setIndex setCount loadLb reps seconds rpe state startedAt updatedAt";
  must(await gql(token, `mutation($g: ID!) { setShareLive(groupId: $g, shareLive: true) { uid } }`, { g: arg }), "share");
  const startedAt = new Date().toISOString();
  const plan = [
    { exercise: "Bench Press", loadLb: 185, reps: 5, sets: 3 },
    { exercise: "Barbell Row", loadLb: 135, reps: 8, sets: 2 },
  ];
  for (const lift of plan) {
    for (let set = 1; set <= lift.sets; set++) {
      for (const state of ["working", "resting"]) {
        must(
          await gql(
            token,
            `mutation($g: ID!, $e: String!, $i: Int!, $n: Int!, $l: Float, $r: Int, $s: String!, $t: AWSDateTime!) {
              publishLiveSet(groupId: $g, workout: "Push day", exercise: $e, setIndex: $i, setCount: $n, loadLb: $l, reps: $r, state: $s, startedAt: $t) { ${fields} }
            }`,
            { g: arg, e: lift.exercise, i: set, n: lift.sets, l: lift.loadLb, r: lift.reps, s: state, t: startedAt },
          ),
          "live",
        );
        console.log(`${lift.exercise} set ${set}/${lift.sets} ${state}`);
        await sleep(4000);
      }
    }
  }
  must(await gql(token, `mutation($g: ID!) { endLiveSession(groupId: $g) { ${fields} } }`, { g: arg }), "end");
  console.log("Workout ended.");
} else if (command === "coach") {
  const client = await signIn("smoke-client");
  must(await gql(client, `mutation { updateProfile(displayName: "Test Client") { uid } }`), "client profile");
  const invite = must(await gql(token, `mutation { createClientInvite { code url } }`), "invite").createClientInvite;
  must(await gql(client, `mutation($c: String!) { acceptCoach(code: $c) { uid } }`, { c: invite.code }), "accept");
  const today = new Date();
  const key = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const at = (offset: number, hour: number) => new Date(today.getFullYear(), today.getMonth(), today.getDate() + offset, hour).getTime() / 1000;
  const m = (metric: string, value: number, unit = metric) => ({ metric, value, unit });
  const plan = (offset: number, slot: string, rows: [string, object[]][]) => ({
    key: `plan#${key(new Date(at(offset, 0) * 1000))}`,
    rows: rows.map(([template, targets], i) => ({ id: crypto.randomUUID(), kind: "workout", at: at(offset, 7) + i, slot, template, targets, note: "", main: i === 0, pinned: false })),
  });
  const units = [
    plan(-2, "Full body A", [["back-squat", [m("sets", 3), m("reps", 5), m("load_lb", 185, "lb")]], ["bench-press", [m("sets", 3), m("reps", 5), m("load_lb", 155, "lb")]]]),
    plan(1, "Full body B", [["romanian-deadlift", [m("sets", 3), m("reps", 8), m("load_lb", 135, "lb")]], ["plank", [m("sets", 3), m("duration_s", 40, "s")]]]),
    { key: `log#${key(new Date(at(-2, 0) * 1000))}`, rows: [
      { id: crypto.randomUUID(), kind: "workout", at: at(-2, 8), template: "back-squat", measurements: [m("reps", 5, "reps"), m("load_lb", 185, "lb"), m("rpe", 8, "rpe")], note: "Knee felt a bit tight on the last set." },
      { id: crypto.randomUUID(), kind: "workout", at: at(-2, 8) + 60, template: "bench-press", measurements: [m("reps", 5, "reps"), m("load_lb", 155, "lb"), m("rpe", 7, "rpe")], note: "" },
    ] },
  ].map((u) => ({ key: u.key, updatedAt: new Date().toISOString(), deleted: false, body: JSON.stringify(u.rows) }));
  must(await gql(client, `mutation($u: [SyncUnitInput!]!) { syncPush(units: $u, source: "buddy") { changedAt } }`, { u: units }), "client sync");
  const { writeFileSync } = await import("node:fs");
  writeFileSync(new URL("../../web/public/session.json", import.meta.url), JSON.stringify({ id: token, refresh: "", expiresAt: Date.now() + 55 * 60_000 }));
  console.log("Test Buddy now coaches Test Client (a sample week synced); the dashboard's dev session is Test Buddy's.");
} else if (command === "program") {
  // This week, as the app syncs it: Monday and Friday planned, Monday logged.
  const today = new Date();
  const sunday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - today.getDay());
  const day = (offset: number, hour = 7) => new Date(sunday.getFullYear(), sunday.getMonth(), sunday.getDate() + offset, hour);
  const key = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const m = (metric: string, value: number, unit: string) => ({ metric, value, unit });
  const row = (d: Date, i: number, slot: string, template: string, targets: object[], note = "") => ({
    id: crypto.randomUUID(), kind: "workout", at: d.getTime() / 1000 + i, slot, template, targets, note, main: i === 1, pinned: false,
  });
  const monday = day(1), friday = day(5);
  const units = [
    { key: `plan#${key(monday)}`, rows: [
      row(monday, 0, "Lower A", "back-squat", [m("sets", 2, "sets"), m("reps", 5, "reps"), m("load_lb", 135, "lb")], "warm-up"),
      row(monday, 1, "Lower A", "back-squat", [m("sets", 4, "sets"), m("reps", 5, "reps"), m("load_lb", 205, "lb")]),
      row(monday, 2, "Lower A", "romanian-deadlift", [m("sets", 3, "sets"), m("reps", 8, "reps"), m("load_lb", 155, "lb")]),
      row(monday, 3, "Lower A", "plank", [m("sets", 3, "sets"), m("duration_s", 45, "s")]),
    ] },
    { key: `log#${key(monday)}`, rows: [
      { id: crypto.randomUUID(), kind: "workout", at: day(1, 8).getTime() / 1000, template: "back-squat", measurements: [m("reps", 5, "reps"), m("load_lb", 205, "lb")], note: "" },
    ] },
    { key: `plan#${key(friday)}`, rows: [
      row(friday, 1, "Upper A", "bench-press", [m("sets", 4, "sets"), m("reps", 5, "reps"), m("load_lb", 185, "lb"), m("rpe", 8, "rpe")]),
      row(friday, 2, "Upper A", "dumbbell-row", [m("sets", 3, "sets"), m("reps", 10, "reps"), m("load_lb_hand", 60, "lb/hand")]),
    ] },
  ].map((u) => ({ key: u.key, updatedAt: new Date().toISOString(), deleted: false, body: JSON.stringify(u.rows) }));
  must(await gql(token, `mutation($u: [SyncUnitInput!]!) { syncPush(units: $u, source: "buddy") { changedAt } }`, { u: units }), "syncPush");
  const { writeFileSync } = await import("node:fs");
  writeFileSync(new URL("../../web/public/session.json", import.meta.url), JSON.stringify({ id: token, refresh: "", expiresAt: Date.now() + 55 * 60_000 }));
  console.log(`Synced ${units.length} units for Test Buddy; the dashboard's dev session is in web/public/session.json.`);
} else if (command === "delete") {
  must(await gql(token, `mutation { deleteAccount }`), "delete");
  console.log("Test Buddy's account is deleted.");
} else {
  console.log("usage: npm run buddy -- join CODE | live GROUPID | program | coach | delete");
}
