import { describe, expect, it } from "vitest";
import { ResolverError, Unauthorized, subscriptionFilters } from "./appsyncUtils.ts";
import * as requireMember from "../resolvers/requireMember.js";
import * as publishLiveSet from "../resolvers/publishLiveSet.js";
import * as publishProgress from "../resolvers/publishProgress.js";
import * as endLiveSession from "../resolvers/endLiveSession.js";
import * as leaveGroup from "../resolvers/leaveGroup.js";
import * as createGroup from "../resolvers/createGroup.js";
import * as joinGroup from "../resolvers/joinGroup.js";
import * as groupDetail from "../resolvers/groupDetail.js";
import * as subscription from "../resolvers/subscription.js";

const ME = "user-a";
const OTHER = "user-b";
const ctx = (over: Record<string, unknown> = {}) =>
  ({ identity: { sub: ME }, args: {}, stash: {}, env: { TABLE: "AICoach-test" }, ...over }) as any;

describe("requireMember", () => {
  it("looks up the caller's membership, never an argument's uid", () => {
    const req = requireMember.request(ctx({ args: { groupId: "g1", uid: OTHER } }));
    expect(req.key).toEqual({ PK: "GROUP#g1", SK: `MEMBER#${ME}` });
    expect(req.consistentRead).toBe(true);
  });

  it("rejects non-members", () => {
    expect(() => requireMember.response(ctx({ result: null }))).toThrow(Unauthorized);
  });

  it("stashes the membership for later steps", () => {
    const c = ctx({ result: { uid: ME, shareLive: true } });
    requireMember.response(c);
    expect(c.stash.member).toEqual({ uid: ME, shareLive: true });
  });
});

describe("publishLiveSet", () => {
  const args = { groupId: "g1", exercise: "Bench press", setIndex: 3, setCount: 5, loadLb: 185, reps: 5, state: "working", startedAt: "2026-10-03T11:50:00Z" };

  it("rejects members who haven't opted in to live sharing (FIT-53)", () => {
    expect(() => publishLiveSet.request(ctx({ args, stash: { member: { shareLive: false } } }))).toThrow(Unauthorized);
  });

  it("writes only the caller's LIVE item, even if another uid is passed", () => {
    const req = publishLiveSet.request(ctx({ args: { ...args, uid: OTHER }, stash: { member: { shareLive: true } } }));
    expect(req.key).toEqual({ PK: "GROUP#g1", SK: `LIVE#${ME}` });
    expect(req.attributeValues.uid).toBe(ME);
    expect(req.attributeValues.expiresAt).toBe(1_790_000_000 + 86_400);
  });
});

describe("a member can't write another member's items", () => {
  it("publishProgress keys by the caller", () => {
    const req = publishProgress.request(ctx({ args: { groupId: "g1", goalId: "goal1", pct: 62, uid: OTHER } }));
    expect(req.key).toEqual({ PK: "GROUP#g1", SK: `PROGRESS#${ME}#goal1` });
    expect(req.attributeValues.uid).toBe(ME);
  });

  it("endLiveSession and leaveGroup touch only the caller's items", () => {
    expect(endLiveSession.request(ctx({ args: { groupId: "g1" } })).key).toEqual({ PK: "GROUP#g1", SK: `LIVE#${ME}` });
    const keys = leaveGroup.request(ctx({ args: { groupId: "g1" } })).transactItems.map((t: any) => t.key);
    expect(keys).toEqual([
      { PK: "GROUP#g1", SK: `MEMBER#${ME}` },
      { PK: "GROUP#g1", SK: `LIVE#${ME}` },
    ]);
  });
});

describe("createGroup", () => {
  it("writes the group, the creator's membership and a unique invite together", () => {
    const c = ctx({ args: { name: "Lose 10" }, stash: { profile: { displayName: "Max" } } });
    const req = createGroup.request(c);
    expect(req.operation).toBe("TransactWriteItems");
    const [meta, member, invite] = req.transactItems;
    expect(meta.condition.expression).toBe("attribute_not_exists(PK)");
    expect(member.key.SK).toBe(`MEMBER#${ME}`);
    expect(member.attributeValues).toMatchObject({ GSI1PK: `USER#${ME}`, displayName: "Max", shareLive: false });
    expect(invite.key.PK).toBe("INVITE#11111111");
    expect(invite.condition.expression).toBe("attribute_not_exists(PK)");
    expect(createGroup.response(c)).toEqual({ groupId: "11111111-2222-3333-4444-555555555555", inviteCode: "11111111", name: "Lose 10", role: "member" });
  });
});

describe("joinGroup", () => {
  const stash = { invite: { groupId: "g1", groupName: "Lose 10" }, profile: null };

  it("joining twice is a no-op", () => {
    const c = ctx({ stash, error: { type: "DynamoDB:ConditionalCheckFailedException", message: "exists" } });
    expect(joinGroup.response(c)).toEqual({ groupId: "g1", name: "Lose 10", role: "member" });
  });

  it("surfaces other errors", () => {
    expect(() => joinGroup.response(ctx({ stash, error: { type: "DynamoDB:Throttling", message: "slow" } }))).toThrow(ResolverError);
  });
});

describe("groupDetail", () => {
  it("hides progress and live items of people who left", () => {
    const items = [
      { SK: "META", name: "Lose 10", createdBy: ME, inviteCode: "ABC", createdAt: "t", updatedAt: "t" },
      { SK: `MEMBER#${ME}`, uid: ME },
      { SK: "GOAL#goal1", goalId: "goal1" },
      { SK: `PROGRESS#${ME}#goal1`, uid: ME },
      { SK: `PROGRESS#${OTHER}#goal1`, uid: OTHER },
      { SK: `LIVE#${OTHER}`, uid: OTHER },
    ];
    const group = groupDetail.response(ctx({ args: { groupId: "g1" }, result: { items } }));
    expect(group.members).toHaveLength(1);
    expect(group.goals).toHaveLength(1);
    expect(group.progress.map((p: any) => p.uid)).toEqual([ME]);
    expect(group.live).toEqual([]);
  });

  it("skips the feed, which has its own resolver", () => {
    const req = groupDetail.request(ctx({ args: { groupId: "g1" } }));
    expect(req.query.expressionValues[":g"]).toBe("G");
    expect("FEED#" < "G").toBe(true);
    expect(["GOAL#", "LIVE#", "MEMBER#", "META", "PROGRESS#"].every((sk) => sk >= "G")).toBe(true);
  });
});

describe("subscriptions", () => {
  it("filter events to the subscribed group", () => {
    subscription.response(ctx({ args: { groupId: "g1" } }));
    expect(subscriptionFilters.at(-1)).toEqual({ filter: { groupId: { eq: "g1" } } });
  });
});
