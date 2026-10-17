import { addDays, bySlug, dayOf, nameOf, WARMUP, type PlanRow, type Profile } from "./training.ts";

// FIT-165: the program's skeleton, as Core/Generators/ProgramPlan.swift (FIT-36) builds it from the profile, so an agent
// sees the same weeks as the phone's Program tab. Repeated here because the Lambda can't import the Swift. Weeks run
// Sunday to Saturday (Week.swift, FIT-82); days are YYYY-MM-DD in the person's time zone.

export type Phase = "base" | "build" | "peak";
export type ProgramWeek = { phase: Phase; kind: Phase | "deload" | "test"; travel: boolean };

/** Deload and test weeks are the light ones. */
export const isLight = (w: ProgramWeek) => w.kind === "deload" || w.kind === "test";

/** TrainingGenerator.deloadRPE: the RPE cap in a light week (plan.md step 4). */
const DELOAD_RPE = 6;

/** Away from the usual gym: dumbbells and bodyweight only. */
export const TRAVEL_EQUIPMENT = ["dumbbells"];

/** AgeTier.of(age).deloadEveryWeeks (fitness-planner CLAUDE.md "Deload"). */
export function deloadEvery(age: number) {
  return age < 30 ? 7 : age < 40 ? 6 : age < 50 ? 5 : 4;
}

/** Week.start: the Sunday on or before a day. */
export const sundayOf = (day: string) => addDays(day, -new Date(`${day}T12:00:00Z`).getUTCDay());

const daysBetween = (a: string, b: string) => Math.round((Date.parse(`${b}T12:00:00Z`) - Date.parse(`${a}T12:00:00Z`)) / 86_400_000);

/** Which week of the program a day falls in; negative before the start. */
export const weekIndex = (day: string, start: string) => Math.floor(daysBetween(sundayOf(start), sundayOf(day)) / 7);

/** Weeks from the start through the week holding the target date. At least one. */
export const weekCount = (start: string, target: string) => Math.max(1, weekIndex(target, start) + 1);

/** The Sunday week `index` starts on. */
export const weekStart = (index: number, start: string) => addDays(sundayOf(start), 7 * index);

/**
 * Base for the first 35% of weeks, build to 75%, then peak; the last week tests the goals. A deload every `every`
 * weeks, except that the last week of a trip takes the deload once half that time has passed, so the light week falls
 * while away.
 */
export function programWeeks(count: number, every: number, travel: Set<number> = new Set()): ProgramWeek[] {
  let since = 0;
  return Array.from({ length: count }, (_, i) => {
    const phase: Phase = i < Math.round(count * 0.35) ? "base" : i < Math.round(count * 0.75) ? "build" : "peak";
    const week: ProgramWeek = { phase, kind: phase, travel: travel.has(i) };
    const tripEnds = travel.has(i) && !travel.has(i + 1);
    if (i === count - 1) week.kind = "test";
    else if (since + 1 >= every || (tripEnds && since + 1 >= Math.floor((every + 1) / 2))) week.kind = "deload";
    since = week.kind === "deload" ? 0 : since + 1;
    return week;
  });
}

/** The profile's program (Profile.program), when it has one. */
export function programOf(profile: Profile | undefined, tz: string) {
  if (!profile?.programStart || !profile.targetDate) return undefined;
  const start = dayOf(new Date(profile.programStart * 1000), tz), target = dayOf(new Date(profile.targetDate * 1000), tz);
  const every = profile.deloadEveryWeeks ?? deloadEvery(profile.age ?? 35);
  return { start, target, every, weeks: programWeeks(weekCount(start, target), every, new Set(profile.travelWeeks ?? [])) };
}

/** The program week a day falls in, if it's within the program. */
export function programWeekOf(profile: Profile | undefined, day: string, tz: string) {
  const program = programOf(profile, tz);
  if (!program) return undefined;
  const index = weekIndex(day, program.start);
  return index >= 0 && index < program.weeks.length ? { index, week: program.weeks[index] } : undefined;
}

