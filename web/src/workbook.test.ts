import { describe, expect, it } from "vitest";
import * as XLSX from "xlsx";
import { isWorkbook, tabsOf } from "./workbook";

const book = (tabs: Record<string, unknown[][]>) => {
  const wb = XLSX.utils.book_new();
  for (const [name, rows] of Object.entries(tabs)) XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(rows), name);
  return XLSX.write(wb, { type: "array", bookType: "xlsx" }) as ArrayBuffer;
};

describe("an .xlsx upload (FIT-292)", () => {
  it("reads each tab as tab-separated cells, skipping empty tabs", async () => {
    const data = book({
      Sam: [["Week", "Day", "Exercise", "Sets x reps", "Load"], [1, "Monday", "Back Squat", "4 x 5", 225], [1, "Monday", "Bench Press", "3 x 8", 155]],
      Notes: [],
      Ann: [["Week 1"], ["Tuesday", "Deadlift", "3 x 3"]],
    });
    expect(await tabsOf(data)).toEqual([
      { name: "Sam", text: "Week\tDay\tExercise\tSets x reps\tLoad\n1\tMonday\tBack Squat\t4 x 5\t225\n1\tMonday\tBench Press\t3 x 8\t155" },
      { name: "Ann", text: "Week 1\t\t\nTuesday\tDeadlift\t3 x 3" },
    ]);
  });

  it("knows a workbook by its name", () => {
    expect(["Program.xlsx", "old.XLS", "macros.xlsm"].every((name) => isWorkbook({ name }))).toBe(true);
    expect(["program.csv", "plan.pdf"].some((name) => isWorkbook({ name }))).toBe(false);
  });
});
