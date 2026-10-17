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
const { owner } = await import("../lambda/sync.ts");
const now = new Date("2026-10-17T03:00:00Z");
const later = (days: number) => new Date(now.getTime() + days * 86_400_000);

beforeEach(() => {
  table.clear();
  table.set("USER#sam|PROFILE", { PK: "USER#sam", SK: "PROFILE", displayName: "Sam Coach" });
  table.set("USER#ann|PROFILE", { PK: "USER#ann", SK: "PROFILE", displayName: "Ann" });
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

  it("gives the client Pro while it lasts", async () => {
    expect(await coach.coached("ann")).toBe(false);
    await linked();
    expect(await coach.coached("ann")).toBe(true);
    expect(await coach.coached("sam")).toBe(false);
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
