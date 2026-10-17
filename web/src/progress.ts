import { dayKey, weekStart } from "./program";
import type { LogRow, PlanRow, Unit } from "./sync";

// FIT-129: progress from synced logs, never stored. The same rules as the app's Core/Progress (Training, Streak), held
// to one fixture with it (Tests/Fixtures/progress-parity.json).

export type LoggedSet = { day: string; exercise: string; value: (metric: string) => number | undefined };

/** Brzycki, fitness-planner CLAUDE.md "1RM Estimation": valid for 1–10 reps at RPE ≤ 8. */
export function estimated1RM(load: number, reps: number, rpe?: number): number | undefined {
  if (reps < 1 || reps > 10 || (rpe ?? 0) > 8) return undefined;
  return (load * 36) / (37 - reps);
}

const estimate = (set: LoggedSet) => {
  const load = set.value("load_lb"), reps = set.value("reps");
  return load !== undefined && reps !== undefined ? estimated1RM(load, reps, set.value("rpe")) : undefined;
};

/** Best estimate per exercise; estimates never regress (review.md step 4). */
export function estimated1RMs(sets: LoggedSet[]): Record<string, number> {
  const best: Record<string, number> = {};
  for (const set of sets) {
    const e = estimate(set);
    if (e !== undefined) best[set.exercise] = Math.max(best[set.exercise] ?? 0, e);
  }
  return best;
}

/** Best estimate so far, one point per training day. */
export function estimated1RMTrend(sets: LoggedSet[], exercise: string): [string, number][] {
  const byDay = new Map<string, number>();
  for (const set of sets.filter((s) => s.exercise === exercise)) {
    const e = estimate(set);
    if (e !== undefined) byDay.set(set.day, Math.max(byDay.get(set.day) ?? 0, e));
  }
  let best = 0;
  return [...byDay.keys()].sort().map((day) => [day, (best = Math.max(best, byDay.get(day)!))]);
}

const parse = (key: string) => {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d);
};
const addDays = (date: Date, n: number) => new Date(date.getFullYear(), date.getMonth(), date.getDate() + n);

/** Program week of a day (Sunday weeks, ProgramPlan.week). */
function weekIndex(day: Date, start: Date) {
  return Math.floor(Math.round((weekStart(day).getTime() - weekStart(start).getTime()) / 86_400_000) / 7);
}

export type StreakStatus = { weeks: number; thisWeek: "onTrack" | "full" | "atRisk" | "broken" };

/** Streak.status: weeks in a row with as many days trained as sessions planned (FIT-121). */
export function streak(start: string, plannedDays: string[], workoutDays: string[], today: string): StreakStatus {
  const s = parse(start), t = parse(today);
  const planned = new Set(plannedDays), done = new Set(workoutDays);
  const inWeek = (days: Set<string>, w: number) => {
    const from = addDays(weekStart(s), 7 * w), to = addDays(from, 7);
    return [...days].filter((d) => parse(d) >= from && parse(d) < to);
  };
  const thisWeek = weekIndex(t, s);
  let weeks = 0;
  for (let w = 0; w < Math.max(0, thisWeek); w++) {
    const days = inWeek(planned, w);
    if (days.length === 0) continue;
    weeks = inWeek(done, w).length >= days.length ? weeks + 1 : 0;
  }
  if (thisWeek < 0) return { weeks: 0, thisWeek: "onTrack" };
  const days = inWeek(planned, thisWeek), trained = inWeek(done, thisWeek);
  if (days.length && trained.length >= days.length) return { weeks: weeks + 1, thisWeek: "full" };
  const missed = days.filter((d) => d < today && !done.has(d));
  if (!missed.length) return { weeks, thisWeek: "onTrack" };
  const next = addDays(weekStart(s), 7 * (thisWeek + 1));
  const left = Math.round((next.getTime() - t.getTime()) / 86_400_000) - (done.has(today) ? 1 : 0);
  return { weeks, thisWeek: trained.length + left >= days.length ? "atRisk" : "broken" };
}

/** Logged workout sets from the synced log units. */
export function loggedSets(units: Map<string, Unit>): LoggedSet[] {
  const out: LoggedSet[] = [];
  for (const [key, unit] of units) {
    if (!key.startsWith("log#") || !unit.body) continue;
    for (const row of JSON.parse(unit.body) as LogRow[]) {
      if (row.kind !== "workout" || !row.template) continue;
      out.push({ day: key.slice(4), exercise: row.template, value: (m) => row.measurements.find((x) => x.metric === m)?.value });
    }
  }
  return out;
}

/** Days with a planned workout, and days with a logged one. */
export function trainingDays(units: Map<string, Unit>) {
  const planned: string[] = [], done: string[] = [];
  for (const [key, unit] of units) {
    if (!unit.body) continue;
    const rows = JSON.parse(unit.body) as (PlanRow | LogRow)[];
    if (!rows.some((r) => r.kind === "workout")) continue;
    if (key.startsWith("plan#")) planned.push(key.slice(5));
    if (key.startsWith("log#")) done.push(key.slice(4));
  }
  return { planned, done };
}

/** The account's streak now, from its profile's program start; undefined without one. */
export function streakNow(units: Map<string, Unit>, today = new Date()): StreakStatus | undefined {
  const profile = units.get("profile")?.body;
  const start: number | undefined = profile ? JSON.parse(profile).programStart : undefined;
  if (start === undefined) return undefined;
  const { planned, done } = trainingDays(units);
  return streak(dayKey(new Date(start * 1000)), planned, done, dayKey(today));
}

/** "4 weeks in a row", from 2 (Streak.line). */
export const streakLine = (s?: StreakStatus) => (s && s.weeks >= 2 && s.thisWeek !== "broken" ? `${s.weeks} weeks in a row` : undefined);
