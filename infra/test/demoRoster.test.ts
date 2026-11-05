import { describe, expect, it } from "vitest";
import { units, WEEKS } from "../lambda/demoClients.ts";
import { addDays, triage, type Flag } from "../../shared/triage.ts";
import { noSignIn, sam } from "../scripts/demoRoster.ts";

const roster = [...noSignIn, [sam, -WEEKS] as const];
// One week of days, Sunday 2026-11-01 first, since a client's latest session and flags depend on the day.
const days = Array.from({ length: 7 }, (_, i) => addDays("2026-11-01", i));
const flags = (name: string, today: string): Flag["kind"][] => {
  const [client, first] = roster.find(([c]) => c.name === name)!;
  return triage(units(client, first, true, today), [], new Map(), "coach", today).flags.map((f) => f.kind);
};

describe("FIT-328: the demo roster", () => {
  it("has ten clients", () => {
    expect(roster).toHaveLength(10);
    expect(new Set(roster.map(([c]) => c.testUser)).size).toBe(10);
  });

  it.each(days)("reaches every state a coach sees on %s", (today) => {
    expect(flags("Mike Torres", today)).toEqual(expect.arrayContaining(["pain", "hard"]));
    expect(flags("Noah Bennett", today)).toContain("missed");
    expect(flags("Hannah Weiss", today)).toContain("hard");
    expect(flags("Leo Martin", today)).toContain("behind");
    expect(flags("Priya Shah", today)).toContain("quiet");
    expect(flags("Tom Okafor", today)).toContain("note");
    for (const onTrack of ["Ava Lindqvist", "Sara Kim", "Jen Alvarez"]) expect(flags(onTrack, today)).toEqual([]);
    expect(flags("Sam Rivera", today)).toEqual(["note"]);
  });

  it("gives Sam a session every day but Sunday, this week and next", () => {
    const sessions = units(sam, -WEEKS, true, "2026-11-05");
    for (let n = 1; n <= 13; n++) {
      if (n === 7) continue;
      expect(sessions.get(`plan#${addDays("2026-11-01", n)}`)).toContain("workout");
    }
    expect(sessions.has("log#2026-11-05")).toBe(false);
    expect(sessions.get("plan#2026-11-07")).toContain("trail-running");
  });
});
