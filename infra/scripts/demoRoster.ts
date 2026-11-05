// FIT-328: the ten clients coach-demo.ts gives coach@barbrabell.com, so the roster reaches each state a coach sees: pain,
// missed, RPE 9+, stalled, behind, quiet, an unanswered note and on track. Sam signs in as client@barbrabell.com, so Sam
// has a session to log every day but Sunday and a run this week.
import { jen, mike, sara, WEEKS, type Client } from "../lambda/demoClients.ts";
import type { ExerciseInput } from "../lambda/training.ts";

const lb = (start: number, step: number, w: number) => start + step * w;

/** Mon/Wed/Fri on the barbell, each main lift 5 or 10 lb more a week. */
const barbell = (squat: number, bench: number, deadlift: number): Client["days"] => ({
  1: { title: "Squat and bench", lifts: (w) => [
    { exercise: "Back Squat", sets: 3, reps: 5, weight_lb: lb(squat, 5, w), main: true },
    { exercise: "Bench Press", sets: 3, reps: 5, weight_lb: lb(bench, 5, w), main: true },
    { exercise: "Plank", sets: 3, seconds: 45 },
  ] },
  3: { title: "Deadlift and pull", lifts: (w) => [
    { exercise: "Deadlift", sets: 3, reps: 5, weight_lb: lb(deadlift, 10, w), main: true },
    { exercise: "Pull-up", sets: 3, reps: 6 },
    { exercise: "Bent Over Barbell Row", sets: 3, reps: 8, weight_lb: lb(bench - 20, 5, w) },
  ] },
  5: { title: "Press and legs", lifts: (w) => [
    { exercise: "Standing Military Press", sets: 3, reps: 6, weight_lb: lb(Math.round(bench * 0.6), 5, w), main: true },
    { exercise: "Romanian Deadlift", sets: 3, reps: 8, weight_lb: lb(Math.round(deadlift * 0.5), 5, w) },
    { exercise: "Dumbbell Lunges", sets: 3, reps: 10, weight_lb_per_hand: 30 },
  ] },
});
const fine = { rpe: 7, effort: 3 };

/** Missed the last two weeks. */
const noah: Client = {
  testUser: "demo-noah", name: "Noah Bennett", age: 27, weight: 181, style: "powerbuilding", days: barbell(185, 145, 245),
  logged: (w) => (w >= -1 ? undefined : fine),
  program: { weeks: 12, goals: [{ goal: { type: "lift_max", exercise: "Back Squat", target: 245 }, baseline: 208 }] },
};

/** Logged only the first week: quiet for over two weeks. */
const priya: Client = {
  testUser: "demo-priya", name: "Priya Shah", age: 36, weight: 137, style: "functional", days: barbell(95, 65, 135),
  logged: (w) => (w === -WEEKS ? fine : undefined),
  program: { weeks: 12, goals: [{ goal: { type: "lift_max", exercise: "Deadlift", target: 185 }, baseline: 152 }] },
};

/** A question in the latest session's note, with nothing that hurts. */
const tom: Client = {
  testUser: "demo-tom", name: "Tom Okafor", age: 45, weight: 205, style: "powerbuilding", days: barbell(205, 165, 275),
  logged: (_w, _day, last) => (last ? { ...fine, note: "Travelling for work next week, hotel gym only. Can we move Friday?" } : fine),
  program: { weeks: 16, goals: [{ goal: { type: "lift_max", exercise: "Bench Press", target: 205 }, baseline: 186 }] },
};

/** The last set of squats at RPE 9 for the last two weeks, with no note. */
const hannah: Client = {
  testUser: "demo-hannah", name: "Hannah Weiss", age: 31, weight: 149, style: "powerlifting", days: barbell(165, 95, 205),
  logged: () => fine,
  actual: (w, day, rows) => {
    if (day !== 1 || w < -1) return;
    const squats = rows.filter((r) => r.template === "back-squat");
    squats.at(-1)!.measurements = squats.at(-1)!.measurements.map((m) => (m.metric === "rpe" ? { ...m, value: 9 } : m));
  },
  program: { weeks: 12, goals: [{ goal: { type: "lift_max", exercise: "Back Squat", target: 215 }, baseline: 186 }] },
};

/** Training well, on a target too far for the date. */
const leo: Client = {
  testUser: "demo-leo", name: "Leo Martin", age: 23, weight: 170, style: "powerlifting", days: barbell(205, 135, 275),
  logged: () => fine,
  program: { weeks: 12, goals: [{ goal: { type: "lift_max", exercise: "Deadlift", target: 500 }, baseline: 309 }] },
};

