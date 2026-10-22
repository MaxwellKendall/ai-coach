import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { estimated1RMs, estimated1RMTrend, plateaued, streak, streakNow, trainingDays, type LoggedSet } from "./progress";

// FIT-129: the app's ProgressParityTests reads the same file; both must agree with it.
const fixture = JSON.parse(readFileSync(new URL("../../Tests/Fixtures/progress-parity.json", import.meta.url), "utf8"));
const sets: LoggedSet[] = fixture.sets.map((s: Record<string, unknown>) => ({
  day: s.day, exercise: s.exercise, value: (m: string) => s[m] as number | undefined,
}));

describe("progress, the same as the app's (FIT-129)", () => {
  it("estimates maxes with Brzycki, 1–10 reps at RPE ≤ 8, never going down", () => {
    expect(estimated1RMs(sets)).toEqual(fixture.expected1RM);
    for (const [exercise, points] of Object.entries(fixture.expectedTrend)) {
      expect(estimated1RMTrend(sets, exercise)).toEqual(points);
    }
  });

  it("knows a stalled lift (FIT-140)", () => {
    const plateauSets: LoggedSet[] = fixture.plateau.sets.map((s: Record<string, unknown>) => ({
      day: s.day, exercise: s.exercise, value: (m: string) => s[m] as number | undefined,
    }));
    for (const [exercise, expected] of Object.entries(fixture.plateau.expected)) {
      expect(plateaued(plateauSets, exercise, fixture.plateau.today), exercise).toBe(expected);
    }
  });

  it("counts the weekly streak", () => {
    const s = streak(fixture.programStart, fixture.plannedDays, fixture.workoutDays, fixture.today);
    expect(s).toEqual({ weeks: fixture.expectedStreakWeeks, thisWeek: fixture.expectedThisWeek });
  });

  it("knows a week at risk and a broken one", () => {
    // Week of Oct 11: Monday missed on Thursday, Wednesday done; two days left for two sessions.
    expect(streak("2026-10-12", ["2026-10-12", "2026-10-14", "2026-10-16"], ["2026-10-14"], "2026-10-15").thisWeek).toBe("atRisk");
    expect(streak("2026-10-12", ["2026-10-12", "2026-10-14", "2026-10-16"], [], "2026-10-16").thisWeek).toBe("broken");
  });

  it("reads training days past goals and the profile, which aren't rows (FIT-222)", () => {
    const workout = JSON.stringify([{ kind: "workout", template: "back-squat", measurements: [] }]);
    const units = new Map(Object.entries({
      profile: JSON.stringify({ programStart: Date.parse("2026-10-12T12:00:00Z") / 1000 }),
      "goal#1": JSON.stringify({ kind: "training", metric: "back-squat.1rm_lb", target: 315 }),
      "plan#2026-10-14": workout,
      "log#2026-10-14": workout,
    }).map(([key, body]) => [key, { key, body, updatedAt: "", deleted: false }]));
    expect(trainingDays(units)).toEqual({ planned: ["2026-10-14"], done: ["2026-10-14"] });
    expect(streakNow(units, new Date("2026-10-15T12:00:00Z"))).toBeDefined();
  });
});
