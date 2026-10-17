import { describe, expect, it } from "vitest";
import {
  checkProgramDay, deloadEvery, programOf, programWeekOf, programWeeks, title, travelWeeks, weekCount, weekIndex, weeklyTarget, type ProgramWeek,
} from "../lambda/program.ts";
import { epoch, type PlanRow, type Profile } from "../lambda/training.ts";

// FIT-165: the same cases as Tests/CoreTests/ProgramPlanTests.swift, so the agent's program matches the phone's.

describe("program skeleton (ProgramPlan.swift)", () => {
  it("counts weeks from the start's Sunday to the target date's week", () => {
    expect(weekCount("2026-09-13", "2027-01-02")).toBe(16);
    expect(weekCount("2026-09-16", "2027-01-02")).toBe(16);
    expect(weekCount("2026-09-13", "2027-03-01")).toBe(25);
    expect(weekCount("2026-09-13", "2026-09-01")).toBe(1);
    expect(weekIndex("2026-09-12", "2026-09-13")).toBe(-1);
  });

  it("puts phases, deloads and the test week where the app does", () => {
    const weeks = programWeeks(16, 6);
    expect(weeks.map((w) => w.phase)).toEqual([...Array(6).fill("base"), ...Array(6).fill("build"), ...Array(4).fill("peak")]);
    expect(weeks.flatMap((w, i) => (w.kind === "deload" ? [i] : []))).toEqual([5, 11]);
    expect(weeks.at(-1)!.kind).toBe("test");
  });

  it("moves the deload into a trip once half the time has passed", () => {
    const weeks = programWeeks(24, 6, new Set([8, 9]));
    expect(weeks.flatMap((w, i) => (w.kind === "deload" ? [i] : []))).toEqual([5, 9, 15, 21]);
    const early = programWeeks(24, 6, new Set([6]));
    expect(early.flatMap((w, i) => (w.kind === "deload" ? [i] : []))).toEqual([5, 11, 17]);
  });

  it("aims each week's sets by phase, light weeks at 55%", () => {
    const profile: Profile = { trainingDays: [0, 2, 4], sessionMinutes: 45, maxWeeklySets: 999 };
    expect(weeklyTarget({ phase: "build", kind: "build", travel: false }, profile)).toBe(54);
    expect(weeklyTarget({ phase: "build", kind: "deload", travel: false }, profile)).toBe(30);
  });

  it("finds the weeks a trip takes a training day from", () => {
    // Trains Mon/Wed/Fri; a trip Thu 2026-10-01 to Tue 2026-10-06 misses Fri of week 2 and Mon of week 3.
    expect(travelWeeks("2026-10-01", "2026-10-06", "2026-09-13", 16, [0, 2, 4])).toEqual([2, 3]);
    expect(travelWeeks("2026-10-03", "2026-10-04", "2026-09-13", 16, [0, 2, 4])).toEqual([]);
  });

  it("reads the profile as Profile.program does, in their time zone", () => {
    const tz = "America/New_York";
    // Onboarding: start is the Sunday, the target is 7 × weeks − 1 days later.
    const profile: Profile = { age: 36, programStart: epoch("2026-10-11", 0, tz), targetDate: epoch("2026-12-26", 0, tz), travelWeeks: [] };
    const program = programOf(profile, tz)!;
    expect(program.weeks).toHaveLength(11);
    expect(program.every).toBe(deloadEvery(36));
    expect(programWeekOf(profile, "2026-10-17", tz)).toMatchObject({ index: 0 });
    expect(programWeekOf(profile, "2026-10-18", tz)).toMatchObject({ index: 1 });
    expect(programWeekOf(profile, "2026-12-27", tz)).toBeUndefined();
    expect(title(program.weeks[5])).toBe("Deload");
    expect(title({ phase: "build", kind: "build", travel: true })).toBe("Build · travel");
  });
});

describe("a program week's plan rules", () => {
  const row = (template: string, sets: number, rpe?: number): PlanRow => ({
    id: template, kind: "workout", at: 0, template, note: "", main: false, pinned: false,
    targets: [{ metric: "sets", value: sets, unit: "" }, ...(rpe ? [{ metric: "rpe", value: rpe, unit: "" }] : [])],
  });
  const profile: Profile = { age: 36, trainingDays: [0, 2, 4], sessionMinutes: 45, equipment: ["barbell", "rack", "bench", "dumbbells"] };
  const deload: ProgramWeek = { phase: "build", kind: "deload", travel: false };

  it("holds a deload's session to about half and RPE 6", () => {
    // 3 days × 45 min: the table's top is 18 a session, so a light one holds 12.
    expect(checkProgramDay([row("back-squat", 4, 6), row("bench-press", 4, 6), row("barbell-row", 4, 6)], profile, deload)).toEqual([]);
    const heavy = checkProgramDay([row("back-squat", 5, 8), row("bench-press", 4), row("barbell-row", 4)], profile, deload);
    expect(heavy).toEqual(["Back Squat: RPE 8 is over 6, the cap in a deload week.", "13 sets in a deload week's session; a light week holds at most 12."]);
  });

  it("keeps a travel week to dumbbells and bodyweight", () => {
    const travel: ProgramWeek = { phase: "base", kind: "base", travel: true };
    expect(checkProgramDay([row("back-squat", 3)], profile, travel)[0]).toMatch(/Back Squat needs barbell.*travel week is dumbbells and bodyweight only/);
    expect(checkProgramDay([row("push-up", 3)], profile, travel)).toEqual([]);
  });
});
