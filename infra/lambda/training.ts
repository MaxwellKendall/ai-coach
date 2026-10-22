import { randomUUID } from "node:crypto";
import seed from "../../Resources/Seed/exercises.json" with { type: "json" };
import { checkIn } from "../../shared/triage.ts";
import { clock, distanceName, goalMeters, meters, miles, MILE, OUTDOOR_RUN, pace, riegel, RUNS, runMetric, seconds } from "./running.ts";

// FIT-149: the training data an agent reads and writes, as the app keeps it in FIT-126's sync units
// (Core/Cloud/SyncUnits.swift: times in seconds since 1970, keys sorted, nil left out). Pure, so it's tested without a
// server. The rules are the web's (web/src/guard.ts, progress.ts), which hold the app's PlanGuard and Training limits;
// web/src can't be imported here (its imports have no file extensions), so the few needed are repeated and cited.

export type Measurement = { metric: string; value: number; unit: string };
export type PlanRow = {
  id: string; kind: string; at: number; slot?: string; template?: string; targets: Measurement[]; note: string;
  adjustedReason?: string; group?: number; main: boolean; pinned: boolean;
};
export type LogRow = { id: string; kind: string; at: number; plannedRef?: string; template?: string; measurements: Measurement[]; note: string };
export type Goal = { kind: string; metric: string; target: number; unit: string; deadline?: number; baseline?: number; status: string };
export type Profile = {
  age?: number; weightLb?: number; daysPerWeek?: number; sessionMinutes?: number; trainingDays?: number[]; workoutTime?: number;
  equipment?: string[]; injuredAreas?: string[]; avoidExercises?: string[]; maxWeeklySets?: number; style?: string;
  programStart?: number; targetDate?: number; deloadEveryWeeks?: number; travelWeeks?: number[];
};
export type Units = Map<string, string>;

export const WARMUP = "warm-up"; // TrainingGenerator.warmupNote
const UNITS: Record<string, string> = {
  sets: "sets", reps: "reps", duration_s: "s", distance_m: "m", load_lb: "lb", load_lb_hand: "lb/hand", rpe: "RPE",
  effort: "/10", completion_rate: "ratio", weight_lb: "lb", hr_avg: "bpm", sleep_h: "h", sleep_quality: "/5", kcal: "kcal", protein_g: "g",
};
const m = (metric: string, value: number): Measurement => ({ metric, value, unit: UNITS[metric] ?? "" });
const value = (list: Measurement[], metric: string) => list.find((x) => x.metric === metric)?.value;

// ---- Catalog ----

export type Exercise = {
  slug: string; name: string; pattern?: string; equipment: string[]; tags: string[]; muscles: string[]; substitutes: string[]; aliases: string[];
};
type SeedTemplate = { slug: string; name: string; attributes: { key: string; values: string[] }[] };
const attr = (t: SeedTemplate, key: string) => t.attributes.find((a) => a.key === key)?.values ?? [];
export const catalog: Exercise[] = (seed as SeedTemplate[]).map((t) => ({
  slug: t.slug, name: t.name, pattern: attr(t, "movement_pattern")[0], equipment: attr(t, "equipment"), tags: attr(t, "tags"),
  muscles: attr(t, "muscles_primary"), substitutes: attr(t, "substitutes"), aliases: attr(t, "aliases"),
}));
export const bySlug = new Map(catalog.map((e) => [e.slug, e]));

// ---- FIT-173: the person's own exercises (template#slug units, as SyncUnits.TemplateBody) ----

export const PATTERNS = [...new Set(catalog.flatMap((e) => (e.pattern ? [e.pattern] : [])))].sort();
export const MUSCLES = [...new Set(catalog.flatMap((e) => e.muscles))].sort();
const bundled = new Set(catalog.map((e) => e.slug));
let own: Exercise[] = [];

/** Whether a slug is one of the person's own exercises (loaded by useAccountExercises). */
export const isOwn = (slug: string) => own.some((e) => e.slug === slug);

/**
 * Adds the account's own exercises to the catalog for this call, so every lookup, search and rule sees them. A Lambda
 * runs one event at a time, so the last account's are simply swapped out.
 */
export function useAccountExercises(units: Units) {
  for (const e of own) bySlug.delete(e.slug);
  catalog.splice(catalog.length - own.length, own.length);
  own = [...units].filter(([k]) => k.startsWith("template#") && !bundled.has(k.slice(9))).flatMap(([k, body]) => {
    const t = JSON.parse(body) as { kind: string; name: string; attributes: { key: string; values: string[] }[] };
    return t.kind === "exercise" ? [toExercise({ slug: k.slice(9), name: t.name, attributes: t.attributes })] : [];
  });
  catalog.push(...own);
  for (const e of own) bySlug.set(e.slug, e);
}

function toExercise(t: SeedTemplate): Exercise {
  return { slug: t.slug, name: t.name, pattern: attr(t, "movement_pattern")[0], equipment: attr(t, "equipment"), tags: attr(t, "tags"),
    muscles: attr(t, "muscles_primary"), substitutes: attr(t, "substitutes"), aliases: attr(t, "aliases") };
}

/** Slug.unique: "Landmine Press" → "landmine-press", numbered past any taken. */
export function slugFor(name: string, taken: Set<string>) {
  const base = name.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().split(/[^a-z0-9]+/).filter(Boolean).join("-") || "item";
  let slug = base;
  for (let n = 2; taken.has(slug); n++) slug = `${base}-${n}`;
  return slug;
}

export type ExerciseFields = { name?: string; pattern?: string; equipment?: string[]; muscles?: string[]; cues?: string[] };

