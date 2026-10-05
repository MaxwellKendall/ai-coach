// FIT-59: the demo group App Review joins. Reviewers sign in with their own Apple ID and join with the
// code below; a demo member is already there with goal progress, an ended live session and a feed item.
// The demo member has no Cognito user, so it can't sign in; it only exists as group items.
//   AWS_PROFILE=aicoach-dev npm run seed-review -- prod
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { BatchWriteCommand, DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";

export const REVIEW_CODE = "REVIEW26";
const stage = process.argv[2] ?? "dev";
const table = `AICoach-${stage}`;
const groupId = "app-review-demo";
const uid = "demo-member";
const goalId = "app-review-goal";
const now = new Date();
const iso = (minutesAgo: number) => new Date(now.getTime() - minutesAgo * 60_000).toISOString();
const deadline = new Date(now.getTime() + 60 * 86_400_000).toISOString().slice(0, 10);

const pk = `GROUP#${groupId}`;
const items = [
  { PK: pk, SK: "META", name: "Demo Group", createdBy: uid, inviteCode: REVIEW_CODE, createdAt: iso(20_000), updatedAt: iso(20_000) },
  { PK: pk, SK: `MEMBER#${uid}`, groupId, uid, groupName: "Demo Group", displayName: "Sam (demo)", role: "member", shareLive: true,
    joinedAt: iso(20_000), GSI1PK: `USER#${uid}`, GSI1SK: pk },
  { PK: pk, SK: `GOAL#${goalId}`, groupId, goalId, metric: "weight_lb", target: -10, deadline, mode: "relative", createdBy: uid, createdAt: iso(20_000) },
  { PK: pk, SK: `PROGRESS#${uid}#${goalId}`, groupId, uid, goalId, baseline: 196, value: 191.4, pct: 46, onPace: true, updatedAt: iso(600) },
  { PK: pk, SK: `LIVE#${uid}`, groupId, uid, workout: "Push day", exercise: "Bench Press", setIndex: 5, setCount: 5, loadLb: 165, reps: 5,
    state: "done", startedAt: iso(120), updatedAt: iso(70) },
  { PK: pk, SK: `FEED#${iso(70)}#demo-session`, groupId, id: "demo-session", uid, kind: "session",
    measurements: JSON.stringify({ workout: "Push day", sets: 18, top: "Bench Press 165 × 5" }), createdAt: iso(70) },
  { PK: pk, SK: `FEED#${iso(600)}#demo-milestone`, groupId, id: "demo-milestone", uid, kind: "milestone",
    measurements: JSON.stringify({ pct: 25, goalId }), createdAt: iso(600) },
  { PK: `INVITE#${REVIEW_CODE}`, SK: "META", groupId, groupName: "Demo Group", createdBy: uid, createdAt: iso(20_000) },
];

const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: "us-east-1" }));
await db.send(new BatchWriteCommand({ RequestItems: { [table]: items.map((Item) => ({ PutRequest: { Item } })) } }));
console.log(`Seeded the App Review demo group in ${table}. Invite code: ${REVIEW_CODE}`);
