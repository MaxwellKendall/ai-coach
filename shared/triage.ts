// FIT-132: which clients need their coach, from their synced units, never stored. A flag is something a coach acts
// on: sessions missed this past week, a very hard set (RPE 9+) on a main lift, a note the coach hasn't answered (pain
// words, WeeklyReview.hurts, come first), a main lift stalled, or nothing logged in two weeks. Flagged clients first.
//
// FIT-278: a goal that, at its rate since the program started, lands short of its target by its date.
//
// FIT-344: the weekly check-in (a log row of kind checkin): low ratings, or, once the coach has chosen a check-in day
// (the `checkin` unit), a check-in missed. What it says is a note like any other.
//
// FIT-196: shared by the dashboard (web/src/triage.ts) and the MCP's roster tools (infra/lambda/mcp.ts), so it imports
// nothing: units are each unit's JSON body by key, and days are YYYY-MM-DD strings.

export type Comment = { day: string; at: string; by: string; byName: string | null; text: string };
export type Flag = { kind: "pain" | "note" | "missed" | "hard" | "plateau" | "behind" | "checkin" | "quiet"; text: string };
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

/**
 * FIT-223: a day's check-in (FIT-204, or log_daily): the weigh-in, the night's sleep, and the client's note, which rides
 * on the sleep row, else the weight row (a weight row with no weight when the note is all there is). Undefined without one.
 */
export type CheckIn = { weight?: number; sleep?: number; note?: string };
export function checkIn(log: Row[]): CheckIn | undefined {
  const of = (kind: string) => log.filter((r) => r.kind === kind);
  const weight = of("bodyweight").map((r) => value(r, "weight_lb")).find((v) => v !== undefined);
  const sleep = of("sleep").map((r) => value(r, "sleep_h")).find((v) => v !== undefined);
  const note = [...of("sleep"), ...of("bodyweight")].map((r) => r.note?.trim()).find(Boolean);
  return weight === undefined && sleep === undefined && !note ? undefined : { weight, sleep, note };
}

/** FIT-344: WeeklyCheckIn.concerns: energy or following the plan at 2 or under, stress or soreness at 4 or over. */
export function concerns(r: Row): string[] {
  const out: string[] = [];
  const v = (metric: string) => value(r, metric);
  if ((v("energy_1to5") ?? 5) <= 2) out.push("low energy");
  if ((v("stress_1to5") ?? 1) >= 4) out.push("high stress");
  if ((v("soreness_1to5") ?? 1) >= 4) out.push("very sore");
  if ((v("adherence_1to5") ?? 5) <= 2) out.push("off the plan");
  return out;
}

/** FIT-344: the weekly check-in's flags: its ratings in the last 7 days, and a missed one on the coach's day. */
function weeklyCheckIn(units: Map<string, string>, today: string): string[] {
  const weekAgo = addDays(today, -7);
  const days = [...units.keys()].flatMap((k) => (k.startsWith("log#") ? [k.slice(4)] : [])).sort();
  const checked = days.filter((d) => rows(units, `log#${d}`).some((r) => r.kind === "checkin"));
  const out: string[] = [];
  const latest = checked.filter((d) => d >= weekAgo && d <= today).at(-1);
  const worries = latest ? rows(units, `log#${latest}`).filter((r) => r.kind === "checkin").flatMap(concerns) : [];
  if (worries.length) out.push(`Check-in: ${worries.join(", ")}`);
  const set = units.get("checkin");
  if (set) {
    // The latest check-in day before today (0 = Monday … 6 = Sunday), and nothing checked in since.
    const day = (JSON.parse(set) as { day: number }).day;
    const due = [1, 2, 3, 4, 5, 6, 7].map((n) => addDays(today, -n)).find((d) => (date(d).getUTCDay() + 6) % 7 === day);
    if (due && !checked.some((d) => d >= due && d <= today)) out.push(`Missed ${weekday(due)}’s check-in`);
  }
  return out;
}

