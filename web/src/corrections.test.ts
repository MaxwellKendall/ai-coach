import { describe, expect, it } from "vitest";
import { clearSession, fixSet, isSet, removeSet, sessionNote, setFields, withNote } from "./corrections";
import type { LogRow } from "./sync";

const m = (metric: string, value: number, unit = metric) => ({ metric, value, unit });
const at = 1_790_000_000;
// A session as the app saves it: each set's note is the session's name, then a summary with the client's note.
function day(): LogRow[] {
  return [
    { id: "s1", kind: "workout", at, template: "back-squat", measurements: [m("reps", 5), m("load_lb", 205, "lb"), m("rpe", 8)], note: "Lower A" },
    { id: "s2", kind: "workout", at: at + 1, template: "dumbbell-row", measurements: [m("reps", 10), m("load_lb_hand", 60, "lb/hand")], note: "Lower A" },
    { id: "s3", kind: "workout", at: at + 2, template: "plank", measurements: [m("duration_s", 45, "s")], note: "Lower A" },
    { id: "run", kind: "workout", at: at + 3, template: "easy-run", measurements: [m("distance_m", 3000, "m")], note: "easy", route: [[1, 2]] } as LogRow,
    { id: "sum", kind: "workout", at: at + 4, measurements: [m("effort", 7)], note: "Left knee a bit sore" },
    { id: "meal", kind: "meal", at: at + 5, measurements: [m("protein_g", 40, "g")], note: "" },
  ];
}

describe("FIT-200: fixing a logged set", () => {
  it("changes the load, reps and RPE, keeping the set's own units", () => {
    const fixed = fixSet(day(), "s1", { load: 215, reps: 4, rpe: 9 });
    expect(fixed[0].measurements).toEqual([m("reps", 4), m("load_lb", 215, "lb"), m("rpe", 9)]);
    expect(fixSet(day(), "s2", { load: 65 })[1].measurements).toContainEqual(m("load_lb_hand", 65, "lb/hand"));
    expect(fixSet(day(), "s3", { seconds: 60 })[2].measurements).toEqual([m("duration_s", 60, "s")]);
  });

  it("adds a number the set didn't have, clears one set to null, and leaves the other rows alone", () => {
    const fixed = fixSet(day(), "s2", { rpe: 8, load: null });
    expect(fixed[1].measurements).toEqual([m("reps", 10), m("rpe", 8, "rpe")]);
    expect(fixed.filter((r) => r.id !== "s2")).toEqual(day().filter((r) => r.id !== "s2"));
  });

  it("keeps fields the web doesn't know, such as a run's route", () => {
    const fixed = fixSet(day(), "run", {});
    expect((fixed[3] as LogRow & { route: unknown }).route).toEqual([[1, 2]]);
  });

  it("shows each set's numbers; runs, the summary and meals aren't sets", () => {
    expect(setFields(day()[1])).toEqual({ load: 60, loadUnit: "lb/hand", timed: false, count: 10, rpe: undefined });
    expect(setFields(day()[2])).toMatchObject({ timed: true, count: 45 });
    expect(day().filter(isSet).map((r) => r.id)).toEqual(["s1", "s2", "s3"]);
  });

  it("removes one set", () => {
    expect(removeSet(day(), "s2").map((r) => r.id)).toEqual(["s1", "s3", "run", "sum", "meal"]);
  });
});

describe("FIT-200: clearing a session", () => {
  it("takes every set, run and the summary, and keeps meals", () => {
    expect(clearSession(day()).map((r) => r.id)).toEqual(["meal"]);
  });
});

describe("FIT-200: the session's note", () => {
  it("is the summary's, not the session's name on each set", () => {
    expect(sessionNote(day(), "Lower A")).toBe("Left knee a bit sore");
    const legacy = day().map((r) => (r.id === "sum" ? { ...r, note: "Lower A" } : r));
    expect(sessionNote(legacy, "Lower A")).toBe("");
  });

  it("is edited or removed on the summary", () => {
    expect(withNote(day(), " Knee fine now ", "Lower A").find((r) => r.id === "sum")!.note).toBe("Knee fine now");
    expect(sessionNote(withNote(day(), "", "Lower A"), "Lower A")).toBe("");
    expect(withNote(day(), "", "Lower A").length).toBe(day().length);
  });

  it("gets a summary when the session was logged without one", () => {
    const bare = day().filter((r) => r.id !== "sum");
    const noted = withNote(bare, "Felt strong", "Lower A", "new");
    expect(noted.at(-1)).toEqual({ id: "new", kind: "workout", at: at + 4, measurements: [], note: "Felt strong" });
    expect(withNote(bare, "", "Lower A")).toEqual(bare);
  });
});
