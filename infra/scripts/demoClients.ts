// FIT-221's demo clients: three weeks of realistic training, Mon/Wed/Fri, as sync units. demo.ts seeds them on dev for
// the coach video; review-account.ts --coach (FIT-236) gives them to the account Claude's directory reviewers sign in with.
import { addDays, dailyRows, encode, logRows, type DailyInput, mergeProfile, sessionRows, type ExerciseInput, type PlanRow } from "../lambda/training.ts";

type Week = (w: number) => ExerciseInput[];
export type Client = {
  testUser: string; name: string; age: number; weight: number; style: string;
  days: Record<number, { title: string; lifts: Week }>;
  /** RPE and the note for a logged session, or undefined when it was missed. `last` is the latest day before today. */
  logged: (w: number, weekday: number, last: boolean) => { rpe: number; note?: string; effort: number } | undefined;
  /** Changes to a logged session's sets, as the client actually did them. */
  actual?: (w: number, weekday: number, rows: ReturnType<typeof logRows>) => void;
  /** FIT-223: the morning check-in `daysAgo` days back (1–6), as the app's Check In saves it. */
  checkIn?: (daysAgo: number) => DailyInput | undefined;
};

const lb = (start: number, step: number, w: number) => start + step * w;
export const WEEKS = 3; // logged weeks before this one; Mike's go one further back, so his stall has a best before it

export const mike: Client = {
  testUser: "demo-mike", name: "Mike Torres", age: 34, weight: 196, style: "powerbuilding",
  days: {
    1: { title: "Squat and push", lifts: (w) => [
      { exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 245, main: true },
      { exercise: "Bench Press", sets: 4, reps: 6, weight_lb: lb(185, 5, w) },
      { exercise: "Dumbbell Lunges", sets: 3, reps: 10, weight_lb_per_hand: 40 },
    ] },
    3: { title: "Hinge and pull", lifts: (w) => [
      { exercise: "Deadlift", sets: 3, reps: 5, weight_lb: lb(295, 10, w), main: true },
      { exercise: "Pull-up", sets: 4, reps: 8 },
      { exercise: "Bent Over Barbell Row", sets: 3, reps: 8, weight_lb: lb(155, 5, w) },
    ] },
    5: { title: "Squat volume and press", lifts: (w) => [
      { exercise: "Back Squat", sets: 3, reps: 8, weight_lb: 205 },
      { exercise: "Standing Military Press", sets: 4, reps: 6, weight_lb: lb(105, 5, w), main: true },
      { exercise: "Plank", sets: 3, seconds: 45 },
    ] },
  },
  // The dashboard flags a note from the last 7 days that the coach hasn't answered, so the knee is the latest session.
  logged: (w, day, last) => {
    if (last) return { rpe: 8, effort: 4, note: "Left knee is sore, worse on squats this week. Felt it on the stairs after." };
    if (w === -2 && day === 1) return { rpe: 8, effort: 4, note: "Squat felt heavy again, couldn't get the 5th rep fast." };
    return { rpe: 7, effort: 3 };
  },
  checkIn: (n) => ({ weight_lb: Math.round((195.4 + 0.2 * n) * 10) / 10, sleep_hours: n === 1 ? 5 : 7, note: n === 1 ? "Slept badly, the knee kept me up." : undefined }),
  // The stall: every week since the first, the last set of 245 goes to RPE 9.
  actual: (w, day, rows) => {
    if (day !== 1 || w === -WEEKS - 1) return;
    const squats = rows.filter((r) => r.template === "back-squat");
    squats.at(-1)!.measurements = squats.at(-1)!.measurements.map((m) => (m.metric === "rpe" ? { ...m, value: 9 } : m));
  },
};