/** All sessions done, on pace, checking in. */
const ava: Client = {
  testUser: "demo-ava", name: "Ava Lindqvist", age: 38, weight: 151, style: "functional", days: barbell(135, 85, 185),
  logged: () => fine,
  checkIn: (n) => (n % 2 ? { weight_lb: 151, sleep_hours: 8 } : undefined),
  program: { weeks: 12, goals: [{ goal: { type: "lift_max", exercise: "Back Squat", target: 185 }, baseline: 152 }] },
};

const liftDay = (title: string, lifts: (w: number) => ExerciseInput[]) => ({ title, lifts });

/** client@barbrabell.com. Saturday's run starts this week, since a planned run isn't logged with the lifts. */
export const sam: Client = {
  testUser: "demo-sam", name: "Sam Rivera", age: 32, weight: 178, style: "powerbuilding",
  trainingDays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
  days: {
    1: liftDay("Squat and bench", (w) => [
      { exercise: "Back Squat", sets: 3, reps: 5, weight_lb: lb(205, 5, w), main: true, note: "Rest 2–3 min between sets." },
      { exercise: "Bench Press", sets: 3, reps: 5, weight_lb: lb(155, 5, w), main: true },
      { exercise: "Plank", sets: 3, seconds: 45 },
    ]),
    2: liftDay("Upper body", (w) => [
      { exercise: "Dumbbell Bench Press", sets: 3, reps: 10, weight_lb_per_hand: 50 },
      { exercise: "Wide-Grip Lat Pulldown", sets: 3, reps: 10, weight_lb: lb(120, 5, w) },
      { exercise: "Dumbbell Shoulder Press", sets: 3, reps: 10, weight_lb_per_hand: 35 },
    ]),
    3: liftDay("Deadlift and pull", (w) => [
      { exercise: "Deadlift", sets: 3, reps: 5, weight_lb: lb(275, 10, w), main: true, note: "Reset each rep." },
      { exercise: "Pull-up", sets: 3, reps: 6, main: true },
      { exercise: "Bent Over Barbell Row", sets: 3, reps: 8, weight_lb: lb(135, 5, w) },
    ]),
    4: liftDay("Lower body", (w) => [
      { exercise: "Romanian Deadlift", sets: 3, reps: 8, weight_lb: lb(165, 5, w) },
      { exercise: "Dumbbell Lunges", sets: 3, reps: 10, weight_lb_per_hand: 40 },
      { exercise: "Farmer Carry", sets: 3, seconds: 40 },
    ]),
    5: liftDay("Press and squat volume", (w) => [
      { exercise: "Standing Military Press", sets: 3, reps: 6, weight_lb: lb(95, 5, w), main: true },
      { exercise: "Back Squat", sets: 3, reps: 8, weight_lb: lb(165, 5, w) },
      { exercise: "Hip Thrust", sets: 3, reps: 10, weight_lb: lb(155, 10, w) },
    ]),
    6: liftDay("Easy run", (w) => (w >= WEEKS ? [{ exercise: "Trail Running/Walking", distance_mi: 3, run: "easy" }] : [])),
  },
  // Friday's note, so the coach has an answer to write whichever day this runs.
  logged: (w, day) => {
    if (day === 6) return undefined;
    return day === 5 && w >= -1 ? { ...fine, note: "Press moved fast today. Can we add more back work next week?" } : fine;
  },
  checkIn: (n) => ({ weight_lb: Math.round((177.6 + 0.1 * n) * 10) / 10, sleep_hours: n === 2 ? 6 : 7.5 }),
  program: { weeks: 12, goals: [
    { goal: { type: "lift_max", exercise: "Back Squat", target: 265 }, baseline: 231 },
    { goal: { type: "lift_max", exercise: "Deadlift", target: 365 }, baseline: 309 },
    { goal: { type: "timed_distance", distance: "5K", time: "26:00" }, baseline: 1680 },
  ] },
};

// On track here, so targets they'll reach: their goals elsewhere are the coach video's and the sample's.
const saraOnPace: Client = { ...sara, program: { weeks: 12, goals: [
  { goal: { type: "lift_max", exercise: "Back Squat", target: 205 }, baseline: 185 },
  { goal: { type: "lift_max", exercise: "Bench Press", target: 130 }, baseline: 117 },
  { goal: { type: "lift_max", exercise: "Deadlift", target: 260 }, baseline: 228 },
] } };
const jenOnPace: Client = { ...jen, program: { weeks: 12, goals: [{ goal: { type: "lift_max", exercise: "Wide-Grip Lat Pulldown", target: 115 }, baseline: 107 }] } };

/** Those with no sign-in of their own, each with the week their history starts. */
export const noSignIn: [Client, number][] = [
  [mike, -WEEKS - 1], [saraOnPace, -WEEKS], [jenOnPace, -WEEKS], [noah, -WEEKS], [priya, -WEEKS], [tom, -WEEKS], [hannah, -WEEKS], [leo, -WEEKS], [ava, -WEEKS],
];
