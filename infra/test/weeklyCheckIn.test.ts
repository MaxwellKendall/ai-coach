import { describe, expect, it } from "vitest";
import { concerns, triage } from "../../shared/triage.ts";

// FIT-344: the weekly check-in's flags for the coach, as Triage.swift has them (TriageTests). "Today" is Friday Oct 16.
const today = "2026-10-16";
const rated = (energy: number, stress: number, soreness: number, adherence: number, note = "") => ({
  id: "c", kind: "checkin", note,
  measurements: [
    { metric: "energy_1to5", value: energy, unit: "/5" }, { metric: "stress_1to5", value: stress, unit: "/5" },
    { metric: "soreness_1to5", value: soreness, unit: "/5" }, { metric: "adherence_1to5", value: adherence, unit: "/5" },
  ],
});
const units = (entries: [string, unknown][]) => new Map(entries.map(([k, v]) => [k, JSON.stringify(v)]));
const flags = (u: Map<string, string>) => triage(u, [], new Map(), "sam", today).flags;

describe("the weekly check-in (FIT-344)", () => {
  it("reads the ratings worth a look", () => {
    expect(concerns(rated(2, 4, 4, 2) as never)).toEqual(["low energy", "high stress", "very sore", "off the plan"]);
    expect(concerns(rated(3, 3, 3, 3) as never)).toEqual([]);
  });

  it("flags low ratings in the last week's check-in, and not a fine one", () => {
    expect(flags(units([["log#2026-10-11", [rated(2, 4, 3, 5)]]]))).toEqual([{ kind: "checkin", text: "Check-in: low energy, high stress" }]);
    expect(flags(units([["log#2026-10-11", [rated(4, 2, 2, 5)]]]))).toEqual([]);
    // Over a week old: not this week's.
    expect(flags(units([["log#2026-10-08", [rated(1, 5, 5, 1)]]]))).toEqual([]);
  });

  it("flags a missed check-in only once the coach has chosen a day", () => {
    // Wednesday (day 2) has passed this week with no check-in since.
    expect(flags(units([["checkin", { day: 2 }]]))).toEqual([{ kind: "checkin", text: "Missed Wednesday’s check-in" }]);
    expect(flags(units([["checkin", { day: 2 }], ["log#2026-10-15", [rated(4, 2, 2, 5)]]]))).toEqual([]);
    // Today's check-in day isn't missed yet; the one before it, a week ago, was done.
    expect(flags(units([["checkin", { day: 4 }], ["log#2026-10-09", [rated(4, 2, 2, 5)]]]))).toEqual([]);
    // No day chosen: nothing is missed.
    expect(flags(units([]))).toEqual([]);
  });

  it("reads what they wrote as a note, pain first", () => {
    const u = units([["log#2026-10-11", [rated(4, 2, 2, 5, "What went well: every session\nWhat was hard: my knee hurts on stairs")]]]);
    expect(flags(u)).toEqual([{ kind: "pain", text: "Sunday: “What went well: every session What was hard: my knee hurts on stairs”" }]);
  });
});
