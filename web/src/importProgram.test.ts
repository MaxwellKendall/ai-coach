import { describe, expect, it } from "vitest";
import { previewLines, sourceOf } from "./ImportProgram";

describe("FIT-290: the import preview", () => {
  it("shows the days, not the proposal's id", () => {
    expect(previewLines("Proposal 1234 — Imported from a spreadsheet\n\nMonday 2026-11-02 — Lower A:\n  + Back Squat 4 × 5 @ 225 lb"))
      .toBe("Monday 2026-11-02 — Lower A:\n  + Back Squat 4 × 5 @ 225 lb");
  });
});

describe("FIT-291: what's imported", () => {
  it("is the sheet link, then a PDF, then the pasted text", () => {
    expect(sourceOf("cells", "https://docs.google.com/spreadsheets/d/x", { name: "p.pdf", data: "JVBE" })).toEqual({ sheet: "https://docs.google.com/spreadsheets/d/x" });
    expect(sourceOf("cells", " ", { name: "p.pdf", data: "JVBE" })).toEqual({ pdf: "JVBE" });
    expect(sourceOf("cells", "")).toEqual({ text: "cells" });
    expect(sourceOf("  ", "")).toBeUndefined();
  });
});
