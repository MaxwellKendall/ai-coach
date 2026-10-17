import { createHash, randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { oauth, unauthorized, type AuthStore, type Config } from "./oauth.ts";
import { push } from "./sync.ts";
import {
  addDays, AREAS, dailyRows, describeDaily, weighIns, type DailyInput, bestBy, bySlug, cautions, checkDay, dayOf, EQUIPMENT, goalBody, mergeProfile, missing, STYLES, WEEKDAYS, describeLog, describeSession, diff, encode, epoch, find, goalsOf, logOf, loggedSets, logRows,
  nameOf, planOf, profileOf, resolve, sessionRows, swapOptions, weekday, weeklySets, type ExerciseInput, type GoalInput, type PlanRow,
  type ProfileInput, type SetInput, type Units,
} from "./training.ts";
import * as progress from "./progress.ts";
import { checkProgramDay, deloadEvery, isLight, programOf, programWeekOf, sundayOf, title, travelWeeks, weekCount, weekIndex, weeklyTarget, weekStart, why } from "./program.ts";

/**
 * FIT-149: the training as tools any agent calls on its own tokens (direction doc, 2026-10-17: agent-first, no hosted AI).
 * MCP over streamable HTTP, stateless: each POST is one JSON-RPC message answered with JSON. The agent reads and
 * writes the account's FIT-126 sync units, so the phone shows its changes on its next sync. Plan changes are proposed,
 * checked by the plan rules, then applied, with Undo.
 *
 * Auth: an OAuth bearer token (FIT-151, oauth.ts), or a long random token in the URL (/mcp/TOKEN, FIT-149). Either names
 * one account and its time zone; only its hash is stored (MCPTOKEN#sha256).
 */

export type Account = { uid: string; tz: string; agent: string };
export interface Store {
  account(tokenHash: string): Promise<Account | undefined>;
  units(uid: string): Promise<Units>;
  write(uid: string, units: { key: string; body: string | null }[], source: string): Promise<void>;
  get(uid: string, key: string): Promise<Record<string, any> | undefined>;
  put(uid: string, key: string, item: Record<string, any>, days: number): Promise<void>;
}

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;

export const dynamoStore: Store = {
  async account(hash) {
    const out = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `MCPTOKEN#${hash}`, SK: "MCPTOKEN" } }));
    const item = live(out.Item);
    return item && !item.revoked ? { uid: item.uid, tz: item.tz, agent: item.agent ?? "agent" } : undefined;
  },
  async units(uid) {
    const units: Units = new Map();
    let start: Record<string, any> | undefined;
    do {
      const out = await db.send(new QueryCommand({
        TableName: TABLE(), KeyConditionExpression: "PK = :p AND begins_with(SK, :s)",
        ExpressionAttributeValues: { ":p": `USER#${uid}`, ":s": "SYNC#" }, ExclusiveStartKey: start,
      }));
      for (const item of out.Items ?? []) if (!item.deleted && item.body) units.set(item.key, item.body);
      start = out.LastEvaluatedKey;
    } while (start);
    return units;
  },
  async write(uid, units, source) {
    const now = new Date().toISOString();
    await push(uid, units.map((u) => (u.body === null ? { key: u.key, updatedAt: now, deleted: true } : { key: u.key, updatedAt: now, deleted: false, body: u.body })), source);
  },
  async get(uid, key) {
    return (await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${uid}`, SK: `MCP#${key}` } }))).Item;
  },
  async put(uid, key, item, days) {
    await db.send(new PutCommand({
      TableName: TABLE(), Item: { PK: `USER#${uid}`, SK: `MCP#${key}`, ...item, expiresAt: Math.floor(Date.now() / 1000) + days * 86_400 },
    }));
  },
};

/** FIT-151: what's past its expiry reads as gone, since DynamoDB's TTL deletes it only eventually. */
const live = (item?: Record<string, any>) => (item && !(item.expiresAt && item.expiresAt * 1000 < Date.now()) ? item : undefined);

export const authStore: AuthStore = {
  async put(key, item, seconds) {
    const expiry = seconds ? { expiresAt: Math.floor(Date.now() / 1000) + seconds } : {};
    await db.send(new PutCommand({ TableName: TABLE(), Item: { PK: key, SK: key.split("#")[0], ...item, ...expiry } }));
  },
  async get(key) {
    return live((await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: key, SK: key.split("#")[0] } }))).Item);
  },
  async take(key) {
    return live((await db.send(new DeleteCommand({ TableName: TABLE(), Key: { PK: key, SK: key.split("#")[0] }, ReturnValues: "ALL_OLD" }))).Attributes);
  },
};

export const hashToken = (token: string) => createHash("sha256").update(token).digest("hex");

// ---- Tools ----

const DATE = { type: "string", description: "A day, YYYY-MM-DD. Defaults to today in the person's time zone." };
const EXERCISE = { type: "string", description: "An exercise by catalog name or slug, e.g. \"Back Squat\" or \"back-squat\"." };
const SESSION = {
  type: "array", minItems: 1, description: "The session's exercises, in order.", items: { type: "object", properties: {
    exercise: EXERCISE, sets: { type: "integer", minimum: 1, maximum: 10 }, reps: { type: "integer" }, seconds: { type: "integer" },
    weight_lb: { type: "number" }, weight_lb_per_hand: { type: "number" }, rpe: { type: "number" },
    main: { type: "boolean", description: "A main lift (defaults to the catalog's goal lifts)." },
    superset: { type: "integer", description: "Exercises sharing a number are done together in rounds." },
  }, required: ["exercise", "sets"] },
};

// MCP tool annotations (FIT-156). Clients take a missing destructiveHint as true, so writes say it.
// The propose tools only store a proposal, so they count as reads. Nothing reaches outside the account.
const READ = { readOnlyHint: true, openWorldHint: false };
const write = (destructive: boolean, idempotent: boolean) =>
  ({ readOnlyHint: false, destructiveHint: destructive, idempotentHint: idempotent, openWorldHint: false });

