import type { LambdaFunctionURLEvent } from "aws-lambda";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { Comment } from "../../shared/triage.ts";
import { answer, callTool, CLIENT_TOOLS, hashToken, serve, type Account, type Store } from "../lambda/mcp.ts";
import { readProgram, readRecap, readSession, readWin } from "../lambda/sharePages.ts";
import { addDays, checkDay, dayOf, encode, epoch, estimated1RM, logRows, resolve, swapOptions, type PlanRow, type Profile } from "../lambda/training.ts";

const tz = "America/New_York";
const now = new Date("2026-10-17T13:00:00Z"); // Saturday 9:00 in New York
const at = (day: string, minutes = 7 * 60) => epoch(day, minutes, tz);
const profile: Profile = { age: 42, equipment: ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"], maxWeeklySets: 60, workoutTime: 7 * 60, trainingDays: [1, 3, 6] };
const row = (template: string, sets: number, extra: Partial<PlanRow> = {}, t = at("2026-10-17")): PlanRow => ({
  id: crypto.randomUUID().toUpperCase(), kind: "workout", at: t, slot: "Lower A", template,
  targets: [{ metric: "sets", value: sets, unit: "sets" }, { metric: "reps", value: 5, unit: "reps" }, { metric: "load_lb", value: 205, unit: "lb" }],
  note: "", main: template === "back-squat", pinned: false, ...extra,
});

type Link = { coach: string; client: string; name: string | null };

function memory(accounts: Record<string, Account>, units: Record<string, Record<string, string>>): Store & { units: Store["units"]; shared: Map<string, { uid: string; kind: string; payload: any }>; links: Link[]; invites: string[]; threads: (Comment & { owner: string })[]; paying: Set<string> } {
  const extra = new Map<string, Record<string, any>>();
  const shared = new Map<string, { uid: string; kind: string; payload: any }>();
  const links: Link[] = [], invites: string[] = [];
  const threads: (Comment & { owner: string })[] = [];
  const paying = new Set(["coach"]);
  return {
    shared,
    links,
    invites,
    threads,
    paying,
    async coachPlan(uid) { return paying.has(uid); },
    async comments(_, client) { return threads.filter((c) => c.owner === client); },
    async comment(coach, client, day, text) { threads.push({ owner: client, day, at: now.toISOString(), by: coach, byName: "Coach", text }); },
    async clients(coach) { return links.filter((l) => l.coach === coach).map((l) => ({ uid: l.client, name: l.name, since: "2026-10-01T00:00:00.000Z" })); },
    async coachOf(coach, client) { return links.some((l) => l.coach === coach && l.client === client); },
    async invite(coach) { invites.push(coach); return { code: "ABCDEFGHJK", url: "https://example.com/c/ABCDEFGHJK" }; },
    async share(uid, kind, payload) {
      const id = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
      shared.set(id, { uid, kind, payload: JSON.parse(JSON.stringify(payload)) });
      return { id, url: `https://example.com/${{ win: "w", recap: "r", program: "p", session: "s" }[kind]}/${id}` };
    },
    async unshare(uid, id) { return shared.get(id)?.uid === uid && shared.delete(id); },
    async setName(uid, name) { extra.set(`${uid}/name`, { name }); },
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
    const reads = ["list_clients", "roster_review", "get_context", "get_day", "find_exercises", "swap_options", "propose_session", "propose_week", "get_program", "get_progress", "get_week_review", "clear_day"];
    const writes = ["invite_client", "log_session", "add_note", "set_profile", "add_goal", "change_goal", "drop_goal", "apply", "undo", "set_program", "log_daily", "delete_log", "share", "stop_sharing", "create_exercise", "edit_exercise", "log_run"];
    expect(Object.keys(by).sort()).toEqual([...reads, ...writes].sort());
    for (const t of list.result.tools) {
      expect(t.title).toBeTruthy();
      // A share is a public page (FIT-169); everything else stays in the account.
      expect(t.annotations).toMatchObject({ title: t.title, openWorldHint: t.name === "share" });
    }
    for (const n of reads) expect(by[n].annotations.readOnlyHint).toBe(true);
    for (const n of writes) expect(by[n].annotations.readOnlyHint).toBe(false);
    // FIT-237: every hint said outright; destructive is whatever overwrites or removes.
    for (const t of list.result.tools) for (const h of ["readOnlyHint", "destructiveHint", "openWorldHint"]) expect(typeof t.annotations[h], `${t.name} ${h}`).toBe("boolean");
    expect(reads.filter((n) => by[n].annotations.destructiveHint)).toEqual([]);
    expect(writes.filter((n) => !by[n].annotations.destructiveHint).sort()).toEqual(["add_goal", "add_note", "create_exercise", "invite_client", "log_run", "share"]);
  });

  it("offers the coaching routines as prompts (FIT-175)", async () => {
    const store = memory({}, data());
    const init: any = await answer({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } }, me, store);
    expect(init.result.capabilities).toEqual({ tools: {}, prompts: {} });
    const list: any = await answer({ jsonrpc: "2.0", id: 2, method: "prompts/list" }, me, store);
    expect(list.result.prompts.map((p: any) => p.name)).toEqual(["set_me_up", "plan_next_week", "weekly_review", "log_today", "change_today", "bring_in_client"]);
    expect(list.result.prompts[3]).toEqual({ name: "log_today", title: "Log today", description: expect.any(String), arguments: [{ name: "what", description: expect.any(String) }] });
    const got: any = await answer({ jsonrpc: "2.0", id: 3, method: "prompts/get", params: { name: "log_today", arguments: { what: "squats felt heavy" } } }, me, store);
    expect(got.result.messages).toEqual([{ role: "user", content: { type: "text", text: expect.stringMatching(/They said: "squats felt heavy"[\s\S]*log_session/) } }]);
    const setup: any = await answer({ jsonrpc: "2.0", id: 4, method: "prompts/get", params: { name: "set_me_up" } }, me, store);
    expect(setup.result.messages[0].content.text).toMatch(/1RM[\s\S]*No program or weights without these/);
    // Every tool a prompt names exists.
    const names = new Set(((await answer({ jsonrpc: "2.0", id: 5, method: "tools/list" }, me, store)) as any).result.tools.map((t: any) => t.name));
    for (const p of list.result.prompts) {
      const text = ((await answer({ jsonrpc: "2.0", id: 6, method: "prompts/get", params: { name: p.name } }, me, store)) as any).result.messages[0].content.text as string;
      for (const used of text.match(/\b[a-z]+_[a-z_]+\b/g) ?? []) if (/^(get|set|log|propose|swap|find|add|delete|clear|share|stop|create|edit)_/.test(used) && !["starting_sets", "injured_areas", "as_planned"].includes(used)) expect(names).toContain(used);
    }
    expect(((await answer({ jsonrpc: "2.0", id: 7, method: "prompts/get", params: { name: "nope" } }, me, store)) as any).error.code).toBe(-32602);
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
    await callTool("set_profile", { starting_sets: [{ exercise: "Bench Press", weight_lb: 185, reps: 5 }] }, me, store, now);
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
    expect(await callTool("set_profile", { name: "Sam" }, fresh, store, now)).toMatch(/they're Sam on what they share/);
    expect(await store.get("new", "name")).toEqual({ name: "Sam" });
    const profile = JSON.parse(units.new.profile);
    expect(profile).toMatchObject({ age: 41, weightLb: 196, trainingDays: [0, 2, 5], daysPerWeek: 3, workoutTime: 390, avoidExercises: ["bench-press"],
      cookWindows: [], fineAreas: {}, travelWeeks: [], warmups: true, style: "powerbuilding", maxWeeklySets: 60 });
    expect(profile.starts).toEqual([{ exercise: "back-squat", measurements: [{ metric: "reps", value: 5, unit: "reps" }, { metric: "load_lb", value: 185, unit: "lb" }] }]);
    await expect(callTool("set_profile", { equipment: ["spaceship"] }, fresh, store, now)).rejects.toThrow(/Unknown equipment/);

    const added = await callTool("add_goal", { type: "lift_max", exercise: "Back Squat", target: 225, by: "2027-03-01" }, fresh, store, now);
    const id = added.match(/goal_id (\S+)\]/)![1];
    expect(JSON.parse(units.new[`goal#${id}`])).toMatchObject({ kind: "training", metric: "back-squat.1rm_lb", target: 225, unit: "lb", status: "active" });
    await callTool("change_goal", { goal_id: id, target: 235 }, fresh, store, now);
    await callTool("add_goal", { type: "body_weight", target: 185 }, fresh, store, now);
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
    await callTool("drop_goal", { goal_id: id }, fresh, store, now);
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

  it("gives progress and the week's review as the app derives them (FIT-167)", async () => {
    const fixture = JSON.parse(readFileSync(new URL("../../Tests/Fixtures/progress-units.json", import.meta.url), "utf8"));
    const units = { me: Object.fromEntries(Object.entries(fixture.units).map(([k, v]) => [k, encode(v)])) };
    const store = memory({}, units);
    const review = await callTool("get_week_review", { date: "2026-10-10" }, me, store, new Date("2026-10-10T16:00:00Z"));
    expect(review).toMatch(/^Week of Sunday 2026-10-04 to Saturday 2026-10-10, program week 4 of 16\.\n4 of 4 workouts\. 10K faster by 2:23\. 3 goals to check in on\. 3 things worth a look\./);
    expect(review).toMatch(/Numbers: 4 of 4 workouts, 18 working sets \(6 push, 6 pull\)\. Protein 143 g a day\. 2,400 kcal a day\. Sleep 6\.8 h a night\./);
    expect(review).toMatch(/- Back squat max: 225 → 242 of 250 lb, ahead of pace\./);
    expect(review).toMatch(/Check-in: well ahead; offer to raise the target to 355 lb \(12 weeks left\)\. Only if they agree: change_goal/);
    expect(review).toMatch(/- Knee came up in 3 notes\. Sep 21, Sep 30 and Oct 7\..*set_profile can add knee to injured_areas/);
    expect(review).toMatch(/- Went well: All 4 workouts done\./);
    expect(review).not.toMatch(/Romanian/);

    const p = await callTool("get_progress", {}, me, store, new Date("2026-10-17T16:00:00Z"));
    expect(p).toMatch(/Program week 5 of 16, ending 2027-01-02\./);
    expect(p).toMatch(/- Back squat max: target 250 lb by 2027-01-02 \[goal_id [^\]]+\]\n  Now 242 lb, from 205 at the start: 82% of the way\.\n  Ahead of pace\./);
    expect(p).toMatch(/  Best set: 215 lb × 5 reps on 2026-10-12\./);
    expect(p).toMatch(/Romanian Deadlift max: target 200 lb/);
    expect(p).toMatch(/Streak: 5 weeks in a row\./);
    expect(p).toMatch(/Wins, newest first \(share one by its id\):\n- 2026-10-12: personal best, Back squat max 242 lb \(was 236\)\./);
    expect(p).toMatch(/- 2026-10-10: 4 weeks in a row, every planned session done/);
  });

  it("gives a new goal its starting point, as onboarding does", async () => {
    const units: Record<string, Record<string, string>> = { new: { profile: encode({ ...profile, weightLb: 196, starts: [{ exercise: "back-squat", measurements: [{ metric: "reps", value: 5, unit: "reps" }, { metric: "load_lb", value: 185, unit: "lb" }] }] }) } };
    const store = memory({}, units);
    for (const goal of [{ type: "lift_max", exercise: "Back Squat", target: 250 }, { type: "body_weight", target: 185 }, { type: "reps", exercise: "Pull-up", target: 10 }]) {
      await callTool("add_goal", { ...goal }, fresh, store, now);
    }
    const goals = Object.entries(units.new).filter(([k]) => k.startsWith("goal#")).map(([, v]) => JSON.parse(v));
    expect(Object.fromEntries(goals.map((g) => [g.metric, g.baseline ?? null]))).toEqual({ "back-squat.1rm_lb": 208, weight_lb: 196, "pull-up.reps": null });
  });

  it("deletes what was logged by mistake, once they agree, and clears a day with undo (FIT-168)", async () => {
    const units = data();
    const store = memory({}, units);
    await callTool("log_daily", { date: "2026-10-15", weight_lb: 190, meals: [{ name: "Chicken bowl", kcal: 700 }, { name: "Chicken soup", kcal: 300 }] }, me, store, now);
    await expect(callTool("delete_log", { date: "2026-10-15", what: "workout" }, me, store, now)).rejects.toThrow(/confirm: true/);
    await expect(callTool("delete_log", { date: "2026-10-15", what: "meal", meal: "chicken", confirm: true }, me, store, now)).rejects.toThrow(/Which meal\? .*Chicken bowl; Chicken soup/);
    expect(await callTool("delete_log", { date: "2026-10-15", what: "meal", meal: "chicken soup", confirm: true }, me, store, now)).toMatch(/Deleted from 2026-10-15:\n  Meals: Chicken soup 300 kcal/);
    expect(await callTool("delete_log", { date: "2026-10-15", what: "workout", confirm: true }, me, store, now)).toMatch(/Back Squat: 200×5 @7/);
    const left = JSON.parse(units.me["log#2026-10-15"]);
    expect(left.map((r: any) => r.kind).sort()).toEqual(["bodyweight", "meal"]);
    await expect(callTool("delete_log", { date: "2026-10-15", what: "sleep", confirm: true }, me, store, now)).rejects.toThrow(/No sleep logged/);
    await callTool("delete_log", { date: "2026-10-15", what: "all", confirm: true }, me, store, now);
    expect(units.me["log#2026-10-15"]).toBeUndefined();

    const before = units.me["plan#2026-10-17"];
    const proposal = await callTool("clear_day", { reason: "Sick today." }, me, store, now);
    expect(proposal).toMatch(/Saturday 2026-10-17 — rest:\n  − Back Squat/);
    await callTool("apply", { proposal_id: proposal.match(/Proposal (\S+)/)![1] }, me, store, now);
    expect(units.me["plan#2026-10-17"]).toBeUndefined();
    await callTool("undo", {}, me, store, now);
    expect(units.me["plan#2026-10-17"]).toBe(before);
    await expect(callTool("clear_day", { date: "2026-10-18", reason: "x" }, me, store, now)).rejects.toThrow(/Nothing is planned/);
  });

  it("shares a win, a week's recap, a session and the program as the app saves them, and stops sharing (FIT-169)", async () => {
    const fixture = JSON.parse(readFileSync(new URL("../../Tests/Fixtures/progress-units.json", import.meta.url), "utf8"));
    const units = { me: Object.fromEntries(Object.entries(fixture.units).map(([k, v]) => [k, encode(v)])) };
    const store = memory({}, units);
    const at = new Date("2026-10-17T16:00:00Z");
    const id = (out: string) => out.match(/\/(\w)\/([0-9a-f]{12})/)!;

    const recap = await callTool("share", { kind: "recap", date: "2026-10-10" }, me, store, at);
    expect(recap).toMatch(/Shared Week 4 of 16: 4 of 4 sessions, 3 new best\(s\)\.\nhttps:\/\/example\.com\/r\//);
    const r = store.shared.get(id(recap)[2])!;
    expect(r.payload).toEqual({ week: 4, weeks: 16, phase: "base", sessions: { done: 4, planned: 4 }, bests: 3, showNumbers: true,
      lifts: [{ metric: "Back squat", from: 225, to: 242, unit: "lb" }, { metric: "Pull-ups", from: 7, to: 8, unit: "reps" }] });
    expect(readRecap(r.payload, "Sam")).toBeDefined();

    const progressOut = await callTool("get_progress", {}, me, store, at);
    const winId = progressOut.match(/\[win (pr:back-squat\.1rm_lb:\d+)\]/)![1];
    const hidden = await callTool("share", { kind: "win", win: winId, show_weights: false }, me, store, at);
    const w = store.shared.get(id(hidden)[2])!.payload;
    expect(w).toMatchObject({ kind: "pr", metric: "Back squat", unit: "%", previous: 100, value: 102.5, showNumbers: false, style: "dark", date: "2026-10-12" });
    expect(readWin(w, "Sam")).toBeDefined();
    await expect(callTool("share", { kind: "win", win: "nope" }, me, store, at)).rejects.toThrow(/No win with that id/);

    const session = await callTool("share", { kind: "session", date: "2026-10-19" }, me, store, at);
    const sp = store.shared.get(id(session)[2])!.payload;
    expect(sp).toMatchObject({ title: "Session", date: "2026-10-19", time: "7:00 AM", minutes: 20, exercises: [
      { exercise: "back-squat", name: "Back Squat", sets: 3, reps: 5 }, { exercise: "bench-press", name: "Bench Press", sets: 3, reps: 5 }] });
    expect(readSession(sp, "Sam")).toBeDefined();

    await expect(callTool("share", { kind: "program" }, me, store, at)).rejects.toThrow(/set_program with phases/);
    await expect(callTool("set_program", { weeks: 16 }, me, store, at)).rejects.toThrow(/Romanian Deadlift: a 1RM/);
    await callTool("set_profile", { starting_sets: [{ exercise: "Romanian Deadlift", weight_lb: 185, reps: 8 }] }, me, store, at);
    await callTool("set_program", { phases: [
      { phase: "base", focus: "Volume and technique.", main_lifts: ["back squat", "Bench Press"], main_reps: 8, accessory_reps: 12 },
      { phase: "build", focus: "Heavier", main_lifts: ["Back Squat", "Deadlift"], main_reps: 5, accessory_reps: 10 },
      { phase: "peak", focus: "Heavy singles", main_lifts: ["Back Squat"], main_reps: 3, accessory_reps: 8 },
    ] }, me, store, at);
    expect(JSON.parse(units.me.profile).brief).toEqual({ key: "", model: "claude", brief: { phases: [
      { phase: "base", focus: "Volume and technique", mainLifts: ["Back Squat", "Bench Press"], mainReps: 8, accessoryReps: 12 },
      { phase: "build", focus: "Heavier", mainLifts: ["Back Squat", "Deadlift"], mainReps: 5, accessoryReps: 10 },
      { phase: "peak", focus: "Heavy singles", mainLifts: ["Back Squat"], mainReps: 3, accessoryReps: 8 }] } });
    const program = await callTool("share", { kind: "program" }, me, store, at);
    const pp = store.shared.get(id(program)[2])!.payload;
    expect(pp).toMatchObject({ name: "Squat 250 by Jan 2", weeks: 16, days: 3, equipment: "Full gym", goals: ["Squat 250 by Jan 2", "10 pull-ups by Jan 2", "Get to 185 lb by Jan 2"],
            // Deloads (weeks 6 and 12) and the test week aren't a phase's hard weeks.
      phases: [{ phase: "base", from: 1, to: 5, mainReps: 8 }, { phase: "build", from: 7, to: 11 }, { phase: "peak", from: 13, to: 15 }] });
    expect(pp.sampleWeek[0]).toEqual({ day: "Monday", title: "Session", items: ["Back Squat 3 × 5", "Bench Press 3 × 5"] });
    expect(pp.sampleWeek).toHaveLength(3);
    expect(readProgram(pp, "Sam")).toBeDefined();

    expect(await callTool("stop_sharing", { link: recap.match(/https:\S+/)![0] }, me, store, at)).toMatch(/expired/);
    expect(store.shared.has(id(recap)[2])).toBe(false);
    await expect(callTool("stop_sharing", { link: id(recap)[2] }, me, store, at)).rejects.toThrow(/isn't one of their/);
  });

  it("makes an exercise of their own, finds and plans it, and edits only theirs (FIT-173)", async () => {
    const units = data();
    const store = memory({}, units);
    await expect(callTool("create_exercise", { name: "Back Squat", pattern: "squat", equipment: ["barbell"] }, me, store, now)).rejects.toThrow(/already in the catalog/);
    await expect(callTool("create_exercise", { name: "Landmine Press", pattern: "wiggle", equipment: [] }, me, store, now)).rejects.toThrow(/pattern is one of/);
    expect(await callTool("create_exercise", { name: "Landmine Press", pattern: "push", equipment: ["barbell"], muscles: ["anterior_deltoids"], cues: ["Ribs down"] }, me, store, now))
      .toMatch(/Added Landmine Press \(landmine-press\)/);
    expect(JSON.parse(units.me["template#landmine-press"])).toEqual({ kind: "exercise", name: "Landmine Press", attributes: [
      { key: "cues", values: ["Ribs down"] }, { key: "equipment", values: ["barbell"] }, { key: "movement_pattern", values: ["push"] }, { key: "muscles_primary", values: ["anterior_deltoids"] }] });
    await expect(callTool("create_exercise", { name: "landmine press", pattern: "push", equipment: [] }, me, store, now)).rejects.toThrow(/already one of theirs/);
    expect(await callTool("find_exercises", { query: "landmine" }, me, store, now)).toMatch(/Landmine Press \(landmine-press\) — push; barbell/);

    const week = await callTool("propose_session", { date: "2026-10-19", title: "Upper", reason: "x", exercises: [{ exercise: "Landmine Press", sets: 3, reps: 8, weight_lb: 45 }] }, me, store, now);
    expect(week).toMatch(/\+ Landmine Press: 3 × 8 @ 45 lb/);
    expect(week).toMatch(/passes the plan rules/);
    await callTool("apply", { proposal_id: week.match(/Proposal (\S+)/)![1] }, me, store, now);
    expect(JSON.parse(units.me["plan#2026-10-19"])[0].template).toBe("landmine-press");
    expect(await callTool("get_day", { date: "2026-10-19" }, me, store, now)).toMatch(/Landmine Press \(landmine-press\): 3 × 8 @ 45 lb/);

    await callTool("edit_exercise", { exercise: "landmine-press", name: "Landmine Shoulder Press" }, me, store, now);
    expect(JSON.parse(units.me["template#landmine-press"]).name).toBe("Landmine Shoulder Press");
    await expect(callTool("edit_exercise", { exercise: "Back Squat", name: "Squat" }, me, store, now)).rejects.toThrow(/Only their own/);
    // Another account doesn't see it.
    expect(await callTool("find_exercises", { query: "landmine" }, fresh, memory({}, {}), now)).not.toMatch(/landmine-press/);
  });

  it("won't lay out a program or weight a main lift without their maxes, and holds weights to them (FIT-174)", async () => {
    const units: Record<string, Record<string, string>> = {};
    const store = memory({}, units);
    await callTool("set_profile", { age: 41, weight_lb: 196, training_days: ["Mon", "Wed", "Sat"] }, fresh, store, now);
    await callTool("add_goal", { type: "lift_max", exercise: "Back Squat", target: 275, by: "2027-03-01" }, fresh, store, now);
    await callTool("add_goal", { type: "reps", exercise: "Pull-up", target: 12 }, fresh, store, now);
    expect(await callTool("get_context", {}, fresh, store, now)).toMatch(/NOT SET UP YET[\s\S]*Back Squat: a 1RM \(tested or estimated\) or a recent heavy set, weight × reps; Pull-up: most reps in a row now/);
    await expect(callTool("set_program", { weeks: 16 }, fresh, store, now)).rejects.toThrow(/Back Squat: a 1RM[\s\S]*Pull-up: most reps/);
    const blind = await callTool("propose_session", { date: "2026-10-19", title: "Lower", reason: "x", exercises: [
      { exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 185, rpe: 7 }, { exercise: "Romanian Deadlift", sets: 3, reps: 8, weight_lb: 135, rpe: 7 }] }, fresh, store, now);
    expect(blind).toMatch(/Back Squat is a main lift with a weight but no known max/);
    expect(blind).toMatch(/Check with them:[\s\S]*Romanian Deadlift at 135 lb is a guess/);

    // Their 1RM: 225. Brzycki gives 200 for 5, plus 5 lb.
    await callTool("set_profile", { starting_sets: [{ exercise: "Back Squat", weight_lb: 225, reps: 1 }, { exercise: "Pull-up", reps: 7 }] }, fresh, store, now);
    expect(await callTool("get_context", {}, fresh, store, now)).not.toMatch(/NOT SET UP YET/);
    await callTool("set_program", { weeks: 16 }, fresh, store, now);
    const heavy = await callTool("propose_session", { date: "2026-10-19", title: "Lower", reason: "x", exercises: [{ exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 215, rpe: 7 }] }, fresh, store, now);
    expect(heavy).toMatch(/Back Squat: 215 lb for 5 is over the most their starting point gives for 5 reps; at most 205 lb\./);
    const right = await callTool("propose_session", { date: "2026-10-19", title: "Lower", reason: "x", exercises: [{ exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 200, rpe: 7 }] }, fresh, store, now);
    expect(right).toMatch(/passes the plan rules/);
  });

  it("sets a race-time goal, logs runs and predicts the race (FIT-177)", async () => {
    const units: Record<string, Record<string, string>> = {};
    const store = memory({}, units);
    await callTool("set_profile", { age: 41, weight_lb: 196, training_days: ["Mon", "Wed", "Sat"] }, fresh, store, now);
    // "10K in 55:00 by April 2; last one was about 60 minutes."
    const added = await callTool("add_goal", { type: "timed_distance", distance: "10K", time: "55:00", by: "2027-04-02" }, fresh, store, now);
    expect(added).toMatch(/Added: 10K in 55:00 by 2027-04-02 .*Ask for their last race/);
    const id = added.match(/goal_id (\S+)\]/)![1];
    expect(JSON.parse(units.new[`goal#${id}`])).toMatchObject({ metric: "run_10000m.time_s", target: 3300, unit: "s", kind: "training" });
    expect(await callTool("get_context", {}, fresh, store, now)).toMatch(/10K: a recent race or hard run, its distance and time/);
    await expect(callTool("set_program", { weeks: 24 }, fresh, store, now)).rejects.toThrow(/10K: a recent race/);
    await callTool("set_profile", { starting_sets: [{ distance: "10K", time: "60:00" }] }, fresh, store, now);
    expect(JSON.parse(units.new.profile).starts).toEqual([{ exercise: "trail-running-walking", measurements: [{ metric: "distance_m", value: 10000, unit: "m" }, { metric: "duration_s", value: 3600, unit: "s" }] }]);
    await callTool("drop_goal", { goal_id: id }, fresh, store, now);
    const again = await callTool("add_goal", { type: "timed_distance", distance: "10k", time: "55:00", by: "2027-04-02" }, fresh, store, now);
    expect(again).toMatch(/Their runs put them at 1:00:00 now/);
    const goal = again.match(/goal_id (\S+)\]/)![1];
    expect(JSON.parse(units.new[`goal#${goal}`]).baseline).toBe(3600);
    await callTool("set_program", { weeks: 24 }, fresh, store, now);

    // An 8 km run in 44:00: Riegel puts a 10K at 44:00 × 1.25^1.06 = 55:44.
    const run = await callTool("log_run", { distance: "8 km", time: "44:00", hr_avg: 152, kind: "tempo", note: "felt strong" }, fresh, store, now);
    expect(run).toMatch(/Logged Saturday 2026-10-17: 5 mi in 44:00 \(8:51\/mi\), HR 152, tempo: felt strong\.\n10K: this predicts 55:44; best so far 55:44 \(goal 55:00\)\./);
    expect(JSON.parse(units.new["log#2026-10-17"])[0]).toMatchObject({ kind: "workout", template: "trail-running-walking", note: "tempo: felt strong",
      measurements: [{ metric: "distance_m", value: 8000 }, { metric: "duration_s", value: 2640 }, { metric: "hr_avg", value: 152, unit: "bpm" }] });
    expect(await callTool("get_day", {}, fresh, store, now)).toMatch(/Trail Running\/Walking: 5 mi in 44:00 \(8:51\/mi\), HR 152 · tempo: felt strong/);
    const p = await callTool("get_progress", {}, fresh, store, now);
    expect(p).toMatch(/- 10K time: target 55:00 by 2027-04-02 \[goal_id [^\]]+\]\n  Now 55:44 predicted from their runs, from 1:00:00 at the start: 85% of the way\./);
    expect(p).toMatch(/Best run: 5 mi in 44:00 \(8:51\/mi\) on 2026-10-17\./);
    expect(await callTool("get_context", {}, fresh, store, now)).toMatch(/- 10K in 55:00 by 2027-04-02 — their runs predict 55:44 now/);
    // A short easy jog doesn't count toward a 10K prediction.
    await callTool("log_run", { distance: "1 mi", time: "7:00", kind: "easy" }, fresh, store, now);
    expect(await callTool("get_progress", {}, fresh, store, now)).toMatch(/Now 55:44 predicted/);
    expect(await callTool("get_week_review", {}, fresh, store, now)).toMatch(/Ran 6 mi\./);
  });

  it("plans runs beside lifting, counts the week's miles, and flags a hard run next to heavy legs (FIT-178)", async () => {
    const units: Record<string, Record<string, string>> = {};
    const store = memory({}, units);
    await callTool("set_profile", { age: 38, weight_lb: 180, training_days: ["Mon", "Wed", "Fri"], starting_sets: [{ exercise: "Back Squat", weight_lb: 225, reps: 5 }, { exercise: "Bench Press", weight_lb: 185, reps: 5 }] }, fresh, store, now);
    const lift = (date: string, main: string, load: number) => ({ date, title: "Lift", exercises: [{ exercise: main, sets: 4, reps: 5, weight_lb: load, rpe: 7 }, { exercise: "Pull-up", sets: 3, reps: 6 }] });
    const run = (date: string, mi: number, kind: string) => ({ date, title: "Run", exercises: [{ exercise: "Trail Running/Walking", distance_mi: mi, run: kind }] });
    // Sunday easy, Mon squats, Tue easy, Wed bench, Thu tempo, Fri squats: the tempo is the day before squats.
    const week = await callTool("propose_week", { reason: "First week with running.", days: [
      // Planned in km still reads (FIT-186).
      { date: "2026-10-18", title: "Run", exercises: [{ exercise: "Trail Running/Walking", distance_km: 5, run: "easy" }] }, lift("2026-10-19", "Back Squat", 205), run("2026-10-20", 4, "easy"), lift("2026-10-21", "Bench Press", 165),
      run("2026-10-22", 5, "tempo"), lift("2026-10-23", "Back Squat", 205),
    ] }, fresh, store, now);
    expect(week).toMatch(/Sunday 2026-10-18 — Run:\n  \+ Trail Running\/Walking: 3\.1 mi · easy/);
    expect(week).toMatch(/2026-10-22: a hard run next to heavy legs \(squats or deadlifts on 2026-10-23\)/);
    expect(week).not.toMatch(/2026-10-20: a hard run/);
    expect(week.match(/a hard run next to heavy legs/g)).toHaveLength(1);
    expect(week).toMatch(/passes the plan rules/); // runs aren't held to the sets rules
    await callTool("apply", { proposal_id: week.match(/Proposal (\S+)/)![1] }, fresh, store, now);
    expect(JSON.parse(units.new["plan#2026-10-22"])[0]).toMatchObject({ template: "trail-running-walking", note: "tempo", main: false,
      targets: [{ metric: "sets", value: 1 }, { metric: "distance_m", value: 8047, unit: "m" }] });

    // A run logged beside the lifting stays when the lifting is logged over, and as-planned leaves runs to log_run.
    const later = new Date("2026-10-23T22:00:00Z");
    // FIT-184: what's left out went as planned. Thursday's 5 mi tempo has no time planned, so it asks for one.
    await expect(callTool("log_run", { date: "2026-10-22" }, fresh, store, later)).rejects.toThrow(/no time: ask them how long it took/);
    expect(await callTool("log_run", { date: "2026-10-22", time: "40:00" }, fresh, store, later)).toMatch(/Logged Thursday 2026-10-22: 5 mi in 40:00 \(8:00\/mi\), tempo\./);
    expect(JSON.parse(units.new["log#2026-10-22"])[0]).toMatchObject({ template: "trail-running-walking", plannedRef: JSON.parse(units.new["plan#2026-10-22"])[0].id, note: "tempo" });
    await expect(callTool("log_run", { date: "2026-10-21" }, fresh, store, later)).rejects.toThrow(/No run is planned 2026-10-21/);
    await callTool("log_run", { date: "2026-10-23", distance: "2 mi", time: "18:00", kind: "easy" }, fresh, store, later);
    await callTool("log_session", { date: "2026-10-23", as_planned: true, rpe: 7 }, fresh, store, later);
    await callTool("log_session", { date: "2026-10-23", as_planned: true, rpe: 8, replace: true }, fresh, store, later);
    expect(JSON.parse(units.new["log#2026-10-23"]).filter((r: any) => r.template === "trail-running-walking")).toHaveLength(1);

    // The next week's running against the last: 12.1 mi planned, plus the 2 mi run on Friday is 14.1; 16 is over 10% more.
    const more = await callTool("propose_week", { reason: "More running.", days: [run("2026-10-25", 6, "long"), run("2026-10-27", 5, "easy"), run("2026-10-29", 5, "easy")] }, fresh, store, later);
    expect(more).toMatch(/Week of 2026-10-25: 16 mi of running, more than 10% over the 14\.1 mi most of the 4 weeks before/);
    expect(await callTool("get_program", {}, fresh, store, later)).toBe("No program yet. set_program lays one out from this week to a target date.");
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
      injured_areas: ["knees"], never: ["Bench Press"], starting_sets: [{ exercise: "Back Squat", weight_lb: 185, reps: 5 }, { exercise: "Pull-up", reps: 6 }] }, a, store, now);
    await callTool("add_goal", { type: "lift_max", exercise: "Back Squat", target: 225, by: "2027-03-01" }, a, store, now);
    await callTool("add_goal", { type: "reps", exercise: "Pull-up", target: 10 }, a, store, now);
    await callTool("set_program", { weeks: 16, trip: { from: "2026-11-02", to: "2026-11-07" } }, a, store, now);
    await callTool("create_exercise", { name: "Landmine Press", pattern: "push", equipment: ["barbell"], muscles: ["anterior_deltoids"] }, a, store, now);
    const week = await callTool("propose_week", { reason: "First week.", days: [
      { date: "2026-10-17", title: "Lower A", exercises: [{ exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 175, rpe: 7 }, { exercise: "Plank", sets: 3, seconds: 45 }] },
      { date: "2026-10-19", title: "Upper A", exercises: [{ exercise: "Dumbbell Bench Press", sets: 3, reps: 10, weight_lb_per_hand: 50, superset: 1 }, { exercise: "Pull-up", sets: 3, reps: 5, superset: 1 },
        { exercise: "Landmine Press", sets: 3, reps: 8, weight_lb: 45 }] },
      { date: "2026-10-18", title: "Easy run", exercises: [{ exercise: "Trail Running/Walking", distance_mi: 3, minutes: 30, run: "easy" }] },
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

describe("FIT-214: no Pro in the MCP", () => {
  const week = { days: [{ date: "2026-11-24", exercises: [{ exercise: "Back Squat", sets: 3, reps: 5, weight_lb: 205 }] }], reason: "a week ahead" };
  const later = new Date(now.getTime() + 30 * 86_400_000); // well past the old 14-day trial

  it("lets anyone plan, with no trial and nothing to buy", async () => {
    const store = memory({}, data());
    await expect(callTool("propose_week", week, me, store, later)).resolves.toMatch(/Proposal/);
    await expect(callTool("propose_session", { date: "2026-11-25", title: "Lower", reason: "r", exercises: [{ exercise: "Back Squat", sets: 3, reps: 5, weight_lb: 205 }] }, me, store, later)).resolves.toMatch(/Proposal/);
    await callTool("set_profile", { starting_sets: [{ exercise: "Pull-up", reps: 5 }] }, me, store, later);
    await expect(callTool("set_program", { weeks: 8 }, me, store, later)).resolves.toMatch(/Saved/);
    expect(await callTool("get_context", {}, me, store, later)).not.toMatch(/Trial|Pro\b|subscribe/);
    await expect(callTool("subscribe", { interval: "year" }, me, store, now)).rejects.toThrow(/Unknown tool/);
    await expect(callTool("manage_subscription", {}, me, store, now)).rejects.toThrow(/Unknown tool/);
    const init: any = await answer({ jsonrpc: "2.0", id: 1, method: "initialize" }, me, store);
    expect(init.result.instructions).not.toMatch(/Pro\b|trial|subscribe/);
  });
});

describe("FIT-194: a coach acts on a linked client", () => {
  const coach: Account = { uid: "coach", tz, agent: "claude" };
  const setup = () => {
    const units = { ...data(), coach: { profile: encode(profile) } as Record<string, string>, other: { profile: encode({ ...profile, age: 30 }) } as Record<string, string> };
    const store = memory({}, units);
    store.links.push({ coach: "coach", client: "me", name: "Sarah Jones" }, { coach: "someone", client: "other", name: "Mike" });
    return { store, units };
  };
  const exercises = [{ exercise: "Back Squat", sets: 3, reps: 5, weight_lb: 205 }];
  // One call per client tool, each valid for Sarah's data.
  const calls: Record<string, Record<string, unknown>> = {
    get_context: {}, get_day: { date: "2026-10-15" }, add_note: { date: "2026-10-15", note: "Ice the knee." }, find_exercises: { query: "squat" }, swap_options: { exercise: "Back Squat" },
    create_exercise: { name: "Zercher Box Squat", pattern: "squat", equipment: ["barbell"] }, edit_exercise: { exercise: "Back Squat", name: "x" },
    clear_day: { date: "2026-10-17", reason: "rest" }, propose_session: { date: "2026-10-19", title: "Lower", reason: "r", exercises },
    propose_week: { reason: "r", days: [{ date: "2026-10-19", exercises }] }, apply: { proposal_id: "none" }, undo: { date: "2026-10-19" },
    get_program: {}, set_program: { weeks: 8 }, get_progress: {}, get_week_review: {}, set_profile: { session_minutes: 60 },
    add_goal: { type: "body_weight", target: 180 },
    change_goal: { goal_id: "X", target: 175 },
    drop_goal: { goal_id: "X" },
  };

  it("takes a client on exactly the planning and reading tools", async () => {
    const list: any = await answer({ jsonrpc: "2.0", id: 1, method: "tools/list" }, coach, setup().store);
    const taking = list.result.tools.filter((t: any) => t.inputSchema.properties.client).map((t: any) => t.name);
    expect(taking.sort()).toEqual(Object.keys(calls).sort());
    for (const own of ["log_session", "log_run", "log_daily", "delete_log", "share", "stop_sharing", "invite_client", "list_clients", "roster_review"]) {
      await expect(callTool(own, { client: "Sarah" }, coach, setup().store, now)).rejects.toThrow(/client's own|takes no client/);
    }
  });

  it("refuses every client tool for someone who isn't their client, and for a link that has ended", async () => {
    for (const [tool, args] of Object.entries(calls)) {
      const { store, units } = setup();
      const before = JSON.stringify(units);
      await expect(callTool(tool, { ...args, client: "Mike" }, coach, store, now), tool).rejects.toThrow(/No client called Mike/);
      await expect(callTool(tool, { ...args, client: "other" }, coach, store, now), tool).rejects.toThrow(/No client called other/);
      expect(JSON.stringify(units), tool).toBe(before);
      // The list said so, but the link is gone by the time it's checked.
      store.coachOf = async () => false;
      await expect(callTool(tool, { ...args, client: "Sarah" }, coach, store, now), tool).rejects.toThrow(/don't coach Sarah Jones any more/);
    }
  });

  it("reads and changes a linked client's data, not the coach's", async () => {
    const { store, units } = setup();
    expect(await callTool("get_context", { client: "sarah" }, coach, store, now)).toMatch(/^Client: Sarah Jones[\s\S]*Note: Knee a bit stiff/);
    expect(await callTool("get_day", { client: "Sarah Jones", date: "2026-10-15" }, coach, store, now)).toMatch(/Back Squat/);
    const proposal = await callTool("propose_session", { client: "me", ...calls.propose_session }, coach, store, now);
    const id = proposal.match(/Proposal (\S+)/)![1];
    // The proposal is Sarah's: it applies only to her.
    await expect(callTool("apply", { proposal_id: id }, coach, store, now)).rejects.toThrow(/pass client me/);
    expect(await callTool("apply", { proposal_id: id, client: "Sarah" }, coach, store, now)).toMatch(/Applied/);
    expect(units.me["plan#2026-10-19"]).toMatch(/back-squat/);
    expect(units.coach["plan#2026-10-19"]).toBeUndefined();
    expect(await callTool("undo", { client: "Sarah", date: "2026-10-19" }, coach, store, now)).toMatch(/Put back/);
    expect(units.me["plan#2026-10-19"]).toBeUndefined();
    await callTool("add_goal", { client: "Sarah", type: "body_weight", target: 180 }, coach, store, now);
    expect(Object.keys(units.me).filter((k) => k.startsWith("goal#"))).toHaveLength(3);
    await expect(callTool("set_profile", { client: "Sarah", name: "Sal" }, coach, store, now)).rejects.toThrow(/theirs to set/);
  });

  it("lists a coach's clients in their own context, and makes invite links", async () => {
    const { store } = setup();
    expect(await callTool("get_context", {}, coach, store, now)).toMatch(/They coach 1 client: Sarah Jones \[me\]/);
    expect(await callTool("get_context", {}, me, store, now)).not.toMatch(/They coach/);
    expect(await callTool("invite_client", {}, coach, store, now)).toMatch(/https:\/\/example\.com\/c\/ABCDEFGHJK[\s\S]*once, for 14 days/);
    expect(store.invites).toEqual(["coach"]);
  });

  it("asks which client when a name is ambiguous", async () => {
    const { store } = setup();
    store.links.push({ coach: "coach", client: "other2", name: "Sarah Lee" });
    await expect(callTool("get_day", { client: "Sarah" }, coach, store, now)).rejects.toThrow(/More than one client is called Sarah/);
    expect(await callTool("get_day", { client: "Sarah Lee" }, coach, store, now)).toMatch(/Nothing planned/);
  });
});

describe("FIT-196: the coach's roster", () => {
  const coach: Account = { uid: "coach", tz, agent: "claude" };
  const setup = () => {
    const units: Record<string, Record<string, string>> = { ...data(), coach: { profile: encode(profile) }, mike: { profile: encode({ ...profile, age: 30 }) } };
    const store = memory({}, units);
    store.links.push({ coach: "coach", client: "me", name: "Sarah Jones" }, { coach: "coach", client: "mike", name: "Mike" });
    return { store, units };
  };

  it("lists clients with the dashboard's flags, those who need the coach first", async () => {
    const { store } = setup();
    const text = await callTool("list_clients", {}, coach, store, now);
    expect(text).toMatch(/^2 clients, those who need them first:\n- Sarah Jones \[me\]: 1 of 1 sessions this week, last session Thursday 2026-10-15\. Flags: note: Thursday: “Knee a bit stiff”\.\n- Mike \[mike\]: 0 of 0 sessions this week, nothing logged yet\. No flags\./);
    // A reply answers the note.
    await callTool("add_note", { client: "Sarah", date: "2026-10-15", note: "Ice it and keep the squat at RPE 7." }, coach, store, now);
    expect(store.threads).toMatchObject([{ owner: "me", day: "2026-10-15", by: "coach", text: "Ice it and keep the squat at RPE 7." }]);
    expect(await callTool("list_clients", {}, coach, store, now)).toMatch(/Sarah Jones \[me\]: .* No flags\./);
    await expect(callTool("list_clients", {}, me, store, now)).rejects.toThrow(/Coaching needs the coach plan/);
    store.paying.add("me");
    expect(await callTool("list_clients", {}, me, store, now)).toMatch(/no clients yet[\s\S]*invite_client/);
  });

  it("leaves out a client whose link ended after listing", async () => {
    const { store } = setup();
    store.coachOf = async (_, client) => client !== "me";
    expect(await callTool("list_clients", {}, coach, store, now)).toMatch(/^1 client, those who need them first:\n- Mike/);
  });

  it("reviews the week across the roster", async () => {
    const { store } = setup();
    const text = await callTool("roster_review", {}, coach, store, now);
    expect(text).toMatch(/^Sarah Jones \[me\]: [\s\S]*\n  Week 2026-10-11 to 2026-10-17, no program: 1 of 2 workouts, \d+ working sets\.[\s\S]*Next week: nothing planned yet\.\n\nMike \[mike\]/);
  });

  it("copies one client's block to another: read a range, propose it for the other", async () => {
    const { store, units } = setup();
    const range = await callTool("get_day", { client: "Sarah", date: "2026-10-11", to: "2026-10-17" }, coach, store, now);
    expect(range).toMatch(/^Thursday 2026-10-15\nNothing planned\.\nLogged:[\s\S]*\n\nSaturday 2026-10-17\nPlanned — Lower A:\n  ★ Back Squat/);
    expect(range).not.toMatch(/Sunday 2026-10-11/);
    await expect(callTool("get_day", { date: "2026-10-01", to: "2026-11-01" }, coach, store, now)).rejects.toThrow(/At most 28 days/);
    const block = { client: "Mike", reason: "Sarah's block at Mike's numbers", days: [{ date: "2026-10-24", title: "Lower A", exercises: [{ exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 185 }] }] };
    // The loads are held to Mike's own max, so it's asked for first.
    expect(await callTool("propose_week", block, coach, store, now)).toMatch(/Back Squat is a main lift with a weight but no known max/);
    await callTool("set_profile", { client: "Mike", starting_sets: [{ exercise: "Back Squat", weight_lb: 245, reps: 1 }] }, coach, store, now);
    const week = await callTool("propose_week", block, coach, store, now);
    expect(week).toMatch(/passes the plan rules/);
    await callTool("apply", { client: "Mike", proposal_id: week.match(/Proposal (\S+)/)![1] }, coach, store, now);
    expect(units.mike["plan#2026-10-24"]).toMatch(/back-squat/);
    expect(units.me["plan#2026-10-24"]).toBeUndefined();
  });
});

describe("FIT-223: the client's daily check-in", () => {
  const coach: Account = { uid: "coach", tz, agent: "claude" };
  // As the app's Check In writes it (FIT-204): a weight row and a sleep row, the note on the sleep row. Mike has a goal
  // and a profile too, units that are objects, not rows.
  const setup = (note = "Knee is a bit sore") => {
    const units: Record<string, Record<string, string>> = { coach: { profile: encode(profile) }, mike: {
      profile: encode({ ...profile, age: 30 }),
      "goal#1": encode({ kind: "body", metric: "weight_lb", target: 180, unit: "lb", status: "active" }),
      "log#2026-10-16": encode([
        { id: "6F1C1B0E-4F7B-4D0A-9E59-0F1F4B7B2C11", kind: "bodyweight", at: at("2026-10-16", 6 * 60 + 50), measurements: [{ metric: "weight_lb", value: 183.5, unit: "lb" }], note: "" },
        { id: "0B9D2C61-2E57-4C55-8A0B-7C58F3A4D2E2", kind: "sleep", at: at("2026-10-16", 6 * 60 + 50), measurements: [{ metric: "sleep_h", value: 6, unit: "h" }], note },
      ]),
    } };
    const store = memory({}, units);
    store.links.push({ coach: "coach", client: "mike", name: "Mike" });
    return { store, units };
  };

  it("shows the coach a client's weight, sleep and note in get_day and get_context", async () => {
    const { store } = setup();
    expect(await callTool("get_day", { client: "Mike", date: "2026-10-16" }, coach, store, now)).toMatch(/No workout logged\.\nWeight 183\.5 lb\nSleep 6 h\nCheck-in note: Knee is a bit sore$/);
    expect(await callTool("get_context", { client: "Mike" }, coach, store, now)).toMatch(/Friday 2026-10-16: Weight 183\.5 lb\. Sleep 6 h\. Check-in note: Knee is a bit sore\./);
    // Only for a coach on the coach plan.
    store.paying.delete("coach");
    await expect(callTool("get_day", { client: "Mike", date: "2026-10-16" }, coach, store, now)).rejects.toThrow(/Coaching needs the coach plan/);
  });

  it("flags the note in the roster until the coach replies on that day", async () => {
    const { store } = setup();
    expect(await callTool("roster_review", {}, coach, store, now)).toMatch(/^Mike \[mike\]: .*Flags: pain: Friday: “Knee is a bit sore”\./);
    await callTool("add_note", { client: "Mike", date: "2026-10-16", note: "Keep the squats light today." }, coach, store, now);
    expect(await callTool("list_clients", {}, coach, store, now)).toMatch(/Mike \[mike\]: .* No flags\./);
  });

  it("logs a check-in note where the app puts it", async () => {
    const units = data();
    const store = memory({}, units);
    // A note on its own is a weight row with no weight, which no weigh-in counts.
    expect(await callTool("log_daily", { note: "Travelling, back Monday" }, me, store, now)).toMatch(/Check-in note: Travelling, back Monday/);
    expect(JSON.parse(units.me["log#2026-10-17"])).toMatchObject([{ kind: "bodyweight", measurements: [], note: "Travelling, back Monday" }]);
    // With sleep it rides on the sleep row, and replaces the day's note.
    await callTool("log_daily", { weight_lb: 186, sleep_hours: 7, note: "Slept well" }, me, store, now);
    const log = JSON.parse(units.me["log#2026-10-17"]);
    expect(log.map((r: any) => [r.kind, r.note])).toEqual([["bodyweight", ""], ["sleep", "Slept well"]]);
    expect(await callTool("get_day", {}, me, store, now)).toMatch(/Weight 186 lb\nSleep 7 h\nCheck-in note: Slept well/);
  });
});

describe("FIT-148: coaching needs the coach plan", () => {
  const coach: Account = { uid: "coach", tz, agent: "claude" };
  const setup = () => {
    const store = memory({}, { ...data(), coach: { profile: encode(profile) } });
    store.links.push({ coach: "coach", client: "me", name: "Sarah" });
    store.paying.clear();
    return store;
  };

  it("answers every coach tool with where to start the coach plan until it's on, then coaches as before", async () => {
    const store = setup();
    const calls: [string, Record<string, unknown>][] = [["list_clients", {}], ["roster_review", {}], ["invite_client", {}],
      ...[...CLIENT_TOOLS].map((t) => [t, { client: "Sarah", date: "2026-10-15" }] as [string, Record<string, unknown>])];
    for (const [tool, args] of calls) {
      await expect(callTool(tool, args, coach, store, now), tool).rejects.toThrow(/coach plan, which this account doesn't have[\s\S]*\/coaches\./);
    }
    expect(store.invites).toEqual([]);
    store.paying.add("coach");
    expect(await callTool("list_clients", {}, coach, store, now)).toMatch(/Sarah \[me\]/);
    expect(await callTool("get_day", { client: "Sarah", date: "2026-10-15" }, coach, store, now)).toMatch(/Back Squat/);
  });

  it("keeps their own training free, and says the clients are waiting on the plan", async () => {
    const store = setup();
    const own = await callTool("get_context", {}, coach, store, now);
    expect(own).toMatch(/They coach 1 client, but their coach plan has ended/);
    expect(own).not.toMatch(/Sarah/);
    await expect(callTool("propose_session", { date: "2026-10-19", title: "Lower", reason: "r", exercises: [{ exercise: "Plank", sets: 3, seconds: 45 }] }, coach, store, now)).resolves.toMatch(/Proposal/);
    // A client's own tools never ask for anything.
    await expect(callTool("get_context", {}, me, store, now)).resolves.not.toMatch(/coach plan/);
  });

  it("says who isn't a client before it says anything about the plan", async () => {
    await expect(callTool("get_day", { client: "Mike" }, coach, setup(), now)).rejects.toThrow(/No client called Mike/);
  });
});

describe("FIT-218: bringing a client's program in", () => {
  const coach: Account = { uid: "coach", tz, agent: "claude" };
  const setup = () => {
    const units: Record<string, Record<string, string>> = { coach: { profile: encode(profile) }, mike: { profile: encode({ ...profile, age: 30, maxWeeklySets: 80 }) } };
    const store = memory({}, units);
    store.links.push({ coach: "coach", client: "mike", name: "Mike" });
    return { store, units };
  };
  const call = (store: Store, tool: string, args: Record<string, unknown>) => callTool(tool, { client: "Mike", ...args }, coach, store, now);
  const maxes = (store: Store) => call(store, "set_profile", { equipment: ["barbell", "rack", "bench", "dumbbells", "pull_up_bar", "cable", "machine", "dip_station"], starting_sets: [
    { exercise: "Back Squat", weight_lb: 315, reps: 1 }, { exercise: "Bench Press", weight_lb: 225, reps: 1 },
    { exercise: "Deadlift", weight_lb: 405, reps: 1 }, { exercise: "OHP", weight_lb: 135, reps: 1 }] });
  const weekdays = (monday: string, weeks: number, offsets: number[]) =>
    Array.from({ length: weeks }, (_, w) => offsets.map((o) => addDays(monday, 7 * w + o))).flat();
  const apply = async (store: Store, proposal: string) => {
    expect(proposal).toMatch(/passes the plan rules/);
    return call(store, "apply", { proposal_id: proposal.match(/Proposal (\S+)/)![1] });
  };

  it("a 4-week Google Sheet block starting a later Monday, with supersets and tempo, in one call", async () => {
    const { store, units } = setup();
    await maxes(store);
    // The sheet has no deload and ends heavy: its 4 weeks, then the test week.
    expect(await call(store, "set_program", { start: "2026-10-26", weeks: 5, deload_every: 12 })).toMatch(/Saved/);
    const squat = [225, 240, 255, 275], days = weekdays("2026-10-26", 4, [0, 2, 4]);
    const sheet = days.map((date, i) => {
      const w = Math.floor(i / 3), day = i % 3;
      const exercises = day === 0 ? [
        { exercise: "Squat", sets: 4, reps: 5 - w % 2, weight_lb: squat[w], note: "3-1-1 tempo, rest 3 min" },
        { exercise: "RDL", sets: 3, reps: 8, weight_lb: 185, superset: 1 }, { exercise: "Hanging Leg Raise", sets: 3, reps: 10, superset: 1 },
      ] : day === 1 ? [
        { exercise: "Bench Press", sets: 4, reps: 6, weight_lb: 170 + 5 * w, note: "pause on the chest" },
        { exercise: "Barbell Row", sets: 4, reps: 8, weight_lb: 135, superset: 1 }, { exercise: "Face Pull", sets: 3, reps: 15, superset: 1 },
      ] : [
        { exercise: "Deadlift", sets: 3, reps: 5, weight_lb: 315 + 10 * w },
        { exercise: "OHP", sets: 4, reps: 6, weight_lb: 95, note: "rest 2 min" }, { exercise: "Lat Pulldown", sets: 3, reps: 10, weight_lb: 120 },
      ];
      return { date, title: ["Lower", "Upper", "Full"][day], exercises };
    });
    const proposal = await call(store, "propose_week", { reason: "Mike's 4-week block from his sheet", days: sheet });
    expect(proposal).toMatch(/Back Squat: 4 × 5 @ 225 lb — “3-1-1 tempo, rest 3 min”/);
    expect(proposal).toMatch(/Matched by name[\s\S]*"Barbell Row" is Bent Over Barbell Row[\s\S]*"OHP" is Standing Military Press/);
    expect(await apply(store, proposal)).toMatch(/Applied:[\s\S]*Friday 2026-11-20: Full/);
    expect(Object.keys(units.mike).filter((k) => k.startsWith("plan#"))).toHaveLength(12);
    const day = await call(store, "get_day", { date: "2026-10-28" });
    expect(day).toMatch(/Bench Press \(bench-press\): 4 × 6 @ 170 lb — “pause on the chest”\n  Bent Over Barbell Row \(bent-over-barbell-row\): 4 × 8 @ 135 lb \[superset 1\]\n  Face Pull \(face-pull\): 3 × 15 \[superset 1\]/);
  });

  it("a PDF from another app: RIR, rep ranges and a deload week, starting mid-week", async () => {
    const { store } = setup();
    await maxes(store);
    expect(await call(store, "set_program", { start: "2026-10-20", weeks: 4, deload_every: 3 })).toMatch(/Deload/);
    const days = weekdays("2026-10-19", 3, [1, 2, 4, 5]);
    const pdf = days.map((date, i) => {
      const deload = i >= 8, sets = deload ? 2 : 3, rpe = deload ? 6 : 7, upper = i % 2 === 0;
      const exercises = upper ? [
        { exercise: "Barbell Bench Press", sets, reps: 6, weight_lb: deload ? 135 : 175, rpe, note: "6–8 reps" },
        { exercise: "Seated Cable Row", sets, reps: 10, rpe, note: "10–12 reps" },
        { exercise: "Incline DB Press", sets, reps: 10, weight_lb_per_hand: 50, rpe },
        { exercise: "Tricep Pushdown", sets: 2, reps: 12, rpe },
      ] : [
        { exercise: "Leg Press", sets, reps: 10, rpe, note: "10–12 reps" }, { exercise: "Leg Curl", sets, reps: 12, rpe },
        { exercise: "Hip Thrust", sets, reps: 10, rpe }, { exercise: "Calf Raise", sets: 2, reps: 15, rpe },
      ];
      return { date, title: upper ? "Upper" : "Lower", exercises };
    });
    const proposal = await call(store, "propose_week", { reason: "Mike's program from his old app", days: pdf });
    expect(proposal).toMatch(/Tuesday 2026-11-03 \(week 3, Deload\)/);
    expect(proposal).toMatch(/- 2026-10-20, 2026-10-23, 2026-10-27, 2026-10-30, 2026-11-03, 2026-11-06: Incline Dumbbell Press at 50 lb each is a guess/);
    expect(proposal).toMatch(/"Leg Curl" is Lying Leg Curls/);
    expect(await apply(store, proposal)).toMatch(/Applied/);
  });

  it("a percentage block: weights from his maxes, a deload, 16 days in one call", async () => {
    const { store, units } = setup();
    await expect(call(store, "propose_week", { reason: "5/3/1", days: [{ date: "2026-11-02", exercises: [{ exercise: "Squat", sets: 1, reps: 5, percent_1rm: 65 }] }] }))
      .rejects.toThrow(/Back Squat at 65% needs their max/);
    await maxes(store);
    expect(await call(store, "set_program", { start: "2026-11-02", weeks: 5, deload_every: 4 })).toMatch(/Saved/);
    const scheme = [[65, 75, 85, 5], [70, 80, 90, 3], [75, 85, 95, 1], [40, 50, 60, 5]];
    const lifts = ["Squat", "Bench Press", "Deadlift", "OHP"];
    const days = weekdays("2026-11-02", 4, [0, 1, 3, 4]).map((date, i) => {
      const [a, b, c, reps] = scheme[Math.floor(i / 4)], lift = lifts[i % 4], deload = i >= 12;
      return { date, title: lift, exercises: [
        { exercise: lift, sets: 1, reps: reps === 1 ? 5 : reps, percent_1rm: a, main: true },
        { exercise: lift, sets: 1, reps: reps === 1 ? 3 : reps, percent_1rm: b, main: true },
        { exercise: lift, sets: 1, reps, percent_1rm: c, main: true, note: deload ? "" : "as many as you can" },
        { exercise: i % 2 ? "Chin-ups" : "Dips", sets: deload ? 2 : 4, reps: 8 },
      ] };
    });
    const proposal = await call(store, "propose_week", { reason: "Mike's 5/3/1 cycle", days });
    expect(proposal).toMatch(/Weights from percentages of their max:\n- Back Squat, max 315 lb: 40% 125, 50% 160, 60% 190, 65% 205, 70% 220, 75% 235, 80% 250, 85% 270, 90% 285, 95% 300 lb\n- Bench Press, max 225 lb: /);
    expect(proposal).toMatch(/Monday 2026-11-23 \(week 4, Deload\)/);
    await apply(store, proposal);
    expect(Object.keys(units.mike).filter((k) => k.startsWith("plan#"))).toHaveLength(16);
    expect(await call(store, "get_day", { date: "2026-11-16" })).toMatch(/Back Squat \(back-squat\): 1 × 1 @ 300 lb — “as many as you can”/);
    await expect(call(store, "propose_session", { date: "2026-11-30", title: "x", reason: "r", exercises: [{ exercise: "Squat", sets: 3, reps: 5, percent_1rm: 70, weight_lb: 220 }] }))
      .rejects.toThrow(/percent_1rm or a weight, not both/);
  });
});

describe("FIT-208: agent-readable tools and errors", () => {
  it("describes every tool, and defines who \"they\" are for a coach", async () => {
    const store = memory({}, data());
    const init: any = await answer({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }, me, store);
    expect(init.result.instructions).toMatch(/"they" is the person whose training it is: the caller, or the client a coach names with client/);
    // FIT-237: short, cross-tool, the key rules first, no persona (ChatGPT's review).
    expect(init.result.instructions.length).toBeLessThan(1000);
    expect(init.result.instructions.slice(0, 512)).toMatch(/get_context first[\s\S]*only through apply, once they agree/);
    expect(init.result.instructions).not.toMatch(/be their coach|link to pay|Checkout/);
    const list: any = await answer({ jsonrpc: "2.0", id: 2, method: "tools/list" }, me, store);
    for (const t of list.result.tools) expect(t.description.length, t.name).toBeGreaterThan(60);
  });

  it("says what to do next when it refuses", async () => {
    const store = memory({}, data());
    const bad = await callTool("propose_session", { date: "2026-10-19", title: "Upper", reason: "r", exercises: [{ exercise: "Bench Press", sets: 8, reps: 5 }] }, me, store, now);
    await expect(callTool("apply", { proposal_id: bad.match(/Proposal (\S+)/)![1] }, me, store, now))
      .rejects.toThrow(/fix these and propose again:\n- 2026-10-19: Bench Press: 8 sets is more than the 5 allowed/);
    await expect(callTool("undo", { date: "2026-10-20" }, me, store, now)).rejects.toThrow(/last 14 days, once\. To change it now, propose_session/);
    await expect(callTool("nope", {}, me, store, now)).rejects.toThrow(/Unknown tool nope\. The tools: get_context, get_day/);
  });
});

describe("the connector's documentation (FIT-236)", () => {
  it("lists every tool and prompt agents are given, grouped by what it does", async () => {
    const { docs, tools } = await import("../lambda/mcp.ts");
    const { prompts } = await import("../lambda/prompts.ts");
    const origin = "https://dev.example.com";
    const page: any = docs({ appName: "Barbrabell", origin, appId: "" }, origin);
    expect(page.statusCode).toBe(200);
    expect(page.body).toContain(`${origin}/mcp`);
    for (const t of tools) expect(page.body).toContain(`<code>${t.name}</code>`);
    for (const p of prompts) expect(page.body).toContain(`<code>${p.name}</code>`);
    expect(page.body).toMatch(/<code>delete_log<\/code> Delete from a day&#39;s log <span class="tag">Changes or deletes data<\/span>/);
    expect(page.body).toMatch(/<code>propose_week<\/code> Propose a week <span class="tag">Proposes a change<\/span><span class="tag">Coaches: for a client<\/span>/);
    expect(page.body).toContain('<a href="/privacy">privacy policy</a>');
  });
});
