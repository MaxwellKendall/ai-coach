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

  it("annotates every tool: reads, writes, the destructive ones, nothing open-world", async () => {
    const list: any = await answer({ jsonrpc: "2.0", id: 1, method: "tools/list" }, me, memory({}, data()));
    const by = Object.fromEntries(list.result.tools.map((t: any) => [t.name, t]));
    const reads = ["get_context", "get_day", "find_exercises", "swap_options", "propose_session", "propose_week", "get_program"];
    const writes = ["log_session", "add_note", "set_profile", "set_goal", "apply", "undo", "set_program", "log_daily"];
    expect(Object.keys(by).sort()).toEqual([...reads, ...writes].sort());
    for (const t of list.result.tools) {
      expect(t.title).toBeTruthy();
      expect(t.annotations).toMatchObject({ title: t.title, openWorldHint: false });
    }
    for (const n of reads) expect(by[n].annotations.readOnlyHint).toBe(true);
    for (const n of writes) expect(by[n].annotations.readOnlyHint).toBe(false);
    expect(writes.filter((n) => by[n].annotations.destructiveHint)).toEqual(["log_session", "set_goal"]);
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

describe("agent-first onboarding (FIT-150)", () => {
  const fresh: Account = { uid: "new", tz, agent: "claude" };

  it("sets up an empty account by conversation, then plans the first week", async () => {
    const units: Record<string, Record<string, string>> = {};
    const store = memory({}, units);
    expect(await callTool("get_context", {}, fresh, store, now)).toMatch(/NOT SET UP YET[\s\S]*profile: age and body weight[\s\S]*goals:/);

    await expect(callTool("set_profile", { training_days: ["Mon"] }, fresh, store, now)).rejects.toThrow(/age and body weight first/);
    await callTool("set_profile", { age: 41, weight_lb: 196 }, fresh, store, now);
    const saved = await callTool("set_profile", {
      training_days: ["Mon", "Wed", "Sat"], session_minutes: 50, workout_time: "06:30", equipment: ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"],
      injured_areas: ["knees"], never: ["Bench Press"], starting_sets: [{ exercise: "back squat", weight_lb: 185, reps: 5 }],
    }, fresh, store, now);
    expect(saved).toMatch(/trains Mon, Wed, Sat, 50 min at 06:30/);
    const profile = JSON.parse(units.new.profile);
    expect(profile).toMatchObject({ age: 41, weightLb: 196, trainingDays: [0, 2, 5], daysPerWeek: 3, workoutTime: 390, avoidExercises: ["bench-press"],
      cookWindows: [], fineAreas: {}, travelWeeks: [], warmups: true, style: "powerbuilding", maxWeeklySets: 60 });
    expect(profile.starts).toEqual([{ exercise: "back-squat", measurements: [{ metric: "reps", value: 5, unit: "reps" }, { metric: "load_lb", value: 185, unit: "lb" }] }]);
    await expect(callTool("set_profile", { equipment: ["spaceship"] }, fresh, store, now)).rejects.toThrow(/Unknown equipment/);

    const added = await callTool("set_goal", { action: "add", type: "lift_max", exercise: "Back Squat", target: 225, by: "2027-03-01" }, fresh, store, now);
    const id = added.match(/goal_id (\S+)\]/)![1];
    expect(JSON.parse(units.new[`goal#${id}`])).toMatchObject({ kind: "training", metric: "back-squat.1rm_lb", target: 225, unit: "lb", status: "active" });
    await callTool("set_goal", { action: "change", goal_id: id, target: 235 }, fresh, store, now);
    await callTool("set_goal", { action: "add", type: "body_weight", target: 185 }, fresh, store, now);
    const ctx = await callTool("get_context", {}, fresh, store, now);
    expect(ctx).not.toMatch(/NOT SET UP YET/);
    expect(ctx).toMatch(/Back Squat 235 lb by 2027-03-01/);
    expect(ctx).toMatch(/Body weight 185 lb/);

    const week = await callTool("propose_week", { reason: "First week: squat twice, easy on the knees.", days: [
      { date: "2026-10-19", title: "Lower A", exercises: [{ exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 175, rpe: 7 }, { exercise: "Plank", sets: 3, seconds: 45 }] },
      { date: "2026-10-21", title: "Upper A", exercises: [{ exercise: "Dumbbell Bench Press", sets: 3, reps: 10, weight_lb_per_hand: 50 }, { exercise: "pull-up", sets: 3, reps: 5 }] },
      { date: "2026-10-20", exercises: [] },
    ] }, fresh, store, now);
    expect(week).toMatch(/Monday 2026-10-19 — Lower A:\n  \+ Back Squat: 4 × 5 @ 175 lb · RPE 7/);
    expect(week).toMatch(/Tuesday 2026-10-20 — rest/);
    expect(week).toMatch(/Back Squat works quads, near an area they said is injured/);
    expect(week).toMatch(/passes the plan rules/);
    await callTool("apply", { proposal_id: week.match(/Proposal (\S+)/)![1] }, fresh, store, now);
    expect(JSON.parse(units.new["plan#2026-10-19"])[0]).toMatchObject({ template: "back-squat", slot: "Lower A", at: epoch("2026-10-19", 390, tz) });
    expect(units.new["plan#2026-10-21"]).toBeDefined();
    expect(units.new["plan#2026-10-20"]).toBeUndefined();
    await callTool("set_goal", { action: "drop", goal_id: id }, fresh, store, now);
    expect(JSON.parse(units.new[`goal#${id}`]).status).toBe("abandoned");
  });

  it("lays out a program as the app does, and holds each week to its kind (FIT-165)", async () => {
    const units: Record<string, Record<string, string>> = { new: { profile: encode({ ...profile, sessionMinutes: 45, trainingDays: [0, 2, 5] }) } };
    const store = memory({}, units);
    expect(await callTool("get_program", {}, fresh, store, now)).toMatch(/No program yet/);
    await expect(callTool("set_program", {}, fresh, store, now)).rejects.toThrow(/How long/);

    // Saturday 2026-10-17: the program starts this week's Sunday and ends 16 weeks later on a Saturday.
    const set = await callTool("set_program", { weeks: 16, trip: { from: "2026-11-02", to: "2026-11-07" } }, fresh, store, now);
    const p = JSON.parse(units.new.profile);
    expect(dayOf(new Date(p.programStart * 1000), tz)).toBe("2026-10-11");
    expect(dayOf(new Date(p.targetDate * 1000), tz)).toBe("2027-01-30");
    expect(p.travelWeeks).toEqual([3]);
    expect(set).toMatch(/16 weeks, Sunday 2026-10-11 to Saturday 2027-01-30\. Deload every 5 weeks \(their age's default\)/);
    expect(set).toMatch(/This is week 1\./);
    // At 42 a deload every 5 weeks; the trip in week 4 takes the first one.
    expect(set).toMatch(/Week 4 · 2026-11-01 · Deload · travel: Dumbbells and bodyweight only\./);
    expect(set).toMatch(/Week 9 · 2026-12-06 · Deload:/);
    expect(set).toMatch(/Week 16 · 2027-01-24 · Test week:/);
    expect(set).toMatch(/Week 1 · 2026-10-11 \(this week\) · Base: .* Aim about 42 working sets\. Not planned yet/);
    expect(await callTool("get_context", {}, fresh, store, now)).toMatch(/Program: week 1 of 16, Base\./);

    const heavy = await callTool("propose_week", { reason: "Deload", days: [{ date: "2026-12-07", title: "Lower", exercises: [
      { exercise: "Back Squat", sets: 5, reps: 5, rpe: 8, main: true }, { exercise: "Romanian Deadlift", sets: 4, reps: 8 }, { exercise: "Walking Lunge", sets: 4, reps: 10 },
    ] }] }, fresh, store, now);
    expect(heavy).toMatch(/Monday 2026-12-07 \(week 9, Deload\)/);
    expect(heavy).toMatch(/Back Squat: RPE 8 is over 6, the cap in a deload week/);
    expect(heavy).toMatch(/13 sets in a deload week's session; a light week holds at most 12/);
    await expect(callTool("apply", { proposal_id: heavy.match(/Proposal (\S+)/)![1] }, fresh, store, now)).rejects.toThrow(/breaks the plan rules/);
    const light = await callTool("propose_week", { reason: "Deload", days: [{ date: "2026-12-07", title: "Lower", exercises: [
      { exercise: "Back Squat", sets: 3, reps: 5, rpe: 6, main: true }, { exercise: "Romanian Deadlift", sets: 1, reps: 8, rpe: 6 },
    ] }] }, fresh, store, now);
    expect(light).toMatch(/passes the plan rules/);
    const away = await callTool("propose_week", { reason: "Trip", days: [{ date: "2026-11-02", title: "Hotel", exercises: [{ exercise: "Back Squat", sets: 3, reps: 5, rpe: 6 }] }] }, fresh, store, now);
    expect(away).toMatch(/Back Squat needs barbell and rack; a travel week is dumbbells and bodyweight only/);

    // Longer, a set deload rhythm, then the trip cleared.
    await callTool("set_program", { by: "2027-03-01", deload_every: 4, clear_trips: true }, fresh, store, now);
    const later = JSON.parse(units.new.profile);
    expect([dayOf(new Date(later.targetDate * 1000), tz), later.deloadEveryWeeks, later.travelWeeks]).toEqual(["2027-03-06", 4, []]);
  });

  it("logs weight, sleep and meals beside the workout, and body-weight goals follow the weigh-ins (FIT-166)", async () => {
    const units = data();
    units.me["goal#3"] = encode({ kind: "body", metric: "weight_lb", target: 180, unit: "lb", status: "active" });
    units.me["log#2026-09-15"] = encode([{ id: "W", kind: "bodyweight", at: at("2026-09-15"), measurements: [{ metric: "weight_lb", value: 191, unit: "lb" }], note: "" }]);
    const store = memory({}, units);
    await expect(callTool("log_daily", {}, me, store, now)).rejects.toThrow(/Nothing to log/);

    // "I weighed 186 this morning and slept 6 hours."
    const out = await callTool("log_daily", { weight_lb: 186, sleep_hours: 6, time: "06:45" }, me, store, now);
    expect(out).toMatch(/Weight 186 lb\n  Sleep 6 h/);
    await callTool("log_daily", { meals: [{ name: "Eggs and toast", kcal: 450, protein_g: 28 }, { name: "Chicken bowl", kcal: 700, protein_g: 52, time: "12:30" }] }, me, store, now);
    await callTool("log_daily", { weight_lb: 185.6 }, me, store, now); // a second weigh-in replaces the first
    const log = JSON.parse(units.me["log#2026-10-17"]);
    expect(log.filter((r: any) => r.kind === "bodyweight")).toMatchObject([{ measurements: [{ metric: "weight_lb", value: 185.6, unit: "lb" }] }]);
    expect(log.find((r: any) => r.kind === "sleep")).toMatchObject({ at: at("2026-10-17", 405), measurements: [{ metric: "sleep_h", value: 6, unit: "h" }] });
    expect(log.filter((r: any) => r.kind === "meal").map((r: any) => r.note)).toEqual(["Eggs and toast", "Chicken bowl"]);

    const day = await callTool("get_day", {}, me, store, now);
    expect(day).toMatch(/Weight 185.6 lb\nSleep 6 h\nMeals: Eggs and toast 450 kcal 28 g protein; Chicken bowl 700 kcal 52 g protein — 1150 kcal, 80 g protein in all/);
    const ctx = await callTool("get_context", {}, me, store, now);
    expect(ctx).toMatch(/Body weight 180 lb — weighed 185.6 lb on 2026-10-17 \(-5.4 in 4 weeks\)/);
    expect(ctx).toMatch(/Weight, sleep and meals, the last 7 days:\nSaturday 2026-10-17: Weight 185.6 lb\. Sleep 6 h\. Meals:/);

    // Logging the workout after keeps them.
    await callTool("log_session", { as_planned: true }, me, store, now);
    expect(JSON.parse(units.me["log#2026-10-17"]).filter((r: any) => r.kind !== "workout")).toHaveLength(4);
    await expect(callTool("log_daily", { date: "2026-10-18", weight_lb: 185 }, me, store, now)).rejects.toThrow(/hasn't happened/);
  });

  it("holds a proposed week to their weekly ceiling", async () => {
    const units: Record<string, Record<string, string>> = { new: { profile: encode({ ...profile, maxWeeklySets: 10 }) } };
    const store = memory({}, units);
    const big = (date: string) => ({ date, title: "Big", exercises: [{ exercise: "back-squat", sets: 5, reps: 5 }, { exercise: "deadlift", sets: 4, reps: 5 }] });
    const out = await callTool("propose_week", { reason: "x", days: [big("2026-10-19"), big("2026-10-21")] }, fresh, store, now);
    expect(out).toMatch(/Week of 2026-10-18: 18 working sets, over their ceiling of 10/);
  });
});

describe("what the app reads (FIT-150)", () => {
  // Tests/Fixtures/agent-setup-units.json: an account set up only through the tools. AgentSetupTests (Swift) applies it
  // with SyncUnits.apply, as a phone signing in would. UPDATE_FIXTURES=1 writes it again.
  it("matches the fixture the app decodes", async () => {
    const units: Record<string, Record<string, string>> = {};
    const store = memory({}, units);
    const a: Account = { uid: "a", tz, agent: "claude" };
    await callTool("set_profile", { age: 41, weight_lb: 196, training_days: ["Mon", "Wed", "Sat"], workout_time: "06:30", equipment: ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"],
      injured_areas: ["knees"], never: ["Bench Press"], starting_sets: [{ exercise: "Back Squat", weight_lb: 185, reps: 5 }] }, a, store, now);
    await callTool("set_goal", { action: "add", type: "lift_max", exercise: "Back Squat", target: 225, by: "2027-03-01" }, a, store, now);
    await callTool("set_goal", { action: "add", type: "reps", exercise: "Pull-up", target: 10 }, a, store, now);
    await callTool("set_program", { weeks: 16, trip: { from: "2026-11-02", to: "2026-11-07" } }, a, store, now);
    const week = await callTool("propose_week", { reason: "First week.", days: [
      { date: "2026-10-17", title: "Lower A", exercises: [{ exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 175, rpe: 7 }, { exercise: "Plank", sets: 3, seconds: 45 }] },
      { date: "2026-10-19", title: "Upper A", exercises: [{ exercise: "Dumbbell Bench Press", sets: 3, reps: 10, weight_lb_per_hand: 50, superset: 1 }, { exercise: "Pull-up", sets: 3, reps: 5, superset: 1 }] },
    ] }, a, store, now);
    await callTool("apply", { proposal_id: week.match(/Proposal (\S+)/)![1] }, a, store, now);
    await callTool("log_session", { as_planned: true, rpe: 7, effort: 6, note: "Knees fine." }, a, store, now);
    await callTool("log_daily", { weight_lb: 195.4, sleep_hours: 7.5, sleep_quality: 4, time: "06:00", meals: [{ name: "Oats and whey", kcal: 520, protein_g: 40, time: "07:30" }] }, a, store, now);
    // Ids are random: the fixture keeps the shape, numbered in order.
    let n = 0;
    const ids = new Map<string, string>();
    const stable = (body: string) => body.replace(/[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/g, (id) => {
      if (!ids.has(id)) ids.set(id, `00000000-0000-4000-8000-${String(++n).padStart(12, "0")}`);
      return ids.get(id)!;
    });
    // Numbered in the order the tools wrote them (random keys would sort differently each run).
    const written = Object.keys(units.a).map((k) => [stable(k), JSON.parse(stable(units.a[k]))] as const);
    const got = Object.fromEntries(written.sort(([x], [y]) => x.localeCompare(y)));
    const file = new URL("../../Tests/Fixtures/agent-setup-units.json", import.meta.url);
    const { readFileSync, writeFileSync } = await import("node:fs");
    if (process.env.UPDATE_FIXTURES) writeFileSync(file, JSON.stringify(got, null, 2) + "\n");
    expect(got).toEqual(JSON.parse(readFileSync(file, "utf8")));
  });
});
