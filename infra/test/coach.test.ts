import { beforeEach, describe, expect, it, vi } from "vitest";

// FIT-130: a fake table for coach links and invites, with TransactWrite's all-or-nothing.
const table = new Map<string, Record<string, any>>();
const id = (k: { PK: string; SK: string }) => `${k.PK}|${k.SK}`;
vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return {
    ...actual,
    DynamoDBDocumentClient: {
      from: () => ({
        send: async (command: any) => {
          const input = command.input;
          switch (command.constructor.name) {
            case "GetCommand": return { Item: table.get(id(input.Key)) };
            case "DeleteCommand": table.delete(id(input.Key)); return {};
            case "QueryCommand": {
              const v = input.ExpressionAttributeValues;
              const prefix = v[":c"] ?? v[":p"];
              const Items = [...table.values()].filter((i) => i.PK === v[":pk"] && String(i.SK).startsWith(prefix));
              return { Items: input.Limit ? Items.slice(0, input.Limit) : Items };
            }
            case "TransactWriteCommand": {
              for (const t of input.TransactItems) {
                if (t.Put?.ConditionExpression && table.has(id(t.Put.Item))) throw Object.assign(new Error("x"), { name: "TransactionCanceledException" });
                if (t.Delete?.ConditionExpression && !table.has(id(t.Delete.Key))) throw Object.assign(new Error("x"), { name: "TransactionCanceledException" });
              }
              for (const t of input.TransactItems) {
                if (t.Put) table.set(id(t.Put.Item), t.Put.Item);
                if (t.Delete) table.delete(id(t.Delete.Key));
              }
              return {};
            }
          }
          throw new Error(`unexpected ${command.constructor.name}`);
        },
      }),
    },
  };
});

process.env.TABLE = "AICoach-test";
process.env.SHARE_ORIGIN = "https://dev.example.com";
const coach = await import("../lambda/coach.ts");
const { owner, coachMayWrite } = await import("../lambda/sync.ts");
const now = new Date("2026-10-17T03:00:00Z");
const later = (days: number) => new Date(now.getTime() + days * 86_400_000);

beforeEach(() => {
  table.clear();
  table.set("USER#sam|PROFILE", { PK: "USER#sam", SK: "PROFILE", displayName: "Sam Coach" });
  table.set("USER#ann|PROFILE", { PK: "USER#ann", SK: "PROFILE", displayName: "Ann" });
  table.set("USER#sam|COACHPLAN", { PK: "USER#sam", SK: "COACHPLAN", status: "active" }); // FIT-148
});

describe("coach invites (FIT-130)", () => {
  it("make a link with a 10-letter code and the coach's name", async () => {
    const { code, url } = await coach.createInvite("sam", undefined, now);
    expect(code).toMatch(/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{10}$/);
    expect(url).toBe(`https://dev.example.com/c/${code}`);
    expect(await coach.inviteName(code.toLowerCase(), now)).toBe("Sam Coach");
  });

  it("prefer the name on the coach's sign-in", async () => {
    const { code } = await coach.createInvite("sam", { name: "Samantha" }, now);
    expect(await coach.inviteName(code, now)).toBe("Samantha");
  });

  it("link both sides once, then are used up", async () => {
    const { code } = await coach.createInvite("sam", undefined, now);
    expect(await coach.accept("ann", code, undefined, now)).toMatchObject({ uid: "sam", name: "Sam Coach" });
    expect(table.get("USER#ann|COACH#sam")).toMatchObject({ coachUid: "sam" });
    expect(table.get("USER#sam|CLIENT#ann")).toMatchObject({ clientUid: "ann", clientName: "Ann" });
    expect(await coach.inviteName(code, now)).toBeNull();
    await expect(coach.accept("bob", code, undefined, now)).rejects.toThrow(/used or has expired/);
  });

  it("expire after 14 days", async () => {
    const { code } = await coach.createInvite("sam", undefined, now);
    expect(await coach.inviteName(code, later(13))).toBe("Sam Coach");
    await expect(coach.accept("ann", code, undefined, later(15))).rejects.toThrow(/used or has expired/);
  });

  it("can't be accepted by the coach who made them, or read as a junk code", async () => {
    const { code } = await coach.createInvite("sam", undefined, now);
    await expect(coach.accept("sam", code, undefined, now)).rejects.toThrow(/your own invite/);
    expect(await coach.inviteName("not-a-code", now)).toBeNull();
  });
});