/** The program weeks a trip takes a training day from (0 = Monday, as profiles store days). */
export function travelWeeks(from: string, to: string, start: string, count: number, trainingDays: number[]) {
  const out: number[] = [];
  for (let week = 0; week < count; week++) {
    const sunday = weekStart(week, start);
    if (trainingDays.some((d) => { const date = addDays(sunday, (d + 1) % 7); return date >= from && date <= to; })) out.push(week);
  }
  return out;
}

/** VolumePlan.of: sets per session from days a week and minutes (fitness-planner CLAUDE.md "Schedule → Volume Mapping"). */
export function setsPerSession(days: number, minutes: number): [number, number] {
  const long = minutes >= 60;
  if (days <= 2) return long ? [20, 24] : [14, 18];
  if (days <= 4) return long ? [18, 22] : [14, 18];
  return [16, 22];
}

/** PlanGuard.lightShare: a light week's session is at most this share of the volume table's top. */
export const lightSessionMost = (profile: Profile) =>
  Math.floor(setsPerSession(profile.trainingDays?.length ?? 3, profile.sessionMinutes ?? 45)[1] * 0.7);

/** ProgramPlan.weeklySets: the working sets a week aims for, by phase; light weeks at TrainingGenerator.deloadSets. */
export function weeklyTarget(week: ProgramWeek, profile: Profile) {
  const days = profile.trainingDays?.length ?? 3;
  const [low, high] = setsPerSession(days, profile.sessionMinutes ?? 45);
  const session = week.phase === "base" ? low : week.phase === "build" ? high : Math.floor((low + high) / 2);
  const sets = Math.min(session, Math.floor((profile.maxWeeklySets ?? Infinity) / Math.max(1, days))) * days;
  return isLight(week) ? Math.round(sets * 0.55) : sets;
}

/** "Base", "Deload", "Test week"; "· travel" while away. */
export function title(week: ProgramWeek) {
  const name = week.kind === "test" ? "Test week" : week.kind[0].toUpperCase() + week.kind.slice(1);
  return week.travel ? `${name} · travel` : name;
}

/** The coach line for a week (ProgramPlan.why). */
export function why(week: ProgramWeek) {
  if (week.travel) return "Dumbbells and bodyweight only.";
  return {
    base: "Moderate work, all the reps. Builds capacity for later.",
    build: "The work gets harder each week.",
    peak: "Hard and short, so you arrive fresh.",
    deload: "Same exercises at about half the work.",
    test: "See where you are.",
  }[week.kind];
}

/** What a program week adds to the plan rules for one day (PlanGuard rule 6, and a trip's equipment). */
export function checkProgramDay(plan: PlanRow[], profile: Profile, week: ProgramWeek): string[] {
  const out: string[] = [];
  const rows = plan.filter((r) => r.kind === "workout" && r.note !== WARMUP);
  const sets = (r: PlanRow) => r.targets.find((t) => t.metric === "sets")?.value ?? 1;
  const kind = week.kind === "test" ? "test" : "deload";
  if (isLight(week)) {
    for (const r of rows) {
      const rpe = r.targets.find((t) => t.metric === "rpe")?.value;
      if (rpe !== undefined && rpe > DELOAD_RPE) out.push(`${nameOf(r.template)}: RPE ${rpe} is over ${DELOAD_RPE}, the cap in a ${kind} week.`);
    }
    const total = rows.reduce((n, r) => n + sets(r), 0), most = lightSessionMost(profile);
    if (total > most) out.push(`${total} sets in a ${kind} week's session; a light week holds at most ${most}.`);
  }
  if (week.travel) {
    const kit = (profile.equipment ?? []).filter((e) => TRAVEL_EQUIPMENT.includes(e));
    for (const r of rows) {
      const e = r.template ? bySlug.get(r.template) : undefined;
      if (e && !e.equipment.every((k) => kit.includes(k))) out.push(`${e.name} needs ${e.equipment.join(" and ").replace(/_/g, " ")}; a travel week is dumbbells and bodyweight only.`);
    }
  }
  return [...new Set(out)];
}