/** A template body for an exercise of their own, the fields checked against the catalog's own lists. */
export function exerciseBody(current: { name: string; attributes: { key: string; values: string[] }[] } | undefined, input: ExerciseFields) {
  const name = (input.name ?? current?.name ?? "").trim();
  if (!name || name.length > 60) throw new Error("An exercise needs a name (60 characters at most).");
  const attributes = new Map((current?.attributes ?? []).map((a) => [a.key, a.values]));
  if (input.pattern !== undefined) {
    if (!PATTERNS.includes(input.pattern)) throw new Error(`pattern is one of ${PATTERNS.join(", ")}.`);
    attributes.set("movement_pattern", [input.pattern]);
  }
  if (input.equipment !== undefined) {
    const bad = input.equipment.filter((e) => !EQUIPMENT.includes(e));
    if (bad.length) throw new Error(`Unknown equipment ${bad.join(", ")}. Use: ${EQUIPMENT.join(", ")}; [] for bodyweight.`);
    attributes.set("equipment", [...new Set(input.equipment)]);
  }
  if (input.muscles !== undefined) {
    const bad = input.muscles.filter((x) => !MUSCLES.includes(x));
    if (bad.length) throw new Error(`Unknown muscles ${bad.join(", ")}. Use: ${MUSCLES.join(", ")}.`);
    attributes.set("muscles_primary", [...new Set(input.muscles)]);
  }
  if (input.cues !== undefined) attributes.set("cues", input.cues.map((c) => c.trim()).filter(Boolean));
  if (!attributes.get("movement_pattern")?.length) throw new Error(`Say its movement pattern: ${PATTERNS.join(", ")}.`);
  if (!attributes.has("equipment")) attributes.set("equipment", []);
  return { kind: "exercise", name, attributes: [...attributes].map(([key, values]) => ({ key, values })).sort((a, b) => a.key.localeCompare(b.key)) };
}
export const nameOf = (slug?: string) => (slug && bySlug.get(slug)?.name) ?? slug ?? "Exercise";

// FIT-218: how coaches' spreadsheets abbreviate and spell the names.
const SAID: Record<string, string> = { db: "dumbbell", bb: "barbell", kb: "kettlebell", ohp: "overhead press", rdl: "romanian deadlift",
  sldl: "stiff legged deadlift", pullup: "pull up", chinup: "chin up", pushup: "push up", flye: "fly", flie: "fly" };
const words = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().split(" ").filter(Boolean)
  .map((w) => (w.length > 2 && w.endsWith("s") && !w.endsWith("ss") ? w.slice(0, -1) : w)).flatMap((w) => (SAID[w] ?? w).split(" "));
/** Common names whose closest catalog wording is a variant: "Overhead Press" is the standing barbell one. */
const COMMON: Record<string, string> = { "overhead press": "standing-military-press", "military press": "standing-military-press",
  dip: "dips-chest-version", "cable fly": "cable-crossover" };
/** Goal lifts, then staples, then the rest: "Barbell Row" is the bent-over row, not the upright one. */
const rank = (e: Exercise) => (e.tags.includes("goal_lift") ? 0 : e.tags.includes("staple") ? 1 : 2);

/** Whether an agent named an exercise exactly (slug, name or alias), rather than loosely. */
export const exactly = (said: string) =>
  bySlug.has(said) || catalog.some((e) => e.name.toLowerCase() === said.toLowerCase() || e.aliases.some((a) => a.toLowerCase() === said.toLowerCase()));

/** A catalog exercise from a slug or a name an agent wrote ("Bench Press", "RDL", "romanian deadlifts"). */
export function resolve(said: string): Exercise {
  const exact = bySlug.get(said) ?? catalog.find((e) => e.name.toLowerCase() === said.toLowerCase() || e.aliases.some((a) => a.toLowerCase() === said.toLowerCase()));
  if (exact) return exact;
  const want = words(said);
  const common = bySlug.get(COMMON[want.join(" ")] ?? "");
  if (common) return common;
  const scored = catalog
    .map((e) => {
      const have = new Set([...words(e.name), ...e.aliases.flatMap(words)]);
      return { e, hit: want.filter((w) => have.has(w)).length, extra: have.size - want.length };
    })
    .filter((s) => s.hit === want.length)
    .sort((a, b) => rank(a.e) - rank(b.e) || a.extra - b.extra || a.e.name.length - b.e.name.length);
  if (scored.length) return scored[0].e;
  const near = catalog.filter((e) => want.some((w) => words(e.name).includes(w))).slice(0, 6).map((e) => `${e.name} (${e.slug})`);
  throw new Error(`No exercise called "${said}" in the catalog.${near.length ? ` Close: ${near.join(", ")}.` : ""} Use find_exercises.`);
}

/** Catalog search for an agent: name words, movement pattern or muscle. */
export function find(query: string, profile?: Profile, limit = 12): Exercise[] {
  const want = words(query);
  return catalog
    .filter((e) => want.every((w) => words(e.name).includes(w) || e.pattern === w || e.muscles.includes(w) || e.tags.includes(w)))
    .filter((e) => usable(e, profile))
    .slice(0, limit);
}

/** The profile's equipment allows it, and it isn't one they avoid. Without equipment on file, anything goes. */
export const usable = (e: Exercise, profile?: Profile) =>
  !(profile?.avoidExercises ?? []).includes(e.slug) && (!profile?.equipment?.length || e.equipment.every((k) => profile.equipment!.includes(k)));

/** Alternatives for the same movement: the card's own substitutes first, then those sharing the most primary muscles. */
export function swapOptions(slug: string, profile?: Profile, limit = 8): Exercise[] {
  const of = bySlug.get(slug);
  if (!of) return [];
  const shared = (e: Exercise) => e.muscles.filter((x) => of.muscles.includes(x)).length;
  return catalog
    .filter((e) => e.slug !== slug && usable(e, profile) && (e.pattern === of.pattern || of.substitutes.includes(e.slug)))
    .sort((a, b) => Number(of.substitutes.includes(b.slug)) - Number(of.substitutes.includes(a.slug)) || shared(b) - shared(a))
    .slice(0, limit);
}

// ---- Days in the person's time zone ----

/** "2026-10-17" for an instant, in `tz`. */
export function dayOf(at: Date, tz: string) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(at);
}

/** Seconds since 1970 for a local day and minutes after midnight in `tz`. */
export function epoch(day: string, minutes: number, tz: string) {
  const [y, mo, d] = day.split("-").map(Number);
  const guess = Date.UTC(y, mo - 1, d, 0, minutes);
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })
    .formatToParts(new Date(guess));
  const get = (t: string) => Number(parts.find((p) => p.type === t)!.value);
  const shown = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"));
  return (guess - (shown - guess)) / 1000;
}

export function addDays(day: string, n: number) {
  const [y, mo, d] = day.split("-").map(Number);
  const date = new Date(Date.UTC(y, mo - 1, d + n));
  return date.toISOString().slice(0, 10);
}

