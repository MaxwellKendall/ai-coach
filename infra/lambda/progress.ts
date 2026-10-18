import { programOf, weekIndex, weekStart, type ProgramWeek } from "./program.ts";
import { clock, distanceName, goalMeters, riegel, RUNS } from "./running.ts";
import { addDays, bySlug, epoch, goalsOf, logOf, planOf, profileOf, type Goal, type Measurement, type Profile, type Units } from "./training.ts";

// FIT-167: the Progress tab and the weekly review, as Core/Progress derives them (GoalProgress, Wins, Streak,
// WeeklyReview) and Features/Progress/WeekReport gathers them, so an agent's numbers are the phone's. Repeated here
// because the Lambda can't import the Swift; Tests/Fixtures/progress-units.json holds the two to the same answers.
// Days are YYYY-MM-DD in the person's time zone; moments are seconds since 1970.

export type LogSet = { at: number; day: string; exercise: string; pattern?: string; measurements: Measurement[] };
export type Dated = { at: number; day: string; value: number };

const value = (list: Measurement[], metric: string) => list.find((m) => m.metric === metric)?.value;
const dayKeys = (units: Units, prefix: string) => [...units.keys()].filter((k) => k.startsWith(prefix)).map((k) => k.slice(prefix.length)).sort();

/** Planner.loggedSets: each logged working set with its exercise's movement pattern, oldest first. */
export function logSets(units: Units): LogSet[] {
  return dayKeys(units, "log#").flatMap((day) => logOf(units, day)
    .filter((r) => r.kind === "workout" && r.template)
    .map((r) => ({ at: r.at, day, exercise: r.template!, pattern: bySlug.get(r.template!)?.pattern, measurements: r.measurements })))
    .sort((a, b) => a.at - b.at);
}

/** Weigh-ins, oldest first. */
export const weighIns = (units: Units): Dated[] => dayKeys(units, "log#").flatMap((day) => logOf(units, day)
  .filter((r) => r.kind === "bodyweight").flatMap((r) => { const v = value(r.measurements, "weight_lb"); return v === undefined ? [] : [{ at: r.at, day, value: v }]; }))
  .sort((a, b) => a.at - b.at);

/** Daily.totals: `metric` summed per day over entries of `kind`, days without it left out. */
export function dailyTotals(units: Units, kind: string, metric: string): Map<string, number> {
  const out = new Map<string, number>();
  for (const day of dayKeys(units, "log#")) {
    for (const r of logOf(units, day).filter((r) => r.kind === kind)) {
      const v = value(r.measurements, metric);
      if (v !== undefined) out.set(day, (out.get(day) ?? 0) + v);
    }
  }
  return out;
}

/** Days with a planned workout, and days with a logged one. */
export const plannedDays = (units: Units) => new Set(dayKeys(units, "plan#").filter((d) => planOf(units, d).some((r) => r.kind === "workout")));
export const workoutDays = (units: Units) => new Set(dayKeys(units, "log#").filter((d) => logOf(units, d).some((r) => r.kind === "workout")));

// ---- GoalProgress ----

/** Brzycki (fitness-planner CLAUDE.md "1RM Estimation"), as ProgramPlan.estimatedMax. */
export const estimatedMax = (load: number, reps: number) => (load * 36) / (37 - Math.min(reps, 36));

/** Swift's rounded(): half away from zero. */
const round = (x: number) => Math.sign(x) * Math.round(Math.abs(x));

