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
import * as onSync from "../resolvers/onSync.js";
import * as removeMember from "../resolvers/removeMember.js";
import * as rotateInvite from "../resolvers/rotateInvite.js";
import * as createShare from "../resolvers/createShare.js";
import * as getShare from "../resolvers/getShare.js";
import * as publishWeek from "../resolvers/publishWeek.js";
import * as clearWeek from "../resolvers/clearWeek.js";
import * as editComment from "../resolvers/editComment.js";
import * as deleteComment from "../resolvers/deleteComment.js";
import * as registerDevice from "../resolvers/registerDevice.js";

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
    expect(member.attributeValues).toMatchObject({ GSI1PK: `USER#${ME}`, displayName: "Max", shareLive: true });
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

  it("onSync (FIT-126): only my own uid, filtered to my pushes", () => {
    expect(() => onSync.request(ctx({ args: { uid: OTHER } }))).toThrow(Unauthorized);
    onSync.request(ctx({ args: { uid: ME } }));
    onSync.response(ctx({ args: { uid: ME } }));
    expect(subscriptionFilters.at(-1)).toEqual({ filter: { uid: { eq: ME } } });
  });
});

describe("creator-only operations", () => {
  const meta = { createdBy: ME, name: "Family", inviteCode: "OLDCODE1" };

  it("removeMember: only the creator, and never themselves", () => {
    expect(() => removeMember.request(ctx({ identity: { sub: OTHER }, args: { groupId: "g1", uid: ME }, stash: { meta } }))).toThrow(Unauthorized);
    expect(() => removeMember.request(ctx({ args: { groupId: "g1", uid: ME }, stash: { meta } }))).toThrow(ResolverError);
    const keys = removeMember.request(ctx({ args: { groupId: "g1", uid: OTHER }, stash: { meta } })).transactItems.map((t: any) => t.key);
    expect(keys).toEqual([
      { PK: "GROUP#g1", SK: `MEMBER#${OTHER}` },
      { PK: "GROUP#g1", SK: `LIVE#${OTHER}` },
    ]);
  });

  it("rotateInvite: only the creator; deletes the old code and writes a new one", () => {
    expect(() => rotateInvite.request(ctx({ identity: { sub: OTHER }, args: { groupId: "g1" }, stash: { meta } }))).toThrow(Unauthorized);
    const c = ctx({ args: { groupId: "g1" }, stash: { meta } });
    const [update, del, put] = rotateInvite.request(c).transactItems;
    expect(update.key).toEqual({ PK: "GROUP#g1", SK: "META" });
    expect(update.update.expressionValues[":c"]).toBe("11111111");
    expect(del.key).toEqual({ PK: "INVITE#OLDCODE1", SK: "META" });
    expect(put.key).toEqual({ PK: "INVITE#11111111", SK: "META" });
    expect(put.attributeValues).toMatchObject({ groupId: "g1", groupName: "Family" });
    expect(rotateInvite.response(c)).toBe("11111111");
  });
});

describe("myGroups", () => {
  it("says which groups I share live workouts with (FIT-53)", async () => {
    const myGroups = await import("../resolvers/myGroups.js");
    const items = [{ groupId: "g1", groupName: "Family", role: "member", shareLive: true }, { groupId: "g2", groupName: "Work", role: "member" }];
    expect(myGroups.response(ctx({ result: { items } }))).toEqual([
      { groupId: "g1", name: "Family", role: "member", shareLive: true },
      { groupId: "g2", name: "Work", role: "member", shareLive: false },
    ]);
  });
});

