// TKL-749: the Lifter Pro demo account, for the App Review demo's AI-designed week. Jordan trains themselves (no coach,
// so the app designs their weeks with AI) and has Lifter Pro with no store behind it, as coach@ has Coach Pro. Three
// weeks are logged, Mon/Wed/Fri. Squat and deadlift move up every week; bench has stalled at 185 with the last set at
// RPE 9, and last Monday's note says so, so "Plan my next week" has something real to change and explain.
import { units, WEEKS, type Client } from "../lambda/demoClients.ts";

export const LIFTER_EMAIL = "lifter@barbrabell.com";

const lb = (start: number, step: number, w: number) => start + step * w;

export const jordan: Client = {
  testUser: "demo-jordan", name: "Jordan Lee", age: 31, weight: 178, style: "powerbuilding",
  days: {
    1: { title: "Squat and bench", lifts: (w) => [
      { exercise: "Back Squat", sets: 4, reps: 5, weight_lb: lb(225, 10, w), main: true },
      { exercise: "Bench Press", sets: 4, reps: 5, weight_lb: 185 },
      { exercise: "Dumbbell Row (Single-Arm)", sets: 3, reps: 10, weight_lb_per_hand: lb(55, 5, w) },
    ] },
    3: { title: "Deadlift and press", lifts: (w) => [
      { exercise: "Deadlift", sets: 3, reps: 5, weight_lb: lb(275, 10, w), main: true },
      { exercise: "Standing Military Press", sets: 4, reps: 6, weight_lb: lb(95, 5, w) },
      { exercise: "Pull-up", sets: 4, reps: 8 },
    ] },
    5: { title: "Bench and legs", lifts: (w) => [
      { exercise: "Bench Press", sets: 3, reps: 8, weight_lb: 155, main: true },
      { exercise: "Romanian Deadlift", sets: 3, reps: 8, weight_lb: lb(165, 10, w) },
      { exercise: "Plank", sets: 3, seconds: 45 },
    ] },
  },
  logged: (w, day) => (w === -1 && day === 1
    ? { rpe: 9, effort: 4, note: "Bench stuck at 185 again, the last set was a grind." }
    : { rpe: 7, effort: 3 }),
  // The stall: every Monday the last set of bench goes to RPE 9.
  actual: (_w, day, rows) => {
    if (day !== 1) return;
    const bench = rows.filter((r) => r.template === "bench-press");
    bench.at(-1)!.measurements = bench.at(-1)!.measurements.map((m) => (m.metric === "rpe" ? { ...m, value: 9 } : m));
  },
  checkIn: (n) => (n % 2 ? undefined : { weight_lb: 178, sleep_hours: 7 }),
  program: { weeks: 12, goals: [
    { goal: { type: "lift_max", exercise: "Back Squat", target: 315 }, baseline: 262 },
    { goal: { type: "lift_max", exercise: "Bench Press", target: 225 }, baseline: 208 },
  ] },
};

/** Jordan's sync units, from three weeks back through next week, each session from their own program. */
export const lifterUnits = (today?: string) => units(jordan, -WEEKS, true, today, "From your program");

/** USER#uid PROPLAN: Lifter Pro, active with no Stripe or App Store behind it (`demo`), renewing in 90 days. */
export const demoProPlan = (now = new Date()) => ({
  SK: "PROPLAN", status: "active", interval: "year", renews: new Date(now.getTime() + 90 * 86_400_000).toISOString(), cancelsAtEnd: false, demo: true,
});