describe("a coach link (FIT-130)", () => {
  async function linked() {
    const { code } = await coach.createInvite("sam", undefined, now);
    await coach.accept("ann", code, undefined, now);
  }

  it("lets the coach read and write the client's units, and nobody else", async () => {
    await linked();
    expect(await owner("sam", "ann")).toBe("ann");
    expect(await owner("ann", undefined)).toBe("ann");
    expect(await owner("ann", "ann")).toBe("ann");
    await expect(owner("bob", "ann")).rejects.toThrow(/Unauthorized/);
    // The link goes one way: the client doesn't get the coach's units.
    await expect(owner("ann", "sam")).rejects.toThrow(/Unauthorized/);
  });

  it("lets the coach change only the plan, never logs, goals or the profile", () => {
    const at = "2026-10-16T12:00:00.000Z";
    expect(() => coachMayWrite([{ key: "plan#2026-10-16", updatedAt: at, deleted: false, body: "[]" }])).not.toThrow();
    for (const key of ["log#2026-10-16", "goal#3F2504E0-4F89-11D3-9A0C-0305E82C3301", "profile"]) {
      expect(() => coachMayWrite([{ key, updatedAt: at, deleted: false, body: "[]" }])).toThrow(/only the plan/);
    }
  });

  it("gives the client Pro while it lasts, and the coach Claude for designing (FIT-141)", async () => {
    expect(await coach.coached("ann")).toBe(false);
    expect(await coach.coaching("sam")).toBe(false);
    await linked();
    expect(await coach.coached("ann")).toBe(true);
    expect(await coach.coached("sam")).toBe(false);
    expect(await coach.coaching("sam")).toBe(true);
    expect(await coach.coaching("ann")).toBe(false);
  });

  it("ends at once from either side", async () => {
    await linked();
    await coach.handler({ identity: { sub: "ann" }, info: { fieldName: "unlinkCoach" }, arguments: { uid: "sam" } } as any);
    await expect(owner("sam", "ann")).rejects.toThrow(/Unauthorized/);
    expect(table.has("USER#sam|CLIENT#ann")).toBe(false);
    await linked();
    await coach.handler({ identity: { sub: "sam" }, info: { fieldName: "removeClient" }, arguments: { uid: "ann" } } as any);
    expect(await coach.coached("ann")).toBe(false);
  });

  it("lists each side's people", async () => {
    await linked();
    const as = (sub: string, fieldName: string) => coach.handler({ identity: { sub }, info: { fieldName }, arguments: {} } as any);
    expect(await as("ann", "myCoaches")).toEqual([{ uid: "sam", name: "Sam Coach", since: now.toISOString() }]);
    expect(await as("sam", "myClients")).toEqual([{ uid: "ann", name: "Ann", since: now.toISOString() }]);
  });
});

