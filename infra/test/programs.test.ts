import { beforeEach, describe, expect, it, vi } from "vitest";

// FIT-131: a fake table, with the conditional put sync relies on.
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
              const old = table.get(id(input.Item));
              if (input.ConditionExpression && old && !(old.updatedAt < input.ExpressionAttributeValues[":u"])) {
                throw Object.assign(new Error("c"), { name: "ConditionalCheckFailedException" });
              }
              table.set(id(input.Item), input.Item);
              return {};
            }
            case "UpdateCommand": {
              const item = table.get(id(input.Key))!;
              item.status = input.ExpressionAttributeValues[":s"];
              item.answeredAt = input.ExpressionAttributeValues[":a"];
              return {};
            }
            case "QueryCommand": {
              const v = input.ExpressionAttributeValues;
              const prefix = v[":o"] ?? v[":c"] ?? v[":p"];
              return { Items: [...table.values()].filter((i) => i.PK === v[":pk"] && String(i.SK).startsWith(prefix)) };
            }
            case "BatchGetCommand": {
              const keys = Object.values(input.RequestItems)[0] as any;
              return { Responses: { "AICoach-test": keys.Keys.map((k: any) => table.get(id(k))).filter(Boolean) } };
            }
          }
          throw new Error(`unexpected ${command.constructor.name}`);
        },
      }),
    },
  };
});

process.env.TABLE = "AICoach-test";
const programs = await import("../lambda/programs.ts");
const now = new Date("2026-10-17T03:00:00Z");
const m = (metric: string, value: number) => ({ metric, value, unit: metric });
const days = [
  { weekday: 1, slot: "Lower", rows: [
    { template: "back-squat", targets: [m("sets", 2), m("reps", 5), m("load_lb", 95)], note: "warm-up", main: true },
    { template: "back-squat", targets: [m("sets", 3), m("reps", 5), m("load_lb", 185)], main: true },
    { template: "plank", targets: [m("sets", 3), m("duration_s", 40)] },
  ] },
  { weekday: 4, slot: "Upper", rows: [{ template: "bench-press", targets: [m("sets", 3), m("reps", 5), m("load_lb", 155)], main: true }] },
];
const unit = (owner: string, key: string, rows: unknown[]) =>
  table.set(`USER#${owner}|SYNC#${key}`, { PK: `USER#${owner}`, SK: `SYNC#${key}`, key, updatedAt: "2026-10-01T00:00:00.000Z", deleted: false, body: JSON.stringify(rows) });
const rowsOf = (owner: string, key: string) => JSON.parse(table.get(`USER#${owner}|SYNC#${key}`)?.body ?? "null");

beforeEach(() => {
  table.clear();
  table.set("USER#ann|COACH#sam", { PK: "USER#ann", SK: "COACH#sam", coachUid: "sam" });
  table.set("USER#sam|COACHPLAN", { PK: "USER#sam", SK: "COACHPLAN", status: "active" }); // FIT-148
});

describe("a program's weeks (FIT-131)", () => {
  it("repeat the template from the start day, skipping days before it", () => {
    // Start Tuesday Oct 20: that week's Monday is before it, so the first session is Thursday.
    const out = programs.expand({ start: "2026-10-20", weeks: 2, addPerWeek: 0 }, days);
    expect(out.map((s) => `${s.day} ${s.slot}`)).toEqual(["2026-10-22 Upper", "2026-10-26 Lower", "2026-10-29 Upper"]);
  });

  it("add load each week to main lifts' working sets only", () => {
    const out = programs.expand({ start: "2026-10-18", weeks: 3, addPerWeek: 5 }, days);
    const squats = out.filter((s) => s.slot === "Lower").map((s) => s.rows.map((r) => r.targets.find((t) => t.metric === "load_lb")?.value));
    expect(squats).toEqual([[95, 185, undefined], [95, 190, undefined], [95, 195, undefined]]);
  });

  it("place a session at the client's workout time, in their time zone, pinned and from the coach", () => {
    const rows = programs.dayRows("2026-10-19", "Lower", days[0].rows, "Sam", 7 * 60, -4 * 60, [{ id: "cook", kind: "cook" }]);
    // 7:00 at UTC−4 is 11:00 UTC.
    expect(new Date((rows[0].at as number) * 1000).toISOString()).toBe("2026-10-19T11:00:00.000Z");
    expect(rows.slice(0, 3).map((r: any) => [r.at - (rows[0].at as number), r.pinned, r.adjustedReason])).toEqual([[0, true, "From Sam"], [1, true, "From Sam"], [2, true, "From Sam"]]);
    expect(rows.at(-1)).toEqual({ id: "cook", kind: "cook" });
  });
});

