import { describe, expect, it } from "vitest";
import { addLine, editLine, editLines, editOf, moveDay, moveLine, removeLine } from "./edit";
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
