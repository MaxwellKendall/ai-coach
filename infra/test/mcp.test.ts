import type { LambdaFunctionURLEvent } from "aws-lambda";
import { describe, expect, it } from "vitest";
import { answer, callTool, hashToken, serve, type Account, type Store } from "../lambda/mcp.ts";
import { checkDay, dayOf, encode, epoch, estimated1RM, logRows, resolve, swapOptions, type PlanRow, type Profile } from "../lambda/training.ts";

const tz = "America/New_York";
const now = new Date("2026-10-17T13:00:00Z"); // Saturday 9:00 in New York
const at = (day: string, minutes = 7 * 60) => epoch(day, minutes, tz);
const profile: Profile = { age: 42, equipment: ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"], maxWeeklySets: 60, workoutTime: 7 * 60, trainingDays: [1, 3, 6] };
const row = (template: string, sets: number, extra: Partial<PlanRow> = {}, t = at("2026-10-17")): PlanRow => ({
  id: crypto.randomUUID().toUpperCase(), kind: "workout", at: t, slot: "Lower A", template,
  targets: [{ metric: "sets", value: sets, unit: "sets" }, { metric: "reps", value: 5, unit: "reps" }, { metric: "load_lb", value: 205, unit: "lb" }],
  note: "", main: template === "back-squat", pinned: false, ...extra,
});

function memory(accounts: Record<string, Account>, units: Record<string, Record<string, string>>): Store & { units: Store["units"] } {
  const extra = new Map<string, Record<string, any>>();
  return {
    async account(hash) { return accounts[hash]; },
    async units(uid) { return new Map(Object.entries(units[uid] ?? {})); },
    async write(uid, list) {
      units[uid] ??= {};
      for (const u of list) if (u.body === null) delete units[uid][u.key]; else units[uid][u.key] = u.body;
    },
    async get(uid, key) { return extra.get(`${uid}/${key}`); },
    async put(uid, key, item) { extra.set(`${uid}/${key}`, item); },
  };
}

const me: Account = { uid: "me", tz, agent: "claude" };
const data = () => ({
  me: {
    profile: encode(profile),
    "goal#2": encode({ kind: "training", metric: "pull-up.reps", target: 8, unit: "reps", status: "active" }),
    "goal#1": encode({ kind: "training", metric: "back-squat.1rm_lb", target: 250, unit: "lb", deadline: 1796000000, status: "active" }),
    "plan#2026-10-17": encode([row("back-squat", 5), row("romanian-deadlift", 3, { main: false })]),
    "log#2026-10-15": encode([
      { id: "A", kind: "workout", at: at("2026-10-15"), template: "back-squat", measurements: [{ metric: "reps", value: 5, unit: "reps" }, { metric: "load_lb", value: 200, unit: "lb" }, { metric: "rpe", value: 7, unit: "RPE" }], note: "Lower B" },
      { id: "B", kind: "workout", at: at("2026-10-15") + 1, measurements: [], note: "Knee a bit stiff" },
    ]),
  } as Record<string, string>,
});

describe("training", () => {
  it("finds exercises by slug, name and loose wording", () => {
    expect(resolve("back-squat").name).toBe("Back Squat");
    expect(resolve("bench press").slug).toBe("bench-press");
    expect(() => resolve("zorbing")).toThrow(/No exercise/);
  });

  it("works in the person's time zone", () => {
    expect(new Date(epoch("2026-10-17", 7 * 60, tz) * 1000).toISOString()).toBe("2026-10-17T11:00:00.000Z");
    expect(dayOf(new Date("2026-10-18T02:00:00Z"), tz)).toBe("2026-10-17");
  });

  it("estimates maxes as the app does (Brzycki, RPE ≤ 8)", () => {
    expect(estimated1RM(200, 5, 7)).toBeCloseTo(225, 0);
    expect(estimated1RM(200, 5, 9)).toBeUndefined();
  });

  it("logs the plan as done, set by set, with a summary row for the note", () => {
    const plan = [row("back-squat", 2)];
    const rows = logRows(plan, 1000, { as_planned: true, rpe: 8, note: "Felt strong" });
    expect(rows).toHaveLength(3);
    expect(rows[0]).toMatchObject({ template: "back-squat", plannedRef: plan[0].id, note: "Lower A" });
    expect(rows[0].measurements.map((m) => m.metric)).toEqual(["reps", "load_lb", "rpe"]);
    expect(rows[2].template).toBeUndefined();
    expect(rows[2].note).toBe("Felt strong");
  });

  it("holds a session to the plan rules", () => {
    const problems = checkDay([
      row("back-squat", 6, { targets: [{ metric: "sets", value: 6, unit: "sets" }, { metric: "load_lb", value: 202, unit: "lb" }, { metric: "rpe", value: 9, unit: "RPE" }] }),
      row("cable-crossover", 3, { main: false }),
    ], profile);
    expect(problems.join("\n")).toMatch(/6 sets/);
    expect(problems.join("\n")).toMatch(/RPE 9 is over 7/);
    expect(problems.join("\n")).toMatch(/202 lb isn't a 5 lb step/);
    expect(problems.join("\n")).toMatch(/which they don't have/);
  });

  it("offers swaps for the same movement with their equipment", () => {
    const options = swapOptions("bench-press", profile);
    expect(options.length).toBeGreaterThan(0);
    expect(options.every((e) => e.equipment.every((k) => profile.equipment!.includes(k)))).toBe(true);
  });
});

describe("mcp", () => {
  it("speaks MCP: initialize, tools, a tool call", async () => {
    const store = memory({}, data());
    const init = await answer({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } }, me, store);
    expect(init).toMatchObject({ result: { protocolVersion: "2025-06-18", capabilities: { tools: {} } } });
    const list: any = await answer({ jsonrpc: "2.0", id: 2, method: "tools/list" }, me, store);
    expect(list.result.tools.map((t: any) => t.name)).toContain("propose_session");
    const ctx: any = await answer({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "get_context", arguments: {} } }, me, store, now);
    const text = ctx.result.content[0].text as string;
    expect(text).toMatch(/Today is Saturday 2026-10-17/);
    expect(text).toMatch(/trains Tue, Thu, Sun/);
    expect(text).toMatch(/Back Squat 250 lb by .* estimated max now 225 lb/);
    expect(text).toMatch(/Note: Knee a bit stiff/);
    expect(text).toMatch(/Pull-up 8 reps — no sets logged yet/);
  });

  it("refuses an unknown link and answers notifications with 202", async () => {
    const token = "x".repeat(43);
    const store = memory({ [hashToken(token)]: me }, data());
    const event = (path: string, body: unknown) => ({ rawPath: path, body: JSON.stringify(body), isBase64Encoded: false, requestContext: { http: { method: "POST" } } }) as unknown as LambdaFunctionURLEvent;
    const call = async (path: string, body: unknown) => (await serve(event(path, body), store)) as { statusCode: number; body?: string };
    expect((await call(`/mcp/${"y".repeat(43)}`, {})).statusCode).toBe(401);
    expect((await call(`/mcp/${token}`, { jsonrpc: "2.0", method: "notifications/initialized" })).statusCode).toBe(202);
    const ok = await call(`/mcp/${token}`, { jsonrpc: "2.0", id: 1, method: "ping" });
    expect(JSON.parse(ok.body!)).toEqual({ jsonrpc: "2.0", id: 1, result: {} });
  });

  it("logs a session, and won't log over one without replace", async () => {
    const units = data();
    const store = memory({}, units);
    const out = await callTool("log_session", { as_planned: true, rpe: 7, note: "Knee fine today" }, me, store, now);
    expect(out).toMatch(/Back Squat: 205×5 @7/);
    expect(JSON.parse(units.me["log#2026-10-17"]).at(-1).note).toBe("Knee fine today");
    await expect(callTool("log_session", { as_planned: true }, me, store, now)).rejects.toThrow(/already logged/);
    expect(await callTool("add_note", { note: "Slept 5 h." }, me, store, now)).toMatch(/Knee fine today Slept 5 h\./);
  });

  it("proposes, applies and undoes a day's session", async () => {
    const units = data();
    const store = memory({}, units);
    const before = units.me["plan#2026-10-17"];
    const proposed = await callTool("propose_session", {
      title: "Upper · chest first", reason: "They asked for chest.",
      exercises: [{ exercise: "Bench Press", sets: 4, reps: 6, weight_lb: 170, rpe: 7 }, { exercise: "Dumbbell Bench Press", sets: 3, reps: 10, weight_lb_per_hand: 50 }],
    }, me, store, now);
    expect(proposed).toMatch(/− Back Squat: 5 × 5 @ 205 lb/);
    expect(proposed).toMatch(/\+ Bench Press: 4 × 6 @ 170 lb · RPE 7/);
    expect(proposed).toMatch(/passes the plan rules/);
    const id = proposed.match(/Proposal (\S+)/)![1];
    expect(units.me["plan#2026-10-17"]).toBe(before);
    await callTool("apply", { proposal_id: id }, me, store, now);
    const applied = JSON.parse(units.me["plan#2026-10-17"]) as PlanRow[];
    expect(applied.map((r) => r.template)).toEqual(["bench-press", "dumbbell-bench-press"]);
    expect(applied[0]).toMatchObject({ slot: "Upper · chest first", pinned: true, adjustedReason: "They asked for chest.", main: true });
    expect(applied[0].at).toBe(at("2026-10-17"));
    await callTool("undo", { date: "2026-10-17" }, me, store, now);
    expect(units.me["plan#2026-10-17"]).toBe(before);
    await expect(callTool("undo", { date: "2026-10-17" }, me, store, now)).rejects.toThrow(/Nothing to undo/);
  });

  it("won't apply a proposal that breaks the rules, or change a past or logged day", async () => {
    const store = memory({}, data());
    const bad = await callTool("propose_session", { title: "Too much", reason: "Test", exercises: [{ exercise: "back-squat", sets: 7, reps: 5 }] }, me, store, now);
    expect(bad).toMatch(/7 sets is more than the 5/);
    await expect(callTool("apply", { proposal_id: bad.match(/Proposal (\S+)/)![1] }, me, store, now)).rejects.toThrow(/breaks the plan rules/);
    await expect(callTool("propose_session", { date: "2026-10-15", title: "x", reason: "x", exercises: [{ exercise: "back-squat", sets: 3 }] }, me, store, now)).rejects.toThrow(/past/);
  });

  it("only ever touches the linked account", async () => {
    const units: Record<string, Record<string, string>> = { ...data(), other: { "plan#2026-10-17": encode([row("deadlift", 3)]) } };
    const store = memory({}, units);
    const ctx = await callTool("get_context", {}, me, store, now);
    expect(ctx).not.toMatch(/Deadlift \(deadlift\)/);
    await callTool("log_session", { as_planned: true }, me, store, now);
    expect(units.other["log#2026-10-17"]).toBeUndefined();
  });
});