export const tools = [
  {
    name: "get_context",
    title: "Get training context",
    annotations: { title: "Get training context", ...READ },
    description: "Start here. The person's goals with deadlines and where they stand, their profile (age, equipment, injuries, never list, schedule), the planned sessions from today on, and recent logged sessions with RPE and notes, plus estimated maxes for the lifts they train. Read it before suggesting, logging or changing anything.",
    inputSchema: { type: "object", properties: {
      days_back: { type: "integer", minimum: 1, maximum: 120, description: "How many past days of logs to include (default 21)." },
      days_ahead: { type: "integer", minimum: 0, maximum: 28, description: "How many days of plan to include from today (default 7)." },
    } },
  },
  {
    name: "get_day",
    title: "Get a day",
    annotations: { title: "Get a day", ...READ },
    description: "One day in full: the planned session (each exercise with sets, reps or seconds, load and RPE) and what was logged.",
    inputSchema: { type: "object", properties: { date: DATE } },
  },
  {
    name: "find_exercises",
    title: "Find exercises",
    annotations: { title: "Find exercises", ...READ },
    description: "Search the exercise catalog (700 exercises) by name words, movement pattern (squat, hinge, horizontal_push, vertical_pull, lunge, carry, core…) or muscle. Only exercises their equipment allows and not on their never list.",
    inputSchema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
  },
  {
    name: "swap_options",
    title: "Swap options",
    annotations: { title: "Swap options", ...READ },
    description: "Alternatives for an exercise: the same movement with their equipment, best first. Use it when they want to replace one exercise.",
    inputSchema: { type: "object", properties: { exercise: EXERCISE }, required: ["exercise"] },
  },
  {
    name: "log_session",
    title: "Log a session",
    annotations: { title: "Log a session", ...write(true, false) },
    description: "Log a workout they did: each set with load, reps (or seconds) and RPE, and a note on how it went (soreness, sleep, how it felt). as_planned logs the day's planned sets; add sets to record what differed. A day already logged needs replace: true. Confirm the numbers with them first when unsure.",
    inputSchema: { type: "object", properties: {
      date: DATE,
      as_planned: { type: "boolean", description: "Log every planned set as planned." },
      sets: { type: "array", description: "One entry per set, in the order done.", items: { type: "object", properties: {
        exercise: EXERCISE, weight_lb: { type: "number" }, weight_lb_per_hand: { type: "number" }, reps: { type: "integer" },
        seconds: { type: "integer" }, rpe: { type: "number", minimum: 1, maximum: 10 },
      }, required: ["exercise"] } },
      rpe: { type: "number", minimum: 1, maximum: 10, description: "RPE for sets that don't give their own." },
      effort: { type: "number", minimum: 1, maximum: 10, description: "How hard the whole session was, 1–10." },
      note: { type: "string", description: "Their words about the session: pain, sleep, energy, what felt easy." },
      replace: { type: "boolean", description: "Replace what's already logged that day." },
    } },
  },
  {
    name: "add_note",
    title: "Add a note",
    annotations: { title: "Add a note", ...write(false, false) },
    description: "Add context to a day already logged, in their words (\"left knee sore on the last set\", \"slept 5 hours\").",
    inputSchema: { type: "object", properties: { date: DATE, note: { type: "string" } }, required: ["note"] },
  },
  {
    name: "log_daily",
    title: "Log weight, sleep or meals",
    annotations: { title: "Log weight, sleep or meals", ...write(false, false) },
    description: "Log what they tell you about the rest of the day: a weigh-in, last night's sleep (hours, and quality 1–5 if they say), or meals with kcal and protein (estimate from what they ate when they don't know, and say it's an estimate). Several in one call. A weigh-in or sleep replaces that day's own; meals add up. Body-weight goals follow the weigh-ins.",
    inputSchema: { type: "object", properties: {
      date: DATE,
      weight_lb: { type: "number", description: "Body weight in pounds." },
      sleep_hours: { type: "number", minimum: 0, maximum: 24 },
      sleep_quality: { type: "integer", minimum: 1, maximum: 5 },
      time: { type: "string", description: "When, 24-hour HH:MM, for the weigh-in or sleep. Defaults to now today, or noon on another day." },
      meals: { type: "array", items: { type: "object", properties: {
        name: { type: "string", description: "What they ate, in their words." }, kcal: { type: "number" }, protein_g: { type: "number" },
        time: { type: "string", description: "HH:MM" },
      }, required: ["name"] } },
    } },
  },
  {
    name: "propose_session",
    title: "Propose a session",
    annotations: { title: "Propose a session", ...READ },
    description: "Propose a new session for a day not yet logged (today or later): the whole list of exercises, in order. Nothing changes until apply. Base it on get_context: their goals, recent logs and RPE, notes, equipment and injuries; keep the goal lifts progressing. Returns what changes and any plan-rule problems to fix first.",
    inputSchema: { type: "object", properties: {
      date: DATE,
      title: { type: "string", description: "The session's name, e.g. \"Upper · chest first\"." },
      reason: { type: "string", description: "One sentence on why, shown to them in the app." },
      exercises: SESSION,
    }, required: ["title", "reason", "exercises"] },
  },
  {
    name: "propose_week",
    title: "Propose a week",
    annotations: { title: "Propose a week", ...READ },
    description: "Propose several days at once, such as the first week after setup or next week from their logs: each day's whole session, or an empty exercises list for a rest day. Days already logged or past are refused. Checked by the plan rules and their weekly set ceiling; nothing changes until apply. Plan the days they said they train, each fitting their minutes.",
    inputSchema: { type: "object", properties: {
      reason: { type: "string", description: "One sentence on the week's aim, shown to them in the app." },
      days: { type: "array", minItems: 1, maxItems: 14, items: { type: "object", properties: {
        date: { type: "string", description: "YYYY-MM-DD" }, title: { type: "string" }, exercises: { ...SESSION, minItems: 0 },
      }, required: ["date", "exercises"] } },
    }, required: ["reason", "days"] },
  },
  {
    name: "get_program",
    title: "Get the program",
    annotations: { title: "Get the program", ...READ },
    description: "The multi-week program as their phone's Program tab shows it: every week from the start to the target date with its phase (base, build, peak), deload and test weeks, trips, the working sets each week aims for, and what's planned in each so far. Plan a week to its kind: a deload or test week is light (RPE 6 at most, about half the sets), a travel week is dumbbells and bodyweight only; propose_week enforces both.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "set_program",
    title: "Set the program",
    annotations: { title: "Set the program", ...write(false, true) },
    description: "Start a program or change it: how many weeks (or the target date), when it starts, how often to deload, and trips. Weeks run Sunday to Saturday. A new program starts this week unless start says otherwise. Code lays out the phases, deloads and the test week; then plan each week with propose_week, the first one or two now and each next week from their logs.",
    inputSchema: { type: "object", properties: {
      weeks: { type: "integer", minimum: 1, maximum: 52, description: "Length in weeks, ending on that week's Saturday." },
      by: { type: "string", description: "Or the target date, YYYY-MM-DD: the program runs through that week." },
      start: { type: "string", description: "YYYY-MM-DD, any day of the first week. Moving the start clears trips." },
      deload_every: { type: "integer", minimum: 0, maximum: 12, description: "A deload every N weeks; 0 goes back to their age's default." },
      trip: { type: "object", description: "A trip away from their gym: the weeks it takes a training day from become travel weeks.", properties: {
        from: { type: "string", description: "YYYY-MM-DD" }, to: { type: "string", description: "YYYY-MM-DD" },
      }, required: ["from", "to"] },
      clear_trips: { type: "boolean", description: "Remove every trip." },
    } },
  },
  {
    name: "get_progress",
    title: "Get progress",
    annotations: { title: "Get progress", ...READ },
    description: "Where each goal stands, as their phone's Progress tab shows it: now against where it started, the pace the program expects (behind, on pace, ahead), where it lands by the end at this rate, what it needs each week, the best set behind it and its trend; the weekly streak line; and the wins (personal bests, 25/50/75/100% milestones, streaks). Use it to celebrate and to coach.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "get_week_review",
    title: "Get the week's review",
    annotations: { title: "Get the week's review", ...READ },
    description: "The weekly review the app shows on Sundays, for the week (Sunday to Saturday) holding `date`: workouts done of planned, sets, push and pull, protein, kcal and sleep averages, weight change, each goal's week and pace, the alerts (low protein or sleep around sessions, an area their notes keep naming, a missing movement) and, every 4th program week, a check-in proposing a new target for a goal well ahead or behind. Write them your take from its facts; goals are theirs, so change one only if they agree.",
    inputSchema: { type: "object", properties: { date: DATE } },
  },
  {
    name: "set_profile",
    title: "Set profile",
    annotations: { title: "Set profile", ...write(false, true) },
    description: "Save what they tell you about themselves, merging into what's there. Call it as each answer comes in during setup, and whenever something changes. A new profile needs age and weight_lb first.",
    inputSchema: { type: "object", properties: {
      age: { type: "integer", minimum: 13, maximum: 100 },
      weight_lb: { type: "number" },
      training_days: { type: "array", items: { type: "string", enum: WEEKDAYS }, description: "The weekdays they train." },
      session_minutes: { type: "integer", minimum: 15, maximum: 180 },
      workout_time: { type: "string", description: "Usual start, 24-hour HH:MM." },
      equipment: { type: "array", items: { type: "string", enum: EQUIPMENT }, description: "Everything they can use. Bodyweight work needs none." },
      injured_areas: { type: "array", items: { type: "string", enum: Object.keys(AREAS) }, description: "Areas to go easy on; [] when none." },
      never: { type: "array", items: { type: "string" }, description: "Exercises they won't do, by name." },
      style: { type: "string", enum: STYLES, description: "powerbuilding (strength and size, the default), powerlifting, hypertrophy, functional." },
      max_weekly_sets: { type: "integer", minimum: 10, maximum: 120, description: "A ceiling on working sets a week (default 60)." },
      starting_sets: { type: "array", description: "A recent set per goal lift, so the first loads fit.", items: { type: "object", properties: {
        exercise: EXERCISE, weight_lb: { type: "number" }, reps: { type: "integer" }, seconds: { type: "integer" },
      }, required: ["exercise"] } },
    } },
  },
  {
    name: "set_goal",
    title: "Set a goal",
    annotations: { title: "Set a goal", ...write(true, false) },
    description: "Add, change or drop a goal. Goals have a target and ideally a date: a lift max (\"squat 225\"), reps in a row (\"10 pull-ups\") or body weight (\"190 lb\"). get_context lists goals with their ids.",
    inputSchema: { type: "object", properties: {
      action: { type: "string", enum: ["add", "change", "drop"] },
      goal_id: { type: "string", description: "For change and drop." },
      type: { type: "string", enum: ["lift_max", "reps", "body_weight"] },
      exercise: EXERCISE,
      target: { type: "number", description: "lb for a lift max or body weight; reps for reps." },
      by: { type: "string", description: "Deadline, YYYY-MM-DD." },
    }, required: ["action"] },
  },
  {
    name: "apply",
    title: "Apply a proposal",
    annotations: { title: "Apply a proposal", ...write(false, false) },
    description: "Apply a proposal from propose_session after they agree. It replaces that day's session on their phone.",
    inputSchema: { type: "object", properties: { proposal_id: { type: "string" } }, required: ["proposal_id"] },
  },
  {
    name: "undo",
    title: "Undo an apply",
    annotations: { title: "Undo an apply", ...write(false, false) },
    description: "Put back the session a day had before the last apply.",
    inputSchema: { type: "object", properties: { date: DATE }, required: ["date"] },
  },
];