export const sara: Client = {
  testUser: "demo-sara", name: "Sara Kim", age: 29, weight: 142, style: "powerlifting",
  days: {
    1: { title: "Squat", lifts: (w) => [
      { exercise: "Back Squat", sets: 5, reps: 3, weight_lb: lb(175, 5, w), main: true },
      { exercise: "Romanian Deadlift", sets: 3, reps: 8, weight_lb: lb(115, 5, w) },
      { exercise: "Plank", sets: 3, seconds: 40 },
    ] },
    3: { title: "Bench", lifts: (w) => [
      { exercise: "Bench Press", sets: 5, reps: 3, weight_lb: lb(110, 5, w), main: true },
      { exercise: "Dumbbell Row (Single-Arm)", sets: 3, reps: 10, weight_lb_per_hand: 35 },
      { exercise: "Standing Military Press", sets: 3, reps: 8, weight_lb: 65 },
    ] },
    5: { title: "Deadlift", lifts: (w) => [
      { exercise: "Deadlift", sets: 4, reps: 3, weight_lb: lb(215, 10, w), main: true },
      { exercise: "Pull-up", sets: 3, reps: 5 },
      { exercise: "Dumbbell Lunges", sets: 3, reps: 10, weight_lb_per_hand: 25 },
    ] },
  },
  // Her note is older than a week, so it doesn't flag her.
  logged: (w, day) => (w === -2 && day === 3 ? { rpe: 8, effort: 4, note: "New bench PR! Meet prep feels on track." } : { rpe: 7, effort: 3 }),
  checkIn: (n) => (n % 2 ? undefined : { weight_lb: 142, sleep_hours: 8 }),
};

export const jen: Client = {
  testUser: "demo-jen", name: "Jen Alvarez", age: 41, weight: 158, style: "functional",
  days: {
    1: { title: "Lower body", lifts: (w) => [
      { exercise: "Goblet Squat", sets: 3, reps: 10, weight_lb: lb(45, 5, w), main: true },
      { exercise: "Hip Thrust", sets: 3, reps: 10, weight_lb: lb(135, 10, w) },
      { exercise: "Plank", sets: 3, seconds: 30 },
    ] },
    3: { title: "Upper body", lifts: (w) => [
      { exercise: "Dumbbell Bench Press", sets: 3, reps: 10, weight_lb_per_hand: 30 },
      { exercise: "Wide-Grip Lat Pulldown", sets: 3, reps: 10, weight_lb: lb(80, 5, w), main: true },
      { exercise: "Dumbbell Shoulder Press", sets: 3, reps: 10, weight_lb_per_hand: 20 },
    ] },
    5: { title: "Full body", lifts: (w) => [
      { exercise: "Romanian Deadlift", sets: 3, reps: 10, weight_lb: lb(85, 5, w), main: true },
      { exercise: "Dumbbell Row (Single-Arm)", sets: 3, reps: 10, weight_lb_per_hand: 30 },
      { exercise: "Farmer Carry", sets: 3, seconds: 40 },
    ] },
  },
  // One session missed last week (two would flag her).
  logged: (w, day) => (w === -1 && day === 3 ? undefined : { rpe: 7, effort: 3 }),
};

const key = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
export const today = key(new Date());
export const sunday = addDays(today, -new Date(`${today}T12:00:00Z`).getUTCDay());
/** Epoch seconds at a local time on a day. */
export const at = (day: string, hour: number) => new Date(`${day}T${String(hour).padStart(2, "0")}:00:00`).getTime() / 1000;

/** The client's sync units: profile, every planned day from their first week through next week, and what they logged. */
export function units(client: Client, first: number) {
  const out = new Map<string, string>();
  const start = addDays(sunday, 7 * first + 1);
  out.set("profile", encode({
    ...mergeProfile(undefined, { age: client.age, weight_lb: client.weight, training_days: ["Mon", "Wed", "Fri"], session_minutes: 60, style: client.style }),
    programStart: at(start, 0),
  }));
  const days = Object.keys(client.days).map(Number);
  const last = [0, -1].flatMap((w) => days.map((d) => addDays(sunday, 7 * w + d))).filter((d) => d < today).sort().at(-1);
  for (let w = first; w <= 1; w++) {
    for (const [weekday, session] of Object.entries(client.days).map(([d, s]) => [Number(d), s] as const)) {
      const day = addDays(sunday, 7 * w + weekday);
      const plan: PlanRow[] = sessionRows([], session.title, session.lifts(w - first), at(day, 7), "Written by the coach");
      out.set(`plan#${day}`, encode(plan));
      const done = day < today ? client.logged(w, weekday, day === last) : undefined;
      if (!done) continue;
      const rows = logRows(plan, at(day, 7) + 3600, { as_planned: true, rpe: done.rpe, note: done.note, effort: done.effort });
      client.actual?.(w, weekday, rows);
      out.set(`log#${day}`, encode(rows));
    }
  }
  for (let n = 6; n >= 1; n--) {
    const day = addDays(today, -n), input = client.checkIn?.(n);
    if (!input) continue;
    const log = out.has(`log#${day}`) ? JSON.parse(out.get(`log#${day}`)!) : [];
    out.set(`log#${day}`, encode(dailyRows(log, input, () => at(day, 6))));
  }
  return out;
}
