import { readFileSync, writeFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import * as progress from "../lambda/progress.ts";
import { addDays, encode, epoch, goalsOf, profileOf } from "../lambda/training.ts";

// FIT-167: five weeks of an account's synced units, and what the server derives from them. ProgressUnitsTests (Swift)
// applies the same units as a phone signing in would and checks WeekReport, Wins and Streak give these answers.
// UPDATE_FIXTURES=1 writes Tests/Fixtures/progress-units.json again.

const tz = "America/New_York";
let n = 0;
const id = () => `00000000-0000-4000-8000-${String(++n).padStart(12, "0")}`;
const m = (metric: string, value: number, unit = "") => ({ metric, value, unit });

function account() {
  n = 0;
  const units: Record<string, unknown> = {};
  const start = "2026-09-13"; // a Sunday; 16 weeks to Saturday 2027-01-02
  units.profile = {
    age: 36, avoidExercises: [], cookWindows: [], daysPerWeek: 3, equipment: ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"], fineAreas: {},
    injuredAreas: [], maxWeeklySets: 60, programStart: epoch(start, 0, tz), sessionMinutes: 45, starts: [], style: "powerbuilding",
    targetDate: epoch(addDays(start, 16 * 7 - 1), 0, tz), trainingDays: [0, 2, 4], travelWeeks: [], warmups: true, weightLb: 200, workoutTime: 7 * 60,
  };
  const goal = (metric: string, unit: string, baseline: number, target: number) => {
    units[`goal#${id()}`] = { baseline, deadline: epoch("2027-01-02", 12 * 60, tz), kind: metric === "weight_lb" ? "body" : "training", metric, status: "active", target, unit };
  };
  goal("back-squat.1rm_lb", "lb", 205, 250);
  goal("pull-up.reps", "reps", 6, 10);
  goal("weight_lb", "lb", 200, 185);
  goal("romanian-deadlift.1rm_lb", "lb", 150, 200); // not one onboarding offers: the review leaves it out
  goal("run_10000m.time_s", "s", 3600, 3300); // FIT-179: a 10K in 55:00, from 1:00:00

  // Mon squat, Wed bench and row, Fri deadlift and pull-ups, weeks 1–6. Week 2 misses Friday; week 5 misses Friday.
  const sessions: Record<number, [string, number, number, number?][]> = {
    1: [["back-squat", 3, 5], ["bench-press", 3, 5]], 3: [["bench-press", 3, 5], ["bent-over-barbell-row", 3, 8]], 5: [["deadlift", 3, 5], ["pull-up", 3, 6]],
  };
  const loads: Record<string, number[]> = {
    "back-squat": [185, 195, 200, 210, 215], "bench-press": [135, 140, 145, 145, 150], "bent-over-barbell-row": [115, 120, 125, 125, 130],
    deadlift: [225, 235, 245, 255, 255], "pull-up": [0, 0, 0, 0, 0],
  };
  const pullReps = [6, 7, 7, 8, 8];
  for (let week = 0; week < 6; week++) {
    for (const offset of [1, 3, 5]) {
      const day = addDays(start, 7 * week + offset), at = epoch(day, 7 * 60, tz);
      const rows = sessions[offset].map(([slug, sets, reps]) => ({ id: id(), kind: "workout", at, slot: "Session", template: slug, note: "", main: slug === "back-squat",
        pinned: false, targets: [m("sets", sets, "sets"), m("reps", slug === "pull-up" ? 6 : reps, "reps")] }));
      units[`plan#${day}`] = rows;
      const missed = (week === 1 || week === 4) && offset === 5;
      if (week > 4 || missed) continue;
      const log: Record<string, unknown>[] = [];
      for (const row of rows) {
        const slug = row.template, sets = row.targets[0].value;
        for (let i = 0; i < sets; i++) {
          const load = loads[slug][week];
          log.push({ at: at + log.length, id: id(), kind: "workout", measurements: [m("reps", slug === "pull-up" ? pullReps[week] - (i ? 1 : 0) : 5, "reps"),
            ...(load ? [m("load_lb", load, "lb")] : []), m("rpe", 7.5, "RPE")], note: "Session", plannedRef: row.id, template: slug });
        }
      }
      const pain = (week === 1 && offset === 1) || (week === 2 && offset === 3) || (week === 3 && offset === 3);
      log.push({ at: at + 100, id: id(), kind: "workout", measurements: [m("effort", 7, "/10")], note: pain ? "Knee a bit sore on squats" : "Good" });
      if (offset === 1) log.push({ at: epoch(day, 6 * 60, tz), id: id(), kind: "bodyweight", measurements: [m("weight_lb", 200 - week * 0.8, "lb")], note: "" });
      log.push({ at: epoch(day, 6 * 60 + 5, tz), id: id(), kind: "sleep", measurements: [m("sleep_h", week === 3 && offset === 3 ? 5.5 : 7.5, "h")], note: "" });
      for (const [meal, kcal, protein] of [["Breakfast", 700, 40], ["Lunch", 800, week === 3 && offset === 1 ? 10 : 60], ["Dinner", 900, 60]] as const) {
        log.push({ at: epoch(day, meal === "Breakfast" ? 8 * 60 : meal === "Lunch" ? 12 * 60 : 19 * 60, tz), id: id(), kind: "meal", measurements: [m("kcal", kcal, "kcal"), m("protein_g", protein, "g")], note: meal });
      }
      units[`log#${day}`] = log;
    }
  }
  // FIT-179: a run every Sunday, unplanned, beside the lifting: 8K, 10K, 8K, a 5K, 8K.
  for (const [week, km, mins, hr] of [[0, 8, 47, 150], [1, 10, 58.5, 154], [2, 8, 45.5, 158], [3, 5, 26.5, 165], [4, 8, 44, 160]] as const) {
    const day = addDays(start, 7 * week), at = epoch(day, 8 * 60, tz);
    units[`log#${day}`] = [{ at, id: id(), kind: "workout", measurements: [m("distance_m", km * 1000, "m"), m("duration_s", mins * 60, "s"), m("hr_avg", hr, "bpm")],
      note: week === 3 ? "race: parkrun" : "easy", template: "trail-running-walking" }];
  }
  return units;
}

function derive(raw: Record<string, unknown>) {
  const units = new Map(Object.entries(raw).map(([k, v]) => [k, encode(v)]));
  const profile = profileOf(units)!;
  const review = progress.weekReport(units, "2026-10-10", epoch("2026-10-10", 12 * 60, tz), tz);
  const today = "2026-10-17", sets = progress.logSets(units), weighs = progress.weighIns(units);
  const tracked = goalsOf(units).filter((g) => g.baseline !== undefined && progress.optionFor(g.metric))
    .map((g) => ({ metric: g.metric, unit: g.unit, baseline: g.baseline!, target: g.target }));
  const won = progress.wins(tracked, sets, weighs, "2026-09-13", profile.programStart!, profile.targetDate!, progress.plannedDays(units), progress.workoutDays(units), today, tz);
  const s = progress.streak("2026-09-13", progress.plannedDays(units), progress.workoutDays(units), today);
  const r2 = (x?: number) => (x === undefined ? null : Math.round(x * 100) / 100);
  return {
    review: {
      from: review.from, programWeek: review.programWeek, programWeeks: review.programWeeks,
      numbers: { ...review.numbers, protein: r2(review.numbers.protein), kcal: r2(review.numbers.kcal), sleep: r2(review.numbers.sleep), weight: r2(review.numbers.weight), weightChange: r2(review.numbers.weightChange) },
      goals: review.goals.map((g) => ({ metric: g.goal.metric, from: g.from, to: g.to, pace: g.pace, forecast: r2(g.forecast), perWeek: r2(g.perWeek), checkIn: g.checkIn ?? null })),
      alerts: review.alerts.map((a) => ({ title: a.title, detail: a.detail, area: a.area ?? null })),
      headline: progress.headline(review), subline: progress.subline(review),
    },
    wins: won.map((w) => ({ key: w.key, day: w.day, value: w.value, previous: w.previous ?? null })),
    streak: { weeks: s.weeks, thisWeek: s.thisWeek.kind, line: progress.streakLine(s, today) ?? null },
  };
}

describe("progress parity with the app (FIT-167)", () => {
  it("derives what the fixture says, and the fixture is what ProgressUnitsTests checks the app against", () => {
    const units = account();
    const got = { about: "FIT-167: an account's synced units and what infra/lambda/progress.ts derives; ProgressUnitsTests checks the app gets the same.", tz,
      reviewAt: "2026-10-10T12:00", today: "2026-10-17", units, expected: derive(units) };
    const file = new URL("../../Tests/Fixtures/progress-units.json", import.meta.url);
    if (process.env.UPDATE_FIXTURES) writeFileSync(file, JSON.stringify(got, null, 2) + "\n");
    expect(got).toEqual(JSON.parse(readFileSync(file, "utf8")));
    // Spot checks that the scenario does what it's for.
    const e = got.expected;
    expect(e.review.goals.map((g) => g.metric)).toEqual(["back-squat.1rm_lb", "pull-up.reps", "weight_lb", "run_10000m.time_s"]);
    expect(e.review.numbers.runKm).toBe(5);
    expect(e.wins.filter((w) => w.key.startsWith("pr:run_10000m"))).not.toHaveLength(0);
    expect(e.review.alerts.map((a) => a.title)).toEqual(["Protein under 120 g around 1 workout", "Under 6 h of sleep before 1 workout", "Knee came up in 3 notes"]);
    // The Sunday runs are days trained, so they make up the missed Fridays (FIT-121: days trained against planned).
    expect(e.streak).toMatchObject({ weeks: 5, thisWeek: "full" });
    expect(e.wins.some((w) => w.key.startsWith("pr:back-squat"))).toBe(true);
  });
});
