import { programOf, type ProgramWeek } from "./program.ts";
import { GOAL_OPTIONS, type GoalOption, type Win, type WeekReport } from "./progress.ts";
import { addDays, logOf, nameOf, planOf, WARMUP, type Goal, type PlanRow, type Profile, type Units } from "./training.ts";

// FIT-169: what a share saves for its page (sharePages.ts reads it), built as the app builds it: SharedWin, Recap,
// SharedSession and SharedProgram. createShare's row holds it; the page shows the sharer's display name.

/** "Back squat", "Pull-ups": GoalOption.liftName. */
const liftName = (o: GoalOption) => o.name.replace(" max", "").replace(" in a row", "");
/** WinWords.shortName. */
const SHORT: Record<string, string> = { squat: "squat", bench: "bench", deadlift: "deadlift", pullups: "pull-up", pushups: "push-up" };
const round1 = (x: number) => Math.round(x * 10) / 10;

/** SharedWin.payload. Without weights, a best goes as percent of the last best and a milestone as percent of the goal. */
export function winPayload(win: Win, showNumbers: boolean, style: "dark" | "paper" = "dark") {
  const option = GOAL_OPTIONS.find((o) => o.metric === win.metric);
  const p: Record<string, unknown> = { date: win.day, showNumbers, style };
  if (win.kind === "pr") {
    Object.assign(p, { kind: "pr", metric: option ? liftName(option) : win.metric, unit: win.unit });
    if (showNumbers) Object.assign(p, { value: win.value, ...(win.previous !== undefined ? { previous: win.previous } : {}), trend: win.trend ?? [] });
    else {
      const base = win.previous ?? win.value, percent = (v: number) => Math.round((v / Math.max(base, 1)) * 1000) / 10;
      Object.assign(p, { value: percent(win.value), previous: 100, trend: (win.trend ?? []).map(percent), unit: "%" });
    }
  } else if (win.kind === "milestone") {
    Object.assign(p, { kind: "milestone", metric: SHORT[option?.id ?? ""] ?? "weight", unit: showNumbers ? win.unit : "%", percent: win.percent ?? 0,
      value: showNumbers ? win.value : win.percent ?? 0, target: showNumbers ? win.target : 100 });
  } else Object.assign(p, { kind: "streak", metric: "Training", unit: "weeks", value: win.value });
  return p;
}

/** Sessions planned from the start to today, and those done (TodayScreen.programSessions). */
export function programSessions(units: Units, start: string, today: string) {
  const planned = new Set<string>(), done = new Set<string>();
  for (const key of units.keys()) {
    const day = key.slice(key.indexOf("#") + 1);
    if (day < start) continue;
    if (key.startsWith("plan#") && day <= today && planOf(units, day).some((r) => r.kind === "workout")) planned.add(day);
    if (key.startsWith("log#") && logOf(units, day).some((r) => r.kind === "workout")) done.add(day);
  }
  return { done: [...planned].filter((d) => done.has(d)).length, planned: planned.size };
}

/** Recap.make and its payload: the week's card, and on the last week the whole program's. */
export function recapPayload(report: WeekReport, weeks: ProgramWeek[], wins: Win[], program: { done: number; planned: number }, showNumbers: boolean) {
  if (report.programWeek === undefined || report.programWeeks === undefined) return undefined;
  const index = report.programWeek, last = index + 1 >= report.programWeeks;
  const lifts = report.goals.filter((g) => g.option.measure !== "body").slice(0, 3)
    .map((g) => ({ name: liftName(g.option), from: last ? g.start : g.from, to: g.to, unit: g.goal.unit }));
  const bests = wins.filter((w) => w.kind === "pr" && (last || (w.day >= report.from && w.day <= report.to))).length;
  return {
    week: index + 1, weeks: report.programWeeks, phase: weeks[index]?.phase ?? "base",
    sessions: last ? program : { done: report.numbers.workoutsDone, planned: report.numbers.workoutsPlanned }, bests, showNumbers,
    lifts: lifts.filter((l) => l.from > 0).map((l) => (showNumbers ? { metric: l.name, from: l.from, to: l.to, unit: l.unit }
      : { metric: l.name, from: 100, to: round1((l.to / l.from) * 100), unit: "%" })),
  };
}

