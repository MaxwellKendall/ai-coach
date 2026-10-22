// FIT-132: which clients need their coach, from their synced units, never stored. A flag is something a coach acts
// on: sessions missed this past week, a very hard set (RPE 9+) on a main lift, a note the coach hasn't answered (pain
// words, WeeklyReview.hurts, come first), a main lift stalled, or nothing logged in two weeks. Flagged clients first.
//
// FIT-196: shared by the dashboard (web/src/triage.ts) and the MCP's roster tools (infra/lambda/mcp.ts), so it imports
// nothing: units are each unit's JSON body by key, and days are YYYY-MM-DD strings.

export type Comment = { day: string; at: string; by: string; byName: string | null; text: string };
export type Flag = { kind: "pain" | "note" | "missed" | "hard" | "plateau" | "quiet"; text: string };
export type Triage = {
  done: number;
  planned: number;
  streak?: number;
  lastSession?: string;
  flags: Flag[];
};

type Row = { id: string; kind: string; template?: string; plannedRef?: string; main?: boolean; note?: string; measurements?: { metric: string; value: number }[] };

/** WeeklyReview.hurts: the words that mean something hurts. */
export const hurts = (text: string) =>
  ["pain", "sore", "hurt", "ache", "tight", "tweak", "twinge", "strain", "sharp", "niggle"].some((w) => text.toLowerCase().includes(w));

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const date = (day: string) => new Date(`${day}T12:00:00Z`);
export const addDays = (day: string, n: number) => new Date(date(day).getTime() + n * 86_400_000).toISOString().slice(0, 10);
/** The Sunday on or before a day (FIT-82's weeks). */
export const sundayOf = (day: string) => addDays(day, -date(day).getUTCDay());
const weekday = (day: string) => DAYS[date(day).getUTCDay()];
/** The day an epoch falls on in a time zone (the device's when none is given). */
const dayIn = (epoch: number, tz?: string) => new Intl.DateTimeFormat("en-CA", { timeZone: tz }).format(new Date(epoch * 1000));

const rows = (units: Map<string, string>, key: string): Row[] => {
  const body = units.get(key);
  return body ? (JSON.parse(body) as Row[]) : [];
};
const value = (r: Row, metric: string) => r.measurements?.find((m) => m.metric === metric)?.value;

/** Days with a planned workout, and days with a logged one. */
function trainingDays(units: Map<string, string>) {
  const planned: string[] = [], done: string[] = [];
  for (const key of units.keys()) {
    const day = /^(plan|log)#(.+)$/.exec(key);
    if (!day || !rows(units, key).some((r) => r.kind === "workout")) continue;
    (day[1] === "plan" ? planned : done).push(day[2]);
  }
  return { planned, done };
}

/** Brzycki, fitness-planner CLAUDE.md "1RM Estimation": valid for 1–10 reps at RPE ≤ 8. */
function estimate(r: Row) {
  const load = value(r, "load_lb"), reps = value(r, "reps"), rpe = value(r, "rpe");
  if (load === undefined || reps === undefined || reps < 1 || reps > 10 || (rpe ?? 0) > 8) return undefined;
  return (load * 36) / (37 - reps);
}

/** FIT-140: Training.plateaued: logged on `days`+ days in the `window` days before today, none beating the best before. */
function plateaued(units: Map<string, string>, exercise: string, today: string, window = 21, days = 3) {
  const start = addDays(today, -window);
  let before = 0;
  const recent = new Map<string, number>();
  for (const key of units.keys()) {
    if (!key.startsWith("log#")) continue;
    const day = key.slice(4);
    for (const r of rows(units, key)) {
      if (r.kind !== "workout" || r.template !== exercise) continue;
      const e = estimate(r);
      if (e === undefined) continue;
      if (day < start) before = Math.max(before, e);
      else if (day < today) recent.set(day, Math.max(recent.get(day) ?? 0, e));
    }
  }
  return before > 0 && recent.size >= days && Math.max(...recent.values()) <= before;
}