/** "weight_lb": the last weigh-in. "<exercise>.1rm_lb": the best estimate (reps ≤ 12). "<exercise>.reps": most reps unloaded. */
export function current(metric: string, sets: LogSet[], weighs: Dated[], since: number): number | undefined {
  const goal = goalMeters(metric);
  if (goal !== undefined) return bestRun(goal, sets, since)?.time; // FIT-177: the best predicted race time
  if (metric === "weight_lb") return weighs.filter((w) => w.at >= since).reduce<Dated | undefined>((a, w) => (!a || w.at > a.at ? w : a), undefined)?.value;
  const [exercise, kind] = metric.split(".");
  const mine = sets.filter((s) => s.exercise === exercise && s.at >= since);
  const max = (xs: number[]) => (xs.length ? Math.max(...xs) : undefined);
  if (kind === "1rm_lb") {
    return max(mine.flatMap((s) => {
      const load = value(s.measurements, "load_lb"), reps = value(s.measurements, "reps");
      return load !== undefined && reps !== undefined && reps <= 12 ? [round(estimatedMax(load, reps))] : [];
    }));
  }
  if (kind === "reps") return max(mine.filter((s) => value(s.measurements, "load_lb") === undefined).flatMap((s) => value(s.measurements, "reps") ?? []));
  return undefined;
}

/** The run whose Riegel prediction for `goal` meters is fastest since `since`, and that time. */
export function bestRun(goal: number, sets: LogSet[], since: number) {
  let top: { run: LogSet; time: number } | undefined;
  for (const run of sets.filter((x) => RUNS.includes(x.exercise) && x.at >= since)) {
    const d = value(run.measurements, "distance_m"), t = value(run.measurements, "duration_s");
    const time = d && t ? riegel(t, d, goal) : undefined;
    if (time !== undefined && (!top || time < top.time)) top = { run, time: Math.round(time) };
  }
  return top;
}

/** Whether a smaller value is better: a race time (FIT-177). */
export const lowerIsBetter = (metric: string) => goalMeters(metric) !== undefined;

/** The set behind `current` for a max or reps goal, or the run behind a race time. */
export function best(metric: string, sets: LogSet[], since: number): LogSet | undefined {
  const goal = goalMeters(metric);
  if (goal !== undefined) return bestRun(goal, sets, since)?.run;
  const [exercise, kind] = metric.split(".");
  const mine = sets.filter((s) => s.exercise === exercise && s.at >= since);
  const score = (s: LogSet) => {
    const load = value(s.measurements, "load_lb"), reps = value(s.measurements, "reps");
    return load !== undefined && reps !== undefined ? round(estimatedMax(load, reps)) : 0;
  };
  // Swift's max(by:) keeps the first of equals.
  const top = (xs: LogSet[], f: (s: LogSet) => number) => xs.reduce<LogSet | undefined>((a, s) => (!a || f(s) > f(a) ? s : a), undefined);
  if (kind === "1rm_lb") return top(mine.filter((s) => (value(s.measurements, "reps") ?? 99) <= 12), score);
  if (kind === "reps") return top(mine.filter((s) => value(s.measurements, "load_lb") === undefined), (s) => value(s.measurements, "reps") ?? 0);
  return undefined;
}

/** The goal over time, one point a day: weigh-ins as logged, maxes and reps as the best so far. */
export function trend(metric: string, sets: LogSet[], weighs: Dated[], since: number): { day: string; value: number }[] {
  const byDay = new Map<string, number>();
  if (metric === "weight_lb") for (const w of weighs.filter((w) => w.at >= since)) byDay.set(w.day, w.value);
  else {
    for (const s of sets.filter((s) => s.at >= since)) {
      if (byDay.has(s.day)) continue;
      const v = current(metric, sets.filter((x) => x.day <= s.day), [], since);
      if (v !== undefined) byDay.set(s.day, v);
    }
  }
  return [...byDay.keys()].sort().map((day) => ({ day, value: byDay.get(day)! }));
}

/** How far from the start to the target, 0–1, either direction. */
export const fraction = (start: number, now: number, target: number) => (target === start ? 1 : Math.min(1, Math.max(0, (now - start) / (target - start))));

/** ProgramPlan.expected: a straight line over the weeks that count; deload and travel weeks hold it flat. */
export function expected(start: number, target: number, index: number, weeks: ProgramWeek[]) {
  const counting = weeks.flatMap((w, i) => (w.kind !== "deload" && !w.travel ? [i] : []));
  if (!counting.length) return target;
  return start + ((target - start) * counting.filter((i) => i <= index).length) / counting.length;
}

export type Pace = "starting" | "behind" | "onPace" | "ahead";

