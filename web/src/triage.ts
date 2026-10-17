import { dayKey, weekStart } from "./program";
import { streakNow, trainingDays } from "./progress";
import type { LogRow, PlanRow, Unit } from "./sync";

// FIT-132: which clients need their coach, from their synced units, never stored. A flag is something a coach acts
// on: sessions missed this past week, a very hard set (RPE 9+) on a main lift, a note the coach hasn't answered (pain
// words, WeeklyReview.hurts, come first), or nothing logged in two weeks. Flagged clients first.

export type Comment = { day: string; at: string; by: string; byName: string | null; text: string };
export type Flag = { kind: "pain" | "note" | "missed" | "hard" | "quiet"; text: string };
export type Triage = {
  done: number;
  planned: number;
  streak?: number;
  lastSession?: string;
  flags: Flag[];
};

/** WeeklyReview.hurts: the words that mean something hurts. */
export const hurts = (text: string) =>
  ["pain", "sore", "hurt", "ache", "tight", "tweak", "twinge", "strain", "sharp", "niggle"].some((w) => text.toLowerCase().includes(w));

const rows = <T>(unit?: Unit): T[] => (unit?.body ? JSON.parse(unit.body) : []);
const shift = (date: Date, days: number) => new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);
const weekday = (key: string) => {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { weekday: "long" });
};

export function triage(units: Map<string, Unit>, comments: Comment[], names: Map<string, string>, coach: string, now = new Date()): Triage {
  const today = dayKey(now);
  const { planned, done } = trainingDays(units);
  const start = dayKey(weekStart(now)), end = dayKey(shift(weekStart(now), 7));
  const thisWeek = (d: string) => d >= start && d < end;
  const lastSession = [...done].sort().at(-1);
  const flags: Flag[] = [];

  // A note in the last 7 days that the coach hasn't replied to after.
  const weekAgo = dayKey(shift(now, -7));
  const replied = (day: string) => comments.some((c) => c.day === day && c.by === coach);
  for (const day of [...done].filter((d) => d >= weekAgo).sort().reverse()) {
    const notes = rows<LogRow>(units.get(`log#${day}`)).map((r) => r.note).filter(Boolean);
    const text = [...new Set(notes)].join(" ");
    if (!text || replied(day)) continue;
    flags.push(hurts(text) ? { kind: "pain", text: `${weekday(day)}: “${text}”` } : { kind: "note", text: `${weekday(day)}: “${text}”` });
  }

  // Sessions planned in the last 7 days, before today, with nothing logged that day.
  const missed = planned.filter((d) => d >= weekAgo && d < today && !done.includes(d));
  if (missed.length >= 2) flags.push({ kind: "missed", text: `Missed ${missed.length} sessions this past week` });

  // A main lift at RPE 9 or more in the last 7 days (the plan row says which lifts are main).
  const main = new Set<string>();
  for (const [key, unit] of units) if (key.startsWith("plan#")) for (const r of rows<PlanRow>(unit)) if (r.main) main.add(r.id);
  const hard = new Set<string>();
  for (const day of done.filter((d) => d >= weekAgo)) {
    for (const r of rows<LogRow>(units.get(`log#${day}`))) {
      const rpe = r.measurements.find((m) => m.metric === "rpe")?.value;
      if (rpe !== undefined && rpe >= 9 && r.plannedRef && main.has(r.plannedRef) && r.template) hard.add(names.get(r.template) ?? r.template);
    }
  }
  if (hard.size) flags.push({ kind: "hard", text: `RPE 9+ on ${[...hard].join(", ")}` });

  // Planned but nothing logged for two weeks.
  if (planned.some((d) => d < today) && (!lastSession || lastSession < dayKey(shift(now, -14)))) {
    flags.push({ kind: "quiet", text: lastSession ? "Nothing logged in over two weeks" : "Nothing logged yet" });
  }

  return {
    done: done.filter(thisWeek).length,
    planned: planned.filter(thisWeek).length,
    streak: streakNow(units, now)?.weeks,
    lastSession,
    flags,
  };
}

const order: Flag["kind"][] = ["pain", "missed", "hard", "quiet", "note"];
/** Clients who need the coach first: by their most pressing flag, then by how many. */
export function byNeed<T extends { triage?: Triage }>(clients: T[]): T[] {
  const rank = (t?: Triage) => (t && t.flags.length ? Math.min(...t.flags.map((f) => order.indexOf(f.kind))) : order.length);
  return [...clients].sort((a, b) => rank(a.triage) - rank(b.triage) || (b.triage?.flags.length ?? 0) - (a.triage?.flags.length ?? 0));
}