type Args = Record<string, any>;

function context(units: Units, today: string, back: number, ahead: number, tz: string) {
  const profile = profileOf(units);
  const out: string[] = [`Today is ${weekday(today)} ${today}.`];
  if (profile) {
    // 0 is Monday, as ProgramDesigner.weekdays.
    const days = (profile.trainingDays ?? []).map((d) => ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][d % 7]).join(", ");
    out.push(`Profile: age ${profile.age ?? "?"}${profile.weightLb ? `, ${profile.weightLb} lb` : ""}; trains ${days || "?"}, ${profile.sessionMinutes ?? "?"} min; style ${profile.style ?? "?"}; at most ${profile.maxWeeklySets ?? "?"} working sets a week.`);
    out.push(`Equipment: ${profile.equipment?.length ? profile.equipment.join(", ").replace(/_/g, " ") : "none (bodyweight)"}.`);
    if (profile.injuredAreas?.length) out.push(`Injured: ${profile.injuredAreas.join(", ")}.`);
    if (profile.avoidExercises?.length) out.push(`Never: ${profile.avoidExercises.map(nameOf).join(", ")}.`);
    const program = programOf(profile, tz), now = programWeekOf(profile, today, tz);
    if (program) out.push(now ? `Program: week ${now.index + 1} of ${program.weeks.length}, ${title(now.week)}. ${why(now.week)} get_program has every week.`
      : `Program: ${today < program.start ? `starts ${program.start}` : `ended ${program.target}`} (get_program).`);
    else if (profile.age) out.push("No program yet: set_program lays one out to a target date.");
  }
  const sets = loggedSets(units);
  const goals = goalsOf(units);
  const needs = missing(profile, goals);
  if (needs.length) {
    out.push("", "NOT SET UP YET. Before planning, ask them, one topic at a time, and save each answer (set_profile, set_goal):", ...needs.map((n) => `- ${n}`),
      "Then set_program to their goal date, propose_week for the days from today to the end of next week, and apply when they agree.");
  }
  if (goals.length) {
    out.push("", "Goals:");
    for (const g of goals) {
      const [slug, kind] = g.metric.split(".");
      const by = g.deadline ? ` by ${dayOf(new Date(g.deadline * 1000), "UTC")}` : "";
      let now = "";
      if (kind === "1rm_lb" && bySlug.has(slug)) {
        const est = bestBy(sets, slug, today), month = bestBy(sets, slug, addDays(today, -28));
        now = est ? ` — estimated max now ${Math.round(est)} lb${month ? ` (${Math.round(est - month) >= 0 ? "+" : ""}${Math.round(est - month)} in 4 weeks)` : ""}` : " — no usable sets yet";
      }
      if (kind === "reps" && bySlug.has(slug)) {
        const best = Math.max(0, ...sets.filter((s) => s.exercise === slug && s.reps !== undefined).map((s) => s.reps!));
        now = best ? ` — best set so far ${best} reps` : " — no sets logged yet";
      }
      if (g.metric === "weight_lb") {
        const all = weighIns(units), last = all.at(-1), month = all.filter((w) => w.day <= addDays(today, -28)).at(-1);
        now = last ? ` — weighed ${last.lb} lb on ${last.day}${month ? ` (${last.lb - month.lb >= 0 ? "+" : ""}${Math.round((last.lb - month.lb) * 10) / 10} in 4 weeks)` : ""}`
          : profile?.weightLb ? ` — ${profile.weightLb} lb at setup, no weigh-ins yet` : "";
      }
      const label = bySlug.has(slug) ? nameOf(slug) : g.metric === "weight_lb" ? "Body weight" : g.metric;
      out.push(`- ${label} ${g.target} ${g.unit}${by}${now} [goal_id ${g.id}]`);
    }
  }
  const trained = [...new Set(sets.filter((s) => s.day >= addDays(today, -back)).map((s) => s.exercise))];
  const maxes = trained.map((slug) => [slug, bestBy(sets, slug, today)] as const).filter(([, e]) => e).sort((a, b) => b[1]! - a[1]!).slice(0, 8);
  if (maxes.length) out.push("", `Estimated maxes (Brzycki, sets at RPE ≤ 8): ${maxes.map(([s, e]) => `${nameOf(s)} ${Math.round(e!)} lb`).join(", ")}.`);
  out.push("", `Plan from today (★ = main lift):`);
  const planned = out.length;
  for (let i = 0; i <= ahead; i++) {
    const day = addDays(today, i);
    const s = describeSession(planOf(units, day));
    const done = logOf(units, day).some((r) => r.kind === "workout");
    if (s.lines.length) out.push(`${weekday(day)} ${day}${s.title ? ` — ${s.title}` : ""}${done ? " (logged)" : ""}:`, ...s.lines.map((l) => `  ${l}`));
  }
  if (out.length === planned) out.push(needs.length ? "  Nothing yet." : "  Nothing planned. Propose the coming days with propose_week.");
  out.push("", `Logged in the last ${back} days:`);
  let any = false;
  for (let i = back; i >= 1; i--) {
    const day = addDays(today, -i);
    const log = logOf(units, day);
    if (!log.some((r) => r.kind === "workout")) continue;
    any = true;
    const l = describeLog(log);
    const title = describeSession(planOf(units, day)).title;
    out.push(`${weekday(day)} ${day}${title ? ` — ${title}` : ""}${l.effort ? ` (effort ${l.effort}/10)` : ""}:`, ...l.lines.map((x) => `  ${x}`), ...(l.note ? [`  Note: ${l.note}`] : []));
  }
  if (!any) out.push("  Nothing.");
  const daily = Array.from({ length: 7 }, (_, i) => addDays(today, -i)).map((d) => [d, describeDaily(logOf(units, d))] as const).filter(([, l]) => l.length);
  if (daily.length) out.push("", "Weight, sleep and meals, the last 7 days:", ...daily.map(([d, l]) => `${weekday(d)} ${d}: ${l.join(". ")}.`));
  return out.join("\n");
}

