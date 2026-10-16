import type { LogRow, Measurement, PlanRow, Unit } from "./sync";

// The week as the app shows it: Sunday to Saturday (FIT-82), each day's session from its plan# unit, and whether
// it was done from its log# unit. Pure, so it's tested without a server.

export const WARMUP = "warm-up"; // TrainingGenerator.warmupNote

export type Line = { exercise: string; sets: number; targets: Measurement[]; note: string };
export type Day = { date: Date; key: string; title?: string; lines: Line[]; done: boolean };

export function dayKey(date: Date) {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

/** The Sunday on or before `date`, at midnight. */
export function weekStart(date: Date) {
  const day = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  day.setDate(day.getDate() - day.getDay());
  return day;
}

function rows<T>(units: Map<string, Unit>, key: string): T[] {
  const body = units.get(key)?.body;
  return body ? (JSON.parse(body) as T[]) : [];
}

const value = (targets: Measurement[], metric: string) => targets.find((m) => m.metric === metric)?.value;

/** A day's working sets, one line per exercise: rows of one exercise with the same targets are counted together. */
export function lines(plan: PlanRow[], names: Map<string, string>): Line[] {
  const out: Line[] = [];
  for (const row of [...plan].filter((r) => r.kind === "workout" && r.note !== WARMUP).sort((a, b) => a.at - b.at)) {
    const exercise = (row.template && names.get(row.template)) ?? row.template ?? "Exercise";
    const targets = row.targets.filter((m) => m.metric !== "sets");
    const sets = value(row.targets, "sets") ?? 1;
    const last = out[out.length - 1];
    if (last && last.exercise === exercise && JSON.stringify(last.targets) === JSON.stringify(targets) && last.note === row.note) {
      last.sets += sets;
    } else {
      out.push({ exercise, sets, targets, note: row.note });
    }
  }
  return out;
}

export function week(units: Map<string, Unit>, today: Date, names: Map<string, string>): Day[] {
  const start = weekStart(today);
  return Array.from({ length: 7 }, (_, i) => {
    const date = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
    const key = dayKey(date);
    const plan = rows<PlanRow>(units, `plan#${key}`).filter((r) => r.kind === "workout");
    const logs = rows<LogRow>(units, `log#${key}`).filter((r) => r.kind === "workout");
    return { date, key, title: plan.find((r) => r.slot)?.slot, lines: lines(plan, names), done: logs.length > 0 };
  });
}

/** "3 × 5 @ 185 lb", "3 × 45 s", "4 × 8 @ 50 lb/hand · RPE 8". */
export function describe(line: Line) {
  const t = line.targets;
  const reps = value(t, "reps");
  const seconds = value(t, "duration_s");
  const meters = value(t, "distance_m");
  const each = reps !== undefined ? `${reps}` : seconds !== undefined ? `${seconds} s` : meters !== undefined ? `${meters} m` : "";
  let text = each ? `${line.sets} × ${each}` : `${line.sets} ${line.sets === 1 ? "set" : "sets"}`;
  const load = value(t, "load_lb");
  const perHand = value(t, "load_lb_hand");
  if (load) text += ` @ ${load} lb`;
  else if (perHand) text += ` @ ${perHand} lb/hand`;
  const rpe = value(t, "rpe");
  if (rpe) text += ` · RPE ${rpe}`;
  return text;
}
