import { readFileSync, writeFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import programs from "../../Resources/Seed/programs.json" with { type: "json" };
import { daysFor, daysNearest, deloads, matches, projection, type ReadyProgram } from "../../shared/readyPrograms.ts";

// FIT-281: the web quiz's answers for each case. ReadyProgramRevealTests (Swift) checks the app gives the same program,
// days and reveal. UPDATE_FIXTURES=1 writes Tests/Fixtures/ready-program-reveal.json again.

const all = programs as ReadyProgram[];
const gym = ["barbell", "rack", "bench", "dumbbells", "pull_up_bar", "cable", "machine"];
const cases: { have: string[]; days: number }[] = [
  ...[2, 3, 4, 5, 6].map((days) => ({ have: gym, days })),
  ...[2, 3, 4].map((days) => ({ have: ["dumbbells"], days })),
  { have: ["dumbbells", "bench"], days: 4 },
  { have: [], days: 3 },
  { have: ["pull_up_bar"], days: 2 },
];

function answer(have: string[], days: number) {
  const program = matches(new Set(have), days, all)[0];
  const trainingDays = daysFor(daysNearest(program, days));
  return { have, days, slug: program.slug, trainingDays, projection: projection(program, trainingDays.length) ?? null };
}

const fixture = new URL("../../Tests/Fixtures/ready-program-reveal.json", import.meta.url);

describe("ready-made programs on the web", () => {
  it("gives the answers the app does", () => {
    const answers = cases.map((c) => answer(c.have, c.days));
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

  it("promises no load for body weight", () => {
    expect(projection(all.find((x) => x.slug === "bodyweight-basics")!, 3)).toBeUndefined();
  });
});