/**
 * Where a new goal starts, as onboarding's answers.baseline: their logs if any, else the starting set (Brzycki
 * rounded, or reps), else the profile's weight. The app's wins and pace count from it.
 */
function baselineOf(units: Units, metric: string): number | undefined {
  const logged = progress.current(metric, progress.logSets(units), progress.weighIns(units), -Infinity);
  if (logged !== undefined) return logged;
  const profile = profileOf(units) as Record<string, any> | undefined;
  if (metric === "weight_lb") return profile?.weightLb;
  const [slug, kind] = metric.split(".");
  const start = (profile?.starts ?? []).find((s: { exercise: string }) => s.exercise === slug);
  const v = (m: string) => start?.measurements.find((x: { metric: string }) => x.metric === m)?.value as number | undefined;
  if (kind === "1rm_lb" && v("load_lb") !== undefined && v("reps") !== undefined) return Math.round(progress.estimatedMax(v("load_lb")!, v("reps")!));
  return kind === "reps" ? v("reps") : undefined;
}

const PACE: Record<progress.Pace, string> = { starting: "just starting", behind: "behind the program's pace", onPace: "on pace", ahead: "ahead of pace" };

function describeProgress(units: Units, today: string, nowSec: number, tz: string) {
  const profile = profileOf(units);
  const program = programOf(profile, tz);
  const sets = progress.logSets(units), weighs = progress.weighIns(units);
  const since = profile?.programStart ?? -Infinity;
  const goals = goalsOf(units).filter((g) => g.status === "active");
  const out: string[] = [];
  const week = program ? Math.max(0, Math.min(program.weeks.length - 1, weekIndex(today, program.start))) : 0;
  const end = profile?.targetDate;
  if (program) out.push(`Program week ${week + 1} of ${program.weeks.length}, ending ${program.target}. Counted from the program's start, ${program.start}.`);
  else out.push("No program yet, so this counts all their logs and there's no pace to compare with (set_program).");
  out.push("", goals.length ? "Goals:" : "No goals yet (set_goal).");
  for (const g of goals) {
    const option = progress.GOAL_OPTIONS.find((o) => o.metric === g.metric);
    const name = option?.name ?? (g.metric.endsWith(".1rm_lb") ? `${nameOf(g.metric.split(".")[0])} max` : g.metric.endsWith(".reps") ? `${nameOf(g.metric.split(".")[0])} in a row` : g.metric);
    const first = g.baseline ?? g.target;
    const now = progress.current(g.metric, sets, weighs, since);
    const n = progress.number;
    const lines = [`- ${name}: target ${n(g.target)} ${g.unit}${g.deadline ? ` by ${dayOf(new Date(g.deadline * 1000), tz)}` : ""} [goal_id ${g.id}]`];
    if (now === undefined) lines.push("  Nothing logged toward it yet.");
    else {
      lines.push(`  Now ${n(now)} ${g.unit}${g.baseline !== undefined ? `, from ${n(first)} at the start: ${Math.round(progress.fraction(first, now, g.target) * 100)}% of the way` : ""}.`);
      if (program && end && profile?.programStart && option) {
        const p = progress.pace(first, now, g.target, week, program.weeks);
        const fc = progress.forecast(first, now, profile.programStart, nowSec, end);
        lines.push(`  ${PACE[p][0].toUpperCase()}${PACE[p].slice(1)}.${fc !== undefined ? ` At this rate, ${n(Math.round(fc * 10) / 10)} ${g.unit} by ${program.target}.` : ""} Needs ${n(Math.round(progress.perWeek(now, g.target, nowSec, end) * 10) / 10)} ${g.unit} a week from here.`);
      }
      const top = progress.best(g.metric, sets, since);
      if (top) {
        const v = (m: string) => top.measurements.find((x) => x.metric === m)?.value;
        lines.push(`  Best set: ${v("load_lb") !== undefined ? `${v("load_lb")} lb × ` : ""}${v("reps")} reps on ${top.day}.`);
      }
      const points = progress.trend(g.metric, sets, weighs, since).slice(-8);
      if (points.length > 1) lines.push(`  Trend: ${points.map((p) => `${p.day} ${n(p.value)}`).join(", ")}.`);
    }
    out.push(...lines);
  }
  if (program && profile?.programStart && end) {
    const s = progress.streak(program.start, progress.plannedDays(units), progress.workoutDays(units), today);
    out.push("", `Streak: ${progress.streakLine(s, today) ?? (s.thisWeek.kind === "broken" ? "this week's sessions can't all be done now, so the streak restarts next week" : `${s.weeks} full week(s) so far; the app shows it from 2`)}.`);
    const tracked = goals.filter((g) => g.baseline !== undefined && progress.GOAL_OPTIONS.some((o) => o.metric === g.metric))
      .map((g) => ({ metric: g.metric, unit: g.unit, baseline: g.baseline!, target: g.target }));
    const won = progress.wins(tracked, sets, weighs, program.start, profile.programStart, end, progress.plannedDays(units), progress.workoutDays(units), today, tz);
    out.push("", won.length ? `Wins, newest first:\n${won.slice(0, 12).map((w) => `- ${progress.describeWin(w)}`).join("\n")}` : "No wins yet.");
  }
  return out.join("\n");
}