describe("sending and answering (FIT-131)", () => {
  const send = (coach = "sam", weeks = 2) => programs.send(coach, "Sam", "ann", "2026-10-18", weeks, "Two weeks of base", JSON.stringify(days), 5, now);

  it("only a client's coach sends, within the limits", async () => {
    await expect(send("bob")).rejects.toThrow(/don't coach/);
    await expect(send("sam", 17)).rejects.toThrow(/From 1 to 16/);
    await expect(programs.send("sam", "Sam", "ann", "2026-10-18", 2, "", "[]", 0, now)).rejects.toThrow(/at least one session/);
    expect(await send()).toMatchObject({ status: "sent", weeks: 2, coachName: "Sam" });
  });

  it("start replaces the client's workouts from the start day, keeps cooking and trained days", async () => {
    unit("ann", "plan#2026-10-19", [{ id: "old", kind: "workout", at: 1, template: "deadlift" }, { id: "cook", kind: "cook", at: 2 }]);
    unit("ann", "plan#2026-10-21", [{ id: "old2", kind: "workout", at: 1, template: "deadlift" }]);
    unit("ann", "plan#2026-10-22", [{ id: "done", kind: "workout", at: 1, template: "deadlift" }]);
    unit("ann", "log#2026-10-22", [{ id: "l", kind: "workout", at: 1 }]);
    unit("ann", "profile", [{}]);
    table.set("USER#ann|SYNC#profile", { ...table.get("USER#ann|SYNC#profile")!, body: JSON.stringify({ workoutTime: 6 * 60 }) });
    const offer = await send();
    const answered = await programs.answer("ann", offer.id, true, -4 * 60, now);
    expect(answered.status).toBe("started");
    // Monday: the coach's Lower, and the cooking stays.
    expect(rowsOf("ann", "plan#2026-10-19").map((r: any) => r.kind === "workout" ? r.template : r.kind)).toEqual(["back-squat", "back-squat", "plank", "cook"]);
    expect(new Date(rowsOf("ann", "plan#2026-10-19")[0].at * 1000).toISOString()).toBe("2026-10-19T10:00:00.000Z");
    // Wednesday had a workout the program doesn't: gone.
    expect(table.get("USER#ann|SYNC#plan#2026-10-21")).toMatchObject({ deleted: true });
    // Thursday was already trained: kept.
    expect(rowsOf("ann", "plan#2026-10-22")[0].id).toBe("done");
    // The second week, with 5 lb more on the main lift.
    expect(rowsOf("ann", "plan#2026-10-26")[1].targets.find((t: any) => t.metric === "load_lb").value).toBe(190);
  });

  it("decline leaves the plan alone; an offer is answered once; the coach sees the answer", async () => {
    const offer = await send();
    await programs.answer("ann", offer.id, false, 0, now);
    expect(table.has("USER#ann|SYNC#plan#2026-10-19")).toBe(false);
    await expect(programs.answer("ann", offer.id, true, 0, now)).rejects.toThrow(/already answered/);
    expect((await programs.offers("sam", "ann")).map((o) => o.status)).toEqual(["declined"]);
    await expect(programs.offers("bob", "ann")).rejects.toThrow(/don't coach/);
    // FIT-148: a lapsed plan keeps the offer, but the coach can't see it or send another until they pay.
    table.set("USER#sam|COACHPLAN", { PK: "USER#sam", SK: "COACHPLAN", status: "canceled" });
    await expect(programs.offers("sam", "ann")).rejects.toThrow(/coach plan/);
    await expect(send()).rejects.toThrow(/coach plan/);
    expect((await programs.offers("ann")).map((o) => o.status)).toEqual(["declined"]);
  });

  it("go to the client's phone as \"Sam sent you a 2-week program\"", async () => {
    const { offerText } = await import("../lambda/push.ts");
    expect(offerText("Sam", 2, "Two weeks of base")).toEqual({ title: "Sam sent you a 2-week program", body: "Two weeks of base" });
  });
});
