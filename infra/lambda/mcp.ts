import { createHash, randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { push } from "./sync.ts";
import {
  addDays, bestBy, bySlug, checkDay, dayOf, describeLog, describeSession, diff, encode, epoch, find, goalsOf, logOf, loggedSets, logRows,
  nameOf, planOf, profileOf, resolve, sessionRows, swapOptions, weekday, weeklySets, type ExerciseInput, type PlanRow, type SetInput, type Units,
} from "./training.ts";

/**
 * FIT-149: the training as tools any agent calls on its own tokens (direction doc, 2026-10-17: agent-first, no hosted AI).
 * MCP over streamable HTTP, stateless: each POST is one JSON-RPC message answered with JSON. The agent reads and
 * writes the account's FIT-126 sync units, so the phone shows its changes on its next sync. Plan changes are proposed,
 * checked by the plan rules, then applied, with Undo.
 *
 * Auth, for now: a long random token in the URL (/mcp/TOKEN) names one account and its time zone; only its hash is
 * stored (MCPTOKEN#sha256). OAuth for any agent comes next.
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
    return out.Item && !out.Item.revoked ? { uid: out.Item.uid, tz: out.Item.tz, agent: out.Item.agent ?? "agent" } : undefined;
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

export const hashToken = (token: string) => createHash("sha256").update(token).digest("hex");

// ---- Tools ----

const DATE = { type: "string", description: "A day, YYYY-MM-DD. Defaults to today in the person's time zone." };
const EXERCISE = { type: "string", description: "An exercise by catalog name or slug, e.g. \"Back Squat\" or \"back-squat\"." };

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
      exercises: { type: "array", minItems: 1, items: { type: "object", properties: {
        exercise: EXERCISE, sets: { type: "integer", minimum: 1, maximum: 10 }, reps: { type: "integer" }, seconds: { type: "integer" },
        weight_lb: { type: "number" }, weight_lb_per_hand: { type: "number" }, rpe: { type: "number" },
        main: { type: "boolean", description: "A main lift (defaults to the catalog's goal lifts)." },
        superset: { type: "integer", description: "Exercises sharing a number are done together in rounds." },
      }, required: ["exercise", "sets"] } },
    }, required: ["title", "reason", "exercises"] },
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
      out.push(`- ${label} ${g.target} ${g.unit}${by}${now}`);
    }
  }
  const trained = [...new Set(sets.filter((s) => s.day >= addDays(today, -back)).map((s) => s.exercise))];
  const maxes = trained.map((slug) => [slug, bestBy(sets, slug, today)] as const).filter(([, e]) => e).sort((a, b) => b[1]! - a[1]!).slice(0, 8);
  if (maxes.length) out.push("", `Estimated maxes (Brzycki, sets at RPE ≤ 8): ${maxes.map(([s, e]) => `${nameOf(s)} ${Math.round(e!)} lb`).join(", ")}.`);
  out.push("", `Plan from today (★ = main lift):`);
  for (let i = 0; i <= ahead; i++) {
    const day = addDays(today, i);
    const s = describeSession(planOf(units, day));
    const done = logOf(units, day).some((r) => r.kind === "workout");
    if (s.lines.length) out.push(`${weekday(day)} ${day}${s.title ? ` — ${s.title}` : ""}${done ? " (logged)" : ""}:`, ...s.lines.map((l) => `  ${l}`));
  }
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
    case "propose_session": {
      const units = await store.units(uid);
      if (day < today) throw new Error("That day is past; plan today or later.");
      if (logOf(units, day).some((r) => r.kind === "workout")) throw new Error(`${day} is already logged.`);
      const before = planOf(units, day);
      const after = sessionRows(before, String(args.title), args.exercises as ExerciseInput[], startOf(units, day, tz), String(args.reason));
      const profile = profileOf(units);
      const problems = checkDay(after, profile);
      const sunday = addDays(day, -new Date(`${day}T12:00:00Z`).getUTCDay());
      const week = Array.from({ length: 7 }, (_, i) => addDays(sunday, i)).map((d) => (d === day ? after : planOf(units, d)));
      const total = weeklySets(week);
      if (profile?.maxWeeklySets && total > profile.maxWeeklySets) problems.push(`The week would have ${total} working sets, over their ceiling of ${profile.maxWeeklySets}.`);
      const id = randomUUID();
      await store.put(uid, `proposal#${id}`, { day, rows: encode(after), problems }, 2);
      return [`Proposal ${id} for ${weekday(day)} ${day} — ${args.title}:`, ...diff(before, after),
        problems.length ? `\nPlan-rule problems; fix these and propose again before applying:\n${problems.map((p) => `- ${p}`).join("\n")}` : "\nIt passes the plan rules. Show them the change, and apply when they agree."].join("\n");
    }
    case "apply": {
      const proposal = await store.get(uid, `proposal#${args.proposal_id}`);
      if (!proposal) throw new Error("No such proposal (they last 2 days). Propose again.");
      if (proposal.problems?.length) throw new Error("That proposal breaks the plan rules; fix them and propose again.");
      const units = await store.units(uid);
      if (logOf(units, proposal.day).some((r) => r.kind === "workout")) throw new Error(`${proposal.day} has been logged since; it can't be replaced.`);
      await store.put(uid, `undo#${proposal.day}`, { body: units.get(`plan#${proposal.day}`) ?? null }, 14);
      await store.write(uid, [{ key: `plan#${proposal.day}`, body: proposal.rows }], account.agent);
      return `Applied: ${weekday(proposal.day)} ${proposal.day} is now ${describeSession(JSON.parse(proposal.rows) as PlanRow[]).title}. It shows on their phone at its next sync. undo puts the old session back.`;
    }
    case "undo": {
      const saved = await store.get(uid, `undo#${day}`);
      if (!saved || saved.used) throw new Error(`Nothing to undo on ${day}.`);
      if (logOf(await store.units(uid), day).some((r) => r.kind === "workout")) throw new Error(`${day} has been logged since; it can't be put back.`);
      await store.write(uid, [{ key: `plan#${day}`, body: saved.body }], account.agent);
      await store.put(uid, `undo#${day}`, { used: true }, 1);
      return `Put back ${day}'s session as it was.`;
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
        instructions: "The person's strength training: goals, plan, logged sessions. Call get_context first. Log what they did with RPE and notes; to change a day, propose_session, show the change, then apply when they agree.",
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

export async function serve(event: LambdaFunctionURLEvent, store: Store): Promise<LambdaFunctionURLResult> {
  const token = event.rawPath.split("/").filter(Boolean).pop() ?? "";
  const account = token.length >= 32 ? await store.account(hashToken(token)) : undefined;
  if (!account) return json(401, { error: "Unknown or revoked connection link." });
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

export const handler = (event: LambdaFunctionURLEvent) => serve(event, dynamoStore);
