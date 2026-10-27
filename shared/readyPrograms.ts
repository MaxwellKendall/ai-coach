// FIT-281: the ready-made programs (Resources/Seed/programs.json) as the web's quiz uses them: which one fits, its
// training days, and the plan reveal's promise. The same rules as the app's (Core/Generators/ReadyProgram.swift and
// ReadyProgramProjection.swift), so the plan revealed on the web is the plan the app opens; Tests/Fixtures/
// ready-program-reveal.json holds both to the same answers. Pure: callers pass the programs in.

export type Place = "gym" | "dumbbells" | "bodyweight";
/** The quiz's "What's your goal?". */
export type Goal = "strength" | "muscle" | "start";
/** What the quiz knows about the person beyond their equipment and days. */
export type Fit = { goal?: Goal; lifted?: boolean };
/** A recent hard set of the program's main lift: lb (a hand, for dumbbells) and reps. */
export type RecentSet = { weight: number; reps: number };

export type Item = {
  exercise?: string;
  ladder?: string[];
  or?: string[];
  sets: number;
  reps?: number[];
  seconds?: number[];
  start?: number;
  step?: number;
  main?: boolean;
  group?: number;
};

export type ReadyProgram = {
  slug: string;
  name: string;
  summary: string;
  level: string;
  /** The goals it serves, for the quiz's pick. */
  goals?: Goal[];
  place: Place;
  days: number[];
  weeks: number;
  minutes: number;
  equipment: string[];
  optional?: string[];
  sessions: { name: string; exercises: Item[] }[];
};

/** "What do you have?": each line and the catalog equipment it stands for. */
export const KIT: { name: string; equipment: string[] }[] = [
  { name: "Barbell and rack", equipment: ["barbell", "rack"] },
  { name: "Bench", equipment: ["bench"] },
  { name: "Dumbbells", equipment: ["dumbbells"] },
  { name: "Pull-up bar", equipment: ["pull_up_bar"] },
  { name: "Cables and machines", equipment: ["cable", "machine"] },
];

/** What equipment someone has is mostly for: a barbell makes the barbell programs the fit. */
export function place(have: Set<string>): Place {
  return have.has("barbell") && have.has("rack") ? "gym" : have.has("dumbbells") ? "dumbbells" : "bodyweight";
}

/** Its days a week closest to `wanted`, the fewer on a tie. */
export function daysNearest(program: ReadyProgram, wanted: number): number {
  return [...program.days].sort((a, b) => Math.abs(a - wanted) - Math.abs(b - wanted) || a - b)[0] ?? wanted;
}

/** The programs the equipment allows, best first: nearest in days a week, then the ones built around what the
 * equipment is mostly for, then the ones for their goal and experience, then the file's order (beginner programs first). */
export function matches(have: Set<string>, days: number, programs: ReadyProgram[], fit: Fit = {}): ReadyProgram[] {
  const where = place(have);
  const level = fit.lifted ? "some" : "new";
  const key = (p: ReadyProgram, i: number) => [
    Math.abs(daysNearest(p, days) - days),
    p.place === where ? 0 : 1,
    !fit.goal || p.goals?.includes(fit.goal) ? 0 : 1,
    fit.goal === undefined && fit.lifted === undefined ? 0 : p.level === level ? 0 : 1,
    i,
  ];
  return programs
    .map((p, i) => ({ p, k: key(p, i) }))
    .filter(({ p }) => p.equipment.every((e) => have.has(e)))
    .sort((a, b) => a.k.reduce((d, v, j) => d || v - b.k[j], 0))
    .map(({ p }) => p);
}

/** Training days (0 = Monday) to start with: spread out, with a rest day between where the count allows. */
export function daysFor(count: number): number[] {
  const spread: Record<number, number[]> = {
    1: [0], 2: [0, 3], 3: [0, 2, 4], 4: [0, 1, 3, 4], 5: [0, 1, 2, 4, 5], 6: [0, 1, 2, 3, 4, 5], 7: [0, 1, 2, 3, 4, 5, 6],
  };
  return spread[count] ?? [0, 2, 4];
}

/** Week indexes that are deloads for someone of unknown age: every 7th week, as `ProgramPlan.weeks(count:deloadEvery: 7)`
 * gives (the last week is a test week, which a ready-made program trains as usual). */
