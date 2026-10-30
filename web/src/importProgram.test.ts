import { describe, expect, it } from "vitest";
import { previewLines } from "./ImportProgram";

describe("FIT-290: the import preview", () => {
  it("shows the days, not the proposal's id", () => {
    expect(previewLines("Proposal 1234 — Imported from a spreadsheet\n\nMonday 2026-11-02 — Lower A:\n  + Back Squat 4 × 5 @ 225 lb"))
      .toBe("Monday 2026-11-02 — Lower A:\n  + Back Squat 4 × 5 @ 225 lb");
  });
});
