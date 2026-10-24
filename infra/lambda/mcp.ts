import { createHash, randomUUID } from "node:crypto";
import { DeleteObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { oauth, unauthorized, type AuthStore, type Config } from "./oauth.ts";
import { MAX_UNITS, push } from "./sync.ts";
import {
  addDays, AREAS, isHardRun, isRun, checkLoads, runTime, unknownMaxes, catalog, exerciseBody, isOwn, MUSCLES, PATTERNS, slugFor, useAccountExercises, type ExerciseFields, dailyRows, describeDaily, weighIns, type DailyInput, bestBy, bySlug, cautions, checkDay, dayOf, EQUIPMENT, goalBody, mergeProfile, missing, STYLES, WEEKDAYS, describeLog, describeSession, diff, encode, epoch, find, goalsOf, logOf, loggedSets, logRows,
  exactly, maxOf, nameOf, planOf, profileOf, resolve, sessionRows, swapOptions, weekday, weeklySets, type ExerciseInput, type GoalInput, type PlanRow,
  type ProfileInput, type SetInput, type Units,
} from "./training.ts";
import * as progress from "./progress.ts";
import { clock, distanceName, goalMeters, meters, MILE, miles, OUTDOOR_RUN, pace as runPace, RUNS, seconds } from "./running.ts";
import { listed as listedPrompts, render as renderPrompt } from "./prompts.ts";
import { programPayload, programSessions, recapPayload, sessionPayload, winPayload, type Brief } from "./sharing.ts";
import { COACH_PRICE, comments, createInvite, hasCoachPlan, INVITE_DAYS, isCoachOf, list as linked, postComment, type Person } from "./coach.ts";
import { PlanError, start as checkout } from "./coachPlan.ts";
import { byNeed, triage, type Comment, type Triage } from "../../shared/triage.ts";
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
  /** by: who's writing, when a coach writes a client's units (FIT-220). */
  write(uid: string, units: { key: string; body: string | null }[], source: string, by?: string): Promise<void>;
  get(uid: string, key: string): Promise<Record<string, any> | undefined>;
  put(uid: string, key: string, item: Record<string, any>, days: number): Promise<void>;
  /** FIT-169: save a share as createShare does (resolvers/createShare.js), and take one down as deleteShare does. */
  share(uid: string, kind: ShareKind, payload: Record<string, unknown>): Promise<{ id: string; url: string }>;
  unshare(uid: string, id: string): Promise<boolean>;
  /** Their display name, as updateProfile sets it: shown on what they share. */
  setName(uid: string, name: string): Promise<void>;
  /** FIT-194: a coach's clients (coach.ts's links), whether a link is there now, and an invite link as the dashboard makes. */
  clients(coach: string): Promise<Person[]>;
  coachOf(coach: string, client: string): Promise<boolean>;
  invite(coach: string): Promise<{ code: string; url: string }>;
  /** FIT-196: a client's session threads (FIT-132), and a coach's reply on one, shown in the app as the coach's. */
  comments(coach: string, client: string): Promise<Comment[]>;
  comment(coach: string, client: string, day: string, text: string): Promise<void>;
  /** FIT-148: whether they have the coach plan, and its monthly Checkout (undefined when Checkout can't start one). */
  coachPlan(uid: string): Promise<boolean>;
  coachCheckout(uid: string): Promise<string | undefined>;
}