/** Against where the program expects it by the end of last week: under 80% is behind, 125% or more ahead. */
export function pace(start: number, now: number, target: number, week: number, weeks: ProgramWeek[]): Pace {
  if (week <= 0) return "starting";
  const want = fraction(start, expected(start, target, week - 1, weeks), target);
  const done = fraction(start, now, target);
  if (done < want * 0.8) return "behind";
  return want > 0 && done >= want * 1.25 ? "ahead" : "onPace";
}

/** Where it lands by `end` at the rate since `started`; nothing in the first week. */
export function forecast(start: number, now: number, started: number, today: number, end: number) {
  const done = today - started, left = Math.max(0, end - today);
  return done >= 7 * 86_400 ? now + ((now - start) / done) * left : undefined;
}

/** How much it has to move each week to reach the target by `end`. */
export const perWeek = (now: number, target: number, today: number, end: number) => (target - now) / Math.max(1, (end - today) / (7 * 86_400));

// ---- GoalOption (onboarding's goals, the ones the program and review track) ----

export const GOAL_OPTIONS = [
  { id: "squat", metric: "back-squat.1rm_lb", name: "Back squat max", short: "Squat", measure: "load" },
  { id: "bench", metric: "bench-press.1rm_lb", name: "Bench press max", short: "Bench", measure: "load" },
  { id: "deadlift", metric: "deadlift.1rm_lb", name: "Deadlift max", short: "Deadlift", measure: "load" },
  { id: "pullups", metric: "pull-up.reps", name: "Pull-ups in a row", short: "Pull-ups", measure: "reps" },
  { id: "weight", metric: "weight_lb", name: "Body weight", short: "Weight", measure: "body" },
  { id: "pushups", metric: "push-up.reps", name: "Push-ups in a row", short: "Push-ups", measure: "reps" },
] as const;
export type GoalOption = (typeof GOAL_OPTIONS)[number] | { id: "run"; metric: string; name: string; short: string; measure: "time" };
/** Onboarding's goals, and a race time for any distance (FIT-177). */
export function optionFor(metric: string): GoalOption | undefined {
  const known = GOAL_OPTIONS.find((o) => o.metric === metric);
  const m = goalMeters(metric);
  // WeekReport.short: "10K", "Half", "Marathon".
  const short = m === undefined ? "" : Math.abs(m - 21098) < 2 ? "Half" : distanceName(m);
  return known ?? (m === undefined ? undefined : { id: "run", metric, name: `${distanceName(m)} time`, short, measure: "time" });
}
const stepOf = (o: GoalOption) => (o.measure === "reps" ? 1 : o.measure === "time" ? 30 : 5);

/** Coach.number: at most one decimal, with thousands separators. */
export const number = (x: number) => x.toLocaleString("en-US", { maximumFractionDigits: 1 });
const shown = (x: number, o: GoalOption) => (o.measure === "time" ? clock(x) : number(o.measure === "body" ? x : round(x)));
/** A goal's value as it reads: "231" (lb), "8" (reps), "57:30" (a race time). */
export const formatValue = (metric: string, x: number) => { const o = optionFor(metric); return o ? shown(x, o) : number(x); };

// ---- Streak ----

export type ThisWeek = { kind: "onTrack" } | { kind: "full" } | { kind: "atRisk"; missed: string[]; lastDay: string } | { kind: "broken" };

/** Whether program week `week` was full (as many days trained as planned); undefined with nothing planned. */
function full(week: number, start: string, planned: Set<string>, done: Set<string>) {
  const from = weekStart(week, start), to = weekStart(week + 1, start);
  const days = [...planned].filter((d) => d >= from && d < to);
  if (!days.length) return undefined;
  return [...done].filter((d) => d >= from && d < to).length >= days.length;
}

