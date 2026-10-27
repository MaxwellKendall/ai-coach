// FIT-281: the consumer app's web quiz (/start), the page its ads open: the goal, whether they've lifted, what they
// have, how many days and a recent set, then the plan revealed and its free trial. The program and the reveal come from shared/readyPrograms.ts, the app's rules.
import programs from "../../Resources/Seed/programs.json";
import {
  daysFor, daysNearest, deloads, endDate, mainLift, matches, projection,
  type Goal, type Projection, type ReadyProgram, type RecentSet,
} from "../../shared/readyPrograms";
import catalog from "./catalog.json";
import type { Config } from "./auth";
import { gql } from "./sync";

/** The consumer app's working name until FIT-265 names it. */
export const PRODUCT = "Liftplan";
/** What Checkout charges after the trial (the ad test, FIT-264, sets the real price; Stripe's is what's billed). */
export const PRICE = "$29.99 a year";
export const TRIAL_DAYS = 7;

const all = programs as ReadyProgram[];
const names = new Map((catalog as { slug: string; name: string }[]).map((e) => [e.slug, e.name]));
export const exerciseName = (slug: string) => names.get(slug) ?? slug;

/** What the plan was bought with, kept on the account for the app (coachPlan.ts quizAnswers). */
export type Answers = {
  slug: string;
  have: string[];
  days: number[];
  goal?: Goal;
  lifted?: boolean;
  /** Their recent set of the program's main lift, which its first sessions start from. */
  recent?: RecentSet & { exercise: string };
};

export type Quiz = { goal?: Goal; lifted?: boolean; have: Set<string>; days: number; recent?: RecentSet };

export type Plan = { program: ReadyProgram; answers: Answers; reveal?: Projection; ends: Date };

/** The program the answers so far pick: what the recent-set question asks about. */
export const pick = ({ goal, lifted, have, days }: Quiz) => matches(have, days, all, { goal, lifted })[0];
export const liftOf = (program: ReadyProgram | undefined) => (program ? mainLift(program)?.exercise : undefined);

/** The plan for the quiz's answers: the best fit, its days spread out, and what it promises. */
export function plan(quiz: Quiz, today = new Date()): Plan | undefined {
  const program = pick(quiz);
  if (!program) return undefined;
  const trainingDays = daysFor(daysNearest(program, quiz.days));
  const lift = liftOf(program);
  const recent = quiz.lifted && lift && quiz.recent ? { exercise: lift, ...quiz.recent } : undefined;
  return {
    program,
    answers: { slug: program.slug, have: [...quiz.have], days: trainingDays, goal: quiz.goal, lifted: quiz.lifted, ...(recent && { recent }) },
    reveal: projection(program, trainingDays.length, deloads(program.weeks), recent),
    ends: endDate(today, program.weeks),
  };
}

const month = (d: Date) => d.toLocaleDateString("en-US", { month: "short", day: "numeric" });

/** The reveal's headline: "Back Squat 45 → 120 lb by Jan 23", or the program's shape without a load to promise. */
export function headline({ program, reveal, ends }: Plan): string {
  if (!reveal) return `${program.name}: ${program.weeks} weeks, done by ${month(ends)}`;
  const unit = reveal.perHand ? " lb a hand" : " lb";
  return `${exerciseName(reveal.exercise)} ${reveal.from} → ${reveal.loads.at(-1)}${unit} by ${month(ends)}`;
}

/** "3 × 5", "3 × 8–12", "3 × 20–60 s", as the app shows a dose. */
export function dose(item: { sets: number; reps?: number[]; seconds?: number[] }): string {
  const range = [...(item.seconds ?? item.reps ?? [])].sort((a, b) => a - b);
  if (!range.length) return `${item.sets} sets`;
  const [low, high] = [range[0], range.at(-1)];
  return `${item.sets} × ${low === high ? low : `${low}–${high}`}${item.seconds ? " s" : ""}`;
}

/** The quiz's answers wait here while sign-in leaves the page, then checkout picks up from them. */
const PENDING = "liftplan.start";
export const savePending = (answers: Answers) => sessionStorage.setItem(PENDING, JSON.stringify(answers));
export function takePending(): Answers | undefined {
  const saved = sessionStorage.getItem(PENDING);
  sessionStorage.removeItem(PENDING);
  try {
    return saved ? (JSON.parse(saved) as Answers) : undefined;
  } catch {
    return undefined;
  }
}
export const hasPending = () => sessionStorage.getItem(PENDING) !== null;

/** Checkout for the trial, or null while the plan isn't on sale. */
export const startTrial = (config: Config, answers: Answers) =>
  gql<{ startTrainerPlan: string | null }>(config, `mutation($a: AWSJSON!) { startTrainerPlan(answers: $a) }`, { a: JSON.stringify(answers) })
    .then((d) => d.startTrainerPlan);
