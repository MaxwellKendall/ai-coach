import { createHash, randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { oauth, unauthorized, type AuthStore, type Config } from "./oauth.ts";
import { push } from "./sync.ts";
import {
  addDays, AREAS, bestBy, bySlug, cautions, checkDay, dayOf, EQUIPMENT, goalBody, mergeProfile, missing, STYLES, WEEKDAYS, describeLog, describeSession, diff, encode, epoch, find, goalsOf, logOf, loggedSets, logRows,
  nameOf, planOf, profileOf, resolve, sessionRows, swapOptions, weekday, weeklySets, type ExerciseInput, type GoalInput, type PlanRow,
  type ProfileInput, type SetInput, type Units,
} from "./training.ts";

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

export const tools = [
  {
    name: "get_context",
    description: "Start here. The person's goals with deadlines and where they stand, their profile (age, equipment, injuries, never list, schedule), the planned sessions from today on, and recent logged sessions with RPE and notes, plus estimated maxes for the lifts they train. Read it before suggesting, logging or changing anything.",
    inputSchema: { type: "object", properties: {
      days_back: { type: "integer", minimum: 1, maximum: 120, description: "How many past days of logs to include (default 21)." },
      days_ahead: { type: "integer", minimum: 0, maximum: 28, description: "How many days of plan to include from today (default 7)." },
    } },
  },
  {
    name: "get_day",
    description: "One day in full: the planned session (each exercise with sets, reps or seconds, load and RPE) and what was logged.",
    inputSchema: { type: "object", properties: { date: DATE } },
  },
  {
    name: "find_exercises",
    description: "Search the exercise catalog (700 exercises) by name words, movement pattern (squat, hinge, horizontal_push, vertical_pull, lunge, carry, core…) or muscle. Only exercises their equipment allows and not on their never list.",
    inputSchema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
  },
  {
    name: "swap_options",
    description: "Alternatives for an exercise: the same movement with their equipment, best first. Use it when they want to replace one exercise.",
    inputSchema: { type: "object", properties: { exercise: EXERCISE }, required: ["exercise"] },
  },
  {
    name: "log_session",
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
    description: "Add context to a day already logged, in their words (\"left knee sore on the last set\", \"slept 5 hours\").",
    inputSchema: { type: "object", properties: { date: DATE, note: { type: "string" } }, required: ["note"] },
  },
  {
    name: "propose_session",
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
    description: "Propose several days at once, such as the first week after setup or next week from their logs: each day's whole session, or an empty exercises list for a rest day. Days already logged or past are refused. Checked by the plan rules and their weekly set ceiling; nothing changes until apply. Plan the days they said they train, each fitting their minutes.",
    inputSchema: { type: "object", properties: {
      reason: { type: "string", description: "One sentence on the week's aim, shown to them in the app." },
      days: { type: "array", minItems: 1, maxItems: 14, items: { type: "object", properties: {
        date: { type: "string", description: "YYYY-MM-DD" }, title: { type: "string" }, exercises: { ...SESSION, minItems: 0 },
      }, required: ["date", "exercises"] } },
    }, required: ["reason", "days"] },
  },
  {
    name: "set_profile",
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
    description: "Apply a proposal from propose_session after they agree. It replaces that day's session on their phone.",
    inputSchema: { type: "object", properties: { proposal_id: { type: "string" } }, required: ["proposal_id"] },
  },
  {
    name: "undo",
    description: "Put back the session a day had before the last apply.",
    inputSchema: { type: "object", properties: { date: DATE }, required: ["date"] },
  },
];

type Args = Record<string, any>;

function context(units: Units, today: string, back: number, ahead: number) {
  const profile = profileOf(units);
  const out: string[] = [`Today is ${weekday(today)} ${today}.`];
  if (profile) {
    // 0 is Monday, as ProgramDesigner.weekdays.
    const days = (profile.trainingDays ?? []).map((d) => ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][d % 7]).join(", ");
    out.push(`Profile: age ${profile.age ?? "?"}${profile.weightLb ? `, ${profile.weightLb} lb` : ""}; trains ${days || "?"}, ${profile.sessionMinutes ?? "?"} min; style ${profile.style ?? "?"}; at most ${profile.maxWeeklySets ?? "?"} working sets a week.`);
    out.push(`Equipment: ${profile.equipment?.length ? profile.equipment.join(", ").replace(/_/g, " ") : "none (bodyweight)"}.`);
    if (profile.injuredAreas?.length) out.push(`Injured: ${profile.injuredAreas.join(", ")}.`);
    if (profile.avoidExercises?.length) out.push(`Never: ${profile.avoidExercises.map(nameOf).join(", ")}.`);
  }
  const sets = loggedSets(units);
  const goals = goalsOf(units);
  const needs = missing(profile, goals);
  if (needs.length) {
    out.push("", "NOT SET UP YET. Before planning, ask them, one topic at a time, and save each answer (set_profile, set_goal):", ...needs.map((n) => `- ${n}`),
      "Then propose_week for the days from today to the end of next week, and apply when they agree.");
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
    lines.push("", `${weekday(d.date)} ${d.date}${d.exercises.length ? ` — ${d.title ?? "Workout"}` : " — rest"}:`, ...diff(before, after).map((l) => `  ${l}`));
    problems.push(...checkDay(after, profile).map((p) => `${d.date}: ${p}`));
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
      return context(units, today, Math.min(args.days_back ?? 21, 120), Math.min(args.days_ahead ?? 7, 28));
    }
    case "get_day": {
      const units = await store.units(uid);
      const s = describeSession(planOf(units, day)), l = describeLog(logOf(units, day));
      return [`${weekday(day)} ${day}`, s.lines.length ? `Planned${s.title ? ` — ${s.title}` : ""}:\n${s.lines.map((x) => `  ${x}`).join("\n")}` : "Nothing planned.",
        l.lines.length ? `Logged:\n${l.lines.map((x) => `  ${x}`).join("\n")}${l.note ? `\n  Note: ${l.note}` : ""}` : "Nothing logged."].join("\n");
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
        serverInfo: { name: "barbrabell", version: "0.1.0" },
        instructions: "The person's strength training: goals, plan, logged sessions. Call get_context first. If it says NOT SET UP YET, be their coach getting to know them: ask one topic at a time (goals with dates, schedule, equipment, injuries, age and weight, a recent set per goal lift), saving each answer with set_profile and set_goal, then propose_week for the first days and apply when they agree. Otherwise, log what they did with RPE and notes, and change days with propose_session or propose_week, showing the change before apply.",
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
  site: { appName: "Rep & Recipe", origin: process.env.SHARE_ORIGIN || ORIGIN, appId: "" },
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