export type ShareKind = "win" | "recap" | "program" | "session";
const SHARE_PATHS: Record<ShareKind, string> = { win: "w", recap: "r", program: "p", session: "s" };

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});
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
  async write(uid, units, source, by) {
    const now = new Date().toISOString();
    const all = units.map((u) => (u.body === null ? { key: u.key, updatedAt: now, deleted: true } : { key: u.key, updatedAt: now, deleted: false, body: u.body }));
    // FIT-218: a block of weeks is more units than one push takes.
    for (let i = 0; i < all.length; i += MAX_UNITS) await push(uid, all.slice(i, i + MAX_UNITS), source, undefined, by);
  },
  async get(uid, key) {
    return (await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${uid}`, SK: `MCP#${key}` } }))).Item;
  },
  async put(uid, key, item, days) {
    await db.send(new PutCommand({
      TableName: TABLE(), Item: { PK: `USER#${uid}`, SK: `MCP#${key}`, ...item, expiresAt: Math.floor(Date.now() / 1000) + days * 86_400 },
    }));
  },
  async share(uid, kind, payload) {
    const body = JSON.stringify(payload);
    if (body.length > 8000) throw new Error("That's too much for one shared page: share a week's recap or one session instead.");
    const profile = (await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${uid}`, SK: "PROFILE" } }))).Item;
    const id = randomUUID().replace(/-/g, "").slice(0, 12);
    await db.send(new PutCommand({
      TableName: TABLE(), ConditionExpression: "attribute_not_exists(PK)",
      // Found again through the user, so deleting the account deletes it (deleteAccount).
      Item: { PK: `SHARE#${id}`, SK: "META", kind, uid, name: profile?.displayName ?? null, payload: body, createdAt: new Date().toISOString(), GSI1PK: `USER#${uid}`, GSI1SK: `SHARE#${id}` },
    }));
    return { id, url: `${process.env.SHARE_ORIGIN}/${SHARE_PATHS[kind]}/${id}` };
  },
  async setName(uid, name) {
    const now = new Date().toISOString();
    await db.send(new UpdateCommand({
      TableName: TABLE(), Key: { PK: `USER#${uid}`, SK: "PROFILE" },
      UpdateExpression: "SET displayName = :n, updatedAt = :u, createdAt = if_not_exists(createdAt, :u), #id = :id",
      ExpressionAttributeNames: { "#id": "uid" }, ExpressionAttributeValues: { ":n": name, ":u": now, ":id": uid },
    }));
  },
  clients: (coach) => linked(coach, "CLIENT#"),
  coachOf: isCoachOf,
  invite: (coach) => createInvite(coach, undefined),
  comments: (coach, client) => comments(coach, client),
  async comment(coach, client, day, text) { await postComment(coach, undefined, client, day, text); },
  coachPlan: hasCoachPlan,
  async coachCheckout(uid) {
    // Billing handles what Checkout won't (a plan unpaid or incomplete, or one Stripe already has).
    return checkout(uid, "month", undefined, process.env.APP_ORIGIN, "coach").catch((error) => {
      if (error instanceof PlanError) return undefined;
      throw error;
    });
  },
  async unshare(uid, id) {
    const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `SHARE#${id}`, SK: "META" } }));
    if (!Item || Item.uid !== uid) return false;
    await db.send(new DeleteCommand({ TableName: TABLE(), Key: { PK: `SHARE#${id}`, SK: "META" } }));
    await s3.send(new DeleteObjectCommand({ Bucket: process.env.CARDS_BUCKET!, Key: `cards/${id}.png` }));
    return true;
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
  type: "array", minItems: 1, description: "The session's exercises, in order. A run is \"Trail Running/Walking\" (or \"Running, Treadmill\") with distance_mi and/or minutes and its kind, no sets; it can be a day of its own or beside lifting.", items: { type: "object", properties: {
    exercise: EXERCISE, sets: { type: "integer", minimum: 1, maximum: 10 }, reps: { type: "integer" }, seconds: { type: "integer" },
    distance_mi: { type: "number", description: "A run's distance in miles." }, minutes: { type: "number", description: "A run's time." },
    run: { type: "string", enum: ["easy", "long", "tempo", "intervals", "race"], description: "A run's kind (default easy). Keep tempo and intervals off the day before, or the day of, heavy legs." },
    weight_lb: { type: "number" }, weight_lb_per_hand: { type: "number" },
    percent_1rm: { type: "number", minimum: 30, maximum: 105, description: "A load as a percent of their max (\"75%\" is 75), in place of weight_lb: code works out the weight from their logs or starting set, to 5 lb." },
    rpe: { type: "number", description: "Target RPE; from RIR, 10 minus RIR." },
    main: { type: "boolean", description: "A main lift (defaults to the catalog's goal lifts)." },
    superset: { type: "integer", description: "Exercises sharing a number are done together in rounds (A1/A2 is one number)." },
    note: { type: "string", description: "The coach's cue for this exercise, shown above its sets on their phone: tempo, rest, a rep range, AMRAP on the last set." },
  }, required: ["exercise"] },
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
    description: "Start here in every conversation, and again with client before working on a coach's client. Their goals (with goal ids, deadlines and where each stands), profile (age, weight, schedule, equipment, injuries, never list), the plan from today on, recent logged sessions with RPE and notes, and estimated maxes. It says NOT SET UP YET for someone new, and lists a coach's clients. In every tool, \"they\" is the person whose training it is: the caller, or the client named with client.",
    inputSchema: { type: "object", properties: {
      days_back: { type: "integer", minimum: 1, maximum: 120, description: "How many past days of logs to include (default 21)." },
      days_ahead: { type: "integer", minimum: 0, maximum: 28, description: "How many days of plan to include from today (default 7)." },
    } },
  },
  {
    name: "get_day",
    title: "Get a day",
    annotations: { title: "Get a day", ...READ },
    description: "One day in full: the planned session (each exercise's sets, reps or seconds, load, RPE, superset and coach note) and what was logged, with weight, sleep and meals. With to, every day from date through to (up to 28), e.g. to read a block before changing it or copying it to another client.",
    inputSchema: { type: "object", properties: { date: DATE, to: { type: "string", description: "The last day of a range, YYYY-MM-DD; days with nothing planned or logged are left out." } } },
  },
  {
    name: "find_exercises",
    title: "Find exercises",
    annotations: { title: "Find exercises", ...READ },
    description: "Search the exercise catalog (about 700, plus their own) by name words, movement pattern (squat, hinge, horizontal_push, vertical_pull, lunge, carry, core…) or muscle, returning names and slugs. Only what their equipment allows and not on their never list. Use it to map a program's exercise names before proposing, and before create_exercise.",
    inputSchema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
  },
  {
    name: "swap_options",
    title: "Swap options",
    annotations: { title: "Swap options", ...READ },
    description: "Alternatives for one exercise: the same movement with their equipment, best first. Use it when they can't or won't do one (pain, missing equipment, a busy gym); then propose_session with the swap.",
    inputSchema: { type: "object", properties: { exercise: EXERCISE }, required: ["exercise"] },
  },
  {
    name: "create_exercise",
    title: "Create an exercise",
    annotations: { title: "Create an exercise", ...write(false, false) },
    description: "Add an exercise the catalog doesn't have, as their own (search find_exercises first: a coach's named variation, say). It's then planned and logged like any other and shows by name on their phone, in the plan and the library.",
    inputSchema: { type: "object", properties: {
      name: { type: "string", description: "As they call it, e.g. \"Landmine Press\"." },
      pattern: { type: "string", enum: PATTERNS, description: "Its movement pattern, which the plan rules and the review count." },
      equipment: { type: "array", items: { type: "string", enum: EQUIPMENT }, description: "What it needs; [] for bodyweight." },
      muscles: { type: "array", items: { type: "string", enum: MUSCLES } },
      cues: { type: "array", items: { type: "string" }, description: "Short coaching cues, one each." },
    }, required: ["name", "pattern", "equipment"] },
  },
  {
    name: "edit_exercise",
    title: "Edit their exercise",
    annotations: { title: "Edit their exercise", ...write(false, true) },
    description: "Change one of their own exercises (made with create_exercise): its name, pattern, equipment, muscles or cues. Catalog exercises can't be changed; create one instead.",
    inputSchema: { type: "object", properties: {
      exercise: EXERCISE,
      name: { type: "string" }, pattern: { type: "string", enum: PATTERNS }, equipment: { type: "array", items: { type: "string", enum: EQUIPMENT } },
      muscles: { type: "array", items: { type: "string", enum: MUSCLES } }, cues: { type: "array", items: { type: "string" } },
    }, required: ["exercise"] },
  },
  {
    name: "log_session",
    title: "Log a session",
    annotations: { title: "Log a session", ...write(true, false) },
    description: "Record a workout they did, today or earlier: each set with load, reps (or seconds) and RPE, and their note on how it went (soreness, sleep, how it felt). as_planned logs the day's planned lifting as is; add sets for what differed. Runs go to log_run; weight, sleep and meals to log_daily. A day already logged needs replace: true. Confirm the numbers with them when unsure. Logging is the person's own: a coach can't log for a client.",
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
    description: "Add context to a day already logged, in their words (\"left knee sore on the last set\", \"slept 5 hours\"). For a coach with client: a reply on the client's session that day, shown in their app as the coach's, and it answers that day's note in list_clients.",
    inputSchema: { type: "object", properties: { date: DATE, note: { type: "string" } }, required: ["note"] },
  },
  {
    name: "log_run",
    title: "Log a run",
    annotations: { title: "Log a run", ...write(false, false) },
    description: "Log a run they did: distance, time, average heart rate if they know it, and what kind (easy, long, tempo, intervals, race). Leave out what went as planned: distance, time and kind default to the day's planned run, so \"did my run\" on a planned 25-minute 2.5 mi needs neither. It's added to the day beside any lifting. Race-time goals follow it.",
    inputSchema: { type: "object", properties: {
      date: DATE,
      distance: { type: "string", description: "\"5 mi\" (a bare number is miles), \"8 km\", \"10K\". Defaults to the planned run's." },
      time: { type: "string", description: "\"44:00\" or \"1:02:10\". Defaults to the planned run's." },
      hr_avg: { type: "integer", minimum: 60, maximum: 220, description: "Average heart rate, bpm." },
      kind: { type: "string", enum: ["easy", "long", "tempo", "intervals", "race"] },
      treadmill: { type: "boolean" },
      note: { type: "string", description: "How it felt, in their words." },
    } },
  },
  {
    name: "log_daily",
    title: "Log weight, sleep or meals",
    annotations: { title: "Log weight, sleep or meals", ...write(false, false) },
    description: "Log what they tell you about the rest of the day: a weigh-in, last night's sleep (hours, and quality 1–5 if they say), a check-in note for their coach, or meals with kcal and protein (estimate from what they ate when they don't know, and say it's an estimate). Several in one call. A weigh-in or sleep replaces that day's own; meals add up. Body-weight goals follow the weigh-ins.",
    inputSchema: { type: "object", properties: {
      date: DATE,
      weight_lb: { type: "number", description: "Body weight in pounds." },
      sleep_hours: { type: "number", minimum: 0, maximum: 24 },
      sleep_quality: { type: "integer", minimum: 1, maximum: 5 },
      time: { type: "string", description: "When, 24-hour HH:MM, for the weigh-in or sleep. Defaults to now today, or noon on another day." },
      note: { type: "string", description: "How they feel today, for their coach, in their words: the day's check-in note, as the app's Check In saves it. Replaces that day's." },
      meals: { type: "array", items: { type: "object", properties: {
        name: { type: "string", description: "What they ate, in their words." }, kcal: { type: "number" }, protein_g: { type: "number" },
        time: { type: "string", description: "HH:MM" },
      }, required: ["name"] } },
    } },
  },
  {
    name: "delete_log",
    title: "Delete from a day's log",
    annotations: { title: "Delete from a day's log", ...write(true, true) },
    description: "Remove something logged by mistake: the day's workout (every set and its note), the weigh-in, the night's sleep, one meal by name, or everything that day. It can't be undone, so say exactly what goes and ask first; confirm must be true. To correct a workout instead, log_session with replace.",
    inputSchema: { type: "object", properties: {
      date: DATE,
      what: { type: "string", enum: ["workout", "weight", "sleep", "meal", "all"] },
      meal: { type: "string", description: "For a meal: its name as get_day shows it." },
      confirm: { type: "boolean", description: "true once they've agreed." },
    }, required: ["what", "confirm"] },
  },
  {
    name: "clear_day",
    title: "Make a day a rest day",
    annotations: { title: "Make a day a rest day", ...READ },
    description: "Propose making a planned day (today or later) a rest day. Nothing changes until apply, and undo puts the session back. To move a session instead, propose_session it on the new day too.",
    inputSchema: { type: "object", properties: { date: DATE, reason: { type: "string", description: "One sentence on why." } }, required: ["reason"] },
  },
  {
    name: "propose_session",
    title: "Propose a session",
    annotations: { title: "Propose a session", ...READ },
    description: "Propose one day's whole session (today or later, not yet logged): every exercise in order, with sets, reps or seconds, load (weight_lb, weight_lb_per_hand or percent_1rm), RPE, superset and note. Once applied it replaces that day's session; nothing changes until apply. Returns the change line by line, any names it matched loosely, weights it worked out from percentages, cautions to check with them, and plan-rule problems to fix first. Base it on get_context: their goals, recent logs and RPE, notes, equipment and injuries; keep the goal lifts progressing.",
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
    description: "Propose several days at once, up to 6 weeks: the first weeks after set_program, next week from their logs, or a block a coach brings in. Each day is a whole session as in propose_session, or an empty exercises list for a rest day; days left out keep what they have. Past or logged days are refused. Checked against the plan rules, each program week's kind and their weekly set ceiling; nothing changes until apply. Plan the days they said they train, each fitting their minutes.",
    inputSchema: { type: "object", properties: {
      reason: { type: "string", description: "One sentence on the week's aim, shown to them in the app." },
      days: { type: "array", minItems: 1, maxItems: 42, items: { type: "object", properties: {
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
    description: "Start or change the multi-week program: its length (weeks, or a target date with by), when it starts, how often to deload, trips, and its brief (phases). Weeks run Sunday to Saturday; a new program starts this week unless start says otherwise. Code lays out the phases (base, build, peak), a deload every deload_every weeks, and a light test week as the last. Each goal lift needs a max or starting set first (set_profile). It plans no sessions: then propose_week, the first one or two weeks now and each next week from their logs.",
    inputSchema: { type: "object", properties: {
      weeks: { type: "integer", minimum: 1, maximum: 52, description: "Length in weeks, ending on that week's Saturday." },
      by: { type: "string", description: "Or the target date, YYYY-MM-DD: the program runs through that week." },
      start: { type: "string", description: "YYYY-MM-DD, any day of the first week. Moving the start clears trips." },
      deload_every: { type: "integer", minimum: 0, maximum: 12, description: "A deload every N weeks; 0 goes back to their age's default." },
      trip: { type: "object", description: "A trip away from their gym: the weeks it takes a training day from become travel weeks.", properties: {
        from: { type: "string", description: "YYYY-MM-DD" }, to: { type: "string", description: "YYYY-MM-DD" },
      }, required: ["from", "to"] },
      clear_trips: { type: "boolean", description: "Remove every trip." },
      phases: { type: "array", maxItems: 3, description: "The program's brief, one per phase it has: its focus, its 2–4 main lifts (the goal lifts among them) and reps. The app's Program tab and a shared program show it.", items: { type: "object", properties: {
        phase: { type: "string", enum: ["base", "build", "peak"] }, focus: { type: "string", description: "A few words." },
        main_lifts: { type: "array", minItems: 1, maxItems: 4, items: EXERCISE }, main_reps: { type: "integer", minimum: 1, maximum: 15 },
        accessory_reps: { type: "integer", minimum: 5, maximum: 20 },
      }, required: ["phase", "focus", "main_lifts", "main_reps", "accessory_reps"] } },
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
    name: "share",
    title: "Share a link",
    annotations: { title: "Share a link", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    description: "Make a public link to paste anywhere, as the app's Share does: a win (its id from get_progress), a week's recap (the week holding date), a planned session (date) for a friend to train with them, or the program (it needs the program's phases, set_program). Anyone with the link can see it: ask before sharing, and whether to show weights (without them, changes go as percents). The page shows their display name and a text preview; the app's card image isn't made here.",
    inputSchema: { type: "object", properties: {
      kind: { type: "string", enum: ["win", "recap", "session", "program"] },
      win: { type: "string", description: "For a win: its id, as get_progress lists it." },
      date: DATE,
      show_weights: { type: "boolean", description: "Show weights and maxes (default true, as the app)." },
    }, required: ["kind"] },
  },
  {
    name: "stop_sharing",
    title: "Stop sharing a link",
    annotations: { title: "Stop sharing a link", ...write(true, true) },
    description: "Take down a link that share made, when they ask: its page then says it has expired. Their other links stay up.",
    inputSchema: { type: "object", properties: { link: { type: "string", description: "The link, or its id." } }, required: ["link"] },
  },
  {
    name: "set_profile",
    title: "Set profile",
    annotations: { title: "Set profile", ...write(false, true) },
    description: "Save what they tell you about themselves; only the fields given change. Call it as each answer comes in during setup and whenever something changes: schedule, equipment, injuries, the never list, and starting_sets (their maxes or recent heavy sets), which programs and weights need. A new profile needs age and weight_lb first. A coach can set everything for a client but their name.",
    inputSchema: { type: "object", properties: {
      name: { type: "string", description: "What to call them, as their shared pages show it (their first name, say)." },
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
      starting_sets: { type: "array", description: "Where they are now, per goal lift and any main lift: their 1RM (weight_lb with reps 1, tested or their best estimate) or a recent heavy set (weight × reps). Required before set_program, and weights are held to it.", items: { type: "object", properties: {
        exercise: EXERCISE, weight_lb: { type: "number" }, reps: { type: "integer" }, seconds: { type: "integer" },
        distance: { type: "string", description: "For a run (a race-time goal's starting point): \"5 mi\", \"10K\", \"8 km\"." },
        time: { type: "string", description: "For a run: its time, \"59:30\"." },
      } } },
    } },
  },
  {
    name: "set_goal",
    title: "Set a goal",
    annotations: { title: "Set a goal", ...write(true, false) },
    description: "Add, change or drop a goal. Goals have a target and ideally a date: a lift max (\"squat 225\"), reps in a row (\"10 pull-ups\"), body weight (\"190 lb\") or a race time (\"10K in 55:00\", type timed_distance with distance and time; save their last race or a hard run as a starting set too). get_context lists goals with their ids.",
    inputSchema: { type: "object", properties: {
      action: { type: "string", enum: ["add", "change", "drop"] },
      goal_id: { type: "string", description: "For change and drop." },
      type: { type: "string", enum: ["lift_max", "reps", "body_weight", "timed_distance"] },
      exercise: EXERCISE,
      target: { type: "number", description: "lb for a lift max or body weight; reps for reps." },
      distance: { type: "string", description: "For a race time: \"5K\", \"10K\", \"half\", \"marathon\", \"5 mi\" or \"8 km\"." },
      time: { type: "string", description: "For a race time: the target, \"55:00\" or \"1:45:30\"." },
      by: { type: "string", description: "Deadline, YYYY-MM-DD." },
    }, required: ["action"] },
  },
  {
    name: "apply",
    title: "Apply a proposal",
    annotations: { title: "Apply a proposal", ...write(false, false) },
    description: "Make a proposal real once they agree: each day in it (from propose_session, propose_week or clear_day) gets its new session, on their phone at its next sync. Give the proposal_id it returned; one with plan-rule problems is refused. A coach passes the same client the proposal was for.",
    inputSchema: { type: "object", properties: { proposal_id: { type: "string" } }, required: ["proposal_id"] },
  },
  {
    name: "undo",
    title: "Undo an apply",
    annotations: { title: "Undo an apply", ...write(false, false) },
    description: "Put back the session one day had before the last apply changed it (within 14 days, once). A day logged since can't be put back.",
    inputSchema: { type: "object", properties: { date: DATE }, required: ["date"] },
  },
  {
    name: "list_clients",
    title: "List clients",
    annotations: { title: "List clients", ...READ },
    description: "For a coach: every client with their id, those who need them first, with this week's sessions done of planned (Sunday to Saturday), their last session, streak, and the dashboard's flags: pain or an unanswered note, missed sessions, RPE 9+ on a main lift, a main lift stalled 3 weeks, nothing logged in 2 weeks. Then pass client to get_context, add_note or a planning tool.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "roster_review",
    title: "Review the roster's week",
    annotations: { title: "Review the roster's week", ...READ },
    description: "For a coach: the week holding date across every client, those who need them first: flags, workouts done of planned, sets, each goal's pace, the week's alerts, and whether next week is planned yet. For \"who needs me this week\"; then get_week_review or get_context with client for one in full.",
    inputSchema: { type: "object", properties: { date: DATE } },
  },
  {
    name: "invite_client",
    title: "Invite a client",
    annotations: { title: "Invite a client", ...write(false, false) },
    description: "For a coach: a link to send one new client, the same as the dashboard's invite. They open it on their phone, get the free Barbrabell app and accept; then they're in get_context's clients. It works once, for 14 days.",
    inputSchema: { type: "object", properties: {} },
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
  const needs = missing(profile, goals, units);
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
      const race = goalMeters(g.metric);
      if (race !== undefined) {
        const t = runTime(units, profile, race);
        out.push(`- ${distanceName(race)} in ${clock(g.target)}${by}${t !== undefined ? ` — their runs predict ${clock(t)} now` : " — no runs to go on yet"} [goal_id ${g.id}]`);
        continue;
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
  const race = goalMeters(metric);
  if (race !== undefined) return runTime(units, profile as any, race);
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
    const option = progress.optionFor(g.metric);
    const name = option?.name ?? (g.metric.endsWith(".1rm_lb") ? `${nameOf(g.metric.split(".")[0])} max` : g.metric.endsWith(".reps") ? `${nameOf(g.metric.split(".")[0])} in a row` : g.metric);
    const first = g.baseline ?? g.target;
    const now = progress.current(g.metric, sets, weighs, since);
    const time = option?.measure === "time";
    const n = (x: number) => progress.formatValue(g.metric, x), u = time ? "" : ` ${g.unit}`;
    const lines = [`- ${name}: target ${n(g.target)}${u}${g.deadline ? ` by ${dayOf(new Date(g.deadline * 1000), tz)}` : ""} [goal_id ${g.id}]`];
    if (now === undefined) lines.push(time ? "  No runs since the program started to predict from (log_run)." : "  Nothing logged toward it yet.");
    else {
      lines.push(`  Now ${n(now)}${u}${time ? " predicted from their runs" : ""}${g.baseline !== undefined ? `, from ${n(first)} at the start: ${Math.round(progress.fraction(first, now, g.target) * 100)}% of the way` : ""}.`);
      if (program && end && profile?.programStart && option) {
        const p = progress.pace(first, now, g.target, week, program.weeks);
        const fc = progress.forecast(first, now, profile.programStart, nowSec, end);
        const per = progress.perWeek(now, g.target, nowSec, end);
        lines.push(`  ${PACE[p][0].toUpperCase()}${PACE[p].slice(1)}.${fc !== undefined ? ` At this rate, ${time ? clock(fc) : `${progress.number(Math.round(fc * 10) / 10)} ${g.unit}`} by ${program.target}.` : ""} `
          + (time ? `Needs ${clock(Math.abs(per))} ${per <= 0 ? "faster" : "slower"} each week from here.` : `Needs ${progress.number(Math.round(per * 10) / 10)} ${g.unit} a week from here.`));
      }
      const top = progress.best(g.metric, sets, since);
      if (top) {
        const v = (m: string) => top.measurements.find((x) => x.metric === m)?.value;
        lines.push(time ? `  Best run: ${miles(v("distance_m")!)} in ${clock(v("duration_s")!)} (${runPace(v("duration_s")!, v("distance_m")!)}) on ${top.day}.`
          : `  Best set: ${v("load_lb") !== undefined ? `${v("load_lb")} lb × ` : ""}${v("reps")} reps on ${top.day}.`);
      }
      const points = progress.trend(g.metric, sets, weighs, since).slice(-8);
      if (points.length > 1) lines.push(`  Trend: ${points.map((p) => `${p.day} ${n(p.value)}`).join(", ")}.`);
    }
    out.push(...lines);
  }
  if (program && profile?.programStart && end) {
    const s = progress.streak(program.start, progress.plannedDays(units), progress.workoutDays(units), today);
    out.push("", `Streak: ${progress.streakLine(s, today) ?? (s.thisWeek.kind === "broken" ? "this week's sessions can't all be done now, so the streak restarts next week" : `${s.weeks} full week(s) so far; the app shows it from 2`)}.`);
    const won = progressWins(units, today, tz);
    out.push("", won.length ? `Wins, newest first (share one by its id):\n${won.slice(0, 12).map((w) => `- ${progress.describeWin(w)} [win ${w.key}]`).join("\n")}` : "No wins yet.");
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
      + (x.runKm ? ` Ran ${miles(x.runKm * 1000)}.` : "")
      + (x.weight !== undefined ? ` Weight ${n(x.weight)} lb${x.weightChange !== undefined ? ` (${x.weightChange >= 0 ? "+" : ""}${n(Math.round(x.weightChange * 10) / 10)} on the week before)` : ""}.` : "")];
  if (r.goals.length) {
    out.push("", "Goals this week:");
    for (const g of r.goals) {
      const f = (x: number) => (g.option.measure === "time" ? clock(x) : n(Math.round(x * 10) / 10)), u = g.option.measure === "time" ? "" : ` ${g.goal.unit}`;
      out.push(`- ${g.option.name}: ${f(g.from)} → ${f(g.to)} of ${f(g.goal.target)}${u}, ${PACE[g.pace]}.${g.forecast !== undefined ? ` At this rate ${f(g.forecast)} by the end.` : ""}`);
      if (g.checkIn) out.push(`  Check-in: ${g.checkIn.ahead ? `well ahead; offer to ${g.option.measure === "time" ? "lower" : "raise"}` : "behind; offer to keep it, or move"} the target to ${f(g.checkIn.proposed)}${u} (${g.checkIn.weeksLeft} weeks left). Only if they agree: set_goal change, goal_id ${g.id}.`);
    }
  }
  out.push("", r.alerts.length ? `Alerts:\n${r.alerts.map((a) => `- ${a.title}. ${a.detail}${a.area ? ` (If it's an injury, set_profile can add ${a.area} to injured_areas.)` : ""}`).join("\n")}` : "No alerts.");
  const f = progress.facts(r);
  out.push("", "Facts for your take:", ...(f.length ? f.map((x) => `- ${x}`) : ["- Nothing to go on yet."]));
  return out.join("\n");
}

/** An exercise's slug by its exact name or slug, without resolve's looser matching. */
function resolveLoose(said: string) {
  const s = said.trim().toLowerCase();
  return catalog.find((e) => e.slug === s || e.name.toLowerCase() === s)?.slug;
}

/** Every win since the program started, as get_progress lists them (WinFeed.wins). */
function progressWins(units: Units, today: string, tz: string) {
  const profile = profileOf(units), program = programOf(profile, tz);
  if (!profile?.programStart || !profile.targetDate || !program) return [];
  const tracked = goalsOf(units).filter((g) => g.status === "active" && g.baseline !== undefined && progress.optionFor(g.metric))
    .map((g) => ({ metric: g.metric, unit: g.unit, baseline: g.baseline!, target: g.target }));
  return progress.wins(tracked, progress.logSets(units), progress.weighIns(units), program.start, profile.programStart, profile.targetDate,
    progress.plannedDays(units), progress.workoutDays(units), today, tz);
}

/** The miles of running a week (Sunday on) holds: logged where a day is logged, else planned. */
function weekMiles(units: Units, sunday: string, planFor: (d: string) => PlanRow[]) {
  let m = 0;
  for (let i = 0; i < 7; i++) {
    const d = addDays(sunday, i), logged = logOf(units, d).filter((r) => isRun(r));
    const rows = logged.length ? logged.map((r) => r.measurements) : planFor(d).filter((r) => isRun(r)).map((r) => r.targets);
    m += rows.reduce((n, ms) => n + (ms.find((x) => x.metric === "distance_m")?.value ?? 0), 0);
  }
  return Math.round((m / MILE) * 10) / 10;
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
    const mi = weekMiles(units, sunday, (d) => planOf(units, d));
    const planned = sessions ? `${sessions} session(s), ${weeklySets(plans)} sets planned${mi ? `, ${mi} mi of running` : ""}${done ? `, ${done} logged` : ""}` : "Not planned yet";
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
async function propose(uid: string, caller: string, tz: string, today: string, days: DayInput[], reason: string, store: Store) {
  const units = await store.units(uid);
  const profile = profileOf(units);
  const out: { day: string; rows: string }[] = [];
  const lines: string[] = [];
  const problems: string[] = [];
  const notes: string[] = [];
  const next = new Map<string, PlanRow[]>();
  // FIT-218: what a pasted program's names and percentages became, for the agent to check before apply.
  const loose = new Map<string, string>(), weights = new Map<string, { said: string; pcts: Map<number, number> }>();
  for (const d of days) {
    d.exercises = (d.exercises ?? []).map((x) => {
      const e = resolve(x.exercise);
      if (!exactly(x.exercise)) loose.set(x.exercise, `"${x.exercise}" is ${e.name} (${e.slug})`);
      if (x.percent_1rm === undefined) return x;
      if (x.weight_lb !== undefined || x.weight_lb_per_hand !== undefined) throw new Error(`${e.name}: give percent_1rm or a weight, not both.`);
      const max = maxOf(units, profile, e.slug, today);
      if (max === undefined) throw new Error(`${e.name} at ${x.percent_1rm}% needs their max. Ask for it, then save it with set_profile starting_sets (a 1RM is weight_lb with reps 1).`);
      const weight = Math.round((max * x.percent_1rm) / 100 / 5) * 5;
      const w = weights.get(e.slug) ?? { said: `${e.name}, max ${Math.round(max)} lb`, pcts: new Map() };
      weights.set(e.slug, w.pcts.set(x.percent_1rm, weight) && w);
      return { ...x, percent_1rm: undefined, weight_lb: weight };
    });
    if (!/^\d{4}-\d{2}-\d{2}$/.test(d.date ?? "")) throw new Error(`Not a date: ${d.date}. Use YYYY-MM-DD.`);
    if (d.date < today) throw new Error(`${d.date} is past; plan today or later.`);
    if (logOf(units, d.date).some((r) => r.kind === "workout")) throw new Error(`${d.date} is already logged, so its plan stays as it was done: leave it out and propose the other days.`);
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
    const loads = checkLoads(after, units, profile);
    problems.push(...loads.problems.map((p) => `${d.date}: ${p}`));
    notes.push(...loads.cautions.map((c) => `${d.date}: ${c}`));
  }
  const sundays = new Set([...next.keys()].map((d) => addDays(d, -new Date(`${d}T12:00:00Z`).getUTCDay())));
  const planFor = (d: string) => next.get(d) ?? planOf(units, d);
  for (const sunday of sundays) {
    const total = weeklySets(Array.from({ length: 7 }, (_, i) => addDays(sunday, i)).map(planFor));
    if (profile?.maxWeeklySets && total > profile.maxWeeklySets) problems.push(`Week of ${sunday}: ${total} working sets, over their ceiling of ${profile.maxWeeklySets}.`);
    // FIT-178: a week's running more than 10% over the most of the 4 before it.
    const mi = weekMiles(units, sunday, planFor), before = Math.max(0, ...[1, 2, 3, 4].map((w) => weekMiles(units, addDays(sunday, -7 * w), (d) => planOf(units, d))));
    if (before > 0 && mi > before * 1.1) notes.push(`Week of ${sunday}: ${mi} mi of running, more than 10% over the ${before} mi most of the 4 weeks before.`);
  }
  // FIT-178: a hard run the day of, or the day before, heavy legs (a main squat or hinge).
  const heavyLegs = (d: string) => planFor(d).some((r) => r.kind === "workout" && r.main && ["squat", "hinge"].includes(bySlug.get(r.template ?? "")?.pattern ?? ""));
  for (const d of next.keys()) {
    for (const day of [d, addDays(d, -1)]) {
      if (planFor(day).some(isHardRun) && (heavyLegs(day) || heavyLegs(addDays(day, 1)))) {
        notes.push(`${day}: a hard run next to heavy legs (${heavyLegs(day) ? "the same day" : `squats or deadlifts on ${addDays(day, 1)}`}). Move one, or make the run easy.`);
      }
    }
  }
  const id = randomUUID();
  // Kept with whoever proposed it, so a coach's apply finds it; uid is whose plan it changes.
  await store.put(caller, `proposal#${id}`, { uid, days: out, problems }, 2);
  return [`Proposal ${id} — ${reason}`, ...lines,
    ...(loose.size ? ["", "Matched by name; check each is the exercise meant, or use find_exercises and propose again:", ...[...loose.values()].map((l) => `- ${l}`)] : []),
    ...(weights.size ? ["", "Weights from percentages of their max:", ...[...weights.values()].map((w) =>
      `- ${w.said}: ${[...w.pcts].sort((a, b) => a[0] - b[0]).map(([p, lb]) => `${p}% ${lb}`).join(", ")} lb`)] : []),
    ...(notes.length ? ["", "Check with them:", ...byText(notes).map((n) => `- ${n}`)] : []),
    problems.length ? `\nPlan-rule problems; fix these and propose again before applying:\n${byText(problems).map((p) => `- ${p}`).join("\n")}` : "\nIt passes the plan rules. Show them the change, and apply when they agree."].join("\n");
}

/** "2026-10-20, 2026-10-27: …" once, for the same note on many days of a block (FIT-218). */
function byText(list: string[]) {
  const days = new Map<string, string[]>();
  for (const item of list) {
    const [, day, text] = /^(\d{4}-\d{2}-\d{2}): (.*)$/s.exec(item) ?? [, "", item];
    const seen = days.get(text) ?? [];
    if (day && !seen.includes(day)) seen.push(day);
    days.set(text, seen);
  }
  return [...days].map(([text, d]) => (d.length ? `${d.join(", ")}: ${text}` : text));
}

function describeDay(units: Units, day: string) {
  const s = describeSession(planOf(units, day)), l = describeLog(logOf(units, day));
  return [`${weekday(day)} ${day}`, s.lines.length ? `Planned${s.title ? ` — ${s.title}` : ""}:\n${s.lines.map((x) => `  ${x}`).join("\n")}` : "Nothing planned.",
    l.lines.length ? `Logged:\n${l.lines.map((x) => `  ${x}`).join("\n")}${l.note ? `\n  Note: ${l.note}` : ""}` : "No workout logged.",
    ...describeDaily(logOf(units, day))].join("\n");
}

// ---- FIT-196: the coach's roster ----

/** A client's line in list_clients: the week so far and the dashboard's flags (shared/triage.ts). */
function rosterLine(client: Person, t: Triage) {
  const streak = t.streak && t.streak >= 2 ? `, ${t.streak} weeks in a row` : "";
  const last = t.lastSession ? `last session ${weekday(t.lastSession)} ${t.lastSession}` : "nothing logged yet";
  const flags = t.flags.length ? ` Flags: ${t.flags.map((f) => `${f.kind}: ${f.text}`).join("; ")}.` : " No flags.";
  return `${shownName(client)} [${client.uid}]: ${t.done} of ${t.planned} sessions this week, ${last}${streak}.${flags}`;
}

/** roster_review's few lines per client: the week's numbers, goals' pace and alerts, and whether next week is planned. */
function weekLines(units: Units, day: string, nowSec: number, tz: string) {
  const r = progress.weekReport(units, day, nowSec, tz), x = r.numbers;
  const out = [`Week ${r.from} to ${r.to}${r.programWeek !== undefined ? ` (program week ${r.programWeek + 1} of ${r.programWeeks})` : ", no program"}: ${x.workoutsDone} of ${x.workoutsPlanned} workouts, ${x.sets} working sets.`];
  for (const g of r.goals) {
    const f = (v: number) => (g.option.measure === "time" ? clock(v) : progress.number(Math.round(v * 10) / 10));
    out.push(`${g.option.name}: ${f(g.to)} of ${f(g.goal.target)}${g.option.measure === "time" ? "" : ` ${g.goal.unit}`}, ${PACE[g.pace]}.`);
  }
  for (const a of r.alerts) out.push(`Alert: ${a.title}. ${a.detail}`);
  const next = Array.from({ length: 7 }, (_, i) => addDays(r.from, 7 + i)).filter((d) => planOf(units, d).some((row) => row.kind === "workout"));
  out.push(next.length ? `Next week: ${next.length} session(s) planned.` : "Next week: nothing planned yet.");
  return out;
}

// ---- FIT-194: a coach acts on a linked client ----

/** The tools a coach can point at a client. Logging and sharing stay the client's own. */
export const CLIENT_TOOLS = new Set(["get_context", "get_day", "add_note", "find_exercises", "swap_options", "create_exercise", "edit_exercise", "clear_day",
  "propose_session", "propose_week", "apply", "undo", "get_program", "set_program", "get_progress", "get_week_review", "set_profile", "set_goal"]);
const CLIENT = { type: "string", description: "Coaches only: the client to act on, by name or id as get_context and list_clients show them. Leave it out for the caller's own training." };
for (const t of tools) if (CLIENT_TOOLS.has(t.name)) (t.inputSchema.properties as Record<string, unknown>).client = CLIENT;

const shownName = (p: Person) => p.name ?? `a client without a name (${p.uid})`;

/** The client a coach named, by uid or by name (whole, or first name when only one has it). */
export function pickClient(clients: Person[], said: string): Person {
  const s = said.trim().toLowerCase();
  const first = (p: Person) => p.name?.trim().toLowerCase().split(/\s+/)[0];
  const found = clients.filter((p) => p.uid.toLowerCase() === s);
  const named = found.length ? found : clients.filter((p) => p.name?.trim().toLowerCase() === s);
  const matched = named.length ? named : clients.filter((p) => first(p) === s);
  if (matched.length === 1) return matched[0];
  const all = clients.map((p) => `${shownName(p)} [${p.uid}]`).join("; ");
  if (matched.length > 1) throw new Error(`More than one client is called ${said}: ${matched.map((p) => `${shownName(p)} [${p.uid}]`).join("; ")}. Use the id.`);
  throw new Error(clients.length ? `No client called ${said}. Their clients: ${all}.` : "They have no clients yet. invite_client makes an invite link.");
}

/** Checked on every call: the account named is the caller's own, or a client linked to them now. */
async function clientOf(caller: string, said: unknown, store: Store): Promise<Person | undefined> {
  if (said === undefined || said === null || said === "") return undefined;
  const client = pickClient(await store.clients(caller), String(said));
  if (!(await store.coachOf(caller, client.uid))) throw new Error(`They don't coach ${shownName(client)} any more: one of them ended the link. invite_client makes a new invite if they both want it.`);
  await needsPlan(caller, store);
  return client;
}

/** The coach tools need the coach plan; without it, its Checkout (FIT-148). The athlete tools stay free. */
async function needsPlan(coach: string, store: Store) {
  if (await store.coachPlan(coach)) return;
  const url = await store.coachCheckout(coach);
  const billing = `${process.env.APP_ORIGIN ?? ""}/billing`;
  throw new Error(`Coaching needs the coach plan, ${COACH_PRICE}; their clients stay free and keep logging meanwhile. `
    + (url ? `Monthly Checkout: ${url}\nYearly, or anything else about billing: ${billing}` : `Start it on the Billing page: ${billing}`)
    + "\nGive them the link. Once they've paid, coaching works on their next request; there's nothing to reconnect.");
}
const COACH_ONLY = new Set(["list_clients", "roster_review", "invite_client"]);

export async function callTool(name: string, args: Args, account: Account, store: Store, now = new Date()): Promise<string> {
  const { tz } = account;
  if (args.client !== undefined && !CLIENT_TOOLS.has(name)) throw new Error(`${name} is the client's own to do, so it takes no client.`);
  const client = await clientOf(account.uid, args.client, store);
  if (COACH_ONLY.has(name)) await needsPlan(account.uid, store);
  // Whose data this call is about. A coach's changes reach the client's phone at its next sync, as the dashboard's do.
  const uid = client?.uid ?? account.uid;
  useAccountExercises(await store.units(uid)); // FIT-173: their own exercises, beside the catalog
  const today = dayOf(now, tz);
  const day = (args.date as string | undefined) ?? today;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error(`Not a date: ${day}. Use YYYY-MM-DD.`);
  switch (name) {
    case "get_context": {
      const units = await store.units(uid);
      const text = context(units, today, Math.min(args.days_back ?? 21, 120), Math.min(args.days_ahead ?? 7, 28), tz);
      if (client) return `Client: ${shownName(client)}, coached by them since ${client.since.slice(0, 10)}. Everything below is the client's.\n\n${text}`;
      const clients = await store.clients(uid);
      if (clients.length && !(await store.coachPlan(uid))) return `${text}\n\nThey coach ${clients.length} client${clients.length === 1 ? "" : "s"}, but their coach plan has ended, so they can't see or change them until it's paid again (any coaching tool gives the link). Their own training above is free as ever.`;
      return clients.length ? `${text}\n\nThey coach ${clients.length} client${clients.length === 1 ? "" : "s"}: ${clients.map((p) => `${shownName(p)} [${p.uid}]`).join("; ")}. To read or plan a client's training, pass client to the tool; everything above is their own.` : text;
    }
    case "invite_client": {
      const made = await store.invite(uid);
      return `Invite link: ${made.url}\nOr the code: ${made.code}, typed on "Join your coach" in the app.\nSend it to one client. They open it on their phone, install the free Barbrabell app and accept; then they're your client here. It works once, for ${INVITE_DAYS} days.`;
    }
    case "get_day": {
      const units = await store.units(uid);
      if (args.to === undefined) return describeDay(units, day);
      const to = String(args.to);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(to) || to < day) throw new Error("to is YYYY-MM-DD, on or after date.");
      if (to > addDays(day, 27)) throw new Error("At most 28 days at a time: ask for the rest in another call.");
      const days: string[] = [];
      for (let d = day; d <= to; d = addDays(d, 1)) if (planOf(units, d).length || logOf(units, d).length) days.push(describeDay(units, d));
      return days.length ? days.join("\n\n") : `Nothing planned or logged from ${day} to ${to}.`;
    }
    case "list_clients":
    case "roster_review": {
      const clients = await store.clients(uid);
      if (!clients.length) return "They have no clients yet. invite_client makes an invite link to send one.";
      const rows = await Promise.all(clients.map(async (c) => {
        if (!(await store.coachOf(uid, c.uid))) return undefined;
        const [units, thread] = await Promise.all([store.units(c.uid), store.comments(uid, c.uid)]);
        useAccountExercises(units);
        return { client: c, units, triage: triage(units, thread, new Map([...bySlug].map(([slug, e]) => [slug, e.name])), uid, today, tz) };
      }));
      const sorted = byNeed(rows.filter((r) => r !== undefined));
      if (name === "list_clients") return [`${sorted.length} client${sorted.length === 1 ? "" : "s"}, those who need them first:`, ...sorted.map((r) => `- ${rosterLine(r.client, r.triage)}`)].join("\n");
      return sorted.map((r) => `${rosterLine(r.client, r.triage)}\n${weekLines(r.units, day, Math.floor(now.getTime() / 1000), tz).map((l) => `  ${l}`).join("\n")}`).join("\n\n");
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
    case "create_exercise": {
      const fields = args as ExerciseFields;
      const taken = bySlug.get(resolveLoose(String(fields.name ?? "")) ?? "");
      if (taken) throw new Error(`${taken.name} is already ${isOwn(taken.slug) ? "one of theirs" : "in the catalog"}; plan it by that name.`);
      const body = exerciseBody(undefined, fields);
      const slug = slugFor(body.name, new Set(catalog.map((e) => e.slug)));
      await store.write(uid, [{ key: `template#${slug}`, body: encode(body) }], account.agent);
      return `Added ${body.name} (${slug}). Plan and log it by name; it shows on their phone at its next sync.`;
    }
    case "edit_exercise": {
      const units = await store.units(uid);
      const slug = resolveLoose(String(args.exercise ?? ""));
      if (!slug || !isOwn(slug)) throw new Error("Only their own exercises can be changed (create_exercise makes one).");
      const body = exerciseBody(JSON.parse(units.get(`template#${slug}`)!), args as ExerciseFields);
      await store.write(uid, [{ key: `template#${slug}`, body: encode(body) }], account.agent);
      return `Saved ${body.name}.`;
    }
    case "log_session": {
      const units = await store.units(uid);
      if (day > today) throw new Error("That day hasn't happened yet: log it on the day, or plan it with propose_session.");
      const existing = logOf(units, day);
      if (existing.some((r) => r.kind === "workout" && !isRun(r)) && !args.replace) {
        throw new Error(`${day} is already logged:\n${describeLog(existing).lines.join("\n")}\nPass replace: true to replace it, or add_note to add context.`);
      }
      const plan = planOf(units, day);
      const made = logRows(plan, startOf(units, day, tz), { sets: args.sets as SetInput[] | undefined, as_planned: args.as_planned, rpe: args.rpe, effort: args.effort, note: args.note });
      await store.write(uid, [{ key: `log#${day}`, body: encode([...existing.filter((r) => r.kind !== "workout" || isRun(r)), ...made]) }], account.agent);
      const l = describeLog(made);
      return `Logged ${weekday(day)} ${day}:\n${l.lines.join("\n")}${l.note ? `\nNote: ${l.note}` : ""}\nIt shows on their phone at its next sync.`;
    }
    case "add_note": {
      if (client) {
        await store.comment(account.uid, uid, day, String(args.note ?? ""));
        return `Replied on ${shownName(client)}'s ${weekday(day)} ${day}: ${String(args.note).trim()}\nIt shows in their app as yours.`;
      }
      const units = await store.units(uid);
      const log = logOf(units, day);
      const summary = log.find((r) => r.kind === "workout" && !r.template);
      if (!summary) throw new Error(`${day} isn't logged yet. Log the session with log_session and put the note there.`);
      summary.note = [summary.note, String(args.note).trim()].filter(Boolean).join(" ");
      await store.write(uid, [{ key: `log#${day}`, body: encode(log) }], account.agent);
      return `Noted on ${day}: ${summary.note}`;
    }
    case "log_run": {
      if (day > today) throw new Error(`${day} hasn't happened yet.`);
      const units = await store.units(uid);
      // FIT-184: what they leave out went as planned.
      const planned = planOf(units, day).find(isRun);
      const target = (metric: string) => planned?.targets.find((m) => m.metric === metric)?.value;
      const d = Math.round(args.distance !== undefined ? meters(String(args.distance)) : target("distance_m") ?? NaN);
      const t = args.time !== undefined ? seconds(String(args.time)) : target("duration_s");
      if (Number.isNaN(d) || t === undefined) {
        const missing = [Number.isNaN(d) && "distance", t === undefined && "time"].filter(Boolean).join(" and ");
        throw new Error(planned ? `The planned run has no ${missing}: ask them how ${t === undefined ? "long it took" : "far they went"}.` : `No run is planned ${day}: give its distance and time.`);
      }
      const slug = args.treadmill ? "running-treadmill" : args.treadmill === false || !planned?.template ? OUTDOOR_RUN : planned.template;
      const ms = [{ metric: "distance_m", value: d, unit: "m" }, { metric: "duration_s", value: t, unit: "s" },
        ...(args.hr_avg ? [{ metric: "hr_avg", value: Math.round(args.hr_avg), unit: "bpm" }] : [])];
      const kind = args.kind ?? planned?.note.match(/^(easy|long|tempo|intervals|race)/i)?.[1].toLowerCase();
      const note = [kind, typeof args.note === "string" ? args.note.trim() : ""].filter(Boolean).join(": ");
      const at = day === today ? Math.floor(now.getTime() / 1000) : epoch(day, 12 * 60, tz);
      const plannedRef = planned?.id;
      const log = [...logOf(units, day), { id: randomUUID().toUpperCase(), kind: "workout", at, template: slug, plannedRef, measurements: ms, note }];
      await store.write(uid, [{ key: `log#${day}`, body: encode(log) }], account.agent);
      const after = new Map([...units, [`log#${day}`, encode(log)]]);
      const moved = goalsOf(after).filter((g) => g.status === "active" && goalMeters(g.metric) !== undefined).map((g) => {
        const race = goalMeters(g.metric)!, now2 = runTime(after, profileOf(after), race);
        return now2 === undefined ? "" : `\n${distanceName(race)}: this predicts ${clock(Math.round(t * (race / d) ** 1.06))}; best so far ${clock(now2)} (goal ${clock(g.target)}).`;
      }).join("");
      return `Logged ${weekday(day)} ${day}: ${miles(d)} in ${clock(t)} (${runPace(t, d)})${args.hr_avg ? `, HR ${Math.round(args.hr_avg)}` : ""}${note ? `, ${note}` : ""}.${moved}`;
    }
    case "log_daily": {
      if (day > today) throw new Error(`${day} hasn't happened yet.`);
      const input = args as DailyInput;
      if (input.weight_lb === undefined && input.sleep_hours === undefined && input.sleep_quality === undefined && !input.note?.trim() && !input.meals?.length) {
        throw new Error("Nothing to log: give weight_lb, sleep_hours, note or meals.");
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
    case "delete_log": {
      if (args.confirm !== true) throw new Error("Ask them first, then call again with confirm: true.");
      const units = await store.units(uid);
      const log = logOf(units, day);
      if (!log.length) throw new Error(`Nothing is logged on ${day}, so there's nothing to delete. Check the date with get_day.`);
      const kinds: Record<string, string> = { workout: "workout", weight: "bodyweight", sleep: "sleep", meal: "meal" };
      let gone: typeof log;
      if (args.what === "all") gone = log;
      else if (args.what === "meal") {
        const name = String(args.meal ?? "").trim().toLowerCase();
        const meals = log.filter((r) => r.kind === "meal");
        const named = meals.filter((r) => r.note.toLowerCase() === name);
        gone = named.length ? named : meals.filter((r) => name && r.note.toLowerCase().includes(name));
        if (gone.length !== 1) throw new Error(meals.length ? `Which meal? ${day} has: ${meals.map((r) => r.note || "Meal").join("; ")}.` : `No meals logged on ${day}.`);
      } else if (kinds[args.what]) gone = log.filter((r) => r.kind === kinds[args.what]);
      else throw new Error("what is workout, weight, sleep, meal or all.");
      if (!gone.length) throw new Error(`No ${args.what} logged on ${day}. get_day shows what is.`);
      const kept = log.filter((r) => !gone.includes(r));
      await store.write(uid, [{ key: `log#${day}`, body: kept.length ? encode(kept) : null }], account.agent);
      const said = args.what === "workout" ? describeLog(gone).lines : describeDaily(gone);
      return `Deleted from ${day}${said.length ? `:\n${said.map((l) => `  ${l}`).join("\n")}` : ` (${gone.length} entr${gone.length === 1 ? "y" : "ies"}).`}\nIt goes from their phone at its next sync.`;
    }
    case "clear_day": {
      const units = await store.units(uid);
      if (!planOf(units, day).some((r) => r.kind === "workout")) throw new Error(`Nothing is planned on ${day}; it's already a rest day.`);
      return propose(uid, account.uid, tz, today, [{ date: day, exercises: [] }], String(args.reason), store);
    }
    case "propose_session":
      return propose(uid, account.uid, tz, today, [{ date: day, title: args.title, exercises: args.exercises }], String(args.reason), store);
    case "propose_week":
      return propose(uid, account.uid, tz, today, args.days as DayInput[], String(args.reason), store);
    case "apply": {
      const proposal = await store.get(account.uid, `proposal#${args.proposal_id}`);
      if (!proposal) throw new Error("No such proposal (they last 2 days). Propose again.");
      const owner = (proposal.uid as string | undefined) ?? account.uid;
      if (owner !== uid) throw new Error(`That proposal is for ${owner === account.uid ? "their own training" : "another client"}: ${owner === account.uid ? "leave client out" : `pass client ${owner}`}.`);
      if (proposal.problems?.length) throw new Error(`That proposal breaks the plan rules; fix these and propose again:\n${proposal.problems.map((p: string) => `- ${p}`).join("\n")}`);
      const days = proposal.days as { day: string; rows: string }[];
      const units = await store.units(uid);
      const logged = days.filter((d) => logOf(units, d.day).some((r) => r.kind === "workout")).map((d) => d.day);
      if (logged.length) throw new Error(`${logged.join(", ")} has been logged since; propose again without it.`);
      for (const d of days) await store.put(uid, `undo#${d.day}`, { body: units.get(`plan#${d.day}`) ?? null }, 14);
      await store.write(uid, days.map((d) => ({ key: `plan#${d.day}`, body: JSON.parse(d.rows).length ? d.rows : null })), account.agent, account.uid);
      const lines = days.map((d) => `${weekday(d.day)} ${d.day}: ${describeSession(JSON.parse(d.rows) as PlanRow[]).title ?? "rest"}`);
      return `Applied:\n${lines.join("\n")}\nIt shows on their phone at its next sync. undo (per day) puts the old session back.`;
    }
    case "undo": {
      const saved = await store.get(uid, `undo#${day}`);
      if (!saved || saved.used) throw new Error(`Nothing to undo on ${day}: undo puts back a day apply changed in the last 14 days, once. To change it now, propose_session.`);
      if (logOf(await store.units(uid), day).some((r) => r.kind === "workout")) throw new Error(`${day} has been logged since; it can't be put back.`);
      await store.write(uid, [{ key: `plan#${day}`, body: saved.body }], account.agent, account.uid);
      await store.put(uid, `undo#${day}`, { used: true }, 1);
      return `Put back ${day}'s session as it was.`;
    }
    case "get_progress":
      return describeProgress(await store.units(uid), today, Math.floor(now.getTime() / 1000), tz);
    case "get_week_review":
      return describeReview(await store.units(uid), day, Math.floor(now.getTime() / 1000), tz);
    case "share": {
      const kind = args.kind as ShareKind, show = args.show_weights !== false;
      const units = await store.units(uid);
      const profile = profileOf(units);
      let payload: Record<string, unknown> | undefined, what = "";
      if (kind === "win") {
        const program = programOf(profile, tz);
        if (!program || !profile?.programStart || !profile.targetDate) throw new Error("Wins count from a program's start; there's no program yet (set_program makes one).");
        const won = progressWins(units, today, tz);
        const win = won.find((w) => w.key === args.win);
        if (!win) throw new Error(`No win with that id. get_progress lists them${won.length ? `, e.g. ${won[0].key}` : ""}.`);
        payload = winPayload(win, show);
        what = progress.describeWin(win);
      } else if (kind === "recap") {
        const r = progress.weekReport(units, day, Math.floor(now.getTime() / 1000), tz);
        const program = programOf(profile, tz);
        payload = program && recapPayload(r, program.weeks, progressWins(units, today, tz), programSessions(units, program.start, today), show);
        if (!payload) throw new Error("A recap is a week of a program; there's no program yet (set_program makes one).");
        what = `Week ${payload.week} of ${payload.weeks}: ${(payload.sessions as any).done} of ${(payload.sessions as any).planned} sessions, ${payload.bests} new best(s)`;
      } else if (kind === "session") {
        const rows = planOf(units, day);
        if (!rows.some((r) => r.kind === "workout")) throw new Error(`Nothing is planned on ${day} to share. get_context lists the planned days.`);
        payload = sessionPayload(rows, day, tz, show);
        what = `${payload.title} on ${weekday(day)} ${day}`;
      } else if (kind === "program") {
        payload = programPayload(units, profile as any, goalsOf(units), today, tz);
        if (!payload) throw new Error("A shared program needs the program and its phases: set_program with phases first.");
        what = String(payload.name);
      } else throw new Error("kind is win, recap, session or program.");
      const made = await store.share(uid, kind, payload);
      return `Shared ${what}.\n${made.url}\nAnyone with the link can see it. stop_sharing takes it down.`;
    }
    case "stop_sharing": {
      const id = /([0-9a-f]{12})\/?$/.exec(String(args.link ?? "").trim())?.[1];
      if (!id || !(await store.unshare(uid, id))) throw new Error("That isn't one of their shared links: give the link share made, or the 12-character id at its end.");
      return "Stopped sharing it: the link now says it has expired.";
    }
    case "get_program":
      return describeProgram(await store.units(uid), today, tz);
    case "set_program": {
      const units = await store.units(uid);
      const current = units.get("profile");
      if (!current) throw new Error("Set up their profile first (set_profile: age and weight).");
      const p = JSON.parse(current);
      // FIT-174: the weights come from where they are now, so no program until each goal lift has it.
      const unknown = unknownMaxes(goalsOf(units), units, p);
      if (unknown.length) throw new Error(`Ask them first, then save with set_profile starting_sets (a 1RM is weight_lb with reps 1):\n${unknown.map((u) => `- ${u}`).join("\n")}`);
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
        if (!added.length) throw new Error("That trip doesn't miss a training day in the program, so nothing changes. get_program shows the program's dates.");
        trips = [...new Set([...trips, ...added])].sort((a, b) => a - b);
      }
      p.travelWeeks = trips;
      if (args.phases) {
        // As ProgramBrief.Stored. Main lifts by catalog name, as ProgramBrief.checked keeps them.
        const brief: Brief = { phases: (args.phases as any[]).map((x) => ({
          phase: String(x.phase), focus: String(x.focus).trim().replace(/[. \n]+$/, ""), mainLifts: [...new Set((x.main_lifts as string[]).map((l) => resolve(l).name))],
          mainReps: Math.round(x.main_reps), accessoryReps: Math.round(x.accessory_reps),
        })) };
        if (brief.phases.some((x) => !["base", "build", "peak"].includes(x.phase))) throw new Error("Each phase is base, build or peak.");
        p.brief = { brief, key: "", model: account.agent };
      }
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
      const name = typeof args.name === "string" ? args.name.trim().slice(0, 40) : "";
      if (name && client) throw new Error("A client's name is theirs to set, in the app.");
      if (name) await store.setName(uid, name);
      if (Object.keys(args).every((k) => k === "name")) {
        if (!name) throw new Error("Nothing to save: give at least one field.");
        return `Saved: they're ${name} on what they share.`;
      }
      const merged = mergeProfile(current ? JSON.parse(current) : undefined, args as ProfileInput);
      await store.write(uid, [{ key: "profile", body: encode(merged) }], account.agent);
      const days = ((merged.trainingDays ?? []) as number[]).map((d) => WEEKDAYS[d]).join(", ");
      return `Saved. Age ${merged.age}, ${merged.weightLb} lb; trains ${days}, ${merged.sessionMinutes} min at ${String(Math.floor(merged.workoutTime / 60)).padStart(2, "0")}:${String(merged.workoutTime % 60).padStart(2, "0")}; `
        + `equipment ${((merged.equipment ?? []) as string[]).join(", ") || "none"}; injured ${((merged.injuredAreas ?? []) as string[]).join(", ") || "none"}; never ${((merged.avoidExercises ?? []) as string[]).map(nameOf).join(", ") || "none"}; `
        + `${merged.style}; ${(merged.starts ?? []).length} starting set(s).`;
    }
    case "set_goal": {
      const units = await store.units(uid);
      const by = args.by as string | undefined;
      if (by !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(by)) throw new Error("by is YYYY-MM-DD.");
      const deadline = by ? epoch(by, 12 * 60, tz) : undefined;
      if (args.action === "add") {
        if (!args.type || (args.type !== "timed_distance" && args.target === undefined)) throw new Error("A new goal needs its type and target.");
        const body = goalBody(args as GoalInput, deadline);
        body.baseline = baselineOf(units, body.metric);
        const id = randomUUID().toUpperCase();
        await store.write(uid, [{ key: `goal#${id}`, body: encode(body) }], account.agent);
        const race = goalMeters(body.metric);
        if (race !== undefined) {
          return `Added: ${distanceName(race)} in ${clock(body.target)}${by ? ` by ${by}` : ""} [goal_id ${id}].`
            + (body.baseline !== undefined ? ` Their runs put them at ${clock(body.baseline)} now.` : " Ask for their last race or a recent hard run (distance and time) and save it as a starting set.");
        }
        return `Added: ${body.metric} ${body.target} ${body.unit}${by ? ` by ${by}` : ""} [goal_id ${id}].`;
      }
      const current = units.get(`goal#${args.goal_id}`);
      if (!current) throw new Error("No goal with that goal_id; get_context lists them.");
      const goal = JSON.parse(current);
      if (args.action === "drop") goal.status = "abandoned";
      else {
        if (args.target !== undefined) goal.target = args.target;
        if (args.time !== undefined && goalMeters(goal.metric) !== undefined) goal.target = seconds(args.time);
        if (deadline !== undefined) goal.deadline = deadline;
      }
      await store.write(uid, [{ key: `goal#${args.goal_id}`, body: encode(goal) }], account.agent);
      return args.action === "drop" ? "Dropped." : `Changed: ${goal.metric} ${goal.target} ${goal.unit}${by ? ` by ${by}` : ""}.`;
    }
    default:
      throw new Error(`Unknown tool ${name}. The tools: ${tools.map((t) => t.name).join(", ")}.`);
  }
}

// ---- MCP over HTTP ----

/** FIT-208: what an agent reads first, in short paragraphs it can follow step by step. */
const INSTRUCTIONS = [
  "Barbrabell holds a person's strength training: goals, a multi-week program, planned sessions and what they logged, shared with their phone app. In every tool, \"they\" is the person whose training it is: the caller, or the client a coach names with client.",
  "Start with get_context. If it says NOT SET UP YET, be their coach getting to know them: ask one topic at a time (goals with dates, schedule, equipment, injuries, age and weight, and a 1RM or recent heavy set for each goal lift: no program or weights without it), saving each answer with set_profile and set_goal; then lay out the program to their goal date with set_program, propose_week for the first days, and apply when they agree.",
  "Day to day: log what they did with log_session, log_run and log_daily, with RPE and their notes. Change days with propose_session, propose_week or clear_day: nothing changes until apply, so show the change and apply only once they agree; undo reverses an apply. Near the end of each week, review it (get_week_review) and plan the next from get_program and their logs. Ask before delete_log, and before share (it makes a public link).",
  "Coaches: if get_context lists clients, the caller coaches them. list_clients and roster_review show who needs them; pass client to read or plan one client's training, and to add_note a reply on their session. Logging and sharing stay the client's. Changes reach the client's phone at its next sync. Coaching needs the coach plan; when it has lapsed, the tools say so with the link to pay.",
  "To give one client's block to another: get_day with to on the first, then propose_week for the second with loads from the second's own maxes (ask for a starting set if there's none).",
  "To bring in a client's existing program (a pasted sheet, CSV, PDF or screenshot): get_context with client; save the maxes it's based on with set_profile starting_sets, and the equipment it needs; set_program with start on its first week, weeks its length plus one (the last week is a light test week), and deload_every its deload spacing (12 when it has none); then propose_week its days, up to 6 weeks a call, in the coach's numbers: percent_1rm for percentages, rpe for RPE (10 minus RIR), the same superset number for A1/A2, reps the low end of a range, and note for tempo, rest, the range or AMRAP. Check the names it matched loosely, show the coach, and apply.",
].join("\n\n");

type Rpc = { jsonrpc: "2.0"; id?: string | number | null; method: string; params?: any };

export async function answer(message: Rpc, account: Account, store: Store, now = new Date()) {
  const reply = (result: unknown) => ({ jsonrpc: "2.0", id: message.id ?? null, result });
  switch (message.method) {
    case "initialize": {
      const asked = message.params?.protocolVersion;
      return reply({
        protocolVersion: typeof asked === "string" && /^\d{4}-\d{2}-\d{2}$/.test(asked) ? asked : "2025-06-18",
        capabilities: { tools: {}, prompts: {} },
        serverInfo: { name: "Barbrabell", version: "0.1.0" },
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
      return reply({});
    case "tools/list":
      return reply({ tools });
    case "prompts/list":
      return reply({ prompts: listedPrompts() });
    case "prompts/get": {
      const got = renderPrompt(String(message.params?.name ?? ""), message.params?.arguments ?? {});
      if (!got) return { jsonrpc: "2.0", id: message.id ?? null, error: { code: -32602, message: `Unknown prompt: ${message.params?.name}` } };
      return reply(got);
    }
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
  // FIT-236: Cognito checks the password itself (USER_PASSWORD_AUTH on this client), so no hosted page offers sign-up.
  async passwordSignIn(email, password) {
    const response = await fetch(`https://cognito-idp.${process.env.AWS_REGION}.amazonaws.com/`, {
      method: "POST",
      headers: { "Content-Type": "application/x-amz-json-1.1", "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth" },
      body: JSON.stringify({ AuthFlow: "USER_PASSWORD_AUTH", ClientId: CLIENT_ID, AuthParameters: { USERNAME: email, PASSWORD: password } }),
    });
    const out = (await response.json()) as { __type?: string; AuthenticationResult?: { IdToken: string } };
    // Wrong password and no such user both say NotAuthorized (preventUserExistenceErrors); a challenge (a temporary
    // password) can't be answered here.
    if (out.__type?.endsWith("NotAuthorizedException") || out.__type?.endsWith("UserNotFoundException") || (response.ok && !out.AuthenticationResult)) return undefined;
    if (!response.ok) throw new Error(`Cognito sign-in failed (${response.status}): ${out.__type}`);
    const claims = JSON.parse(Buffer.from(out.AuthenticationResult!.IdToken.split(".")[1], "base64url").toString());
    if (claims.aud !== CLIENT_ID || typeof claims.sub !== "string") throw new Error("Unexpected id token");
    return { uid: claims.sub };
  },
};

export async function handler(event: LambdaFunctionURLEvent) {
  return (ORIGIN && (await oauth(event, authStore, config))) || serve(event, dynamoStore, ORIGIN || undefined);
}
