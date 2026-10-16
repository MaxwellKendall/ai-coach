import { editLines } from "./edit";
import type { PlanRow } from "./sync";

// FIT-128: PlanGuard's rules (Core/Generators/PlanGuard.swift, FIT-71) that a hand edit can break, as warnings. The app
// repairs a designed plan; here the person chose the numbers, so the web says so and leaves them. Same limits: sets per
// exercise (TrainingGenerator.maxSets / minSets), the weekly ceiling, RPE caps by age tier (fitness-planner CLAUDE.md
// "Intensity by tier"), barbell loads in 5 lb steps, and equipment on hand.

export type Exercise = { slug: string; name: string; equipment: string[] };
export type Profile = { age?: number; equipment?: string[]; maxWeeklySets?: number };

const MAX_SETS = { main: 5, accessory: 4 };
const MIN_SETS = 2;
const BARBELL = ["barbell", "trap_bar", "ez_bar"];

/** AgeTier.of(age): the RPE caps for main lifts and accessories. */
export function rpeCaps(age: number) {
  if (age < 30) return { main: 9, accessory: 8 };
  if (age < 40) return { main: 8, accessory: 7 };
  if (age < 50) return { main: 7, accessory: 7 };
  if (age < 60) return { main: 7, accessory: 6 };
  return { main: 6, accessory: 6 };
}

const value = (row: PlanRow, metric: string) => row.targets.find((m) => m.metric === metric)?.value;

/** Warnings for one day's session. */
export function checkDay(rows: PlanRow[], profile: Profile | undefined, catalog: Map<string, Exercise>): string[] {
  const out: string[] = [];
  const name = (slug?: string) => (slug && catalog.get(slug)?.name) ?? slug ?? "An exercise";
  const caps = profile?.age ? rpeCaps(profile.age) : undefined;
  const sets = new Map<string, { sets: number; main: boolean }>();
  for (const line of editLines(rows)) {
    const key = line.template ?? "";
    const first = rows.find((r) => r.id === line.ids[0])!;
    const so = sets.get(key) ?? { sets: 0, main: false };
    sets.set(key, { sets: so.sets + line.sets, main: so.main || first.main });
  }
  for (const [slug, { sets: n, main }] of sets) {
    const most = main ? MAX_SETS.main : MAX_SETS.accessory;
    if (n > most) out.push(`${name(slug)}: ${n} sets is more than the ${most} the app plans for ${main ? "a main lift" : "an accessory"}.`);
    else if (n < MIN_SETS) out.push(`${name(slug)}: ${n} set is fewer than the ${MIN_SETS} the app plans.`);
  }
  const seen = new Set<string>();
  for (const row of rows.filter((r) => r.kind === "workout")) {
    const exercise = row.template ? catalog.get(row.template) : undefined;
    const rpe = value(row, "rpe");
    const cap = caps && (row.main ? caps.main : caps.accessory);
    if (cap !== undefined && rpe !== undefined && rpe > cap && !seen.has(`rpe${row.template}`)) {
      seen.add(`rpe${row.template}`);
      out.push(`${name(row.template)}: RPE ${rpe} is over ${cap}, the cap at ${profile!.age} for ${row.main ? "a main lift" : "an accessory"}.`);
    }
    const load = value(row, "load_lb");
    if (exercise && load !== undefined && exercise.equipment.some((e) => BARBELL.includes(e)) && load % 5 !== 0 && !seen.has(`plates${row.template}`)) {
      seen.add(`plates${row.template}`);
      out.push(`${name(row.template)}: ${load} lb isn't a 5 lb step on a barbell.`);
    }
    const missing = exercise && profile?.equipment ? exercise.equipment.filter((e) => !profile.equipment!.includes(e)) : [];
    if (missing.length && !seen.has(`kit${row.template}`)) {
      seen.add(`kit${row.template}`);
      out.push(`${name(row.template)} needs ${missing.map((e) => e.replace(/_/g, " ")).join(" and ")}, which isn't in your equipment.`);
    }
  }
  return out;
}

/** The week's working sets against the profile's ceiling. */
export function checkWeek(days: PlanRow[][], profile: Profile | undefined): string | undefined {
  if (!profile?.maxWeeklySets) return undefined;
  const total = days.flatMap((rows) => editLines(rows)).reduce((sum, line) => sum + line.sets, 0);
  return total > profile.maxWeeklySets ? `${total} working sets this week, over your ceiling of ${profile.maxWeeklySets}.` : undefined;
}