function describeReview(units: Units, day: string, nowSec: number, tz: string) {
  const r = progress.weekReport(units, day, nowSec, tz);
  const n = progress.number, x = r.numbers;
  const out = [`Week of ${weekday(r.from)} ${r.from} to ${weekday(r.to)} ${r.to}${r.programWeek !== undefined ? `, program week ${r.programWeek + 1} of ${r.programWeeks}` : ""}.`,
    `${progress.headline(r).replace(/^Your week$/, "Nothing logged yet this week.")} ${progress.subline(r)}`, "",
    `Numbers: ${x.workoutsDone} of ${x.workoutsPlanned} workouts, ${x.sets} working sets (${x.push} push, ${x.pull} pull).`
      + (x.protein !== undefined ? ` Protein ${Math.round(x.protein)} g a day.` : "") + (x.kcal !== undefined ? ` ${Math.round(x.kcal).toLocaleString("en-US")} kcal a day.` : "")
      + (x.sleep !== undefined ? ` Sleep ${n(x.sleep)} h a night.` : "") + " (Averages over the days logged.)"
      + (x.weight !== undefined ? ` Weight ${n(x.weight)} lb${x.weightChange !== undefined ? ` (${x.weightChange >= 0 ? "+" : ""}${n(Math.round(x.weightChange * 10) / 10)} on the week before)` : ""}.` : "")];
  if (r.goals.length) {
    out.push("", "Goals this week:");
    for (const g of r.goals) {
      out.push(`- ${g.option.name}: ${n(Math.round(g.from * 10) / 10)} → ${n(Math.round(g.to * 10) / 10)} of ${n(g.goal.target)} ${g.goal.unit}, ${PACE[g.pace]}.${g.forecast !== undefined ? ` At this rate ${n(Math.round(g.forecast * 10) / 10)} by the end.` : ""}`);
      if (g.checkIn) out.push(`  Check-in: ${g.checkIn.ahead ? "well ahead; offer to raise" : "behind; offer to keep it, or move"} the target to ${n(g.checkIn.proposed)} ${g.goal.unit} (${g.checkIn.weeksLeft} weeks left). Only if they agree: set_goal change, goal_id ${g.id}.`);
    }
  }
  out.push("", r.alerts.length ? `Alerts:\n${r.alerts.map((a) => `- ${a.title}. ${a.detail}${a.area ? ` (If it's an injury, set_profile can add ${a.area} to injured_areas.)` : ""}`).join("\n")}` : "No alerts.");
  const f = progress.facts(r);
  out.push("", "Facts for your take:", ...(f.length ? f.map((x) => `- ${x}`) : ["- Nothing to go on yet."]));
  return out.join("\n");
}

/** Every program week with its kind, aim and what's planned so far. */
function describeProgram(units: Units, today: string, tz: string) {
  const profile = profileOf(units);
  const program = programOf(profile, tz);
  if (!profile || !program) return "No program yet. set_program lays one out from this week to a target date.";
  const now = weekIndex(today, program.start);
  const every = profile.deloadEveryWeeks ? `every ${profile.deloadEveryWeeks} weeks` : `every ${deloadEvery(profile.age ?? 35)} weeks (their age's default)`;
  const out = [`Program: ${program.weeks.length} weeks, ${weekday(program.start)} ${program.start} to ${weekday(addDays(weekStart(program.weeks.length - 1, program.start), 6))} ${addDays(weekStart(program.weeks.length - 1, program.start), 6)}. Deload ${every}.`,
    now < 0 ? `It starts in ${-now} week(s).` : now >= program.weeks.length ? "It has ended; set_program starts the next one." : `This is week ${now + 1}.`, ""];
  program.weeks.forEach((w, i) => {
    const sunday = weekStart(i, program.start);
    const days = Array.from({ length: 7 }, (_, d) => addDays(sunday, d));
    const plans = days.map((d) => planOf(units, d));
    const sessions = plans.filter((p) => p.some((r) => r.kind === "workout")).length;
    const done = days.filter((d) => logOf(units, d).some((r) => r.kind === "workout")).length;
    const planned = sessions ? `${sessions} session(s), ${weeklySets(plans)} sets planned${done ? `, ${done} logged` : ""}` : "Not planned yet";
    out.push(`Week ${i + 1} · ${sunday}${i === now ? " (this week)" : ""} · ${title(w)}: ${why(w)} Aim about ${weeklyTarget(w, profile)} working sets. ${planned}.`);
  });
  return out.join("\n");
}