describe("replies on a session (FIT-132)", () => {
  async function linked() {
    const { code } = await coach.createInvite("sam", undefined, now);
    await coach.accept("ann", code, undefined, now);
  }

  it("are written by the client or their coach, into the client's account, and read by both", async () => {
    await linked();
    const reply = await coach.postComment("sam", undefined, "ann", "2026-10-14", "  Good squats. Ice the knee.  ", now);
    expect(reply).toMatchObject({ day: "2026-10-14", by: "sam", byName: "Sam Coach", text: "Good squats. Ice the knee." });
    await coach.postComment("ann", undefined, undefined, "2026-10-14", "Will do", later(0.01));
    expect([...table.keys()].filter((k) => k.includes("COMMENT#")).every((k) => k.startsWith("USER#ann|"))).toBe(true);
    const thread = await coach.comments("ann", undefined, "2026-10-14");
    expect(thread.map((c) => c.text)).toEqual(["Good squats. Ice the knee.", "Will do"]);
    expect(await coach.comments("sam", "ann")).toHaveLength(2);
  });

  it("refuse anyone else, an empty or long reply, and a bad day", async () => {
    await linked();
    await expect(coach.postComment("bob", undefined, "ann", "2026-10-14", "hi", now)).rejects.toThrow(/don't coach/);
    await expect(coach.comments("bob", "ann")).rejects.toThrow(/don't coach/);
    await expect(coach.postComment("sam", undefined, "ann", "2026-10-14", "   ", now)).rejects.toThrow(/Write something/);
    await expect(coach.postComment("sam", undefined, "ann", "2026-10-14", "x".repeat(1001), now)).rejects.toThrow(/too long/);
    await expect(coach.postComment("sam", undefined, "ann", "Oct 14", "hi", now)).rejects.toThrow(/Not a day/);
  });

  it("go to the client's phone as \"Sam replied on Wednesday's session\"", async () => {
    const { replyText } = await import("../lambda/push.ts");
    expect(replyText("Sam", "2026-10-14", "Good squats.")).toEqual({ title: "Sam replied on Wednesday's session", body: "Good squats." });
    expect(replyText(null, "2026-10-14", "x".repeat(200)).body).toHaveLength(178);
  });
});

describe("coaching needs the coach plan (FIT-148)", () => {
  const as = (sub: string, fieldName: string, args: Record<string, string> = {}) => coach.handler({ identity: { sub }, info: { fieldName }, arguments: args } as any);
  const plan = (status?: string) => status ? table.set("USER#sam|COACHPLAN", { PK: "USER#sam", SK: "COACHPLAN", status }) : table.delete("USER#sam|COACHPLAN");
  async function linked() {
    const { code } = await coach.createInvite("sam", undefined, now);
    await coach.accept("ann", code, undefined, now);
  }

  it("counts active, trialing and past_due as the plan", async () => {
    for (const status of ["active", "trialing", "past_due"]) { plan(status); expect(await coach.hasCoachPlan("sam")).toBe(true); }
    for (const status of ["canceled", "unpaid", "incomplete", undefined]) { plan(status); expect(await coach.hasCoachPlan("sam")).toBe(false); }
  });

  it("holds back invites, the client list, a client's units and their threads; the coach's own and the client's stay free", async () => {
    await linked();
    plan("canceled");
    for (const [field, args] of [["createClientInvite", {}], ["myClients", {}], ["comments", { uid: "ann" }], ["postComment", { uid: "ann", day: "2026-10-14", text: "hi" }]] as const) {
      await expect(as("sam", field, args), field).rejects.toThrow("Coaching needs the coach plan, $19.99 a month or $199 a year. Start it on the Billing page.");
    }
    await expect(owner("sam", "ann")).rejects.toThrow(/coach plan/);
    // The link stays, and nothing else changes for either of them.
    expect(table.has("USER#ann|COACH#sam")).toBe(true);
    expect(await owner("sam", undefined)).toBe("sam");
    expect(await owner("ann", undefined)).toBe("ann");
    expect(await as("ann", "myCoaches")).toHaveLength(1);
    await expect(coach.postComment("ann", undefined, undefined, "2026-10-14", "Still logging", now)).resolves.toBeTruthy();
    // Someone who isn't a client hears that, not about the plan.
    await expect(owner("bob", "ann")).rejects.toThrow(/Unauthorized/);
    // Paying again restores everything.
    plan("active");
    expect(await owner("sam", "ann")).toBe("ann");
    expect(await as("sam", "myClients")).toHaveLength(1);
  });

  it("still lets a lapsed coach end a link", async () => {
    await linked();
    plan(undefined);
    await as("sam", "removeClient", { uid: "ann" });
    expect(table.has("USER#ann|COACH#sam")).toBe(false);
  });
});
