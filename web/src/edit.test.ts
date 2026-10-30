import { describe, expect, it } from "vitest";
import { addLine, addWarmup, copyDay, editLine, editLines, editOf, groupWithNext, moveDay, moveLine, removeLine, removeWarmup, ungroup, warmupLines } from "./edit";
import { describe as text, lines, WARMUP } from "./program";
import type { PlanRow } from "./sync";

const m = (metric: string, value: number, unit = metric) => ({ metric, value, unit });
const start = 1_790_000_000 - (1_790_000_000 % 60);
let n = 0;
const row = (template: string, targets: PlanRow["targets"], over: Partial<PlanRow> = {}): PlanRow => ({
  id: `r${++n}`, kind: "workout", at: start + n, slot: "Upper", template, targets, note: "", main: false, pinned: false, ...over,
});
const names = new Map([["bench-press", "Bench Press"], ["dumbbell-row", "Row"], ["plank", "Plank"]]);
const shown = (rows: PlanRow[]) => lines(rows, names).map((l) => `${l.exercise} ${text(l)}`);

function session() {
  n = 0;
  return [
    row("bench-press", [m("sets", 2), m("reps", 5), m("load_lb", 95, "lb")], { note: WARMUP }),
    row("bench-press", [m("sets", 3), m("reps", 5), m("load_lb", 185, "lb")], { main: true }),
    row("dumbbell-row", [m("sets", 3), m("reps", 10), m("load_lb_hand", 60, "lb/hand")]),
    row("plank", [m("sets", 3), m("duration_s", 45, "s")]),
  ];
}

describe("editing a session (FIT-128)", () => {
  it("changes a line's sets, reps and load, and pins the day like an edit in the app", () => {
    const rows = session();
    const bench = editLines(rows)[0];
    const out = editLine(rows, bench, { ...editOf(bench), sets: 4, reps: 4, load: 195 });
    expect(shown(out)).toEqual(["Bench Press 4 × 4 @ 195 lb", "Row 3 × 10 @ 60 lb/hand", "Plank 3 × 45 s"]);
    expect(out.every((r) => r.pinned)).toBe(true);
    expect(out.find((r) => r.id === bench.ids[0])).toMatchObject({ main: true, adjustedReason: "edited" });
    // The warm-up stays as it was.
    expect(out[0].targets).toEqual(rows[0].targets);
  });

  it("keeps a per-hand load per hand and a timed set timed", () => {
    const rows = session();
    const [, row_, plank] = editLines(rows);
    expect(shown(editLine(rows, row_, { ...editOf(row_), load: 65 }))[1]).toBe("Row 3 × 10 @ 65 lb/hand");
    expect(shown(editLine(rows, plank, { ...editOf(plank), seconds: 60 }))[2]).toBe("Plank 3 × 60 s");
  });

  it("folds a line split over several rows into one row", () => {
    n = 0;
    const rows = [row("bench-press", [m("reps", 5)]), row("bench-press", [m("reps", 5)]), row("bench-press", [m("reps", 5)])];
    const [line] = editLines(rows);
    expect(line).toMatchObject({ ids: ["r1", "r2", "r3"], sets: 3 });
    const out = editLine(rows, line, { ...editOf(line), sets: 5 });
    expect(out.map((r) => r.id)).toEqual(["r1"]);
    expect(shown(out)).toEqual(["Bench Press 5 × 5"]);
  });

  it("removes a line with its warm-ups", () => {
    const rows = session();
    const out = removeLine(rows, editLines(rows)[0]);
    expect(out.map((r) => r.template)).toEqual(["dumbbell-row", "plank"]);
    expect(out.map((r) => r.at)).toEqual([start, start + 1]);
  });

  it("moves a line with its warm-ups, and goes no further than the ends", () => {
    const rows = session();
    const [bench, , plank] = editLines(rows);
    const down = moveLine(rows, bench, 1);
    expect(down.map((r) => `${r.template}${r.note ? "*" : ""}`)).toEqual(["dumbbell-row", "bench-press*", "bench-press", "plank"]);
    expect(down.map((r) => r.at)).toEqual([start + 1, start + 2, start + 3, start + 4].map((t) => t - 1));
    expect(moveLine(rows, bench, -1)).toBe(rows);
    expect(moveLine(rows, plank, 1)).toBe(rows);
  });

  it("adds an exercise at the end, in the session", () => {
    const rows = session();
    const out = addLine(rows, "plank", undefined, start, "new");
    expect(out.at(-1)).toMatchObject({ id: "new", template: "plank", slot: "Upper", at: rows.at(-1)!.at + 1, pinned: true });
    expect(shown(out).at(-1)).toBe("Plank 3 × 10");
  });

  it("starts a rest day's first exercise at 7:00", () => {
    expect(addLine([], "plank", "Workout", start, "x")[0]).toMatchObject({ at: start + 7 * 3600, slot: "Workout" });
  });
});

