import { describe, expect, it } from "vitest";
import { brief, choices, request, toWeek, type CatalogEntry } from "./design";
import type { Unit } from "./sync";

const catalog: CatalogEntry[] = [
  { slug: "back-squat", name: "Back Squat", equipment: ["barbell", "rack"], pattern: "squat", tags: [] },
  { slug: "goblet-squat", name: "Goblet Squat", equipment: ["dumbbells"], pattern: "squat", tags: [] },
  { slug: "lat-pulldown", name: "Lat Pulldown", equipment: ["cable"], pattern: "pull", tags: [] },
  { slug: "push-up", name: "Push-Up", equipment: [], pattern: "push", tags: [] },
  { slug: "power-clean", name: "Power Clean", equipment: ["barbell"], pattern: "olympic", tags: [] },
];
const unit = (key: string, body: unknown): [string, Unit] => [key, { key, updatedAt: "", deleted: false, body: JSON.stringify(body) }];

describe("Design it for me (FIT-141)", () => {
  it("offers what the client's equipment allows, by main pattern, nothing avoided", () => {
    const profile = { equipment: ["barbell", "rack", "dumbbells"], avoidExercises: ["goblet-squat"] };
    expect(choices(catalog, profile).map((t) => t.slug)).toEqual(["back-squat", "push-up"]);
    expect(choices(catalog).map((t) => t.slug)).toEqual(["back-squat", "goblet-squat", "push-up", "lat-pulldown"]);
  });

  it("describes the client: days from Sunday, goals, maxes", () => {
    const units = new Map([
      unit("profile", { age: 42, trainingDays: [0, 2, 4], sessionMinutes: 45, maxWeeklySets: 40 }),
      unit("goal#1", { metric: "back-squat.1rm_lb", target: 315, unit: "lb", status: "active" }),
      unit("log#2026-10-12", [{ id: "l", kind: "workout", at: 1, template: "back-squat", measurements: [{ metric: "load_lb", value: 225, unit: "lb" }, { metric: "reps", value: 5, unit: "reps" }], note: "" }]),
    ]);
    const text = brief(units, new Map([["back-squat", "Back Squat"]])).text;
    expect(text).toContain("Age 42.");
    expect(text).toContain("weekdays 1, 3, 5 (0 = Sunday)");
    expect(text).toContain("Goals: Back Squat 315 lb (one-rep max).");
    expect(text).toContain("Back Squat 253 lb");
  });

  it("asks Haiku through the answer tool, with only the listed slugs allowed", () => {
    const body = request("Age 42.", catalog.slice(0, 2), "Squat focus");
    expect(body.model).toBe("claude-haiku-5-5");
    expect(body.tool_choice).toEqual({ type: "tool", name: "answer" });
    const slugEnum = (body.tools[0].input_schema.properties.days.items.properties.exercises.items.properties.slug as { enum: string[] }).enum;
    expect(slugEnum).toEqual(["back-squat", "goblet-squat"]);
    expect(body.messages[0].content).toContain("What the coach wants: Squat focus");
  });

  it("turns the answer into the builder's week, dropping what isn't on the menu", () => {
    const sunday = new Date(2026, 9, 18);
    const week = toWeek({ days: [
      { weekday: 1, slot: "Lower", exercises: [
        { slug: "back-squat", sets: 4, reps: 5, load_lb: 185, main: true },
        { slug: "made-up", sets: 3, reps: 10, main: false },
        { slug: "push-up", sets: 3, seconds: 0, reps: 12, main: false },
      ] },
      { weekday: 9, slot: "Nope", exercises: [] },
    ] }, catalog, sunday);
    expect(week[1].map((r) => r.template)).toEqual(["back-squat", "push-up"]);
    expect(week[1][0].targets).toEqual([{ metric: "sets", value: 4, unit: "sets" }, { metric: "reps", value: 5, unit: "reps" }, { metric: "load_lb", value: 185, unit: "lb" }]);
    expect(new Date(week[1][0].at * 1000).getDate()).toBe(19);
    expect(week.filter((d) => d.length)).toHaveLength(1);
  });
});