export const weekday = (day: string) => new Date(`${day}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });

// ---- Units ----

/** The app's encoding: keys sorted, nothing for nil. */
export function encode(value: unknown): string {
  return JSON.stringify(value, (_, v) =>
    v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.keys(v).sort().filter((k) => v[k] !== undefined).map((k) => [k, v[k]])) : v);
}
const rows = <T>(units: Units, key: string): T[] => {
  const body = units.get(key);
  return body ? (JSON.parse(body) as T[]) : [];
};
export const planOf = (units: Units, day: string) => rows<PlanRow>(units, `plan#${day}`);
export const logOf = (units: Units, day: string) => rows<LogRow>(units, `log#${day}`);
export const profileOf = (units: Units): Profile | undefined => (units.get("profile") ? JSON.parse(units.get("profile")!) : undefined);
export const goalsOf = (units: Units): (Goal & { id: string })[] =>
  [...units].filter(([k]) => k.startsWith("goal#")).map(([k, b]) => ({ ...(JSON.parse(b) as Goal), id: k.slice(5) })).filter((g) => g.status === "active");

const working = (r: PlanRow) => r.kind === "workout" && r.note !== WARMUP;
/** FIT-178: a run in the plan, which the sets and load rules leave alone. */
export const isRun = (r: { template?: string }) => !!r.template && RUNS.includes(r.template);
const lifting = (r: PlanRow) => working(r) && !isRun(r);
/** A run that's hard work: tempo, intervals or a race (its kind is the row's note). */
export const isHardRun = (r: PlanRow) => isRun(r) && /^(tempo|intervals|race)/i.test(r.note);

// ---- Reading ----

/** "4 × 6 @ 170 lb · RPE 8", per exercise, from plan rows (one row per set or per exercise, as the app writes either). */
export function sessionLines(plan: PlanRow[]) {
  const out: { slug?: string; sets: number; targets: Measurement[]; main: boolean; group?: number; note?: string }[] = [];
  for (const row of [...plan].filter(working).sort((a, b) => a.at - b.at)) {
    const targets = row.targets.filter((x) => x.metric !== "sets");
    const sets = value(row.targets, "sets") ?? 1;
    const note = row.note || undefined;
    const last = out[out.length - 1];
    if (last && last.slug === row.template && last.note === note && JSON.stringify(last.targets) === JSON.stringify(targets)) last.sets += sets;
    else out.push({ slug: row.template, sets, targets, main: row.main, group: row.group ?? undefined, note });
  }
  return out;
}

/** "5 mi · 45 min · easy". */
export function describeRun(t: Measurement[], note?: string) {
  const d = value(t, "distance_m"), s = value(t, "duration_s");
  return [d ? miles(d) : "", s ? `${Math.round(s / 60)} min` : "", note ?? ""].filter(Boolean).join(" · ") || "a run";
}

export function describeTargets(sets: number, t: Measurement[]) {
  const reps = value(t, "reps"), seconds = value(t, "duration_s"), meters = value(t, "distance_m");
  let text = reps !== undefined ? `${sets} × ${reps}` : seconds !== undefined ? `${sets} × ${seconds} s` : meters !== undefined ? `${sets} × ${meters} m` : `${sets} sets`;
  const load = value(t, "load_lb"), hand = value(t, "load_lb_hand"), rpe = value(t, "rpe");
  if (load) text += ` @ ${load} lb`;
  else if (hand) text += ` @ ${hand} lb/hand`;
  if (rpe) text += ` · RPE ${rpe}`;
  return text;
}

/** A session line's dose, and a lift's coach note (FIT-218: tempo, rest, a rep range). */
const line = (l: ReturnType<typeof sessionLines>[number]) =>
  l.slug && RUNS.includes(l.slug) ? describeRun(l.targets, l.note) : `${describeTargets(l.sets, l.targets)}${l.note && l.note !== WARMUP ? ` — “${l.note}”` : ""}`;

export function describeSession(plan: PlanRow[]) {
  const title = plan.find((r) => r.kind === "workout" && r.slot)?.slot;
  const lines = sessionLines(plan).map((l) => `${l.main ? "★ " : ""}${nameOf(l.slug)} (${l.slug}): ${line(l)}${l.group ? ` [superset ${l.group}]` : ""}`);
  return { title, lines };
}

/** "Back Squat 205×5 @7, 205×5 @8" per exercise, and the session's note. */
export function describeLog(log: LogRow[]) {
  const sets = log.filter((r) => r.kind === "workout" && r.template && !RUNS.includes(r.template));
  const runs = log.filter((r) => r.kind === "workout" && r.template && RUNS.includes(r.template)).map((r) => {
    const d = value(r.measurements, "distance_m"), t = value(r.measurements, "duration_s"), hr = value(r.measurements, "hr_avg");
    return `${nameOf(r.template)}: ${d ? miles(d) : ""}${d && t ? " in " : ""}${t ? clock(t) : ""}${d && t ? ` (${pace(t, d)})` : ""}${hr ? `, HR ${hr}` : ""}${r.note ? ` · ${r.note}` : ""}`;
  });
  const byExercise = new Map<string, string[]>();
  for (const s of sets) {
    const reps = value(s.measurements, "reps"), sec = value(s.measurements, "duration_s");
    const load = value(s.measurements, "load_lb") ?? value(s.measurements, "load_lb_hand");
    const rpe = value(s.measurements, "rpe");
    const one = `${load ? `${load}×` : ""}${reps ?? (sec !== undefined ? `${sec}s` : "?")}${rpe ? ` @${rpe}` : ""}`;
    byExercise.set(s.template!, [...(byExercise.get(s.template!) ?? []), one]);
  }
  const summary = log.find((r) => r.kind === "workout" && !r.template);
  const notes = [...new Set(log.filter((r) => r.kind === "workout" && !r.template && r.note).map((r) => r.note))];
  return {
    lines: [...[...byExercise].map(([slug, list]) => `${nameOf(slug)}: ${list.join(", ")}`), ...runs],
    note: notes.join(" "),
    effort: summary ? value(summary.measurements, "effort") : undefined,
  };
}

// ---- FIT-166: weight, sleep and meals, as LogDraftEntry saves them ----

export type DailyInput = {
  weight_lb?: number; sleep_hours?: number; sleep_quality?: number; time?: string; note?: string;
  meals?: { name: string; kcal?: number; protein_g?: number; time?: string }[];
};

/**
 * A day's log with these added: a weigh-in (kind bodyweight, weight_lb) and a night's sleep (kind sleep, sleep_h and
 * sleep_quality 1–5) replace that day's own, a meal (kind meal, its name as the note, kcal, protein_g) is added. The
 * workout rows stay as they are. `at` gives the moment for an HH:MM, or the default one. A note goes where the app's
 * check-in puts it (FIT-204): on the day's sleep row, else its weight row, else a weight row with no weight.
 */
export function dailyRows(log: LogRow[], input: DailyInput, at: (time?: string) => number): LogRow[] {
  let out = [...log];
  const add = (kind: string, ms: (Measurement | undefined)[], note: string, time?: string) =>
    out.push({ id: uuid(), kind, at: at(time), measurements: ms.filter((x): x is Measurement => !!x), note });
  if (input.weight_lb !== undefined) {
    if (!(input.weight_lb > 50 && input.weight_lb < 700)) throw new Error("weight_lb is their body weight in pounds.");
    out = out.filter((r) => r.kind !== "bodyweight");
    add("bodyweight", [m("weight_lb", input.weight_lb)], "", input.time);
  }
  if (input.sleep_hours !== undefined || input.sleep_quality !== undefined) {
    if (input.sleep_hours === undefined || input.sleep_hours < 0 || input.sleep_hours > 24) throw new Error("sleep_hours is how long they slept, 0–24.");
    out = out.filter((r) => r.kind !== "sleep");
    const quality = input.sleep_quality === undefined ? undefined : m("sleep_quality", Math.min(5, Math.max(1, Math.round(input.sleep_quality))));
    add("sleep", [m("sleep_h", input.sleep_hours), quality], "", input.time);
  }
  const note = input.note?.trim();
  if (note) {
    const holder = out.find((r) => r.kind === "sleep") ?? out.find((r) => r.kind === "bodyweight");
    if (holder) out = out.map((r) => (r === holder ? { ...r, note } : r));
    else add("bodyweight", [], note, input.time);
  }
  for (const meal of input.meals ?? []) {
    if (!meal.name?.trim()) throw new Error("Each meal needs a name, as they said it.");
    add("meal", [meal.kcal === undefined ? undefined : m("kcal", Math.round(meal.kcal)), meal.protein_g === undefined ? undefined : m("protein_g", Math.round(meal.protein_g))],
      meal.name.trim(), meal.time);
  }
  return out;
}

/** Weight, sleep and meals in a day's log, one line each, meals with the day's totals. */
export function describeDaily(log: LogRow[]): string[] {
  const out: string[] = [];
  const weight = log.filter((r) => r.kind === "bodyweight").map((r) => value(r.measurements, "weight_lb")).find((v) => v !== undefined);
  if (weight !== undefined) out.push(`Weight ${weight} lb`);
  for (const r of log.filter((r) => r.kind === "sleep")) {
    const q = value(r.measurements, "sleep_quality");
    out.push(`Sleep ${value(r.measurements, "sleep_h") ?? "?"} h${q ? ` (quality ${q}/5)` : ""}`);
  }
  const note = checkIn(log)?.note;
  if (note) out.push(`Check-in note: ${note}`);
  const meals = log.filter((r) => r.kind === "meal").sort((a, b) => a.at - b.at);
  if (meals.length) {
    const kcal = meals.reduce((n, r) => n + (value(r.measurements, "kcal") ?? 0), 0);
    const protein = meals.reduce((n, r) => n + (value(r.measurements, "protein_g") ?? 0), 0);
    const one = (r: LogRow) => [r.note || "Meal", value(r.measurements, "kcal") !== undefined ? `${value(r.measurements, "kcal")} kcal` : "",
      value(r.measurements, "protein_g") !== undefined ? `${value(r.measurements, "protein_g")} g protein` : ""].filter(Boolean).join(" ");
    out.push(`Meals: ${meals.map(one).join("; ")} — ${kcal} kcal, ${protein} g protein in all`);
  }
  return out;
}

/** Every weigh-in, oldest first (GoalProgress's weighIns). */
export function weighIns(units: Units): { day: string; lb: number }[] {
  const out: { day: string; lb: number }[] = [];
  for (const [key] of units) {
    if (!key.startsWith("log#")) continue;
    const day = key.slice(4);
    for (const r of logOf(units, day).filter((r) => r.kind === "bodyweight")) {
      const lb = value(r.measurements, "weight_lb");
      if (lb !== undefined) out.push({ day, lb });
    }
  }
  return out.sort((a, b) => a.day.localeCompare(b.day));
}

export type LoggedSet = { day: string; exercise: string; load?: number; reps?: number; rpe?: number };
export function loggedSets(units: Units): LoggedSet[] {
  const out: LoggedSet[] = [];
  for (const [key, body] of units) {
    if (!key.startsWith("log#")) continue;
    for (const r of JSON.parse(body) as LogRow[]) {
      if (r.kind !== "workout" || !r.template) continue;
      out.push({ day: key.slice(4), exercise: r.template, load: value(r.measurements, "load_lb"), reps: value(r.measurements, "reps"), rpe: value(r.measurements, "rpe") });
    }
  }
  return out.sort((a, b) => a.day.localeCompare(b.day));
}

/** Brzycki, as web/src/progress.ts and the app's Training: 1–10 reps at RPE ≤ 8 (fitness-planner CLAUDE.md "1RM Estimation"). */
export function estimated1RM(load: number, reps: number, rpe?: number) {
  if (reps < 1 || reps > 10 || (rpe ?? 0) > 8) return undefined;
  return (load * 36) / (37 - reps);
}

/** Best estimated max for an exercise by `day` (estimates never regress), or undefined without a usable set. */
export function bestBy(sets: LoggedSet[], exercise: string, day: string) {
  let best: number | undefined;
  for (const s of sets) {
    if (s.exercise !== exercise || s.day > day || s.load === undefined || s.reps === undefined) continue;
    const e = estimated1RM(s.load, s.reps, s.rpe);
    if (e !== undefined) best = Math.max(best ?? 0, e);
  }
  return best;
}

// ---- Plan rules (web/src/guard.ts, from Core/Generators/PlanGuard.swift, FIT-71) ----

const MAX_SETS = { main: 5, accessory: 4 };
const MIN_SETS = 2;
const BARBELL = ["barbell", "trap_bar", "ez_bar"];

/** AgeTier.of(age): RPE caps for main lifts and accessories (fitness-planner CLAUDE.md "Intensity by tier"). */
export function rpeCaps(age: number) {
  if (age < 30) return { main: 9, accessory: 8 };
  if (age < 40) return { main: 8, accessory: 7 };
  if (age < 50) return { main: 7, accessory: 7 };
  if (age < 60) return { main: 7, accessory: 6 };
  return { main: 6, accessory: 6 };
}

/** What breaks the rules in one day's session; empty when it's fine. A light week allows one set (PlanGuard). */
export function checkDay(plan: PlanRow[], profile?: Profile, least = MIN_SETS): string[] {
  const out: string[] = [];
  const caps = profile?.age ? rpeCaps(profile.age) : undefined;
  const sets = new Map<string, { n: number; main: boolean }>();
  for (const r of plan.filter(lifting)) {
    const k = r.template ?? "";
    const so = sets.get(k) ?? { n: 0, main: false };
    sets.set(k, { n: so.n + (value(r.targets, "sets") ?? 1), main: so.main || r.main });
  }
  for (const [slug, { n, main }] of sets) {
    const most = main ? MAX_SETS.main : MAX_SETS.accessory;
    if (n > most) out.push(`${nameOf(slug)}: ${n} sets is more than the ${most} allowed for ${main ? "a main lift" : "an accessory"}.`);
    else if (n < least) out.push(`${nameOf(slug)}: ${n} set is fewer than the ${least} minimum.`);
  }
  for (const r of plan.filter(lifting)) {
    const e = r.template ? bySlug.get(r.template) : undefined;
    const rpe = value(r.targets, "rpe"), cap = caps && (r.main ? caps.main : caps.accessory);
    if (cap !== undefined && rpe !== undefined && rpe > cap) out.push(`${nameOf(r.template)}: RPE ${rpe} is over ${cap}, the cap at age ${profile!.age} for ${r.main ? "a main lift" : "an accessory"}.`);
    const load = value(r.targets, "load_lb");
    if (e && load !== undefined && e.equipment.some((k) => BARBELL.includes(k)) && load % 5 !== 0) out.push(`${e.name}: ${load} lb isn't a 5 lb step on a barbell.`);
    if (e && !usable(e, profile)) {
      out.push((profile?.avoidExercises ?? []).includes(e.slug) ? `${e.name} is on their never list.`
        : `${e.name} needs ${e.equipment.filter((k) => !profile!.equipment!.includes(k)).join(" and ").replace(/_/g, " ")}, which they don't have.`);
    }
  }
  return [...new Set(out)];
}

export function weeklySets(days: PlanRow[][]) {
  return days.flatMap((d) => d.filter(lifting)).reduce((sum, r) => sum + (value(r.targets, "sets") ?? 1), 0);
}

// ---- Writing ----

const uuid = () => randomUUID().toUpperCase();

export type ExerciseInput = {
  exercise: string; sets?: number; distance_mi?: number; distance_km?: number; minutes?: number; run?: string; reps?: number; seconds?: number; weight_lb?: number; weight_lb_per_hand?: number; rpe?: number;
  percent_1rm?: number; main?: boolean; superset?: number; note?: string;
};

/** A day's new session: one row per exercise, in order, pinned so the app's weekly planning keeps it. Other kinds stay. */
export function sessionRows(existing: PlanRow[], title: string, exercises: ExerciseInput[], start: number, reason: string): PlanRow[] {
  const kept = existing.filter((r) => r.kind !== "workout");
  const made = exercises.map((x, i): PlanRow => {
    const e = resolve(x.exercise);
    if (RUNS.includes(e.slug)) {
      // FIT-178: a run is one row: its distance and/or time, its kind as the note.
      // FIT-186: planned in miles, as the app shows runs; km still read.
      const distance = x.distance_mi !== undefined ? x.distance_mi * MILE : x.distance_km !== undefined ? x.distance_km * 1000 : undefined;
      if (distance === undefined && x.minutes === undefined) throw new Error(`${e.name}: give distance_mi or minutes.`);
      const run = [m("sets", 1), ...(distance !== undefined ? [m("distance_m", Math.round(distance))] : []), ...(x.minutes !== undefined ? [m("duration_s", Math.round(x.minutes * 60))] : [])];
      return { id: uuid(), kind: "workout", at: start + i, slot: title, template: e.slug, targets: run, note: x.run ?? "easy", adjustedReason: reason, group: x.superset, main: false, pinned: true };
    }
    if (x.sets === undefined) throw new Error(`${e.name}: give sets, 1 to 10.`);
    const targets = [m("sets", x.sets)];
    if (x.seconds !== undefined) targets.push(m("duration_s", x.seconds));
    else if (x.reps !== undefined) targets.push(m("reps", x.reps));
    if (x.weight_lb !== undefined) targets.push(m("load_lb", x.weight_lb));
    else if (x.weight_lb_per_hand !== undefined) targets.push(m("load_lb_hand", x.weight_lb_per_hand));
    if (x.rpe !== undefined) targets.push(m("rpe", x.rpe));
    return {
      id: uuid(), kind: "workout", at: start + i, slot: title, template: e.slug, targets, note: x.note?.trim() ?? "", adjustedReason: reason,
      group: x.superset, main: x.main ?? e.tags.includes("goal_lift"), pinned: true,
    };
  });
  return [...kept, ...made];
}

/** What a new session changes, line by line, for the agent to show before it applies. */
export function diff(before: PlanRow[], after: PlanRow[]) {
  const named = (l: ReturnType<typeof sessionLines>[number]) => `${nameOf(l.slug)}: ${line(l)}${l.group ? ` [superset ${l.group}]` : ""}`;
  const a = sessionLines(before).map(named);
  const b = sessionLines(after).map(named);
  return [...a.filter((x) => !b.includes(x)).map((x) => `− ${x}`), ...b.filter((x) => !a.includes(x)).map((x) => `+ ${x}`), ...b.filter((x) => a.includes(x)).map((x) => `= ${x}`)];
}

export type SetInput = { exercise: string; weight_lb?: number; weight_lb_per_hand?: number; reps?: number; seconds?: number; rpe?: number };

/**
 * A session as the app saves one (WorkoutDraft.save): a row per set, its note the session's name, then a summary row
 * (no exercise) with the effort and the person's note. "As planned" fills the sets from the day's plan.
 */
export function logRows(plan: PlanRow[], start: number, input: { sets?: SetInput[]; as_planned?: boolean; rpe?: number; note?: string; effort?: number }): LogRow[] {
  const title = plan.find((r) => r.kind === "workout" && r.slot)?.slot ?? "Workout";
  // Runs are logged with log_run, with what was actually run (FIT-178).
  const planned = [...plan].filter(lifting).sort((a, b) => a.at - b.at);
  const sets: (SetInput & { slug: string; plannedRef?: string })[] = [];
  if (input.as_planned) {
    if (!planned.length) throw new Error("Nothing is planned that day, so list the sets.");
    for (const r of planned) {
      for (let i = 0; i < (value(r.targets, "sets") ?? 1); i++) {
        sets.push({ exercise: r.template ?? "", slug: r.template ?? "", plannedRef: r.id, reps: value(r.targets, "reps"), seconds: value(r.targets, "duration_s"),
          weight_lb: value(r.targets, "load_lb"), weight_lb_per_hand: value(r.targets, "load_lb_hand"), rpe: input.rpe ?? value(r.targets, "rpe") });
      }
    }
  }
  for (const s of input.sets ?? []) {
    const slug = resolve(s.exercise).slug;
    sets.push({ ...s, slug, plannedRef: planned.find((r) => r.template === slug)?.id, rpe: s.rpe ?? input.rpe });
  }
  if (!sets.length) throw new Error("No sets: give the sets, or as_planned.");
  const out: LogRow[] = sets.map((s, i) => {
    const ms: Measurement[] = [];
    if (s.seconds !== undefined) ms.push(m("duration_s", s.seconds));
    else if (s.reps !== undefined) ms.push(m("reps", s.reps));
    if (s.weight_lb !== undefined) ms.push(m("load_lb", s.weight_lb));
    else if (s.weight_lb_per_hand !== undefined) ms.push(m("load_lb_hand", s.weight_lb_per_hand));
    if (s.rpe !== undefined) ms.push(m("rpe", s.rpe));
    return { id: uuid(), kind: "workout", at: start + i, plannedRef: s.plannedRef, template: s.slug, measurements: ms, note: title };
  });
  const plannedSets = planned.reduce((n, r) => n + (value(r.targets, "sets") ?? 1), 0);
  const summary: Measurement[] = [];
  if (input.effort !== undefined) summary.push(m("effort", input.effort));
  if (plannedSets) summary.push(m("completion_rate", Math.min(1, sets.length / plannedSets)));
  out.push({ id: uuid(), kind: "workout", at: start + sets.length, measurements: summary, note: input.note?.trim() ?? "" });
  return out;
}

// ---- Setup (FIT-150): the profile and goals an agent fills in by conversation ----

/** Profile.allEquipment. */
export const EQUIPMENT = ["barbell", "rack", "bench", "dumbbells", "pull_up_bar", "kettlebells", "cable", "machine", "bands", "ez_bar", "trap_bar",
  "dip_station", "suspension", "box", "medicine_ball", "exercise_ball", "sled", "bike", "rower", "treadmill", "jump_rope"];
/** BodyArea.muscles: the areas the app knows, and the muscles each covers. */
export const AREAS: Record<string, string[]> = {
  shoulders: ["anterior_deltoids", "rear_deltoids", "deltoids"], chest: ["pectorals"], "upper back": ["lats", "rhomboids", "mid_trapezius", "traps", "upper_back"],
  "lower back": ["spinal_erectors"], neck: ["traps", "neck"], elbows: ["biceps", "triceps"], wrists: ["forearms"], hips: ["glutes", "adductors", "abductors"],
  knees: ["quads"], hamstrings: ["hamstrings"], abs: ["core", "rectus_abdominis", "transverse_abdominis", "obliques"], calves: ["calves"],
};
export const STYLES = ["powerlifting", "hypertrophy", "powerbuilding", "functional"];
export const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]; // 0 is Monday (ProgramDesigner.weekdays)