/** Days with a planned workout, and days with a logged one. */
function trainingDays(units: Map<string, string>) {
  const planned: string[] = [], done: string[] = [];
  for (const key of units.keys()) {
    const day = /^(plan|log)#(.+)$/.exec(key);
    // FIT-349: a goal's test (GoalUpdate.marker in the app) isn't a session.
    if (!day || !rows(units, key).some((r) => r.kind === "workout" && !r.measurements?.some((m) => m.metric === "test"))) continue;
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

type Goal = { metric: string; target: number; deadline?: number; baseline?: number; status: string };
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const short = (epoch: number) => { const d = new Date(epoch * 1000); return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`; };
/** Coach.number: at most one decimal. */
const number = (x: number) => String(Math.round(x * 10) / 10);

/** GoalProgress.current for a max, reps or body weight since `since` (a race time isn't flagged here). */
function goalNow(units: Map<string, string>, metric: string, since: string): number | undefined {
  let best: number | undefined;
  let weighed: string | undefined;
  for (const key of units.keys()) {
    if (!key.startsWith("log#") || key.slice(4) < since) continue;
    const day = key.slice(4);
    for (const r of rows(units, key)) {
      if (metric === "weight_lb") {
        const w = r.kind === "bodyweight" ? value(r, "weight_lb") : undefined;
        if (w !== undefined && (!weighed || day > weighed)) { weighed = day; best = w; }
        continue;
      }
      const [exercise, kind] = metric.split(".");
      if (r.kind !== "workout" || r.template !== exercise) continue;
      const load = value(r, "load_lb"), reps = value(r, "reps");
      const v = kind === "1rm_lb" && load !== undefined && reps !== undefined && reps <= 12 ? Math.round((load * 36) / (37 - reps))
        : kind === "reps" && load === undefined ? reps : undefined;
      if (v !== undefined) best = Math.max(best ?? v, v);
    }
  }
  return best;
}

/**
 * FIT-278: GoalProgress.forecast to the goal's own date, else the program's, and how far short of the target it lands
 * (as on the goal card: "12 lb short of 250 by Jan 16"). Not before two weeks of the program; a goal that hasn't moved
 * toward its target lands where it is.
 */
function behind(units: Map<string, string>, names: Map<string, string>, today: string): string[] {
  const profile = units.get("profile");
  const { programStart, targetDate } = profile ? (JSON.parse(profile) as { programStart?: number; targetDate?: number }) : {};
  const now = date(today).getTime() / 1000;
  if (programStart === undefined || now - programStart < 14 * 86_400) return [];
  const out: string[] = [];
  for (const [key, body] of [...units].sort(([a], [b]) => a.localeCompare(b))) {
    if (!key.startsWith("goal#")) continue;
    const g = JSON.parse(body) as Goal;
    const due = g.deadline ?? targetDate;
    if (g.status !== "active" || g.baseline === undefined || due === undefined || due <= now) continue;
    if (g.metric !== "weight_lb" && !/\.(1rm_lb|reps)$/.test(g.metric)) continue;
    const start = g.baseline, logged = goalNow(units, g.metric, new Date(programStart * 1000).toISOString().slice(0, 10));
    const at = logged === undefined ? start : g.metric === "weight_lb" ? logged : Math.max(logged, start);
    const way = g.metric === "weight_lb" && g.target < start ? -1 : 1;
    const moved = (at - start) * way > 0;
    const lands = moved ? Math.max(0, at + ((at - start) / (now - programStart)) * (due - now)) : at;
    const gap = (g.target - lands) * way;
    if (gap <= 0) continue;
    const name = g.metric === "weight_lb" ? "Weight" : names.get(g.metric.split(".")[0]) ?? g.metric.split(".")[0];
    const unit = g.metric.endsWith(".reps") ? (Math.round(gap) === 1 ? "rep" : "reps") : "lb";
    const amount = g.metric === "weight_lb" ? number(gap) : String(Math.max(1, Math.round(gap)));
    out.push(`${name}: ${amount} ${unit} short of ${number(g.target)} by ${short(due)}`);
  }
  return out;
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
  // row (each set's note is the session's name, WorkoutDraft.save), or on the day's check-in (FIT-223).
  const weekAgo = addDays(today, -7);
  const replied = (day: string) => comments.some((c) => c.day === day && c.by === coach);
  const logged = [...units.keys()].flatMap((k) => (k.startsWith("log#") && k.slice(4) >= weekAgo ? [k.slice(4)] : []));
  for (const day of logged.sort().reverse()) {
    const log = rows(units, `log#${day}`);
    const notes = [...log.filter((r) => r.kind === "workout" && !r.template).map((r) => r.note), checkIn(log)?.note,
      ...log.filter((r) => r.kind === "checkin").map((r) => r.note?.replace(/\n/g, " "))].filter(Boolean);
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

  for (const text of behind(units, names, today)) flags.push({ kind: "behind", text });
  for (const text of weeklyCheckIn(units, today)) flags.push({ kind: "checkin", text });

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

const order: Flag["kind"][] = ["pain", "missed", "hard", "plateau", "behind", "checkin", "quiet", "note"];
/** Clients who need the coach first: by their most pressing flag, then by how many. */
export function byNeed<T extends { triage?: Triage }>(clients: T[]): T[] {
  const rank = (t?: Triage) => (t && t.flags.length ? Math.min(...t.flags.map((f) => order.indexOf(f.kind))) : order.length);
  return [...clients].sort((a, b) => rank(a.triage) - rank(b.triage) || (b.triage?.flags.length ?? 0) - (a.triage?.flags.length ?? 0));
}