/** When a day's session starts: its first planned row, else their usual workout time. */
function startOf(units: Units, day: string, tz: string) {
  const first = planOf(units, day).filter((r) => r.kind === "workout").sort((a, b) => a.at - b.at)[0];
  return first ? Math.floor(first.at / 60) * 60 : epoch(day, profileOf(units)?.workoutTime ?? 7 * 60, tz);
}

type DayInput = { date: string; title?: string; exercises: ExerciseInput[] };

/** One or more days' new sessions, checked by the plan rules, stored for apply. */
async function propose(uid: string, tz: string, today: string, days: DayInput[], reason: string, store: Store) {
  const units = await store.units(uid);
  const profile = profileOf(units);
  const out: { day: string; rows: string }[] = [];
  const lines: string[] = [];
  const problems: string[] = [];
  const notes: string[] = [];
  const next = new Map<string, PlanRow[]>();
  for (const d of days) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(d.date ?? "")) throw new Error(`Not a date: ${d.date}. Use YYYY-MM-DD.`);
    if (d.date < today) throw new Error(`${d.date} is past; plan today or later.`);
    if (logOf(units, d.date).some((r) => r.kind === "workout")) throw new Error(`${d.date} is already logged.`);
    const before = planOf(units, d.date);
    const after = d.exercises.length ? sessionRows(before, d.title ?? "Workout", d.exercises, startOf(units, d.date, tz), reason) : before.filter((r) => r.kind !== "workout");
    next.set(d.date, after);
    out.push({ day: d.date, rows: encode(after) });
    const week = programWeekOf(profile, d.date, tz);
    const kind = week ? ` (week ${week.index + 1}, ${title(week.week)})` : "";
    lines.push("", `${weekday(d.date)} ${d.date}${kind}${d.exercises.length ? ` — ${d.title ?? "Workout"}` : " — rest"}:`, ...diff(before, after).map((l) => `  ${l}`));
    problems.push(...checkDay(after, profile, week && isLight(week.week) ? 1 : undefined).map((p) => `${d.date}: ${p}`));
    if (week && profile) problems.push(...checkProgramDay(after, profile, week.week).map((p) => `${d.date}: ${p}`));
    notes.push(...cautions(after, profile).map((c) => `${d.date}: ${c}`));
  }
  const sundays = new Set([...next.keys()].map((d) => addDays(d, -new Date(`${d}T12:00:00Z`).getUTCDay())));
  for (const sunday of sundays) {
    const total = weeklySets(Array.from({ length: 7 }, (_, i) => addDays(sunday, i)).map((d) => next.get(d) ?? planOf(units, d)));
    if (profile?.maxWeeklySets && total > profile.maxWeeklySets) problems.push(`Week of ${sunday}: ${total} working sets, over their ceiling of ${profile.maxWeeklySets}.`);
  }
  const id = randomUUID();
  await store.put(uid, `proposal#${id}`, { days: out, problems }, 2);
  return [`Proposal ${id} — ${reason}`, ...lines,
    ...(notes.length ? ["", "Check with them:", ...notes.map((n) => `- ${n}`)] : []),
    problems.length ? `\nPlan-rule problems; fix these and propose again before applying:\n${problems.map((p) => `- ${p}`).join("\n")}` : "\nIt passes the plan rules. Show them the change, and apply when they agree."].join("\n");
}