export type ProfileInput = {
  age?: number; weight_lb?: number; training_days?: string[]; session_minutes?: number; workout_time?: string; equipment?: string[];
  injured_areas?: string[]; never?: string[]; style?: string; max_weekly_sets?: number;
  starting_sets?: { exercise?: string; weight_lb?: number; reps?: number; seconds?: number; distance?: string | number; time?: string | number }[];
};

/**
 * The profile unit with these answers merged in. A new one has every field SyncUnits.ProfileBody decodes, with the
 * app's defaults (Profile.init: 3 days, 45 minutes, 7:00, powerbuilding, 60 sets), and needs age and weight.
 */
export function mergeProfile(current: Record<string, any> | undefined, input: ProfileInput): Record<string, any> {
  if (!current && (input.age === undefined || input.weight_lb === undefined)) throw new Error("A new profile needs their age and body weight first.");
  const p: Record<string, any> = current ? { ...current } : {
    avoidExercises: [], cookWindows: [], daysPerWeek: 3, equipment: EQUIPMENT.slice(0, 5), fineAreas: {}, injuredAreas: [], maxWeeklySets: 60,
    sessionMinutes: 45, starts: [], style: "powerbuilding", trainingDays: [0, 2, 4], travelWeeks: [], warmups: true, workoutTime: 7 * 60,
  };
  if (input.age !== undefined) p.age = Math.round(input.age);
  if (input.weight_lb !== undefined) p.weightLb = input.weight_lb;
  if (input.training_days) {
    const days = input.training_days.map((d) => WEEKDAYS.findIndex((w) => d.toLowerCase().startsWith(w.toLowerCase())));
    if (days.some((d) => d < 0) || !days.length) throw new Error(`Training days are weekday names: ${WEEKDAYS.join(", ")}.`);
    p.trainingDays = [...new Set(days)].sort();
    p.daysPerWeek = p.trainingDays.length;
  }
  if (input.session_minutes !== undefined) p.sessionMinutes = Math.round(input.session_minutes);
  if (input.workout_time !== undefined) {
    const match = /^(\d{1,2}):(\d{2})$/.exec(input.workout_time);
    if (!match) throw new Error("workout_time is 24-hour HH:MM, like 07:00 or 18:30.");
    p.workoutTime = Number(match[1]) * 60 + Number(match[2]);
  }
  if (input.equipment) {
    const bad = input.equipment.filter((e) => !EQUIPMENT.includes(e));
    if (bad.length) throw new Error(`Unknown equipment ${bad.join(", ")}. Use: ${EQUIPMENT.join(", ")}.`);
    p.equipment = [...new Set(input.equipment)];
  }
  if (input.injured_areas) {
    const bad = input.injured_areas.filter((a) => !AREAS[a]);
    if (bad.length) throw new Error(`Unknown area ${bad.join(", ")}. Use: ${Object.keys(AREAS).join(", ")}.`);
    p.injuredAreas = [...new Set(input.injured_areas)];
  }
  if (input.never) p.avoidExercises = [...new Set(input.never.map((n) => resolve(n).slug))];
  if (input.style !== undefined) {
    if (!STYLES.includes(input.style)) throw new Error(`style is one of ${STYLES.join(", ")}.`);
    p.style = input.style;
  }
  if (input.max_weekly_sets !== undefined) p.maxWeeklySets = Math.round(input.max_weekly_sets);
  for (const s of input.starting_sets ?? []) {
    // FIT-177: a recent race or hard run, as distance and time, starts a race-time goal.
    if (s.distance !== undefined || s.time !== undefined) {
      if (s.distance === undefined || s.time === undefined) throw new Error("A run's starting point needs its distance and time.");
      const run = [m("distance_m", Math.round(meters(s.distance))), m("duration_s", seconds(s.time))];
      p.starts = [...(p.starts ?? []).filter((x: { exercise: string }) => x.exercise !== OUTDOOR_RUN), { exercise: OUTDOOR_RUN, measurements: run }];
      continue;
    }
    if (!s.exercise) throw new Error("Each starting set names its exercise.");
    const slug = resolve(s.exercise).slug;
    const ms: Measurement[] = [];
    if (s.seconds !== undefined) ms.push(m("duration_s", s.seconds));
    else if (s.reps !== undefined) ms.push(m("reps", s.reps));
    if (s.weight_lb !== undefined) ms.push(m("load_lb", s.weight_lb));
    p.starts = [...(p.starts ?? []).filter((x: { exercise: string }) => x.exercise !== slug), { exercise: slug, measurements: ms }];
  }
  return p;
}

