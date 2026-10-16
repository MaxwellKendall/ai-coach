import { describe, expect, it } from "vitest";
import { checkDay, checkWeek, rpeCaps, type Exercise } from "./guard";
import type { PlanRow } from "./sync";

const m = (metric: string, value: number) => ({ metric, value, unit: metric });
let n = 0;
const row = (template: string, targets: PlanRow["targets"], over: Partial<PlanRow> = {}): PlanRow => ({
  id: `r${++n}`, kind: "workout", at: n, template, targets, note: "", main: false, pinned: false, ...over,
});
const catalog = new Map<string, Exercise>([
  ["bench-press", { slug: "bench-press", name: "Bench Press", equipment: ["barbell", "bench"] }],
  ["lat-pulldown", { slug: "lat-pulldown", name: "Lat Pulldown", equipment: ["cable"] }],
  ["plank", { slug: "plank", name: "Plank", equipment: [] }],
]);
const profile = { age: 42, equipment: ["barbell", "bench", "rack"], maxWeeklySets: 12 };

describe("plan checks on the web (FIT-128, PlanGuard)", () => {
  it("pass a plan the app would make", () => {
    expect(checkDay([row("bench-press", [m("sets", 4), m("reps", 5), m("load_lb", 185), m("rpe", 7)], { main: true }),
                     row("plank", [m("sets", 3), m("duration_s", 45)])], profile, catalog)).toEqual([]);
  });

  it("warn on sets past the app's limit, main and accessory", () => {
    expect(checkDay([row("bench-press", [m("sets", 6), m("reps", 5)], { main: true })], profile, catalog))
      .toEqual(["Bench Press: 6 sets is more than the 5 the app plans for a main lift."]);
    expect(checkDay([row("plank", [m("sets", 5)])], profile, catalog))
      .toEqual(["Plank: 5 sets is more than the 4 the app plans for an accessory."]);
    expect(checkDay([row("plank", [m("sets", 1)])], profile, catalog)).toEqual(["Plank: 1 set is fewer than the 2 the app plans."]);
  });

  it("warn on RPE over the age tier's cap", () => {
    expect(rpeCaps(42)).toEqual({ main: 7, accessory: 7 });
    expect(checkDay([row("bench-press", [m("sets", 3), m("rpe", 9)], { main: true })], profile, catalog))
      .toEqual(["Bench Press: RPE 9 is over 7, the cap at 42 for a main lift."]);
  });

  it("warn on a barbell load off the 5 lb steps, and on equipment not on hand", () => {
    expect(checkDay([row("bench-press", [m("sets", 3), m("load_lb", 187)])], profile, catalog))
      .toEqual(["Bench Press: 187 lb isn't a 5 lb step on a barbell."]);
    expect(checkDay([row("lat-pulldown", [m("sets", 3)])], profile, catalog))
      .toEqual(["Lat Pulldown needs cable, which isn't in your equipment."]);
  });

  it("warn when the week's working sets go over the ceiling", () => {
    const day = [row("bench-press", [m("sets", 4)]), row("plank", [m("sets", 3)])];
    expect(checkWeek([day], profile)).toBeUndefined();
    expect(checkWeek([day, day], profile)).toBe("14 working sets this week, over your ceiling of 12.");
  });

  it("don't guess without a profile", () => {
    expect(checkDay([row("bench-press", [m("sets", 3), m("rpe", 10)], { main: true })], undefined, catalog)).toEqual([]);
    expect(checkWeek([[row("plank", [m("sets", 40)])]], undefined)).toBeUndefined();
  });
});