export async function callTool(name: string, args: Args, account: Account, store: Store, now = new Date()): Promise<string> {
  const { uid, tz } = account;
  const today = dayOf(now, tz);
  const day = (args.date as string | undefined) ?? today;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error(`Not a date: ${day}. Use YYYY-MM-DD.`);
  switch (name) {
    case "get_context": {
      const units = await store.units(uid);
      return context(units, today, Math.min(args.days_back ?? 21, 120), Math.min(args.days_ahead ?? 7, 28), tz);
    }
    case "get_day": {
      const units = await store.units(uid);
      const s = describeSession(planOf(units, day)), l = describeLog(logOf(units, day));
      return [`${weekday(day)} ${day}`, s.lines.length ? `Planned${s.title ? ` — ${s.title}` : ""}:\n${s.lines.map((x) => `  ${x}`).join("\n")}` : "Nothing planned.",
        l.lines.length ? `Logged:\n${l.lines.map((x) => `  ${x}`).join("\n")}${l.note ? `\n  Note: ${l.note}` : ""}` : "No workout logged.",
        ...describeDaily(logOf(units, day))].join("\n");
    }
    case "find_exercises": {
      const found = find(String(args.query ?? ""), profileOf(await store.units(uid)));
      return found.length ? found.map((e) => `${e.name} (${e.slug}) — ${e.pattern}; ${e.equipment.join(", ") || "bodyweight"}`).join("\n") : "Nothing matched. Try a movement (hinge, squat…) or a muscle.";
    }
    case "swap_options": {
      const e = resolve(String(args.exercise));
      const list = swapOptions(e.slug, profileOf(await store.units(uid)));
      return list.length ? `Instead of ${e.name}:\n${list.map((x) => `${x.name} (${x.slug}) — ${x.equipment.join(", ") || "bodyweight"}`).join("\n")}` : `No alternatives for ${e.name} with their equipment.`;
    }
    case "log_session": {
      const units = await store.units(uid);
      if (day > today) throw new Error("That day hasn't happened yet.");
      const existing = logOf(units, day);
      if (existing.some((r) => r.kind === "workout") && !args.replace) {
        throw new Error(`${day} is already logged:\n${describeLog(existing).lines.join("\n")}\nPass replace: true to replace it, or add_note to add context.`);
      }
      const plan = planOf(units, day);
      const made = logRows(plan, startOf(units, day, tz), { sets: args.sets as SetInput[] | undefined, as_planned: args.as_planned, rpe: args.rpe, effort: args.effort, note: args.note });
      await store.write(uid, [{ key: `log#${day}`, body: encode([...existing.filter((r) => r.kind !== "workout"), ...made]) }], account.agent);
      const l = describeLog(made);
      return `Logged ${weekday(day)} ${day}:\n${l.lines.join("\n")}${l.note ? `\nNote: ${l.note}` : ""}\nIt shows on their phone at its next sync.`;
    }
    case "add_note": {
      const units = await store.units(uid);
      const log = logOf(units, day);
      const summary = log.find((r) => r.kind === "workout" && !r.template);
      if (!summary) throw new Error(`${day} isn't logged yet. Log the session with log_session and put the note there.`);
      summary.note = [summary.note, String(args.note).trim()].filter(Boolean).join(" ");
      await store.write(uid, [{ key: `log#${day}`, body: encode(log) }], account.agent);
      return `Noted on ${day}: ${summary.note}`;
    }
    case "log_daily": {
      if (day > today) throw new Error(`${day} hasn't happened yet.`);
      const input = args as DailyInput;
      if (input.weight_lb === undefined && input.sleep_hours === undefined && input.sleep_quality === undefined && !input.meals?.length) {
        throw new Error("Nothing to log: give weight_lb, sleep_hours or meals.");
      }
      const at = (time?: string) => {
        if (time === undefined) return day === today ? Math.floor(now.getTime() / 1000) : epoch(day, 12 * 60, tz);
        const match = /^(\d{1,2}):(\d{2})$/.exec(time);
        if (!match) throw new Error("time is 24-hour HH:MM.");
        return epoch(day, Number(match[1]) * 60 + Number(match[2]), tz);
      };
      const units = await store.units(uid);
      const log = dailyRows(logOf(units, day), input, at);
      await store.write(uid, [{ key: `log#${day}`, body: encode(log) }], account.agent);
      return `Logged on ${day}:\n${describeDaily(log).map((l) => `  ${l}`).join("\n")}\nIt shows on their phone at its next sync.`;
    }
    case "propose_session":
      return propose(uid, tz, today, [{ date: day, title: args.title, exercises: args.exercises }], String(args.reason), store);
    case "propose_week":
      return propose(uid, tz, today, args.days as DayInput[], String(args.reason), store);
    case "apply": {
      const proposal = await store.get(uid, `proposal#${args.proposal_id}`);
      if (!proposal) throw new Error("No such proposal (they last 2 days). Propose again.");
      if (proposal.problems?.length) throw new Error("That proposal breaks the plan rules; fix them and propose again.");
      const days = proposal.days as { day: string; rows: string }[];
      const units = await store.units(uid);
      const logged = days.filter((d) => logOf(units, d.day).some((r) => r.kind === "workout")).map((d) => d.day);
      if (logged.length) throw new Error(`${logged.join(", ")} has been logged since; propose again without it.`);
      for (const d of days) await store.put(uid, `undo#${d.day}`, { body: units.get(`plan#${d.day}`) ?? null }, 14);
      await store.write(uid, days.map((d) => ({ key: `plan#${d.day}`, body: JSON.parse(d.rows).length ? d.rows : null })), account.agent);
      const lines = days.map((d) => `${weekday(d.day)} ${d.day}: ${describeSession(JSON.parse(d.rows) as PlanRow[]).title ?? "rest"}`);
      return `Applied:\n${lines.join("\n")}\nIt shows on their phone at its next sync. undo (per day) puts the old session back.`;
    }
    case "undo": {
      const saved = await store.get(uid, `undo#${day}`);
      if (!saved || saved.used) throw new Error(`Nothing to undo on ${day}.`);
      if (logOf(await store.units(uid), day).some((r) => r.kind === "workout")) throw new Error(`${day} has been logged since; it can't be put back.`);
      await store.write(uid, [{ key: `plan#${day}`, body: saved.body }], account.agent);
      await store.put(uid, `undo#${day}`, { used: true }, 1);
      return `Put back ${day}'s session as it was.`;
    }
    case "get_progress":
      return describeProgress(await store.units(uid), today, Math.floor(now.getTime() / 1000), tz);
    case "get_week_review":
      return describeReview(await store.units(uid), day, Math.floor(now.getTime() / 1000), tz);
    case "get_program":
      return describeProgram(await store.units(uid), today, tz);
    case "set_program": {
      const units = await store.units(uid);
      const current = units.get("profile");
      if (!current) throw new Error("Set up their profile first (set_profile: age and weight).");
      const p = JSON.parse(current);
      const old = programOf(p, tz);
      const date = (v: unknown, name: string) => {
        if (v === undefined) return undefined;
        if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v)) throw new Error(`${name} is YYYY-MM-DD.`);
        return v;
      };
      const start = sundayOf(date(args.start, "start") ?? old?.start ?? today);
      const by = date(args.by, "by");
      const count = args.weeks !== undefined ? Math.round(args.weeks) : by ? weekCount(start, by) : old ? weekCount(start, old.target) : undefined;
      if (!count) throw new Error("How long? Give weeks or a target date (by).");
      // As onboarding writes it: the start's Sunday, and the target the Saturday of the last week (OnboardingView.start).
      p.programStart = epoch(start, 0, tz);
      p.targetDate = epoch(addDays(start, 7 * count - 1), 0, tz);
      const moved = old && old.start !== start;
      let trips: number[] = moved || args.clear_trips ? [] : (p.travelWeeks ?? []).filter((w: number) => w < count);
      if (args.trip) {
        const from = date(args.trip.from, "trip.from")!, to = date(args.trip.to, "trip.to")!;
        const added = travelWeeks(from, to, start, count, p.trainingDays ?? []);
        if (!added.length) throw new Error("That trip doesn't miss a training day in the program.");
        trips = [...new Set([...trips, ...added])].sort((a, b) => a - b);
      }
      p.travelWeeks = trips;
      if (args.deload_every !== undefined) {
        if (args.deload_every === 0) delete p.deloadEveryWeeks;
        else p.deloadEveryWeeks = Math.max(2, Math.round(args.deload_every));
      }
      await store.write(uid, [{ key: "profile", body: encode(p) }], account.agent);
      const note = moved && (old?.weeks.some((w) => w.travel)) ? " Moving the start cleared the trips; add them again." : "";
      return `Saved.${note}\n\n${describeProgram(new Map([...units, ["profile", encode(p)]]), today, tz)}`;
    }
    case "set_profile": {
      const units = await store.units(uid);
      const current = units.get("profile");
      const merged = mergeProfile(current ? JSON.parse(current) : undefined, args as ProfileInput);
      await store.write(uid, [{ key: "profile", body: encode(merged) }], account.agent);
      const days = (merged.trainingDays as number[]).map((d) => WEEKDAYS[d]).join(", ");
      return `Saved. Age ${merged.age}, ${merged.weightLb} lb; trains ${days}, ${merged.sessionMinutes} min at ${String(Math.floor(merged.workoutTime / 60)).padStart(2, "0")}:${String(merged.workoutTime % 60).padStart(2, "0")}; `
        + `equipment ${(merged.equipment as string[]).join(", ") || "none"}; injured ${(merged.injuredAreas as string[]).join(", ") || "none"}; never ${(merged.avoidExercises as string[]).map(nameOf).join(", ") || "none"}; `
        + `${merged.style}; ${merged.starts.length} starting set(s).`;
    }
    case "set_goal": {
      const units = await store.units(uid);
      const by = args.by as string | undefined;
      if (by !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(by)) throw new Error("by is YYYY-MM-DD.");
      const deadline = by ? epoch(by, 12 * 60, tz) : undefined;
      if (args.action === "add") {
        if (args.target === undefined || !args.type) throw new Error("A new goal needs its type and target.");
        const body = goalBody(args as GoalInput, deadline);
        body.baseline = baselineOf(units, body.metric);
        const id = randomUUID().toUpperCase();
        await store.write(uid, [{ key: `goal#${id}`, body: encode(body) }], account.agent);
        return `Added: ${body.metric} ${body.target} ${body.unit}${by ? ` by ${by}` : ""} [goal_id ${id}].`;
      }
      const current = units.get(`goal#${args.goal_id}`);
      if (!current) throw new Error("No goal with that goal_id; get_context lists them.");
      const goal = JSON.parse(current);
      if (args.action === "drop") goal.status = "abandoned";
      else {
        if (args.target !== undefined) goal.target = args.target;
        if (deadline !== undefined) goal.deadline = deadline;
      }
      await store.write(uid, [{ key: `goal#${args.goal_id}`, body: encode(goal) }], account.agent);
      return args.action === "drop" ? "Dropped." : `Changed: ${goal.metric} ${goal.target} ${goal.unit}${by ? ` by ${by}` : ""}.`;
    }
    default:
      throw new Error(`Unknown tool ${name}`);
  }
}

