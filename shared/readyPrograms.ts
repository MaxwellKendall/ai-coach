// FIT-281: the ready-made programs (Resources/Seed/programs.json) as the web's quiz uses them: which one fits, its
// training days, and the plan reveal's promise. The same rules as the app's (Core/Generators/ReadyProgram.swift and
// ReadyProgramProjection.swift), so the plan revealed on the web is the plan the app opens; Tests/Fixtures/
// ready-program-reveal.json holds both to the same answers. Pure: callers pass the programs in.

export type Place = "gym" | "dumbbells" | "bodyweight";

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
 * equipment is mostly for, then the file's order (beginner programs first). */
export function matches(have: Set<string>, days: number, programs: ReadyProgram[]): ReadyProgram[] {
  const where = place(have);
  const key = (p: ReadyProgram, i: number) => [Math.abs(daysNearest(p, days) - days), p.place === where ? 0 : 1, i];
  return programs
    .map((p, i) => ({ p, k: key(p, i) }))
    .filter(({ p }) => p.equipment.every((e) => have.has(e)))
    .sort((a, b) => a.k[0] - b.k[0] || a.k[1] - b.k[1] || a.k[2] - b.k[2])
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
};

/** The reveal's promise: the program's first main lift if every session goes to plan, by the program's rule. One rep
 * count adds the step every session; a rep range climbs a rep a session and adds the step once at the top. Deload
 * weeks don't count. Body-weight programs have no load to promise. */
export function projection(program: ReadyProgram, days: number, light = deloads(program.weeks)): Projection | undefined {
  const item = program.sessions.flatMap((s) => s.exercises).find((i) => i.main && i.start !== undefined && i.reps && i.exercise);
  if (!item?.exercise || item.start === undefined || !item.reps) return undefined;
  const slug = item.exercise;
  const low = Math.min(...item.reps);
  const high = Math.max(...item.reps);
  const perStep = high - low + 1;
  const step = item.step ?? 5;
  const loads = [item.start];
  let counted = 0;
  let latest = item.start;
  let session = 0;
  for (let week = 0; week < program.weeks; week++) {
    for (let day = 0; day < days; day++) {
      const current = program.sessions[session % program.sessions.length];
      session += 1;
      if (light.has(week) || !current.exercises.some((i) => i.exercise === slug)) continue;
      latest = item.start + step * Math.floor(counted / perStep);
      counted += 1;
    }
    loads.push(latest);
  }
  return { exercise: slug, loads, perHand: program.place === "dumbbells" };
}

/** The program's last day, as the app's `Planner.start` sets it: the Saturday ending its last week, counting the
 * week it starts in (weeks start on Sunday, as `Week.start`). Local dates. */
export function endDate(start: Date, weeks: number): Date {
  const sunday = new Date(start.getFullYear(), start.getMonth(), start.getDate() - start.getDay());
  return new Date(sunday.getFullYear(), sunday.getMonth(), sunday.getDate() + 7 * weeks - 1);
}