/** Streak.status's weeks: weeks in a row with as many days trained as sessions planned (FIT-121), from the program's start. */
function streakWeeks(start: string, planned: string[], done: string[], today: string) {
  const first = sundayOf(start), thisWeek = Math.floor((date(sundayOf(today)).getTime() - date(first).getTime()) / (7 * 86_400_000));
  if (thisWeek < 0) return 0;
  const inWeek = (days: string[], w: number) => days.filter((d) => d >= addDays(first, 7 * w) && d < addDays(first, 7 * w + 7));
  let weeks = 0;
  for (let w = 0; w < thisWeek; w++) {
    const days = inWeek(planned, w);
    if (days.length === 0) continue;
    weeks = inWeek(done, w).length >= days.length ? weeks + 1 : 0;
  }
  const days = inWeek(planned, thisWeek);
  return days.length && inWeek(done, thisWeek).length >= days.length ? weeks + 1 : weeks;
}

/** One client's week: sessions done of planned (Sunday to Saturday), the last session, the streak and the flags. */
export function triage(units: Map<string, string>, comments: Comment[], names: Map<string, string>, coach: string, today: string, tz?: string): Triage {
  const { planned, done } = trainingDays(units);
  const start = sundayOf(today), end = addDays(start, 7);
  const thisWeek = (d: string) => d >= start && d < end;
  const lastSession = [...done].sort().at(-1);
  const flags: Flag[] = [];

  // A note in the last 7 days that the coach hasn't replied to after. The client's words are on the session's summary
  // row; each set's note is the session's name (WorkoutDraft.save).
  const weekAgo = addDays(today, -7);
  const replied = (day: string) => comments.some((c) => c.day === day && c.by === coach);
  for (const day of done.filter((d) => d >= weekAgo).sort().reverse()) {
    const notes = rows(units, `log#${day}`).filter((r) => r.kind === "workout" && !r.template).map((r) => r.note).filter(Boolean);
    const text = [...new Set(notes)].join(" ");
    if (!text || replied(day)) continue;
    flags.push({ kind: hurts(text) ? "pain" : "note", text: `${weekday(day)}: “${text}”` });
  }

  // Sessions planned in the last 7 days, before today, with nothing logged that day.
  const missed = planned.filter((d) => d >= weekAgo && d < today && !done.includes(d));
  if (missed.length >= 2) flags.push({ kind: "missed", text: `Missed ${missed.length} sessions this past week` });

  // A main lift at RPE 9 or more in the last 7 days (the plan row says which lifts are main).
  const main = new Set<string>(), mainLifts = new Set<string>();
  for (const key of units.keys()) if (key.startsWith("plan#")) for (const r of rows(units, key)) if (r.main) {
    main.add(r.id);
    if (r.template) mainLifts.add(r.template);
  }
  const hard = new Set<string>();
  for (const day of done.filter((d) => d >= weekAgo)) {
    for (const r of rows(units, `log#${day}`)) {
      const rpe = value(r, "rpe");
      if (rpe !== undefined && rpe >= 9 && r.plannedRef && main.has(r.plannedRef) && r.template) hard.add(names.get(r.template) ?? r.template);
    }
  }
  if (hard.size) flags.push({ kind: "hard", text: `RPE 9+ on ${[...hard].join(", ")}` });

  // FIT-140: a main lift with no new best in three weeks of training it.
  const stalled = [...mainLifts].filter((slug) => plateaued(units, slug, today)).map((slug) => names.get(slug) ?? slug);
  if (stalled.length) flags.push({ kind: "plateau", text: `No new best on ${stalled.join(", ")} in 3 weeks` });

  // Planned but nothing logged for two weeks.
  if (planned.some((d) => d < today) && (!lastSession || lastSession < addDays(today, -14))) {
    flags.push({ kind: "quiet", text: lastSession ? "Nothing logged in over two weeks" : "Nothing logged yet" });
  }

  const profile = units.get("profile");
  const programStart: number | undefined = profile ? JSON.parse(profile).programStart : undefined;
  return {
    done: done.filter(thisWeek).length,
    planned: planned.filter(thisWeek).length,
    streak: programStart === undefined ? undefined : streakWeeks(dayIn(programStart, tz), planned, done, today),
    lastSession,
    flags,
  };
}

const order: Flag["kind"][] = ["pain", "missed", "hard", "plateau", "quiet", "note"];
/** Clients who need the coach first: by their most pressing flag, then by how many. */
export function byNeed<T extends { triage?: Triage }>(clients: T[]): T[] {
  const rank = (t?: Triage) => (t && t.flags.length ? Math.min(...t.flags.map((f) => order.indexOf(f.kind))) : order.length);
  return [...clients].sort((a, b) => rank(a.triage) - rank(b.triage) || (b.triage?.flags.length ?? 0) - (a.triage?.flags.length ?? 0));
}