// ---- MCP over HTTP ----

type Rpc = { jsonrpc: "2.0"; id?: string | number | null; method: string; params?: any };

export async function answer(message: Rpc, account: Account, store: Store, now = new Date()) {
  const reply = (result: unknown) => ({ jsonrpc: "2.0", id: message.id ?? null, result });
  switch (message.method) {
    case "initialize": {
      const asked = message.params?.protocolVersion;
      return reply({
        protocolVersion: typeof asked === "string" && /^\d{4}-\d{2}-\d{2}$/.test(asked) ? asked : "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "Barbrabell", version: "0.1.0" },
        instructions: "The person's strength training: goals, plan, logged sessions. Call get_context first. If it says NOT SET UP YET, be their coach getting to know them: ask one topic at a time (goals with dates, schedule, equipment, injuries, age and weight, a recent set per goal lift), saving each answer with set_profile and set_goal, then lay out the program to their goal date with set_program, propose_week for the first days and apply when they agree. Otherwise, log what they did with RPE and notes, and change days with propose_session or propose_week, showing the change before apply. Near the end of each week, plan the next one from get_program and their logs.",
      });
    }
    case "ping":
      return reply({});
    case "tools/list":
      return reply({ tools });
    case "tools/call": {
      try {
        const text = await callTool(message.params?.name, message.params?.arguments ?? {}, account, store, now);
        return reply({ content: [{ type: "text", text }] });
      } catch (error: any) {
        return reply({ content: [{ type: "text", text: String(error?.message ?? error) }], isError: true });
      }
    }
    default:
      return { jsonrpc: "2.0", id: message.id ?? null, error: { code: -32601, message: `Method not found: ${message.method}` } };
  }
}

const json = (statusCode: number, body?: unknown): LambdaFunctionURLResult =>
  ({ statusCode, headers: { "Content-Type": "application/json" }, body: body === undefined ? "" : JSON.stringify(body) });

export async function serve(event: LambdaFunctionURLEvent, store: Store, origin?: string): Promise<LambdaFunctionURLResult> {
  const bearer = /^Bearer\s+(\S+)$/i.exec(event.headers?.authorization ?? "")?.[1];
  const parts = event.rawPath.split("/").filter(Boolean);
  const token = bearer ?? (parts.length === 2 && parts[0] === "mcp" ? parts[1] : "");
  const account = token.length >= 32 ? await store.account(hashToken(token)) : undefined;
  if (!account) {
    // A link names its own account; anything else signs in (or refreshes) by OAuth.
    const link = !bearer && parts.length === 2;
    return origin && !link ? unauthorized(origin) : json(401, { error: "Unknown or revoked connection link." });
  }
  if (event.requestContext.http.method !== "POST") return { statusCode: 405, headers: { Allow: "POST" }, body: "" };
  let parsed: Rpc | Rpc[];
  try {
    parsed = JSON.parse(event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString() : (event.body ?? ""));
  } catch {
    return json(400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
  }
  const messages = Array.isArray(parsed) ? parsed : [parsed];
  const answers = [];
  for (const message of messages) if (message.id !== undefined && message.id !== null) answers.push(await answer(message, account, store));
  if (!answers.length) return { statusCode: 202, body: "" };
  return json(200, Array.isArray(parsed) ? answers : answers[0]);
}

// ---- FIT-151: sign-in through Cognito's hosted UI ----

const ORIGIN = process.env.PUBLIC_ORIGIN ?? "";
const COGNITO = `https://${process.env.COGNITO_DOMAIN}`;
const CLIENT_ID = process.env.COGNITO_CLIENT_ID ?? "";

export const config: Config = {
  origin: ORIGIN,
  site: { appName: "Barbrabell", origin: process.env.SHARE_ORIGIN || ORIGIN, appId: "" },
  providers: (process.env.PROVIDERS ?? "").split(",").filter(Boolean),
  authorizeUrl: (params) => `${COGNITO}/oauth2/authorize?${new URLSearchParams({ client_id: CLIENT_ID, ...params })}`,
  async exchange(code, verifier, redirectUri) {
    const response = await fetch(`${COGNITO}/oauth2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "authorization_code", client_id: CLIENT_ID, code, code_verifier: verifier, redirect_uri: redirectUri }),
    });
    if (!response.ok) throw new Error(`Cognito token exchange failed (${response.status}): ${await response.text()}`);
    const { id_token } = (await response.json()) as { id_token: string };
    // Straight from Cognito's token endpoint over TLS, so its signature needn't be checked (OIDC Core 3.1.3.7).
    const claims = JSON.parse(Buffer.from(id_token.split(".")[1], "base64url").toString());
    if (claims.aud !== CLIENT_ID || typeof claims.sub !== "string") throw new Error("Unexpected id token");
    return { uid: claims.sub };
  },
};

export async function handler(event: LambdaFunctionURLEvent) {
  return (ORIGIN && (await oauth(event, authStore, config))) || serve(event, dynamoStore, ORIGIN || undefined);
}