export type GoalInput = { type: "lift_max" | "reps" | "body_weight" | "timed_distance"; exercise?: string; target?: number; by?: string; distance?: string | number; time?: string | number };

/** A goal unit's body, as SyncUnits.GoalBody: "back-squat.1rm_lb", "pull-up.reps" or "weight_lb", like Onboarding's options. */
export function goalBody(input: GoalInput, deadline: number | undefined, baseline?: number): Goal {
  if (input.type === "timed_distance") {
    if (input.distance === undefined || input.time === undefined) throw new Error("A race-time goal needs its distance and target time, e.g. 10K in 55:00.");
    return { kind: "training", metric: runMetric(meters(input.distance)), target: seconds(input.time), unit: "s", deadline, baseline, status: "active" };
  }
  if (input.target === undefined) throw new Error("A goal needs its target.");
  if (input.type === "body_weight") return { kind: "body", metric: "weight_lb", target: input.target, unit: "lb", deadline, baseline, status: "active" };
  if (!input.exercise) throw new Error("A lift or reps goal needs its exercise.");
  const slug = resolve(input.exercise).slug;
  return input.type === "lift_max"
    ? { kind: "training", metric: `${slug}.1rm_lb`, target: input.target, unit: "lb", deadline, baseline, status: "active" }
    : { kind: "training", metric: `${slug}.reps`, target: input.target, unit: "reps", deadline, baseline, status: "active" };
}

