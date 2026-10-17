import { randomUUID } from "node:crypto";
import seed from "../../Resources/Seed/exercises.json" with { type: "json" };

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
  effort: "/10", completion_rate: "ratio",
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
export const nameOf = (slug?: string) => (slug && bySlug.get(slug)?.name) ?? slug ?? "Exercise";

const words = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().split(" ").filter(Boolean)
  .map((w) => (w.length > 3 && w.endsWith("s") ? w.slice(0, -1) : w));

/** A catalog exercise from a slug or a name an agent wrote ("Bench Press", "RDL", "romanian deadlifts"). */
export function resolve(said: string): Exercise {
  const exact = bySlug.get(said) ?? catalog.find((e) => e.name.toLowerCase() === said.toLowerCase() || e.aliases.some((a) => a.toLowerCase() === said.toLowerCase()));
  if (exact) return exact;
  const want = words(said);
  const scored = catalog
    .map((e) => {
      const have = new Set([...words(e.name), ...e.aliases.flatMap(words)]);
      return { e, hit: want.filter((w) => have.has(w)).length, extra: have.size - want.length };
    })
    .filter((s) => s.hit === want.length)
    .sort((a, b) => a.extra - b.extra || a.e.name.length - b.e.name.length);
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

// ---- Reading ----

/** "4 × 6 @ 170 lb · RPE 8", per exercise, from plan rows (one row per set or per exercise, as the app writes either). */
export function sessionLines(plan: PlanRow[]) {
  const out: { slug?: string; sets: number; targets: Measurement[]; main: boolean; group?: number }[] = [];
  for (const row of [...plan].filter(working).sort((a, b) => a.at - b.at)) {
    const targets = row.targets.filter((x) => x.metric !== "sets");
    const sets = value(row.targets, "sets") ?? 1;
    const last = out[out.length - 1];
    if (last && last.slug === row.template && JSON.stringify(last.targets) === JSON.stringify(targets)) last.sets += sets;
    else out.push({ slug: row.template, sets, targets, main: row.main, group: row.group ?? undefined });
  }
  return out;
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

export function describeSession(plan: PlanRow[]) {
  const title = plan.find((r) => r.kind === "workout" && r.slot)?.slot;
  const lines = sessionLines(plan).map((l) => `${l.main ? "★ " : ""}${nameOf(l.slug)} (${l.slug}): ${describeTargets(l.sets, l.targets)}${l.group ? ` [superset ${l.group}]` : ""}`);
  return { title, lines };
}

/** "Back Squat 205×5 @7, 205×5 @8" per exercise, and the session's note. */
export function describeLog(log: LogRow[]) {
  const sets = log.filter((r) => r.kind === "workout" && r.template);
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
    lines: [...byExercise].map(([slug, list]) => `${nameOf(slug)}: ${list.join(", ")}`),
    note: notes.join(" "),
    effort: summary ? value(summary.measurements, "effort") : undefined,
  };
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
  for (const r of plan.filter(working)) {
    const k = r.template ?? "";
    const so = sets.get(k) ?? { n: 0, main: false };
    sets.set(k, { n: so.n + (value(r.targets, "sets") ?? 1), main: so.main || r.main });
  }
  for (const [slug, { n, main }] of sets) {
    const most = main ? MAX_SETS.main : MAX_SETS.accessory;
    if (n > most) out.push(`${nameOf(slug)}: ${n} sets is more than the ${most} allowed for ${main ? "a main lift" : "an accessory"}.`);
    else if (n < least) out.push(`${nameOf(slug)}: ${n} set is fewer than the ${least} minimum.`);
  }
  for (const r of plan.filter(working)) {
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
  return days.flatMap((d) => d.filter(working)).reduce((sum, r) => sum + (value(r.targets, "sets") ?? 1), 0);
}

// ---- Writing ----

const uuid = () => randomUUID().toUpperCase();

export type ExerciseInput = {
  exercise: string; sets: number; reps?: number; seconds?: number; weight_lb?: number; weight_lb_per_hand?: number; rpe?: number;
  main?: boolean; superset?: number;
};

/** A day's new session: one row per exercise, in order, pinned so the app's weekly planning keeps it. Other kinds stay. */
export function sessionRows(existing: PlanRow[], title: string, exercises: ExerciseInput[], start: number, reason: string): PlanRow[] {
  const kept = existing.filter((r) => r.kind !== "workout");
  const made = exercises.map((x, i): PlanRow => {
    const e = resolve(x.exercise);
    const targets = [m("sets", x.sets)];
    if (x.seconds !== undefined) targets.push(m("duration_s", x.seconds));
    else if (x.reps !== undefined) targets.push(m("reps", x.reps));
    if (x.weight_lb !== undefined) targets.push(m("load_lb", x.weight_lb));
    else if (x.weight_lb_per_hand !== undefined) targets.push(m("load_lb_hand", x.weight_lb_per_hand));
    if (x.rpe !== undefined) targets.push(m("rpe", x.rpe));
    return {
      id: uuid(), kind: "workout", at: start + i, slot: title, template: e.slug, targets, note: "", adjustedReason: reason,
      group: x.superset, main: x.main ?? e.tags.includes("goal_lift"), pinned: true,
    };
  });
  return [...kept, ...made];
}

/** What a new session changes, line by line, for the agent to show before it applies. */
export function diff(before: PlanRow[], after: PlanRow[]) {
  const a = sessionLines(before).map((l) => `${nameOf(l.slug)}: ${describeTargets(l.sets, l.targets)}`);
  const b = sessionLines(after).map((l) => `${nameOf(l.slug)}: ${describeTargets(l.sets, l.targets)}`);
  return [...a.filter((x) => !b.includes(x)).map((x) => `− ${x}`), ...b.filter((x) => !a.includes(x)).map((x) => `+ ${x}`), ...b.filter((x) => a.includes(x)).map((x) => `= ${x}`)];
}

export type SetInput = { exercise: string; weight_lb?: number; weight_lb_per_hand?: number; reps?: number; seconds?: number; rpe?: number };

/**
 * A session as the app saves one (WorkoutDraft.save): a row per set, its note the session's name, then a summary row
 * (no exercise) with the effort and the person's note. "As planned" fills the sets from the day's plan.
 */
export function logRows(plan: PlanRow[], start: number, input: { sets?: SetInput[]; as_planned?: boolean; rpe?: number; note?: string; effort?: number }): LogRow[] {
  const title = plan.find((r) => r.kind === "workout" && r.slot)?.slot ?? "Workout";
  const planned = [...plan].filter(working).sort((a, b) => a.at - b.at);
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
  starting_sets?: { exercise: string; weight_lb?: number; reps?: number; seconds?: number }[];
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
    const slug = resolve(s.exercise).slug;
    const ms: Measurement[] = [];
    if (s.seconds !== undefined) ms.push(m("duration_s", s.seconds));
    else if (s.reps !== undefined) ms.push(m("reps", s.reps));
    if (s.weight_lb !== undefined) ms.push(m("load_lb", s.weight_lb));
    p.starts = [...(p.starts ?? []).filter((x: { exercise: string }) => x.exercise !== slug), { exercise: slug, measurements: ms }];
  }
  return p;
}

export type GoalInput = { type: "lift_max" | "reps" | "body_weight"; exercise?: string; target: number; by?: string };

/** A goal unit's body, as SyncUnits.GoalBody: "back-squat.1rm_lb", "pull-up.reps" or "weight_lb", like Onboarding's options. */
export function goalBody(input: GoalInput, deadline: number | undefined, baseline?: number): Goal {
  if (input.type === "body_weight") return { kind: "body", metric: "weight_lb", target: input.target, unit: "lb", deadline, baseline, status: "active" };
  if (!input.exercise) throw new Error("A lift or reps goal needs its exercise.");
  const slug = resolve(input.exercise).slug;
  return input.type === "lift_max"
    ? { kind: "training", metric: `${slug}.1rm_lb`, target: input.target, unit: "lb", deadline, baseline, status: "active" }
    : { kind: "training", metric: `${slug}.reps`, target: input.target, unit: "reps", deadline, baseline, status: "active" };
}

/** What a new account still needs before the first week can be planned. */
export function missing(profile: Profile | undefined, goals: Goal[]): string[] {
  const out: string[] = [];
  if (!profile) out.push("profile: age and body weight, training days, minutes per session, usual time, equipment, injuries, exercises they never do");
  if (!goals.length) out.push("goals: what they want to reach and by when (a lift max, reps, or body weight)");
  return out;
}

/** Soft cautions that don't block apply: an exercise that loads an area they said is injured. */
export function cautions(plan: PlanRow[], profile?: Profile): string[] {
  const hurt = new Set((profile?.injuredAreas ?? []).flatMap((a) => AREAS[a.toLowerCase().replace(/_/g, " ")] ?? [a]));
  if (!hurt.size) return [];
  return [...new Set(plan.filter(working).map((r) => bySlug.get(r.template ?? "")).filter((e): e is Exercise => !!e && e.muscles.some((x) => hurt.has(x)))
    .map((e) => `${e.name} works ${e.muscles.filter((x) => hurt.has(x)).join(", ").replace(/_/g, " ")}, near an area they said is injured. Check with them.`))];
}
