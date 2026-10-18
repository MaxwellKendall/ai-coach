import { describe, expect, it } from "vitest";
import { programWeeks } from "../lambda/program.ts";
import { alerts, checkIn, current, forecast, fraction, pace, perWeek, streak, streakLine, trend, wins, type LogSet } from "../lambda/progress.ts";
import { epoch } from "../lambda/training.ts";

// FIT-167: the cases of Tests/CoreTests/{StreakTests, WinsTests, WeeklyReviewTests, ProgramPlanTests}.swift, so the
// agent's progress is the phone's. Swift's dates there are noon in New York.
const tz = "America/New_York";
const d = (m: number, day: number) => `2026-${String(m).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
const noon = (m: number, day: number) => epoch(d(m, day), 12 * 60, tz);
const set = (exercise: string, m: number, day: number, load: number | undefined, reps: number, pattern?: string): LogSet => ({
  at: noon(m, day), day: d(m, day), exercise, pattern,
  measurements: [...(load === undefined ? [] : [{ metric: "load_lb", value: load, unit: "lb" }]), { metric: "reps", value: reps, unit: "" }],
});

describe("goal progress (GoalProgress)", () => {
  it("counts from the program's start, Brzycki to 12 reps, reps unloaded", () => {
    const start = noon(9, 28);
    const sets = [set("back-squat", 9, 1, 200, 5), set("back-squat", 9, 30, 155, 5), set("back-squat", 10, 2, 135, 15),
      set("pull-up", 9, 30, undefined, 6), set("pull-up", 9, 30, 25, 8)];
    expect(current("back-squat.1rm_lb", sets, [], start)).toBe(174);
    expect(current("pull-up.reps", sets, [], start)).toBe(6);
    expect(current("deadlift.1rm_lb", sets, [], start)).toBeUndefined();
    expect(current("weight_lb", [], [{ at: noon(9, 29), day: d(9, 29), value: 199 }, { at: noon(10, 2), day: d(10, 2), value: 197.4 }], start)).toBe(197.4);
  });

  it("trends as the best so far", () => {
    const sets = [set("back-squat", 9, 21, 225, 5), set("back-squat", 9, 28, 155, 5), set("back-squat", 9, 30, 165, 5),
      set("back-squat", 9, 30, 135, 8), set("back-squat", 10, 2, 145, 5)];
    expect(trend("back-squat.1rm_lb", sets, [], noon(9, 28))).toEqual([{ day: d(9, 28), value: 174 }, { day: d(9, 30), value: 186 }, { day: d(10, 2), value: 186 }]);
  });

  it("paces against the program's line, flat through deloads", () => {
    const weeks = programWeeks(16, 6);
    expect(fraction(200, 195, 180)).toBe(0.25);
    expect(fraction(200, 205, 180)).toBe(0);
    expect(pace(200, 200, 180, 0, weeks)).toBe("starting");
    expect(pace(200, 195, 180, 4, weeks)).toBe("onPace");
    expect(pace(200, 196, 180, 4, weeks)).toBe("behind");
    expect(pace(200, 193, 180, 4, weeks)).toBe("onPace");
    expect(pace(200, 192.5, 180, 4, weeks)).toBe("ahead");
  });

  it("forecasts at the rate so far, and says what each week needs", () => {
    const start = noon(8, 10), today = noon(10, 5), end = noon(11, 30);
    expect(forecast(201, 194.6, start, today, end)!).toBeCloseTo(188.2, 1);
    expect(perWeek(194.6, 180, today, end)).toBeCloseTo(-1.825, 2);
    expect(forecast(201, 200, start, noon(8, 14), end)).toBeUndefined();
  });
});

describe("the weekly streak (Streak)", () => {
  // The program starts Mon Aug 10 (its Sunday week); sessions Mon and Wed.
  const start = d(8, 10);
  const past = [d(8, 10), d(8, 12), d(8, 17), d(8, 19), d(8, 24), d(8, 26)];
  const thisWeek = [d(8, 31), d(9, 2)];
  const status = (done: string[], today: string, planned = [...past, ...thisWeek]) => streak(start, new Set(planned), new Set(done), today);

  it("counts full weeks, and this week joins when it's done", () => {
    expect(status([...past, d(8, 31)], d(9, 2))).toEqual({ weeks: 3, thisWeek: { kind: "onTrack" } });
    expect(streakLine(status([...past, d(8, 31)], d(9, 2)), d(9, 2))).toBe("3 weeks in a row");
    expect(status([...past, ...thisWeek], d(9, 2))).toEqual({ weeks: 4, thisWeek: { kind: "full" } });
  });

  it("lets a missed session be made up before the week ends", () => {
    expect(streakLine(status([...past, d(8, 31)], d(9, 3)), d(9, 3))).toBe("Do Wednesday’s session by Saturday to make it 4 weeks in a row");
    expect(streakLine(status([...past, d(8, 31)], d(9, 5)), d(9, 5))).toBe("Do Wednesday’s session today to make it 4 weeks in a row");
    expect(status([...past, d(8, 31), d(9, 4)], d(9, 5))).toEqual({ weeks: 4, thisWeek: { kind: "full" } });
  });

  it("ends when too many are missed, starts over after a missed week, and skips an empty one", () => {
    const late = status(past, d(9, 5), [...past, d(8, 31), d(9, 2), d(9, 4)]);
    expect(late.thisWeek.kind).toBe("broken");
    expect(streakLine(late, d(9, 5))).toBeUndefined();
    const missed = past.filter((x) => x !== d(8, 19));
    expect(status(missed, d(8, 31)).weeks).toBe(1);
    const gap = past.filter((x) => x !== d(8, 17) && x !== d(8, 19));
    expect(status(gap, d(8, 31), gap).weeks).toBe(2);
  });
});

describe("wins (Wins)", () => {
  const start = d(8, 10), since = noon(8, 10), end = noon(11, 29);
  const squat = { metric: "back-squat.1rm_lb", unit: "lb", baseline: 186, target: 250 };
  const detect = (goals: (typeof squat)[], sets: LogSet[] = [], weighs: { at: number; day: string; value: number }[] = [], planned: string[] = [], done: string[] = [], today = d(10, 5)) =>
    wins(goals, sets, weighs, start, since, end, new Set(planned), new Set(done), today, tz);

  it("counts personal bests over where the goal started, and the first crossing of each milestone", () => {
    const all = detect([squat], [set("back-squat", 8, 12, 165, 5), set("back-squat", 9, 14, 185, 5), set("back-squat", 10, 3, 195, 5)]);
    const prs = all.filter((w) => w.kind === "pr");
    expect(prs.map((w) => [w.value, w.previous, w.day, w.weeksLeft])).toEqual([[219, 208, d(10, 3), 8], [208, 186, d(9, 14), 10]]);
    expect(all.filter((w) => w.kind === "milestone").map((w) => w.key)).toEqual(["milestone:back-squat.1rm_lb:50", "milestone:back-squat.1rm_lb:25"]);
    const weight = { metric: "weight_lb", unit: "lb", baseline: 201, target: 180 };
    const loss = detect([weight], [], [{ at: noon(9, 6), day: d(9, 6), value: 195.5 }, { at: noon(9, 13), day: d(9, 13), value: 196 }]);
    expect(loss.map((w) => w.key)).toEqual(["milestone:weight_lb:25"]);
  });

  it("makes a streak from 2 full weeks, then every 4, dated the week's Saturday", () => {
    const weeks = Array.from({ length: 7 }, (_, i) => {
      const mon = new Date(Date.UTC(2026, 7, 10 + 7 * i)).toISOString().slice(0, 10), wed = new Date(Date.UTC(2026, 7, 12 + 7 * i)).toISOString().slice(0, 10);
      return { planned: [mon, wed], done: i === 2 ? [mon] : [mon, wed] };
    });
    const streaks = detect([], [], [], weeks.flatMap((w) => w.planned), weeks.flatMap((w) => w.done), d(9, 28)).filter((w) => w.kind === "streak");
    expect(streaks.map((w) => [w.key, w.workouts, w.day])).toEqual([["streak:4", 8, d(9, 26)], ["streak:2", 4, d(9, 12)], ["streak:2", 4, d(8, 22)]]);
  });
});

describe("the weekly review (WeeklyReview)", () => {
  // Sunday Sep 27 to Saturday Oct 3; sessions Mon, Wed, Fri.
  const from = d(9, 27);
  const sessions = [d(9, 28), d(9, 30), d(10, 2)];
  const none = { protein: new Map(), kcal: new Map(), sleep: new Map(), notes: [], injured: [] };

  it("flags protein, sleep and kcal around sessions", () => {
    const found = alerts(from, { ...none, sessions,
      protein: new Map([[d(9, 27), 104], [d(9, 28), 150], [d(9, 29), 140], [d(9, 30), 112], [d(10, 1), 160], [d(10, 2), 150]]),
      kcal: new Map([[d(9, 28), 2400], [d(10, 2), 1950]]), sleep: new Map([[d(9, 30), 5.5], [d(10, 2), 7]]) });
    expect(found.map((a) => a.title)).toEqual(["Protein under 120 g around 2 workouts", "Under 6 h of sleep before 1 workout", "Under 2,200 kcal on 1 training day"]);
    expect(found[0].detail).toBe("Sunday 104 g and Wednesday 112 g.");
    expect(found[2].detail).toBe("Friday 1,950.");
  });

  it("flags an area three notes name, unless it's an injury or said fine", () => {
    const note = (m: number, day: number, text: string) => ({ at: noon(m, day), day: d(m, day), text });
    const notes = [note(9, 21, "left knee a bit sore on the way down"), note(9, 30, "knee pain on squats"), note(10, 3, "knee tight again"),
      note(10, 1, "great session, knee felt fine"), note(8, 20, "knee ached"), note(10, 2, "lower back tight")];
    const found = alerts(from, { ...none, sessions: [], notes });
    expect(found.map((a) => [a.title, a.area])).toEqual([["Knee came up in 3 notes", "knee"]]);
    expect(found[0].detail.startsWith("Sep 21, Sep 30 and Oct 3.")).toBe(true);
    expect(alerts(from, { ...none, sessions: [], notes, injured: ["knees"] })).toEqual([]);
    expect(alerts(from, { ...none, sessions: [], notes, fine: { knee: noon(10, 1) } }).filter((a) => a.area)).toEqual([]);
  });

  it("flags a main movement missing for 4 weeks; lunges count for squats", () => {
    const three = (p: string, m: number, day: number) => [0, 1, 2].map(() => set(p, m, day, undefined, 5, p));
    const history = [...three("squat", 9, 22), ...three("push", 9, 24), ...three("pull", 9, 30)];
    expect(alerts(from, { ...none, sessions: [], sets: history }).map((a) => a.title)).toContain("No hinges in 4 weeks");
    const lunges = [...three("lunge", 9, 22), ...three("hinge", 9, 23), ...three("push", 9, 24), ...three("pull", 9, 30)];
    expect(alerts(from, { ...none, sessions: [], sets: lunges })).toEqual([]);
    expect(alerts(from, { ...none, sessions: [], sets: [] })).toEqual([]);
  });

  it("checks in every 4 weeks on a goal well ahead or behind", () => {
    expect(checkIn(6, 9, 10, "ahead", 12, 1, 7, 16)).toEqual({ proposed: 12, ahead: true, weeksLeft: 8 });
    expect(checkIn(201, 194.6, 180, "behind", 188.2, 5, 7, 16)).toEqual({ proposed: 190, ahead: false, weeksLeft: 8 });
    expect(checkIn(6, 9, 10, "ahead", 10.2, 1, 7, 16)?.proposed).toBe(11);
    expect(checkIn(6, 9, 10, "ahead", 12, 1, 6, 16)).toBeUndefined();
    expect(checkIn(6, 9, 10, "ahead", 12, 1, 11, 14)).toBeUndefined();
    expect(checkIn(201, 194.6, 180, "onPace", 181, 5, 7, 16)).toBeUndefined();
  });
});

describe("race times (FIT-177)", () => {
  it("reads distances and times as people say them", async () => {
    const { meters, seconds, clock, riegel, runMetric, goalMeters } = await import("../lambda/running.ts");
    expect([meters("10K"), meters("half"), meters("Marathon"), meters("8 km"), meters("5 mi"), meters(8)]).toEqual([10000, 21097.5, 42195, 8000, 8046.72, 8000]);
    expect([seconds("55:00"), seconds("1:45:30"), seconds("48 min"), seconds(55)]).toEqual([3300, 6330, 2880, 3300]);
    expect([clock(3344), clock(6330)]).toEqual(["55:44", "1:45:30"]);
    expect(() => meters("far")).toThrow(/Not a distance/);
    expect(goalMeters(runMetric(10000))).toBe(10000);
    // A run under a quarter of the distance, or under 1.6 km, doesn't predict it.
    expect(riegel(420, 1609, 10000)).toBeUndefined();
    expect(Math.round(riegel(1500, 5000, 10000)!)).toBe(3127);
  });

  it("counts a faster time as a personal best", () => {
    const run = (m: number, day: number, km: number, mins: number): LogSet => ({ at: noon(m, day), day: d(m, day), exercise: "trail-running-walking",
      measurements: [{ metric: "distance_m", value: km * 1000, unit: "m" }, { metric: "duration_s", value: mins * 60, unit: "s" }] });
    const goal = { metric: "run_10000m.time_s", unit: "s", baseline: 3600, target: 3300 };
    const runs = [run(9, 1, 10, 59), run(9, 8, 8, 46), run(9, 15, 10, 61)];
    // 8 km in 46:00 predicts 58:17, faster than the 59:00 10K before it; the slower 10K after changes nothing.
    expect(current(goal.metric, runs, [], noon(8, 10))).toBe(3497);
    const won = wins([goal], runs, [], d(8, 10), noon(8, 10), noon(11, 29), new Set(), new Set(), d(10, 5), tz);
    expect(won.filter((w) => w.kind === "pr").map((w) => [w.day, w.value, w.previous])).toEqual([[d(9, 8), 3497, 3540], [d(9, 1), 3540, 3600]]);
    expect(pace(3600, 3497, 3300, 4, programWeeks(16, 6))).toBe("onPace"); // 34% of the way, 29% expected: under 125% of it
  });
});
