import { describe, expect, it } from "vitest";
import type { LogRow, PlanRow, Unit } from "./sync";
import { byNeed, hurts, triage, type Comment } from "./triage";

// FIT-132's three clients: one on track, one who missed sessions, one who left a note. "Now" is Friday Oct 16.
const now = new Date(2026, 9, 16, 18);
const at = (day: string) => new Date(`${day}T07:00:00`).getTime() / 1000;
const names = new Map([["back-squat", "Back Squat"]]);
const unit = (key: string, body: unknown[]): [string, Unit] => [key, { key, updatedAt: "", deleted: false, body: JSON.stringify(body) }];
const plan = (day: string, id = `p-${day}`): [string, Unit] =>
  unit(`plan#${day}`, [{ id, kind: "workout", at: at(day), slot: "Lower", template: "back-squat", targets: [], note: "", main: true, pinned: false } as PlanRow]);
const log = (day: string, over: Partial<LogRow> = {}): [string, Unit] =>
  unit(`log#${day}`, [{ id: `l-${day}`, kind: "workout", at: at(day), plannedRef: `p-${day}`, template: "back-squat", measurements: [], note: "", ...over } as LogRow]);

const onTrack = new Map([plan("2026-10-12"), plan("2026-10-14"), plan("2026-10-17"), log("2026-10-12"), log("2026-10-14")]);
const missing = new Map([plan("2026-10-12"), plan("2026-10-14"), plan("2026-10-16"), log("2026-10-09")]);
const noted = new Map([plan("2026-10-14"), log("2026-10-14", { note: "Knee felt tight on the last set" })]);

describe("which clients need their coach (FIT-132)", () => {
  it("counts this week's sessions and the last one", () => {
    expect(triage(onTrack, [], names, "sam", now)).toMatchObject({ done: 2, planned: 3, lastSession: "2026-10-14", flags: [] });
  });

  it("flags missed sessions", () => {
    expect(triage(missing, [], names, "sam", now).flags).toEqual([{ kind: "missed", text: "Missed 2 sessions this past week" }]);
  });

  it("flags a note, and pain first, until the coach replies on that day", () => {
    const t = triage(noted, [], names, "sam", now);
    expect(t.flags).toEqual([{ kind: "pain", text: "Wednesday: “Knee felt tight on the last set”" }]);
    const reply: Comment = { day: "2026-10-14", at: "", by: "sam", byName: "Sam", text: "Ice it." };
    expect(triage(noted, [reply], names, "sam", now).flags).toEqual([]);
    // The client's own reply doesn't count as the coach's.
    expect(triage(noted, [{ ...reply, by: "ann" }], names, "sam", now).flags).toHaveLength(1);
  });

  it("flags RPE 9+ on a main lift", () => {
    const hard = new Map([plan("2026-10-14"), log("2026-10-14", { measurements: [{ metric: "rpe", value: 9.5, unit: "rpe" }] })]);
    expect(triage(hard, [], names, "sam", now).flags).toEqual([{ kind: "hard", text: "RPE 9+ on Back Squat" }]);
  });

  it("flags a main lift with no new best in three weeks (FIT-140)", () => {
    const sq = (day: string, load: number): [string, Unit] => log(day, { measurements: [{ metric: "load_lb", value: load, unit: "lb" }, { metric: "reps", value: 5, unit: "reps" }] });
    const stalled = new Map([plan("2026-10-14"), sq("2026-09-14", 245), sq("2026-09-30", 240), sq("2026-10-07", 240), sq("2026-10-14", 240)]);
    expect(triage(stalled, [], names, "sam", now).flags).toContainEqual({ kind: "plateau", text: "No new best on Back Squat in 3 weeks" });
  });

  it("flags two quiet weeks", () => {
    const quiet = new Map([plan("2026-10-14"), log("2026-09-20")]);
    expect(triage(quiet, [], names, "sam", now).flags).toContainEqual({ kind: "quiet", text: "Nothing logged in over two weeks" });
  });

  it("puts the client in pain first, then the one missing sessions, then the one on track", () => {
    const clients = [onTrack, missing, noted].map((u, i) => ({ i, triage: triage(u, [], names, "sam", now) }));
    expect(byNeed(clients).map((c) => c.i)).toEqual([2, 1, 0]);
  });

  it("knows the words that mean something hurts", () => {
    expect(hurts("Lower back a bit sore")).toBe(true);
    expect(hurts("Felt great")).toBe(false);
  });
});
