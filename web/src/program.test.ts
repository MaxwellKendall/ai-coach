import { describe as group, expect, it } from "vitest";
import { describe, lines, week, weekStart, WARMUP } from "./program";
import type { PlanRow, Unit } from "./sync";

const names = new Map([["bench-press", "Bench Press"], ["plank", "Plank"]]);
const at = (iso: string, offset = 0) => new Date(iso).getTime() / 1000 + offset;
const row = (over: Partial<PlanRow>): PlanRow => ({
  id: crypto.randomUUID(), kind: "workout", at: at("2026-10-16T07:00:00"), targets: [], note: "", main: false, pinned: false, ...over,
});
const unit = (key: string, body: unknown): [string, Unit] => [key, { key, updatedAt: "", deleted: false, body: JSON.stringify(body) }];

group("the week", () => {
  it("runs Sunday to Saturday", () => {
    expect(weekStart(new Date("2026-10-16T15:00:00")).toDateString()).toBe(new Date("2026-10-11T00:00:00").toDateString());
    expect(weekStart(new Date("2026-10-11T00:30:00")).getDate()).toBe(11);
  });

  it("shows each day's session, and whether it was logged", () => {
    const units = new Map([
      unit("plan#2026-10-16", [row({ slot: "Upper", template: "bench-press", targets: [{ metric: "sets", value: 3, unit: "sets" }] })]),
      unit("log#2026-10-16", [{ id: "l1", kind: "workout", at: at("2026-10-16T07:30:00"), measurements: [], note: "" }]),
      unit("plan#2026-10-18", [row({ template: "plank" })]),
    ]);
    const days = week(units, new Date("2026-10-16T12:00:00"), names);
    expect(days.map((d) => d.key)).toEqual(["2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"]);
    expect(days[5]).toMatchObject({ title: "Upper", done: true, lines: [{ exercise: "Bench Press", sets: 3 }] });
    expect(days[4].lines).toEqual([]);
  });
});

group("a session's lines", () => {
  const reps = (n: number) => ({ metric: "reps", value: n, unit: "reps" });
  const load = (n: number) => ({ metric: "load_lb", value: n, unit: "lb" });

  it("count rows of one exercise with the same targets together, in order, without warm-ups", () => {
    const plan = [
      row({ template: "bench-press", at: 3, targets: [reps(5), load(185)] }),
      row({ template: "bench-press", at: 1, targets: [reps(5), load(95)], note: WARMUP }),
      row({ template: "bench-press", at: 2, targets: [reps(5), load(185)] }),
      row({ template: "bench-press", at: 4, targets: [reps(3), load(195)] }),
    ];
    expect(lines(plan, names).map(describe)).toEqual(["2 × 5 @ 185 lb", "1 × 3 @ 195 lb"]);
  });

  it("read like the app", () => {
    const line = (targets: PlanRow["targets"], sets = 3) => describe({ exercise: "x", sets, targets, note: "" });
    expect(line([{ metric: "duration_s", value: 45, unit: "s" }])).toBe("3 × 45 s");
    expect(line([reps(8), { metric: "load_lb_hand", value: 50, unit: "lb/hand" }, { metric: "rpe", value: 8, unit: "rpe" }], 4))
      .toBe("4 × 8 @ 50 lb/hand · RPE 8");
    expect(line([], 1)).toBe("1 set");
  });

  it("name an exercise the catalog doesn't know by its slug", () => {
    expect(lines([row({ template: "zercher-squat" })], names)[0].exercise).toBe("zercher-squat");
  });
});