/** What a new account still needs before the first week can be planned. */
export function missing(profile: Profile | undefined, goals: Goal[], units: Units = new Map()): string[] {
  const out: string[] = [];
  if (!profile) out.push("profile: age and body weight, training days, minutes per session, usual time, equipment, injuries, exercises they never do");
  if (!goals.length) out.push("goals: what they want to reach and by when (a lift max, reps, body weight, or a race time)");
  const unknown = unknownMaxes(goals, units, profile);
  if (unknown.length) out.push(`where they are now, so the weights are right (FIT-174): ${unknown.join("; ")}. Save each with set_profile starting_sets (a 1RM is weight_lb with reps 1)`);
  return out;
}

// ---- FIT-174: no program or weights without their maxes; loads held to them (PlanGuard rule 3) ----

/** PlanGuard.maxJump: at most 10% over the last top set. */
const MAX_JUMP = 1.1;

/** Every logged set of an exercise with `metric`, oldest first. */
function setsOf(units: Units, slug: string, metric: string) {
  const out: { day: string; load: number; reps?: number; rpe?: number }[] = [];
  for (const key of [...units.keys()].filter((k) => k.startsWith("log#")).sort()) {
    for (const r of logOf(units, key.slice(4)).filter((r) => r.kind === "workout" && r.template === slug)) {
      const load = value(r.measurements, metric);
      if (load !== undefined) out.push({ day: key.slice(4), load, reps: value(r.measurements, "reps"), rpe: value(r.measurements, "rpe") });
    }
  }
  return out;
}

