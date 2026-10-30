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
            case "PutCommand": {
              if (input.ConditionExpression && table.has(id(input.Item))) throw Object.assign(new Error("x"), { name: "ConditionalCheckFailedException" });
              table.set(id(input.Item), input.Item);
              return {};
            }
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
  it("make a link with a 6-letter code (FIT-234) and the coach's name", async () => {
    const { code, url } = await coach.createInvite("sam", undefined, now);
    expect(code).toMatch(/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/);
    expect(url).toBe(`https://dev.example.com/c/${code}`);
    expect(await coach.inviteName(code.toLowerCase(), now)).toBe("Sam Coach");
  });

  it("read 6-letter codes, and 10-letter ones made before FIT-234, typed any way", () => {
    expect(coach.readCode(" k7m-4qx ")).toBe("K7M4QX");
    expect(coach.readCode("R9UCZN897P")).toBe("R9UCZN897P");
    expect(coach.readCode("K7M4Q")).toBeUndefined();
    expect(coach.readCode("K7M4QXZ")).toBeUndefined();
    expect(coach.readCode("K7M4Q0")).toBeUndefined();
  });

  it("prefer the name on the coach's sign-in", async () => {
    const { code } = await coach.createInvite("sam", { name: "Samantha" }, now);
    expect(await coach.inviteName(code, now)).toBe("Samantha");
  });

  it("from a coach with no name read as no name: the app's ask and the link (FIT-227)", async () => {
    table.set("USER#sam|PROFILE", { PK: "USER#sam", SK: "PROFILE", displayName: "  " });
    const { code } = await coach.createInvite("sam", { name: "" }, now);
    expect(table.get(`COACHINVITE#${code}|META`)).toMatchObject({ coachName: null });
    expect(await coach.inviteName(code, now)).toBe("Your coach");
    expect(await coach.accept("ann", code, undefined, now)).toMatchObject({ uid: "sam", name: null });
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

  it("lets the coach change the plan and (FIT-200) correct the logs, never goals or the profile", () => {
    const at = "2026-10-16T12:00:00.000Z";
    for (const key of ["plan#2026-10-16", "log#2026-10-16"]) {
      expect(() => coachMayWrite([{ key, updatedAt: at, deleted: false, body: "[]" }])).not.toThrow();
    }
    for (const key of ["goal#3F2504E0-4F89-11D3-9A0C-0305E82C3301", "profile"]) {
      expect(() => coachMayWrite([{ key, updatedAt: at, deleted: false, body: "[]" }])).toThrow(/only the plan and the logs/);
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

describe("coaching is free, with any number of clients (FIT-284)", () => {
  const as = (sub: string, fieldName: string, args: Record<string, string> = {}) => coach.handler({ identity: { sub }, info: { fieldName }, arguments: args } as any);
  const plan = (status?: string) => status ? table.set("USER#sam|COACHPLAN", { PK: "USER#sam", SK: "COACHPLAN", status }) : table.delete("USER#sam|COACHPLAN");

  it("counts active, trialing and past_due as Pro, the coach plan", async () => {
    for (const status of ["active", "trialing", "past_due"]) { plan(status); expect(await coach.hasCoachPlan("sam")).toBe(true); }
    for (const status of ["canceled", "unpaid", "incomplete", undefined]) { plan(status); expect(await coach.hasCoachPlan("sam")).toBe(false); }
  });

  it("lets a coach without Pro invite and coach ten clients: their list, units and threads", async () => {
    plan(undefined);
    const clients = Array.from({ length: 10 }, (_, i) => `client${i}`);
    for (const client of clients) {
      const { code } = (await as("sam", "createClientInvite")) as { code: string };
      await coach.accept(client, code, undefined, now);
    }
    expect(((await as("sam", "myClients")) as { uid: string }[]).map((c) => c.uid).sort()).toEqual([...clients].sort());
    for (const client of clients) expect(await owner("sam", client)).toBe(client);
    await expect(as("sam", "postComment", { uid: "client3", day: "2026-10-14", text: "Good squats." })).resolves.toBeTruthy();
    expect(await as("sam", "comments", { uid: "client3" })).toHaveLength(1);
    // A lapsed Pro changes nothing about coaching.
    plan("canceled");
    expect(await as("sam", "myClients")).toHaveLength(10);
    // Someone who isn't a client still hears that.
    await expect(owner("bob", "client3")).rejects.toThrow(/Unauthorized/);
  });

  // FIT-240
  it("gives a coach with no clients a sample client, and only once", async () => {
    plan(undefined);
    const [sample] = (await as("sam", "myClients")) as { uid: string; name: string }[];
    expect(sample).toMatchObject({ uid: "sample-mike-sam", name: "Mike Torres (sample)" });
    expect(table.get("USER#sample-mike-sam|PROFILE")).toMatchObject({ displayName: "Mike Torres", sample: true });
    expect([...table.keys()].filter((k) => k.startsWith("USER#sample-mike-sam|SYNC#plan#")).length).toBeGreaterThan(10);
    expect(await owner("sam", "sample-mike-sam")).toBe("sample-mike-sam");
    // Removed, it stays gone.
    await as("sam", "removeClient", { uid: "sample-mike-sam" });
    expect(await as("sam", "myClients")).toEqual([]);
    expect(table.has("USER#sam|CLIENT#sample-mike-sam")).toBe(false);
  });
});