/** SharedSession.make: a day's planned workout, one entry per exercise (warm-ups out), in order. */
export function sessionPayload(rows: PlanRow[], day: string, tz: string, showNumbers: boolean) {
  const work = rows.filter((r) => r.kind === "workout" && r.note !== WARMUP && r.template).sort((a, b) => a.at - b.at);
  const v = (r: PlanRow, m: string) => r.targets.find((t) => t.metric === m)?.value;
  const exercises: { exercise: string; name: string; sets: number; reps?: number; seconds?: number; load?: number; unit?: string }[] = [];
  for (const r of work) {
    const sets = Math.trunc(v(r, "sets") ?? 1), load = v(r, "load_lb") ?? v(r, "load_lb_hand"), last = exercises.at(-1);
    if (last && last.exercise === r.template) {
      last.sets += sets;
      if (showNumbers && load !== undefined) last.load = Math.max(last.load ?? 0, load);
      continue;
    }
    exercises.push({ exercise: r.template!, name: nameOf(r.template), sets, reps: v(r, "reps") === undefined ? undefined : Math.trunc(v(r, "reps")!),
      seconds: v(r, "duration_s") === undefined ? undefined : Math.trunc(v(r, "duration_s")!), load: showNumbers ? load : undefined,
      unit: showNumbers && load !== undefined ? (v(r, "load_lb_hand") !== undefined ? "lb/hand" : "lb") : undefined });
  }
  const sets = exercises.reduce((n, e) => n + e.sets, 0);
  const time = work[0] ? new Date(work[0].at * 1000).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: tz }) : undefined;
  return { title: (work[0]?.slot ?? "Workout").slice(0, 40), date: day, time, minutes: sets > 0 ? Math.trunc((sets * 2.5 + 5) / 5) * 5 : undefined, exercises };
}

/** GoalOption.title(target) and the deadline, as Planner.goalLines. */
function goalLines(goals: Goal[], tz: string) {
  return goals.filter((g) => g.status === "active").flatMap((g) => {
    const o = GOAL_OPTIONS.find((x) => x.metric === g.metric);
    if (!o) return [];
    const n = Math.round(g.target);
    const title = { weight: `Get to ${n} lb`, squat: `Squat ${n}`, bench: `Bench ${n}`, deadlift: `Deadlift ${n}`, pullups: `${n} pull-ups`, pushups: `${n} push-ups` }[o.id];
    const by = g.deadline ? ` by ${new Date(g.deadline * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: tz })}` : "";
    return [`${title}${by}`];
  });
}

export type Brief = { phases: { phase: string; focus: string; mainLifts: string[]; mainReps: number; accessoryReps: number }[] };

/** SharedProgram.make: the program as its brief, goals, days, equipment and this week's sessions; never weights or logs. */
export function programPayload(units: Units, profile: Profile & { brief?: { brief: Brief } }, goals: Goal[], today: string, tz: string) {
  const program = programOf(profile, tz), brief = profile.brief?.brief;
  if (!program || !brief) return undefined;
  const lines = goalLines(goals, tz);
  const phases = brief.phases.flatMap((line) => {
    const weeks = program.weeks.flatMap((w, i) => (w.phase === line.phase && w.kind !== "deload" && w.kind !== "test" ? [i] : []));
    return weeks.length ? [{ phase: line.phase, from: weeks[0] + 1, to: weeks.at(-1)! + 1, focus: line.focus, mainLifts: line.mainLifts, mainReps: line.mainReps }] : [];
  });
  const sunday = addDays(today, -new Date(`${today}T12:00:00Z`).getUTCDay());
  const sampleWeek = Array.from({ length: 7 }, (_, i) => addDays(sunday, i)).filter((d) => planOf(units, d).some((r) => r.kind === "workout")).map((d) => {
    const s = sessionPayload(planOf(units, d), d, tz, false);
    return { day: new Date(`${d}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" }), title: s.title,
      items: s.exercises.slice(0, 12).map((e) => `${e.name} ${e.sets} × ${e.reps ?? (e.seconds !== undefined ? `${e.seconds} s` : "")}`) };
  });
  const kit = new Set(profile.equipment ?? []);
  return {
    name: lines[0] ?? `${program.weeks.length}-week program`, weeks: program.weeks.length, days: (profile.trainingDays ?? []).length,
    equipment: kit.has("barbell") && kit.has("rack") ? "Full gym" : kit.has("dumbbells") ? "Dumbbells" : "Bodyweight",
    goals: lines.slice(0, 4), phases, sampleWeek, brief,
  };
}
