import { readFileSync, writeFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import programs from "../../Resources/Seed/programs.json" with { type: "json" };
import { daysFor, daysNearest, deloads, matches, projection, type Fit, type ReadyProgram, type RecentSet } from "../../shared/readyPrograms.ts";

// FIT-281: the web quiz's answers for each case. ReadyProgramRevealTests (Swift) checks the app gives the same program,
// days and reveal. UPDATE_FIXTURES=1 writes Tests/Fixtures/ready-program-reveal.json again.

const all = programs as ReadyProgram[];
const gym = ["barbell", "rack", "bench", "dumbbells", "pull_up_bar", "cable", "machine"];
type Case = { have: string[]; days: number; fit?: Fit; recent?: RecentSet };
const cases: Case[] = [
  ...[2, 3, 4, 5, 6].map((days) => ({ have: gym, days })),
  ...[2, 3, 4].map((days) => ({ have: ["dumbbells"], days })),
  { have: ["dumbbells", "bench"], days: 4 },
  { have: [], days: 3 },
  { have: ["pull_up_bar"], days: 2 },
  // The quiz's goal and experience, and a recent set of the main lift.
  ...(["strength", "muscle", "start"] as const).flatMap((goal) => [{ have: gym, days: 3, fit: { goal, lifted: goal !== "start" } }]),
  { have: gym, days: 3, fit: { goal: "strength", lifted: true }, recent: { weight: 225, reps: 5 } },
  { have: gym, days: 3, fit: { goal: "strength", lifted: true }, recent: { weight: 135, reps: 10 } },
  { have: gym, days: 4, fit: { goal: "strength", lifted: true }, recent: { weight: 185, reps: 3 } },
  { have: gym, days: 5, fit: { goal: "muscle", lifted: true }, recent: { weight: 315, reps: 5 } },
  { have: gym, days: 2, fit: { goal: "strength", lifted: true }, recent: { weight: 40, reps: 5 } },
  { have: ["dumbbells"], days: 3, fit: { goal: "muscle", lifted: true }, recent: { weight: 30, reps: 10 } },
  { have: ["dumbbells"], days: 4, fit: { goal: "muscle", lifted: true }, recent: { weight: 50, reps: 8 } },
];

function answer({ have, days, fit, recent }: Case) {
  const program = matches(new Set(have), days, all, fit)[0];
  const trainingDays = daysFor(daysNearest(program, days));
  const reveal = projection(program, trainingDays.length, deloads(program.weeks), recent);
  return { have, days, ...fit, ...(recent && { recent }), slug: program.slug, trainingDays, projection: reveal ?? null };
}

const fixture = new URL("../../Tests/Fixtures/ready-program-reveal.json", import.meta.url);

describe("ready-made programs on the web", () => {
  it("gives the answers the app does", () => {
    const answers = cases.map(answer);
    if (process.env.UPDATE_FIXTURES) writeFileSync(fixture, JSON.stringify(answers, null, 2) + "\n");
    expect(answers).toEqual(JSON.parse(readFileSync(fixture, "utf8")));
  });

  it("deloads every 7th week, and never the last", () => {
    expect([...deloads(12)]).toEqual([6]);
    expect([...deloads(7)]).toEqual([]);
  });

  it("adds the step every session for one rep count, skipping the deload", () => {
    // Full Body 3-Day: squat on Day A, so 2 sessions one week and 1 the next; 45 lb, +5 a session.
    const p = projection(all.find((x) => x.slug === "full-body-3")!, 3)!;
    expect(p.exercise).toBe("back-squat");
    expect(p.loads.slice(0, 3)).toEqual([45, 50, 55]);
    expect(p.loads[7]).toBe(p.loads[6]);
    expect(p.perHand).toBe(false);
  });

  it("climbs the rep range before adding load", () => {
    // Dumbbell Full Body: split squats 3 × 8–12 at 15 lb a hand, so 5 sessions a step.
    const p = projection(all.find((x) => x.slug === "dumbbell-full-body")!, 3)!;
    expect(p.perHand).toBe(true);
    expect(p.loads[1]).toBe(15);
    expect(p.loads.at(-1)).toBeGreaterThan(15);
  });

  it("starts someone who has lifted under their number, back to it each session, then a step a week at most, to 10% more by the end", () => {
    // Squat 225 × 5: 205 to start, +5 a session to 225, then 230 … 250.
    const p = projection(all.find((x) => x.slug === "full-body-3")!, 3, deloads(12), { weight: 225, reps: 5 })!;
    expect(p.loads[0]).toBe(205);
    expect(p.from).toBe(225);
    expect(p.loads.at(-1)).toBe(250);
    const weekly = p.loads.slice(1).map((v, i) => v - p.loads[i]).filter((_, i) => p.loads[i] >= 225);
    expect(Math.max(...weekly)).toBeLessThanOrEqual(5);
  });

  it("promises no load for body weight", () => {
    expect(projection(all.find((x) => x.slug === "bodyweight-basics")!, 3)).toBeUndefined();
  });
});