describe("createShare (FIT-105)", () => {
  const share = (args: Record<string, unknown>) =>
    ctx({ args, stash: { profile: { displayName: "Max Kendall" } }, env: { TABLE: "AICoach-test", SHARE_ORIGIN: "https://share.example.com" } });

  it("saves under the caller, with their own name, and returns the link", () => {
    const c = share({ kind: "win", payload: JSON.stringify({ kind: "pr", name: "Someone Else" }) });
    const req = createShare.request(c);
    expect(req.key.PK).toMatch(/^SHARE#[0-9a-f]{12}$/);
    expect(req.attributeValues).toMatchObject({ kind: "win", uid: ME, name: "Max Kendall", GSI1PK: `USER#${ME}` });
    expect(createShare.response(c)).toEqual({ id: req.key.PK.slice(6), url: `https://share.example.com/w/${req.key.PK.slice(6)}` });
  });

  it("takes only wins, recaps and programs, and not too much of them", () => {
    expect(() => createShare.request(share({ kind: "group", payload: "{}" }))).toThrow(ResolverError);
    expect(() => createShare.request(share({ kind: "win", payload: "x".repeat(8001) }))).toThrow(ResolverError);
  });
});

describe("getShare (FIT-113)", () => {
  it("reads a share by a well-formed id, and hands back its payload parsed", () => {
    expect(getShare.request(ctx({ args: { id: "ae79125c4c25" } })).key).toEqual({ PK: "SHARE#ae79125c4c25", SK: "META" });
    expect(() => getShare.request(ctx({ args: { id: "../GROUP#x" } }))).toThrow(ResolverError);
    const c = ctx({ args: { id: "ae79125c4c25" }, result: { kind: "session", name: "Max", payload: '{"title":"Legs"}' } });
    expect(getShare.response(c)).toEqual({ id: "ae79125c4c25", kind: "session", name: "Max", payload: { title: "Legs" } });
    expect(getShare.response(ctx({ args: { id: "ae79125c4c25" }, result: null }))).toBeNull();
  });
});

describe("week plans (FIT-114)", () => {
  it("are keyed by the caller, a week at most, with short names", () => {
    const days = [{ day: "2026-10-12", title: "Lower body" }];
    const req = publishWeek.request(ctx({ args: { groupId: "g1", weekOf: "2026-10-12", days, uid: OTHER } }));
    expect(req.key).toEqual({ PK: "GROUP#g1", SK: `WEEK#${ME}` });
    expect(req.attributeValues).toMatchObject({ uid: ME, weekOf: "2026-10-12", days });
    expect(() => publishWeek.request(ctx({ args: { groupId: "g1", weekOf: "2026-10-12", days: Array(8).fill(days[0]) } }))).toThrow(ResolverError);
    expect(() => publishWeek.request(ctx({ args: { groupId: "g1", weekOf: "2026-10-12", days: [{ day: "2026-10-12", title: "x".repeat(41) }] } }))).toThrow(ResolverError);
    expect(clearWeek.request(ctx({ args: { groupId: "g1" } })).key).toEqual({ PK: "GROUP#g1", SK: `WEEK#${ME}` });
  });

  it("show only members' weeks in the group", () => {
    const items = [{ SK: "META", name: "G" }, { SK: `MEMBER#${ME}`, uid: ME }, { SK: `WEEK#${ME}`, uid: ME }, { SK: "WEEK#gone", uid: "gone" }];
    const group = groupDetail.response(ctx({ args: { groupId: "g1" }, result: { items } }));
    expect(group.weeks.map((w: { uid: string }) => w.uid)).toEqual([ME]);
  });
});

describe("FIT-200: a reply's author corrects or deletes it", () => {
  const args = { uid: OTHER, day: "2026-10-20", at: "2026-10-20T18:00:00.000Z" };
  it("reaches only a reply the caller wrote, in the thread asked for", () => {
    const req = editComment.request(ctx({ args: { ...args, text: " Go lighter next week " } }));
    expect(req.key).toEqual({ PK: `USER#${OTHER}`, SK: `COMMENT#2026-10-20#2026-10-20T18:00:00.000Z#${ME}` });
    expect(req.update.expressionValues[":text"]).toBe("Go lighter next week");
    expect(req.condition.expression).toBe("attribute_exists(PK)");
    expect(deleteComment.request(ctx({ args: { day: args.day, at: args.at } })).key)
      .toEqual({ PK: `USER#${ME}`, SK: `COMMENT#2026-10-20#2026-10-20T18:00:00.000Z#${ME}` });
  });

  it("refuses an empty or long reply, or a day that isn't one", () => {
    expect(() => editComment.request(ctx({ args: { ...args, text: "  " } }))).toThrow(ResolverError);
    expect(() => editComment.request(ctx({ args: { ...args, text: "x".repeat(1001) } }))).toThrow(/too long/);
    expect(() => deleteComment.request(ctx({ args: { ...args, day: "2026-10-20#X" } }))).toThrow(/Not a day/);
  });

  it("says when the reply is gone, and returns the edited one", () => {
    expect(() => editComment.response(ctx({ error: { type: "DynamoDB:ConditionalCheckFailedException", message: "x" } }))).toThrow(/gone/);
    const c = { day: args.day, at: args.at, by: ME, text: "New", PK: "x" };
    expect(editComment.response(ctx({ result: c }))).toEqual({ day: args.day, at: args.at, by: ME, byName: null, text: "New" });
  });
});

describe("FIT-220: a device's evening nudge", () => {
  it("lists a device with a time zone under NUDGE, unless nudges are off", () => {
    const on = registerDevice.request(ctx({ args: { token: "t1", platform: "ios", tz: "America/New_York" } }));
    expect(on.attributeValues).toMatchObject({ tz: "America/New_York", GSI1PK: "NUDGE", GSI1SK: `${ME}#t1` });
    const off = registerDevice.request(ctx({ args: { token: "t1", platform: "ios", tz: "America/New_York", nudges: false } }));
    expect(off.attributeValues.GSI1PK).toBeUndefined();
    // An older app sends no time zone, so it gets no nudge.
    expect(registerDevice.request(ctx({ args: { token: "t1", platform: "ios" } })).attributeValues.GSI1PK).toBeUndefined();
  });
});
