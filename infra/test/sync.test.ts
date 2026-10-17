import { beforeEach, describe, expect, it, vi } from "vitest";

// FIT-126: a fake table in place of DynamoDB, with the conditional put the Lambda relies on.
const table = new Map<string, Record<string, any>>();
const sent: any[] = [];
vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return {
    ...actual,
    DynamoDBDocumentClient: {
      from: () => ({
        send: async (command: any) => {
          const input = command.input;
          sent.push(command);
          const name = command.constructor.name;
          if (name === "PutCommand") {
            const id = `${input.Item.PK}|${input.Item.SK}`;
            const old = table.get(id);
            if (old && !(old.updatedAt < input.ExpressionAttributeValues[":u"])) {
              throw Object.assign(new Error("conditional"), { name: "ConditionalCheckFailedException" });
            }
            table.set(id, input.Item);
            return {};
          }
          if (name === "GetCommand") return { Item: table.get(`${input.Key.PK}|${input.Key.SK}`) };
          if (name === "QueryCommand") {
            const v = input.ExpressionAttributeValues;
            const items = [...table.values()]
              .filter((i) => i.GSI1PK === v[":p"] && (!v[":s"] || i.GSI1SK > v[":s"]))
              .sort((a, b) => (a.GSI1SK < b.GSI1SK ? -1 : 1));
            const page = items.slice(0, input.Limit);
            return { Items: page, LastEvaluatedKey: items.length > input.Limit ? {} : undefined };
          }
          throw new Error(`unexpected ${name}`);
        },
      }),
    },
  };
});

const { checked, push, pull, handler, MAX_UNITS } = await import("../lambda/sync.ts");

const t0 = new Date("2026-10-16T12:00:00.000Z");
const later = (s: number) => new Date(t0.getTime() + s * 1000);
const plan = (body: string, updatedAt = t0.toISOString()) => ({ key: "plan#2026-10-16", updatedAt, deleted: false, body });

beforeEach(() => {
  table.clear();
  sent.length = 0;
});

describe("sync units", () => {
  it("accept only the known keys", () => {
    for (const key of ["plan#2026-10-16", "log#2026-01-02", "goal#3F2504E0-4F89-11D3-9A0C-0305E82C3301", "profile", "template#landmine-press"]) {
      expect(checked({ key, updatedAt: t0.toISOString(), deleted: true }, t0).key).toBe(key);
    }
    for (const key of ["plan#2026-10", "PROFILE", "goal#x", "plan#2026-10-16#x", "../SHARE#1", "template#", "template#Landmine", "template#a/b", "template#-x"]) {
      expect(() => checked({ key, updatedAt: t0.toISOString(), deleted: true }, t0)).toThrow();
    }
  });

  it("need a body unless deleted, and a tombstone drops it", () => {
    expect(() => checked({ key: "profile", updatedAt: t0.toISOString(), deleted: false }, t0)).toThrow();
    expect(checked({ key: "profile", updatedAt: t0.toISOString(), deleted: true, body: "{}" }, t0).body).toBeUndefined();
  });

  it("take a time in the future as now", () => {
    expect(checked(plan("{}", later(3600).toISOString()), t0).updatedAt).toBe(t0.toISOString());
  });

  it("are limited in size and count", async () => {
    expect(() => checked(plan("x".repeat(100_001)), t0)).toThrow();
    await expect(push("a", Array.from({ length: MAX_UNITS + 1 }, () => plan("{}")), undefined, t0)).rejects.toThrow();
  });
});

describe("push and pull", () => {
  it("the newest write wins, and a stale one comes back with the server's copy", async () => {
    await push("a", [plan('{"v":2}', later(10).toISOString())], "web", later(10));
    const stale = await push("a", [plan('{"v":1}', later(5).toISOString())], "phone", later(20));
    expect(stale.rejected).toEqual([expect.objectContaining({ key: "plan#2026-10-16", body: '{"v":2}' })]);
    const newer = await push("a", [plan('{"v":3}', later(30).toISOString())], "phone", later(30));
    expect(newer.rejected).toEqual([]);
    expect((await pull("a", null)).units.map((u) => u.body)).toEqual(['{"v":3}']);
  });

  it("keep each user's units in their own partition", async () => {
    await push("a", [plan("{}")], undefined, t0);
    expect([...table.keys()]).toEqual(["USER#a|SYNC#plan#2026-10-16"]);
    expect((await pull("b", null)).units).toEqual([]);
  });

  it("pull what changed after the cursor, in pages", async () => {
    await push("a", [plan('{"v":1}')], undefined, t0);
    const first = await pull("a", null);
    expect(first.units).toHaveLength(1);
    expect((await pull("a", first.cursor)).units).toEqual([]);
    await push("a", [{ key: "log#2026-10-16", updatedAt: later(5).toISOString(), deleted: false, body: "[]" }], undefined, later(5));
    const next = await pull("a", first.cursor);
    expect(next.units.map((u) => u.key)).toEqual(["log#2026-10-16"]);
    expect(next.more).toBe(false);
  });

  it("deleted units come back as tombstones", async () => {
    await push("a", [plan("{}")], undefined, t0);
    await push("a", [{ key: "plan#2026-10-16", updatedAt: later(1).toISOString(), deleted: true }], undefined, later(1));
    expect((await pull("a", null)).units).toEqual([expect.objectContaining({ deleted: true, body: null })]);
  });

  it("the handler uses the caller's identity, and refuses someone else's uid unless they're the caller's client (FIT-130)", async () => {
    await handler({ identity: { sub: "a" }, info: { fieldName: "syncPush" }, arguments: { units: [plan("{}")] } } as any);
    expect([...table.keys()]).toEqual(["USER#a|SYNC#plan#2026-10-16"]);
    await expect(handler({ identity: { sub: "a" }, info: { fieldName: "syncPush" }, arguments: { units: [plan("{}")], uid: "b" } } as any))
      .rejects.toThrow(/Unauthorized/);
    expect([...table.keys()]).toEqual(["USER#a|SYNC#plan#2026-10-16"]);
  });
});