export function deloads(weeks: number, every = 7): Set<number> {
  const light = new Set<number>();
  let since = 0;
  for (let i = 0; i < weeks; i++) {
    if (i !== weeks - 1 && since + 1 >= every) {
      light.add(i);
      since = 0;
    } else {
      since += 1;
    }
  }
  return light;
}

export type Projection = {
  exercise: string;
  /** The load in lb (a hand, for a dumbbell program): where it starts, then at the end of each week. */
  loads: number[];
  perHand: boolean;
  /** The headline's first number: their own load for the program's reps when they gave a recent set, else the start. */
  from: number;
};

/** The lift the reveal promises and the quiz asks a recent set of: the program's first main lift with a load. */
export function mainLift(program: ReadyProgram): (Item & { exercise: string; start: number; reps: number[] }) | undefined {
  return program.sessions.flatMap((s) => s.exercises)
    .find((i): i is Item & { exercise: string; start: number; reps: number[] } => Boolean(i.main && i.start !== undefined && i.reps && i.exercise));
}

/** Someone who has lifted gains this much on their own number over a program, at most and in proportion to the weeks
 * gone (an intermediate's pace), and never less than one step. */
export const LIFTED_GAIN = 0.1;

const roundTo5 = (value: number) => Math.round(value / 5) * 5;
/** Brzycki (fitness-planner CLAUDE.md "1RM Estimation"), as `ProgramPlan.estimatedMax`. */
const estimatedMax = ({ weight, reps }: RecentSet) => (weight * 36) / (37 - Math.min(reps, 36));

/** Their load for the program's reps (`ProgramPlan.load(forMax:reps:)`), and where the program starts them: 90% of it,
 * as `ProgramPlan.firstTargets`, and never under the program's own start. Nil when it's no more than that start, which is
 * where someone new begins too. */
export function fromRecent(item: { start: number }, low: number, recent: RecentSet) {
  const max = estimatedMax(recent);
  const current = roundTo5((max * (37 - low)) / 36);
  return current > item.start ? { current, start: Math.max(item.start, roundTo5(((max * (37 - low)) / 36) * 0.9)) } : undefined;
}

/** The reveal's promise: the program's main lift if every session goes to plan, by the program's rule. One rep count
 * adds the step every session; a rep range climbs a rep a session and adds the step once at the top. Deload weeks don't
 * count. With a recent set it starts a little under their number and climbs back to it at that pace, then a step a
 * week at most, up to `LIFTED_GAIN` more by the last week. Body-weight programs have no load to promise. */
export function projection(program: ReadyProgram, days: number, light = deloads(program.weeks), recent?: RecentSet): Projection | undefined {
  const item = mainLift(program);
  if (!item) return undefined;
  const slug = item.exercise;
  const low = Math.min(...item.reps);
  const high = Math.max(...item.reps);
  const perStep = high - low + 1;
  const step = item.step ?? 5;
  const own = recent ? fromRecent(item, low, recent) : undefined;
  const start = own?.start ?? item.start;
  const gain = own ? Math.max(step, roundTo5(own.current * LIFTED_GAIN)) : 0;
  const loads = [start];
  let counted = 0;
  let latest = start;
  let session = 0;
  let due = false;
  for (let week = 0; week < program.weeks; week++) {
    let stepped = false;
    const ceiling = own ? own.current + (gain * (week + 1)) / program.weeks : Infinity;
    for (let day = 0; day < days; day++) {
      const current = program.sessions[session % program.sessions.length];
      session += 1;
      if (light.has(week) || !current.exercises.some((i) => i.exercise === slug)) continue;
      if (counted > 0 && counted % perStep === 0) due = true;
      const next = latest + step;
      if (due && (!own || next <= own.current)) {
        latest = next;
        due = false;
      } else if (due && !stepped && next <= ceiling) {
        latest = next;
        due = false;
        stepped = true;
      }
      counted += 1;
    }
    loads.push(latest);
  }
  return { exercise: slug, loads, perHand: program.place === "dumbbells", from: own && latest > own.current ? own.current : start };
}

/** The program's last day, as the app's `Planner.start` sets it: the Saturday ending its last week, counting the
 * week it starts in (weeks start on Sunday, as `Week.start`). Local dates. */
export function endDate(start: Date, weeks: number): Date {
  const sunday = new Date(start.getFullYear(), start.getMonth(), start.getDate() - start.getDay());
  return new Date(sunday.getFullYear(), sunday.getMonth(), sunday.getDate() + 7 * weeks - 1);
}