describe("moving a session to another day (FIT-128)", () => {
  it("keeps its rows, ids and time of day", () => {
    const rows = session();
    const day = 86_400;
    const out = moveDay(rows, start - 7 * 3600, start - 7 * 3600 + 2 * day);
    expect(out.map((r) => r.id)).toEqual(rows.map((r) => r.id));
    expect(out.map((r) => r.at - 2 * day)).toEqual(rows.map((r) => r.at));
    expect(out.every((r) => r.pinned)).toBe(true);
  });
});

describe("copying a session forward (FIT-128)", () => {
  it("makes new rows a week on, at the same time, pinned, without the day's kitchen", () => {
    const rows = [...session(), row("", [], { kind: "cook" })];
    let k = 0;
    const out = copyDay(rows, start, start + 7 * 86_400, () => `c${++k}`);
    expect(out.map((r) => r.id)).toEqual(["c1", "c2", "c3", "c4"]);
    expect(out.map((r) => r.at - 7 * 86_400)).toEqual(rows.slice(0, 4).map((r) => r.at));
    expect(out.every((r) => r.pinned && r.kind === "workout")).toBe(true);
  });
});

describe("supersets (FIT-128)", () => {
  it("group a line with the next, and come apart again", () => {
    const rows = session();
    const [, rowLine] = editLines(rows);
    const grouped = groupWithNext(rows, rowLine);
    const lines = editLines(grouped);
    expect(lines.map((l) => l.group)).toEqual([undefined, 1, 1]);
    // Taking one out of a pair leaves no group at all.
    const apart = ungroup(grouped, lines[1]);
    expect(editLines(apart).map((l) => l.group)).toEqual([undefined, undefined, undefined]);
  });

  it("join an existing group, and the last line has nothing to join", () => {
    const rows = session();
    const lines = editLines(rows);
    const two = groupWithNext(rows, lines[0]);
    const three = groupWithNext(two, editLines(two)[1]);
    expect(editLines(three).map((l) => l.group)).toEqual([1, 1, 1]);
    expect(groupWithNext(rows, lines[2])).toBe(rows);
  });
});

describe("a session's written warm-up (FIT-300)", () => {
  it("adds items before the lifts, edits and removes them, and leaves a lift's ramp sets with the lift", () => {
    const rows = session();
    expect(warmupLines(rows)).toEqual([]); // the bench's ramp set is the bench's
    const withRow = addWarmup(rows, "rowing-stationary", "Upper", start, "w1");
    const withBands = addWarmup(withRow, "band-pull-apart", "Upper", start, "w2");
    const ordered = [...withBands].sort((a, b) => a.at - b.at);
    expect(ordered.map((r) => r.template)).toEqual(["rowing-stationary", "band-pull-apart", "bench-press", "bench-press", "dumbbell-row", "plank"]);
    expect(ordered[0]).toMatchObject({ note: WARMUP, main: false, pinned: true, targets: [m("sets", 1, "sets"), m("duration_s", 300, "s")] });
    // The lifts are unchanged, and the warm-up isn't one of them.
    expect(shown(withBands)).toEqual(shown(rows));
    const bands = warmupLines(withBands)[1];
    const edited = editLine(withBands, bands, { sets: 2, seconds: 30 });
    expect(warmupLines(edited)[1]).toMatchObject({ template: "band-pull-apart", sets: 2, targets: [m("duration_s", 30, "s")] });
    const out = removeWarmup(edited, warmupLines(edited)[0]);
    expect(warmupLines(out).map((l) => l.template)).toEqual(["band-pull-apart"]);
    expect(out.find((r) => r.id === "w1")).toBeUndefined();
  });
});