const startOf = (profile: Profile | undefined, slug: string) =>
  ((profile as Record<string, any> | undefined)?.starts ?? []).find((s: { exercise: string }) => s.exercise === slug) as { measurements: Measurement[] } | undefined;

/** FIT-177: the best race time their runs (or the starting run) predict for `race` meters, by Riegel. */
export function runTime(units: Units, profile: Profile | undefined, race: number): number | undefined {
  const runs = [...units.keys()].filter((k) => k.startsWith("log#")).flatMap((k) => logOf(units, k.slice(4)))
    .filter((r) => r.kind === "workout" && r.template && RUNS.includes(r.template)).map((r) => r.measurements);
  const start = startOf(profile, OUTDOOR_RUN)?.measurements;
  const times = [...runs, ...(start ? [start] : [])].flatMap((ms) => {
    const d = value(ms, "distance_m"), t = value(ms, "duration_s"), p = d && t ? riegel(t, d, race) : undefined;
    return p === undefined ? [] : [p];
  });
  return times.length ? Math.round(Math.min(...times)) : undefined;
}

/** Whether a weight for this exercise has something to go on: its own logged sets, or (for load_lb) a starting set. */
export function knowsMax(units: Units, profile: Profile | undefined, slug: string, metric = "load_lb") {
  const start = startOf(profile, slug);
  return setsOf(units, slug, metric).length > 0 || (metric === "load_lb" && value(start?.measurements ?? [], "load_lb") !== undefined && value(start?.measurements ?? [], "reps") !== undefined);
}

