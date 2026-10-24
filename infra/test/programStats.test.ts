import { describe, expect, it } from "vitest";
import { fateOf, fingerprint, tally, type Written } from "../lambda/programStats.ts";
import type { PlanRow } from "../lambda/training.ts";

const row = (template: string, load: number, note = ""): PlanRow => ({
  id: crypto.randomUUID(), kind: "workout", at: 0, slot: "Lower", template, note, main: false, pinned: true,
  targets: [{ metric: "sets", value: 3, unit: "sets" }, { metric: "reps", value: 5, unit: "reps" }, { metric: "load_lb", value: load, unit: "lb" }],
});
const session = [row("back-squat", 225), row("plank", 0)];
const w = (extra: Partial<Written> = {}): Written => ({ day: "2026-10-26", at: "2026-10-24T06:00:00Z", by: "coach", owner: "client", fp: fingerprint(session), ...extra });

describe("FIT-209: whether a Claude-written session was kept", () => {
  it("is kept when the exercises, targets and notes are the same, whatever the row ids", () => {
    const again = session.map((r) => ({ ...r, id: crypto.randomUUID() }));
    expect(fateOf(w(), JSON.stringify(again))).toBe("kept");
  });

  it("is edited when a load, an exercise or a note changed, removed when the day is gone, undone after undo", () => {
    expect(fateOf(w(), JSON.stringify([row("back-squat", 205), row("plank", 0)]))).toBe("edited");
    expect(fateOf(w(), JSON.stringify([row("box-squat", 225), row("plank", 0)]))).toBe("edited");
    expect(fateOf(w(), JSON.stringify([row("back-squat", 225, "knee"), row("plank", 0)]))).toBe("edited");
    expect(fateOf(w(), undefined)).toBe("removed");
    expect(fateOf(w({ undone: true }), JSON.stringify(session))).toBe("undone");
  });

  it("tallies them, with sessions written for a client and those logged", () => {
    expect(tally([
      { written: w(), plan: JSON.stringify(session), logged: true },
      { written: w({ by: "me", owner: "me" }), plan: JSON.stringify([row("back-squat", 205)]), logged: false },
      { written: w(), plan: undefined, logged: false },
    ])).toEqual({ written: 3, forClients: 2, kept: 1, edited: 1, removed: 1, undone: 0, logged: 1 });
  });
});