export function streak(start: string, planned: Set<string>, done: Set<string>, today: string): { weeks: number; thisWeek: ThisWeek } {
  const now = weekIndex(today, start);
  let weeks = 0;
  for (let w = 0; w < Math.max(0, now); w++) {
    const f = full(w, start, planned, done);
    if (f !== undefined) weeks = f ? weeks + 1 : 0;
  }
  if (now < 0) return { weeks: 0, thisWeek: { kind: "onTrack" } };
  const from = weekStart(now, start), to = weekStart(now + 1, start);
  const days = [...planned].filter((d) => d >= from && d < to);
  const trained = [...done].filter((d) => d >= from && d < to);
  if (days.length && trained.length >= days.length) return { weeks: weeks + 1, thisWeek: { kind: "full" } };
  const missed = days.filter((d) => d < today && !done.has(d)).sort();
  if (!missed.length) return { weeks, thisWeek: { kind: "onTrack" } };
  const left = Math.round((Date.parse(`${to}T12:00:00Z`) - Date.parse(`${today}T12:00:00Z`)) / 86_400_000) - (done.has(today) ? 1 : 0);
  const lastDay = addDays(to, -1);
  return { weeks, thisWeek: trained.length + left >= days.length ? { kind: "atRisk", missed, lastDay } : { kind: "broken" } };
}

const weekdayName = (day: string) => new Date(`${day}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });

/** "a", "a and b", "a, b and c". */
export const list = (items: string[]) => (items.length <= 1 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`);
const count = (n: number, noun: string) => `${n} ${noun}${n === 1 ? "" : "s"}`;

/** Streak.line: "4 weeks in a row", or what keeps it going. */
export function streakLine(s: { weeks: number; thisWeek: ThisWeek }, today: string): string | undefined {
  const t = s.thisWeek;
  if (t.kind === "full" || t.kind === "onTrack") return s.weeks >= 2 ? `${s.weeks} weeks in a row` : undefined;
  if (t.kind === "broken" || s.weeks < 1) return undefined;
  const names = t.missed.map((d) => `${weekdayName(d)}’s`);
  const what = t.missed.length === 1 ? `${names[0]} session` : `${list(names)} sessions`;
  const by = today === t.lastDay ? "today" : `by ${weekdayName(t.lastDay)}`;
  return `Do ${what} ${by} to make it ${s.weeks + 1} weeks in a row`;
}

// ---- Wins ----

export type Win = {
  kind: "pr" | "milestone" | "streak"; day: string; key: string; metric: string; unit: string; value: number;
  previous?: number; target?: number; percent?: number; weeksLeft?: number; workouts?: number;
  /** The goal's value on each day it changed, from the start, for the card's line. */
  trend?: number[];
};

/** Every win since the program started, newest first (Wins.detect). */
export function wins(goals: { metric: string; unit: string; baseline: number; target: number }[], sets: LogSet[], weighs: Dated[],
  start: string, since: number, end: number, planned: Set<string>, done: Set<string>, today: string, tz: string): Win[] {
  const out: Win[] = [];
  const left = (day: string) => Math.max(0, Math.floor((end - epoch(day, 0, tz)) / (7 * 86_400)));
  for (const g of goals) {
    let top = g.baseline;
    const crossed = new Set<number>(), values = [g.baseline];
    for (const p of trend(g.metric, sets, weighs, since)) {
      values.push(p.value);
      if (g.metric !== "weight_lb" && (lowerIsBetter(g.metric) ? p.value < top : p.value > top)) {
        out.push({ kind: "pr", day: p.day, key: `pr:${g.metric}:${round(p.value)}`, metric: g.metric, unit: g.unit, value: p.value, previous: top, target: g.target, weeksLeft: left(p.day), trend: [...values] });
        top = p.value;
      }
      const done = fraction(g.baseline, p.value, g.target);
      for (const percent of [25, 50, 75, 100]) {
        if (crossed.has(percent) || done < percent / 100) continue;
        crossed.add(percent);
        out.push({ kind: "milestone", day: p.day, key: `milestone:${g.metric}:${percent}`, metric: g.metric, unit: g.unit, value: p.value, target: g.target, percent, weeksLeft: left(p.day), trend: [...values] });
      }
    }
  }
  // Full weeks in a row: a win at 2, then every 4. The week in progress doesn't count yet.
  const now = weekIndex(today, start);
  let run = 0, workouts = 0;
  for (let w = 0; w < now; w++) {
    const f = full(w, start, planned, done);
    if (f === undefined) continue;
    if (!f) { run = 0; workouts = 0; continue; }
    const from = weekStart(w, start), to = weekStart(w + 1, start);
    run += 1;
    workouts += [...planned].filter((d) => d >= from && d < to).length;
    if (run === 2 || run % 4 === 0) out.push({ kind: "streak", day: addDays(to, -1), key: `streak:${run}`, metric: "streak", unit: "weeks", value: run, workouts });
  }
  return out.sort((a, b) => (a.day === b.day ? (a.key < b.key ? 1 : -1) : a.day < b.day ? 1 : -1));
}

