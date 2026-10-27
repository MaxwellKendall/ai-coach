import { describe, expect, it } from "vitest";
import { dose, headline, plan } from "./start";

// FIT-281: the quiz's plan and its reveal. The program picks and loads themselves are held to the app's by
// infra/test/readyPrograms.test.ts; here, what the page says about them.

const gym = new Set(["barbell", "rack", "bench", "dumbbells", "pull_up_bar", "cable", "machine"]);
const tuesday = new Date(2026, 9, 27);

describe("the quiz's plan", () => {
  it("is the best fit, its days spread out, and ends on the Saturday of its last week", () => {
    const made = plan(gym, 3, tuesday)!;
    expect(made.answers).toEqual({ slug: "full-body-3", have: [...gym], days: [0, 2, 4] });
    expect(made.ends).toEqual(new Date(2027, 0, 16));
  });

  it("promises the first main lift's load by the end date", () => {
    expect(headline(plan(gym, 3, tuesday)!)).toBe("Back Squat 45 → 120 lb by Jan 16");
    expect(headline(plan(new Set(["dumbbells"]), 3, tuesday)!)).toMatch(/ lb a hand by Jan 16$/);
  });

  it("has no load to promise for body weight", () => {
    expect(headline(plan(new Set(), 3, tuesday)!)).toBe("Bodyweight Basics: 12 weeks, done by Jan 16");
  });

  it("doses as the app does", () => {
    expect(dose({ sets: 3, reps: [5, 5] })).toBe("3 × 5");
    expect(dose({ sets: 3, reps: [12, 8] })).toBe("3 × 8–12");
    expect(dose({ sets: 2, seconds: [20, 60] })).toBe("2 × 20–60 s");
  });
});