/** FIT-218: the max a percentage is of: the best estimate from their logs, else their starting set's (Brzycki). */
export function maxOf(units: Units, profile: Profile | undefined, slug: string, day: string) {
  const start = startOf(profile, slug), load = value(start?.measurements ?? [], "load_lb"), reps = value(start?.measurements ?? [], "reps");
  return bestBy(loggedSets(units), slug, day) ?? (load !== undefined && reps !== undefined ? (load * 36) / (37 - Math.min(reps, 36)) : undefined);
}

/** Goal lifts with nothing to set weights from: a max goal with no loaded set or starting set, a reps goal with no reps. */
export function unknownMaxes(goals: Goal[], units: Units, profile: Profile | undefined): string[] {
  return goals.filter((g) => g.status === "active").flatMap((g) => {
    const [slug, kind] = g.metric.split(".");
    if (kind === "1rm_lb" && !knowsMax(units, profile, slug)) return [`${nameOf(slug)}: a 1RM (tested or estimated) or a recent heavy set, weight × reps`];
    if (kind === "reps" && !setsOf(units, slug, "reps").length && value(startOf(profile, slug)?.measurements ?? [], "reps") === undefined) return [`${nameOf(slug)}: most reps in a row now`];
    const race = goalMeters(g.metric);
    if (race !== undefined && runTime(units, profile, race) === undefined) return [`${distanceName(race)}: a recent race or hard run, its distance and time`];
    return [];
  });
}

/**
 * PlanGuard.ceiling: the most a planned load can be for its reps. Brzycki from the best known max plus 5 lb (history
 * with RPE-adjusted reps, else the starting set), and 10% over the last top set of the two weeks before the last log.
 */
export function loadCeiling(units: Units, profile: Profile | undefined, slug: string, metric: string, reps?: number) {
  const sets = setsOf(units, slug, metric);
  const ceilings: { load: number; why: string }[] = [];
  const reserve = (rpe?: number) => 10 - Math.min(Math.max(rpe ?? 8, 6), 10);
  const brzycki = (load: number, r: number) => (load * 36) / (37 - Math.min(r, 36));
  if (reps !== undefined) {
    const fromLogs = sets.filter((x) => x.reps !== undefined && x.reps >= 1 && x.reps <= 10).map((x) => brzycki(x.load, x.reps! + reserve(x.rpe)));
    const start = startOf(profile, slug), sl = value(start?.measurements ?? [], "load_lb"), sr = value(start?.measurements ?? [], "reps");
    const best = fromLogs.length ? Math.max(...fromLogs) : undefined;
    const max = best ?? (metric === "load_lb" && sl !== undefined && sr !== undefined ? brzycki(sl, sr) : undefined);
    if (max !== undefined) ceilings.push({ load: (max * (37 - Math.min(reps, 36))) / 36 + 5, why: `the most their ${best === undefined ? "starting point" : "history"} gives for ${reps} reps` });
  }
  const last = sets.at(-1)?.day;
  if (last) {
    const since = addDays(last, -14);
    const top = Math.max(...sets.filter((x) => x.day >= since).map((x) => {
      if (reps === undefined || x.reps === undefined || x.reps === reps) return x.load;
      const r = reserve(x.rpe);
      return (x.load * (37 - Math.min(reps + r, 36))) / (37 - Math.min(x.reps + r, 36));
    }));
    ceilings.push({ load: top * MAX_JUMP, why: "10% over their last top set" });
  }
  return ceilings.reduce<{ load: number; why: string } | undefined>((a, c) => (!a || c.load < a.load ? c : a), undefined);
}

/** Loads over their ceiling, and weighted main lifts with no max to go on: plan-rule problems. */
export function checkLoads(plan: PlanRow[], units: Units, profile: Profile | undefined): { problems: string[]; cautions: string[] } {
  const problems: string[] = [], notes: string[] = [];
  for (const r of plan.filter(working)) {
    if (!r.template) continue;
    const metric = value(r.targets, "load_lb") !== undefined ? "load_lb" : value(r.targets, "load_lb_hand") !== undefined ? "load_lb_hand" : undefined;
    if (!metric) continue;
    const load = value(r.targets, metric)!, reps = value(r.targets, "reps"), name = nameOf(r.template);
    if (!knowsMax(units, profile, r.template, metric)) {
      if (r.main) problems.push(`${name} is a main lift with a weight but no known max. Ask for their 1RM or a recent heavy set first (set_profile starting_sets).`);
      else notes.push(`${name} at ${load} lb${metric === "load_lb_hand" ? " each" : ""} is a guess: nothing logged to go on.`);
      continue;
    }
    const c = loadCeiling(units, profile, r.template, metric, reps);
    const barbell = (bySlug.get(r.template)?.equipment ?? []).some((k) => BARBELL.includes(k));
    if (c && load > c.load) {
      const capped = barbell ? Math.floor(c.load / 5) * 5 : Math.floor(c.load);
      problems.push(`${name}: ${load} lb${reps ? ` for ${reps}` : ""} is over ${c.why}; at most ${capped} lb${metric === "load_lb_hand" ? " each" : ""}.`);
    }
  }
  return { problems: [...new Set(problems)], cautions: [...new Set(notes)] };
}

/** Soft cautions that don't block apply: an exercise that loads an area they said is injured. */
export function cautions(plan: PlanRow[], profile?: Profile): string[] {
  const hurt = new Set((profile?.injuredAreas ?? []).flatMap((a) => AREAS[a.toLowerCase().replace(/_/g, " ")] ?? [a]));
  if (!hurt.size) return [];
  return [...new Set(plan.filter(working).map((r) => bySlug.get(r.template ?? "")).filter((e): e is Exercise => !!e && e.muscles.some((x) => hurt.has(x)))
    .map((e) => `${e.name} works ${e.muscles.filter((x) => hurt.has(x)).join(", ").replace(/_/g, " ")}, near an area they said is injured. Check with them.`))];
}
