import { describe, expect, it } from "vitest";
import { importProgram, keepPercents, mondayOf, toDays, unmatched } from "../lambda/importProgram.ts";
import { applyProposal, type Store } from "../lambda/mcp.ts";
import { encode, type PlanRow } from "../lambda/training.ts";

// FIT-290: a pasted program becomes a proposal for a client, then their plan.
const tz = "America/New_York";
const now = new Date("2026-10-28T14:00:00Z"); // Wednesday

function store(units: Record<string, Record<string, string>>, links: [string, string][] = [["coach", "ann"]]) {
  const extra = new Map<string, Record<string, any>>();
  return {
    async units(uid: string) { return new Map(Object.entries(units[uid] ?? {})); },
    async write(uid: string, list: { key: string; body: string | null }[]) {
      units[uid] ??= {};
      for (const u of list) if (u.body === null) delete units[uid][u.key]; else units[uid][u.key] = u.body;
    },
    async get(uid: string, key: string) { return extra.get(`${uid}/${key}`); },
    async put(uid: string, key: string, item: Record<string, any>) { extra.set(`${uid}/${key}`, item); },
    async coachOf(coach: string, client: string) { return links.some(([c, k]) => c === coach && k === client); },
  } as unknown as Store;
}

const sheet = {
  days: [
    { week: 1, weekday: 1, title: "Lower A", exercises: [{ exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 225 }, { exercise: "RDL", sets: 3, reps: 8, percent_1rm: 60 }] },
    { week: 1, weekday: 4, title: "Upper A", exercises: [{ exercise: "DB Bench", sets: 3, reps: 10, weight_lb: 60 }, { exercise: "Banded Monster Walk", sets: 2, reps: 15, pattern: "legs" }] },
    { week: 2, weekday: 1, title: "Lower A", exercises: [{ exercise: "Back Squat", sets: 4, reps: 5, weight_lb: 230 }] },
  ],
};

describe("reading a pasted program (FIT-290)", () => {
  it("lays weeks and weekdays out from the Monday it starts", () => {
    expect(mondayOf("2026-11-04")).toBe("2026-11-02");
    expect(mondayOf("2026-11-02")).toBe("2026-11-02");
    const days = toDays(sheet, "2026-11-02");
    expect(days.map((d) => [d.date, d.title, d.exercises.length])).toEqual([["2026-11-02", "Lower A", 2], ["2026-11-05", "Upper A", 2], ["2026-11-09", "Lower A", 1]]);
    expect(days[1].exercises[1]).not.toHaveProperty("pattern");
    expect(toDays({ days: [{ week: 17, weekday: 1, exercises: [{ exercise: "Plank", sets: 3 }] }, { week: 1, weekday: 2, exercises: [] }] }, "2026-11-02")).toEqual([]);
  });

  it("finds the names the catalog can't place, with their pattern, and reads the sheets' abbreviations", () => {
    expect([...unmatched(sheet)]).toEqual([["Banded Monster Walk", "legs"]]);
  });

  it("keeps a percentage with no max to take it from as a note", () => {
    const [day] = keepPercents(toDays(sheet, "2026-11-02"), () => undefined);
    expect(day.exercises[1]).toMatchObject({ exercise: "RDL", percent_1rm: undefined, note: "60% of max" });
    const [kept] = keepPercents(toDays(sheet, "2026-11-02"), () => 315);
    expect(kept.exercises[1].percent_1rm).toBe(60);
  });
});

describe("importing for a client (FIT-290)", () => {
  const reader = async () => ({ parsed: sheet, usage: { input_tokens: 900, output_tokens: 700 } });
  const allowed = async () => true;

  it("proposes the weeks, adds the client's own exercise, and saves them on apply", async () => {
    const units: Record<string, Record<string, string>> = { ann: {} };
    const s = store(units);
    const made = await importProgram("coach", "ann", "Back Squat\t4x5\t225\n…", "2026-11-02", tz, s, now, reader, allowed);
    expect(made.days).toBe(3);
    expect(made.added).toEqual(["Banded Monster Walk"]);
    expect(made.preview).toMatch(/^Proposal \S+ — Imported from a spreadsheet/);
    expect(made.preview).toMatch(/Monday 2026-11-02/);
    expect(Object.keys(units.ann).some((k) => k.startsWith("template#banded-monster-walk"))).toBe(true);
    expect(units.ann["plan#2026-11-02"]).toBeUndefined();
    await applyProposal(made.id, "ann", { uid: "coach", tz, agent: "dashboard" }, s, now, { allowProblems: true });
    const monday = JSON.parse(units.ann["plan#2026-11-02"]) as PlanRow[];
    expect(monday.map((r) => r.template)).toEqual(["back-squat", "romanian-deadlift"]);
    expect(monday[0].targets).toEqual(expect.arrayContaining([{ metric: "load_lb", value: 225, unit: "lb" }]));
    expect(monday[1].note).toMatch(/60% of max/);
    expect(JSON.parse(units.ann["plan#2026-11-05"]).map((r: PlanRow) => r.template)).toContain("banded-monster-walk");
  });

  it("refuses someone who isn't their client, an empty paste, a past start and a spent allowance", async () => {
    const s = store({ ann: {} });
    await expect(importProgram("bob", "ann", "x", "2026-11-02", tz, s, now, reader, allowed)).rejects.toThrow(/don't coach/);
    await expect(importProgram("coach", "ann", "   ", "2026-11-02", tz, s, now, reader, allowed)).rejects.toThrow(/Paste the program/);
    await expect(importProgram("coach", "ann", "x", "2026-10-01", tz, s, now, reader, allowed)).rejects.toThrow(/start day/);
    await expect(importProgram("coach", "ann", "x", "2026-11-02", tz, s, now, reader, async () => false)).rejects.toThrow(/this month's 30 imports/);
    await expect(importProgram("coach", "ann", "x".repeat(40_001), "2026-11-02", tz, s, now, reader, allowed)).rejects.toThrow(/too long/);
  });

  it("skips days already past in the week it starts, and keeps a logged day as it was", async () => {
    const units: Record<string, Record<string, string>> = { coach: { "log#2026-11-05": encode([{ id: "L", kind: "workout", at: 0, template: "bench-press", measurements: [], note: "" }]) } };
    await expect(importProgram("coach", "coach", "x", "2026-10-28", tz, store(units, []), now, async () => ({ parsed: { days: [{ week: 1, weekday: 1, exercises: [{ exercise: "Plank", sets: 3, seconds: 45 }] }] } }), allowed))
      .rejects.toThrow(/Couldn't find any training days/);
    await expect(importProgram("coach", "coach", "x", "2026-11-02", tz, store(units, []), now, reader, allowed)).rejects.toThrow(/2026-11-05 is already logged/);
  });
});
