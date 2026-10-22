import { describe, expect, it } from "vitest";
import type { LogRow, PlanRow, Unit } from "./sync";
import { checkIn } from "../../shared/triage";
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
// As the app saves a session: each set's note is the session's name, the client's words are on the summary row.
const noted = new Map([plan("2026-10-14"), unit("log#2026-10-14", [
  { id: "l-1", kind: "workout", at: at("2026-10-14"), plannedRef: "p-2026-10-14", template: "back-squat", measurements: [], note: "Lower" },
  { id: "l-2", kind: "workout", at: at("2026-10-14") + 1, measurements: [], note: "Knee felt tight on the last set" },
])]);

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

// FIT-223: a check-in as the app's Check In writes it (FIT-204, SyncUnits.LogRow): weight and sleep rows, the note on
// the sleep row. The client also has goals and a profile, units that are objects, not rows.
const checkedIn = (note: string, rows?: unknown[]) => new Map([
  unit("log#2026-10-15", rows ?? [
    { id: "6F1C1B0E-4F7B-4D0A-9E59-0F1F4B7B2C11", kind: "bodyweight", at: at("2026-10-15"), measurements: [{ metric: "weight_lb", value: 183.5, unit: "lb" }], note: "" },
    { id: "0B9D2C61-2E57-4C55-8A0B-7C58F3A4D2E2", kind: "sleep", at: at("2026-10-15"), measurements: [{ metric: "sleep_h", value: 6, unit: "h" }], note },
  ]),
  ["goal#1", { key: "goal#1", updatedAt: "", deleted: false, body: JSON.stringify({ kind: "body", metric: "weight_lb", target: 180, unit: "lb", status: "active" }) }] as [string, Unit],
  ["profile", { key: "profile", updatedAt: "", deleted: false, body: JSON.stringify({ age: 42, equipment: [] }) }] as [string, Unit],
]);

describe("the client's daily check-in (FIT-223)", () => {
  const rows = (units: Map<string, Unit>) => JSON.parse(units.get("log#2026-10-15")!.body!) as LogRow[];

  it("reads weight, sleep and the note from the day's log", () => {
    expect(checkIn(rows(checkedIn("Knee is a bit sore")))).toEqual({ weight: 183.5, sleep: 6, note: "Knee is a bit sore" });
    expect(checkIn(rows(checkedIn("")))).toEqual({ weight: 183.5, sleep: 6, note: undefined });
    // A note on its own is a weight row with no weight.
    const alone = [{ id: "A", kind: "bodyweight", at: at("2026-10-15"), measurements: [], note: "Travelling, back Monday" }];
    expect(checkIn(rows(checkedIn("", alone)))).toEqual({ weight: undefined, sleep: undefined, note: "Travelling, back Monday" });
    // A workout's notes and meals aren't a check-in.
    expect(checkIn([{ id: "W", kind: "workout", measurements: [], note: "Felt great" }, { id: "M", kind: "meal", measurements: [], note: "Oats" }])).toBeUndefined();
  });

  it("flags a check-in note until the coach replies on that day, pain first", () => {
    expect(triage(checkedIn("Knee is a bit sore"), [], names, "sam", now).flags).toEqual([{ kind: "pain", text: "Thursday: “Knee is a bit sore”" }]);
    expect(triage(checkedIn("Slept badly, busy week"), [], names, "sam", now).flags).toEqual([{ kind: "note", text: "Thursday: “Slept badly, busy week”" }]);
    const reply: Comment = { day: "2026-10-15", at: "", by: "sam", byName: "Sam", text: "Rest up." };
    expect(triage(checkedIn("Knee is a bit sore"), [reply], names, "sam", now).flags).toEqual([]);
    expect(triage(checkedIn(""), [], names, "sam", now).flags).toEqual([]);
  });
});