export function describeWin(w: Win) {
  const o = optionFor(w.metric);
  const name = o?.name ?? w.metric;
  const v = (x: number) => (o ? shown(x, o) : number(x));
  const u = o?.measure === "time" ? "" : ` ${w.unit}`;
  if (w.kind === "streak") return `${w.day}: ${w.value} weeks in a row, every planned session done (${w.workouts} workouts).`;
  if (w.kind === "pr") return `${w.day}: personal best, ${name} ${v(w.value)}${u} (was ${v(w.previous!)}).`;
  return w.percent === 100 ? `${w.day}: goal reached, ${name} ${v(w.value)}${u}.` : `${w.day}: ${w.percent}% of the way to ${name} ${v(w.target!)}${u}, at ${v(w.value)}.`;
}

// ---- BodyArea (notes that keep naming an area) ----

const BODY: Record<string, string[]> = {
  shoulders: ["anterior_deltoids", "rear_deltoids", "deltoids"], chest: ["pectorals"], upper_back: ["lats", "rhomboids", "mid_trapezius", "traps", "upper_back"],
  lower_back: ["spinal_erectors"], neck: ["traps", "neck"], elbows: ["biceps", "triceps"], wrists: ["forearms"], hips: ["glutes", "adductors", "abductors"],
  knees: ["quads"], hamstrings: ["hamstrings"], abs: ["core", "rectus_abdominis", "transverse_abdominis", "obliques"], calves: ["calves"],
};

function muscles(areas: string[]) {
  return new Set(areas.flatMap((a) => { const k = a.toLowerCase().trim().replace(/ /g, "_"); return BODY[k] ?? BODY[`${k}s`] ?? [k]; }));
}

/** The first body part named, as said ("lower back", "knee"). */
function mentioned(words: string[]) {
  const text = ` ${words.join(" ")} `;
  const names = Object.keys(BODY).map((k) => k.replace(/_/g, " ")).sort((a, b) => b.length - a.length);
  const name = names.find((n) => { const one = n.endsWith("s") ? n.slice(0, -1) : n; return text.includes(` ${n} `) || text.includes(` ${one} `); });
  return name && name.endsWith("s") && name !== "abs" ? name.slice(0, -1) : name;
}

const hurts = (text: string) => ["pain", "sore", "hurt", "ache", "tight", "tweak", "twinge", "strain", "sharp", "niggle"].some((w) => text.toLowerCase().includes(w));

// ---- WeeklyReview ----

