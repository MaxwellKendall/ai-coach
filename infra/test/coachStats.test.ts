import { describe, expect, it } from "vitest";
import { coachRow, retention, type CoachFacts } from "../lambda/coachStats.ts";

const today = "2026-12-31";
const coach = (signup: string, clients: CoachFacts["clients"], paid = true): CoachFacts => ({ coach: "c", signup, paid, clients });

describe("FIT-210: coach retention at 30, 60 and 90 days", () => {
  it("counts a coach active at a mark when a client logged, or they wrote a client's plan, in the week up to it", () => {
    // Signed up Oct 1: day 30 is Oct 31, day 60 Nov 30, day 90 Dec 30.
    const row = coachRow(coach("2026-10-01", [
      { uid: "ann", since: "2026-10-01", logged: ["2026-10-28", "2026-12-30"], coachWrote: [] },
      { uid: "bob", since: "2026-10-05", logged: [], coachWrote: ["2026-11-25"] },
    ]), today);
    expect(row.active).toEqual({ 30: true, 60: true, 90: true });
    expect(row).toMatchObject({ clients: 2, loggingNow: 1 });
  });

  it("isn't active when nothing happened that week, and isn't due before the mark", () => {
    const row = coachRow(coach("2026-11-20", [{ uid: "ann", since: "2026-11-20", logged: ["2026-12-01"], coachWrote: [] }]), today);
    expect(row.active).toEqual({ 30: false, 60: undefined, 90: undefined });
    expect(row.loggingNow).toBe(0);
  });

  it("leaves out sample and demo clients", () => {
    const row = coachRow(coach("2026-10-01", [
      { uid: "sample-mike-c", since: "2026-10-01", logged: ["2026-10-30"], coachWrote: ["2026-10-30"] },
      { uid: "demo-sara-for-c", since: "2026-10-01", logged: ["2026-10-30"], coachWrote: [] },
    ]), today);
    expect(row).toMatchObject({ clients: 0, active: { 30: false } });
  });

  it("gives each mark's share of the coaches old enough for it", () => {
    const rows = [
      coachRow(coach("2026-10-01", [{ uid: "ann", since: "2026-10-01", logged: ["2026-10-30"], coachWrote: [] }]), today),
      coachRow(coach("2026-10-01", []), today),
      coachRow(coach("2026-12-15", []), today),
    ];
    expect(retention(rows)).toEqual({ 30: { due: 2, active: 1 }, 60: { due: 2, active: 0 }, 90: { due: 2, active: 0 } });
  });
});
