import { describe, expect, it } from "vitest";
import { effective } from "../lambda/plan.ts";
import { addDays } from "../lambda/training.ts";
import { demoProPlan, lifterUnits } from "../scripts/lifterDemo.ts";

// Thursday 2026-11-05: its week's Sunday is 2026-11-01.
const today = "2026-11-05";
const sessions = lifterUnits(today);

describe("TKL-749: the Lifter Pro demo account", () => {
  it("has Lifter Pro now, with no store behind it", () => {
    const plan = demoProPlan(new Date("2026-11-05T12:00:00Z"));
    expect(plan.SK).toBe("PROPLAN");
    expect(effective(plan as never, new Date("2026-11-05T12:00:00Z")).has).toBe(true);
    expect(effective(plan as never, new Date("2027-03-01T12:00:00Z")).has).toBe(true);
  });

  it("logs Mon/Wed/Fri for the three weeks before this one", () => {
    for (const w of [-3, -2, -1]) for (const d of [1, 3, 5]) expect(sessions.has(`log#${addDays("2026-11-01", 7 * w + d)}`)).toBe(true);
    expect(sessions.has(`log#${today}`)).toBe(false);
  });

  it("plans this week and next from their own program, not a coach", () => {
    for (const day of ["2026-11-06", "2026-11-09", "2026-11-13"]) expect(sessions.get(`plan#${day}`)).toContain("From your program");
    expect([...sessions.values()].join("")).not.toContain("Written by the coach");
  });

  it("has a program and goals, and the bench stall the AI week can change", () => {
    expect(JSON.parse(sessions.get("profile")!)).toHaveProperty("targetDate");
    expect([...sessions.keys()].filter((k) => k.startsWith("goal#"))).toHaveLength(2);
    expect(sessions.get(`log#${addDays("2026-11-01", -7 + 1)}`)).toContain("Bench stuck at 185");
  });
});
