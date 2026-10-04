// Dev-only second member for trying groups on one simulator (FIT-16/53):
//   AWS_PROFILE=aicoach-dev npm run buddy -- join CODE      join, share progress, post a milestone
//   AWS_PROFILE=aicoach-dev npm run buddy -- live GROUPID   opt in to live sharing and log a workout, a set every few seconds
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
} else if (command === "delete") {
  must(await gql(token, `mutation { deleteAccount }`), "delete");
  console.log("Test Buddy's account is deleted.");
} else {
  console.log("usage: npm run buddy -- join CODE | live GROUPID | delete");
}