export type Alert = { title: string; detail: string; area?: string };
const shortDate = (day: string) => new Date(`${day}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });

export type Note = { at: number; day: string; text: string };
export type AlertInput = {
  sessions: Iterable<string>; protein: Map<string, number>; kcal: Map<string, number>; sleep: Map<string, number>; notes: Note[];
  injured: string[]; fine?: Record<string, number>; sets?: LogSet[];
};

/** A session's note is on each of its sets, and meal notes are the meal's name: one note per day and text, no meals. */
export function notesOf(units: Units): Note[] {
  const seen = new Set<string>(), out: Note[] = [];
  for (const day of dayKeys(units, "log#")) {
    for (const r of logOf(units, day).filter((r) => r.kind !== "meal" && r.note)) {
      if (seen.has(`${day} ${r.note}`)) continue;
      seen.add(`${day} ${r.note}`);
      out.push({ at: r.at, day, text: r.note });
    }
  }
  return out;
}

/** FIT-8's alerts for the week (Sunday `from` to Saturday): protein, sleep and kcal around sessions, pain notes, missing movements. */
export function alerts(from: string, input: AlertInput): Alert[] {
  const to = addDays(from, 7);
  const sessions = [...new Set(input.sessions)].filter((d) => d >= from && d < to).sort();
  const { protein, kcal, sleep } = input;
  const out: Alert[] = [];

  const lowProtein = sessions.flatMap((s) => {
    const pair = [addDays(s, -1), s].flatMap((d) => (protein.has(d) ? [[d, protein.get(d)!] as const] : []));
    const low = pair.reduce<readonly [string, number] | undefined>((a, x) => (!a || x[1] < a[1] ? x : a), undefined);
    return low && low[1] < 120 ? [low] : [];
  });
  if (lowProtein.length) out.push({ title: `Protein under 120 g around ${count(lowProtein.length, "workout")}`, detail: `${list(lowProtein.map(([d, g]) => `${weekdayName(d)} ${round(g)} g`))}.` });

  const shortSleep = sessions.flatMap((s) => (sleep.has(s) && sleep.get(s)! < 6 ? [[s, sleep.get(s)!] as const] : []));
  if (shortSleep.length) out.push({ title: `Under 6 h of sleep before ${count(shortSleep.length, "workout")}`, detail: `${list(shortSleep.map(([d, h]) => `${weekdayName(d)} ${number(h)} h`))}. Say so on the day and it’ll go easier.` });

  const lowKcal = sessions.flatMap((s) => (kcal.has(s) && kcal.get(s)! < 2200 ? [[s, kcal.get(s)!] as const] : []));
  if (lowKcal.length) out.push({ title: `Under 2,200 kcal on ${count(lowKcal.length, "training day")}`, detail: `${list(lowKcal.map(([d, k]) => `${weekdayName(d)} ${round(k).toLocaleString("en-US")}`))}.` });

  // Notes from the 4 weeks to the week's end. FIT-54: "it's fine" holds until the area comes up again.
  const since = addDays(to, -28), byArea = new Map<string, string[]>();
  for (const note of input.notes.filter((n) => n.day >= since && n.day < to && hurts(n.text))) {
    const area = mentioned(note.text.toLowerCase().split(/[^\p{L}]+/u).filter(Boolean));
    if (area && note.at > (input.fine?.[area] ?? -Infinity)) byArea.set(area, [...(byArea.get(area) ?? []), note.day]);
  }
  const known = muscles(input.injured);
  for (const [area, days] of [...byArea].sort(([a], [b]) => a.localeCompare(b))) {
    if (days.length < 3 || [...muscles([area])].some((m) => known.has(m))) continue;
    out.push({ title: `${area[0].toUpperCase()}${area.slice(1)} came up in ${days.length} notes`, detail: `${list(days.sort().map(shortDate))}. Plans can go easier on it until you say it’s fine.`, area });
  }

  // review.md step 3: a main movement with no sets in 28 days, while training.
  const volume = new Map<string, number>();
  for (const s of (input.sets ?? []).filter((s) => s.day > addDays(to, -29) && s.day < to && s.pattern)) volume.set(s.pattern!, (volume.get(s.pattern!) ?? 0) + 1);
  if (volume.size) {
    const names: Record<string, string> = { squat: "squats", hinge: "hinges", push: "pushing", pull: "pulling" };
    const missing = ["squat", "hinge", "push", "pull"].filter((p) => !volume.get(p) && (!volume.has("lunge") || p !== "squat"));
    if (missing.length) out.push({ title: `No ${list(missing.map((p) => names[p]))} in 4 weeks`, detail: "Balanced training keeps every main movement in. Ask for some in a session, or regenerate the week." });
  }
  return out;
}

/** Every 4 weeks (not in the last 4), a goal well ahead or behind gets a proposed target, to the goal's step. */
export function checkIn(start: number, now: number, target: number, p: Pace, fc: number | undefined, step: number, week: number, weeks: number) {
  const done = week + 1, left = weeks - done;
  if (done % 4 !== 0 || left < 4 || fc === undefined || (p !== "ahead" && p !== "behind")) return undefined;
  const up = target >= start, proposed = round(fc / step) * step;
  if (p === "ahead") return { proposed: up ? Math.max(proposed, target + step) : Math.min(proposed, target - step), ahead: true, weeksLeft: left };
  if (!(up ? proposed < target && proposed > now : proposed > target && proposed < now)) return undefined;
  return { proposed, ahead: false, weeksLeft: left };
}

export type GoalRow = {
  id: string; goal: Goal; option: GoalOption; from: number; to: number; start: number; pace: Pace;
  forecast?: number; perWeek: number; checkIn?: ReturnType<typeof checkIn>;
};

/** WeekReport.make: the review of the week holding `today`, at the moment `nowSec`. */
export function weekReport(units: Units, today: string, nowSec: number, tz: string) {
  const profile = profileOf(units);
  const from = addDays(today, -new Date(`${today}T12:00:00Z`).getUTCDay()), to = addDays(from, 7);
  const sets = logSets(units), weighs = weighIns(units);
  const planned = plannedDays(units);
  const inWeek = sets.filter((s) => s.day >= from && s.day < to);
  const doneDays = new Set(inWeek.map((s) => s.day));
  const average = (m: Map<string, number>) => { const xs = [...m].filter(([d]) => d >= from && d < to).map(([, v]) => v); return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : undefined; };
  const last = weighs.filter((w) => w.day >= from && w.day < to).at(-1), before = weighs.filter((w) => w.day < from).at(-1);
  const numbers = {
    workoutsDone: doneDays.size,
    workoutsPlanned: new Set([...[...planned].filter((d) => d >= from && d < to), ...doneDays]).size,
    sets: inWeek.filter((s) => !RUNS.includes(s.exercise)).length,
    protein: average(dailyTotals(units, "meal", "protein_g")), kcal: average(dailyTotals(units, "meal", "kcal")), sleep: average(dailyTotals(units, "sleep", "sleep_h")),
    weight: last?.value, weightChange: last && before ? last.value - before.value : undefined,
    push: inWeek.filter((s) => s.pattern === "push").length, pull: inWeek.filter((s) => s.pattern === "pull").length,
    // FIT-177: the week's running, which isn't working sets.
    runKm: Math.round(inWeek.filter((s) => RUNS.includes(s.exercise)).reduce((n, s) => n + (value(s.measurements, "distance_m") ?? 0), 0) / 100) / 10,
  };
  const fine = (profile as Record<string, any> | undefined)?.fineAreas as Record<string, number> | undefined;
  const found = alerts(from, { sessions: planned, protein: dailyTotals(units, "meal", "protein_g"), kcal: dailyTotals(units, "meal", "kcal"),
    sleep: dailyTotals(units, "sleep", "sleep_h"), notes: notesOf(units), injured: profile?.injuredAreas ?? [], fine, sets });
  const report = { from, to: addDays(to, -1), numbers, alerts: found, goals: [] as GoalRow[], programWeek: undefined as number | undefined, programWeeks: undefined as number | undefined, end: undefined as number | undefined };
  const program = programOf(profile, tz);
  if (profile && program && profile.programStart) {
    const week = Math.max(0, Math.min(program.weeks.length - 1, weekIndex(today, program.start)));
    const end = profile.targetDate ?? epoch(weekStart(program.weeks.length, program.start), 0, tz);
    const startSec = profile.programStart, weekSec = epoch(from, 0, tz);
    Object.assign(report, { programWeek: week, programWeeks: program.weeks.length, end });
    for (const g of goalsOf(units).filter((g) => g.status === "active")) {
      const option = optionFor(g.metric);
      if (!option) continue;
      const first = g.baseline ?? g.target;
      const now = current(g.metric, sets, weighs, startSec) ?? first;
      const was = current(g.metric, sets.filter((s) => s.at < weekSec), weighs.filter((w) => w.at < weekSec), startSec) ?? first;
      const p = pace(first, now, g.target, week, program.weeks);
      const fc = forecast(first, now, startSec, nowSec, end);
      report.goals.push({ id: g.id, goal: g, option, from: was, to: now, start: first, pace: p, forecast: fc, perWeek: perWeek(now, g.target, nowSec, end),
        checkIn: checkIn(first, now, g.target, p, fc, stepOf(option), week, program.weeks.length) });
    }
  }
  return report;
}
export type WeekReport = ReturnType<typeof weekReport>;

const change = (r: GoalRow) => {
  const delta = r.to - r.from, unit = r.goal.unit === "reps" && Math.abs(delta) === 1 ? "rep" : r.goal.unit;
  if (r.option.measure === "time") return `${delta < 0 ? "faster by" : "slower by"} ${clock(Math.abs(delta))}`;
  return `${delta < 0 ? "down" : "up"} ${shown(Math.abs(delta), r.option)} ${unit}`;
};

/** "3 of 3 workouts. Squat up 9 lb." */
export function headline(r: WeekReport) {
  const parts: string[] = [];
  if (r.numbers.workoutsPlanned > 0) parts.push(`${r.numbers.workoutsDone} of ${r.numbers.workoutsPlanned} workouts.`);
  const progress = (g: GoalRow) => Math.abs(g.to - g.from) / Math.max(Math.abs(g.goal.target - g.start), 1);
  const moved = r.goals.filter((g) => g.to !== g.from && (g.to - g.from) * (g.goal.target - g.start) > 0)
    .reduce<GoalRow | undefined>((a, g) => (!a || progress(g) > progress(a) ? g : a), undefined);
  if (moved) parts.push(`${moved.option.short} ${change(moved)}.`);
  return parts.length ? parts.join(" ") : "Your week";
}

/** "Weight is behind. 2 goals to check in on." */
export function subline(r: WeekReport) {
  const behind = r.goals.filter((g) => g.pace === "behind").map((g) => g.option.short);
  const checks = r.goals.filter((g) => g.checkIn).length;
  const parts: string[] = [];
  if (behind.length) { const names = list(behind); parts.push(`${names[0].toUpperCase()}${names.slice(1).toLowerCase()} ${behind.length === 1 ? "is" : "are"} behind.`); }
  if (checks) parts.push(`${checks === 1 ? "1 goal" : `${checks} goals`} to check in on.`);
  if (r.alerts.length && parts.length < 2) parts.push(`${count(r.alerts.length, "thing")} worth a look.`);
  return parts.length ? parts.join(" ") : "Everything’s on pace.";
}

/** The facts a coach's take is written from; code says which went well and which need work. */
export function facts(r: WeekReport) {
  const good: string[] = [], work: string[] = [], plain: string[] = [];
  const { workoutsDone: done, workoutsPlanned: planned } = r.numbers;
  if (planned > 0) {
    if (done >= planned) good.push(`All ${planned} workouts done.`);
    else if (done === 0) work.push(`No workouts logged this week (${planned} planned).`);
    else work.push(`${done} of ${planned} workouts done.`);
  }
  for (const g of r.goals) {
    const now = g.option.measure === "time" ? `now ${shown(g.to, g.option)} for a ${shown(g.goal.target, g.option)} goal`
      : `now ${shown(g.to, g.option)} of a ${shown(g.goal.target, g.option)} ${g.goal.unit} goal`;
    if ((g.to - g.from) * (g.goal.target - g.start) > 0) good.push(`${g.option.name} ${change(g)} this week, ${now}.`);
    if (g.pace === "behind") work.push(`${g.option.name} is behind the plan's pace, ${now}.`);
  }
  if (r.numbers.protein !== undefined) plain.push(`Protein averaged ${round(r.numbers.protein)} g a day.`);
  if (r.numbers.sleep !== undefined) plain.push(`Sleep averaged ${number(r.numbers.sleep)} hours a night.`);
  work.push(...r.alerts.map((a) => `${a.title}.`));
  return [...good.map((x) => `Went well: ${x}`), ...work.map((x) => `Needs work: ${x}`), ...plain.map((x) => `Also: ${x}`)];
}
