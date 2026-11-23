import { describe, expect, it } from "vitest";
import { BENCHMARK, funnelReport, parseBatch, stepKeys, type FunnelRow } from "../../shared/funnel.ts";
import { handleEvents, record, type FunnelStore } from "../lambda/funnel.ts";

// TKL-466: the first launch's funnel, each screen to the paywall and the purchase, read per monetization strategy.

const install = "3F2504E0-4F89-41D3-9A0C-0305E82C3301";
const now = new Date("2026-11-23T12:00:00.000Z");

/** The table as three maps: each install's cohort, each install's first steps, and the day's counters. */
function memory(): FunnelStore & { counters: Map<string, Record<string, number>> } {
  const cohorts = new Map<string, { day: string; strategy: "hard" | "freemium" }>();
  const seen = new Set<string>();
  const counters = new Map<string, Record<string, number>>();
  return {
    counters,
    async cohort(id, strategy, at, starts) {
      if (starts && !cohorts.has(id)) cohorts.set(id, { day: at.toISOString().slice(0, 10), strategy });
      return cohorts.get(id);
    },
    async countOnce(id, day, strategy, key) {
      if (seen.has(`${id}|${key}`)) return;
      seen.add(`${id}|${key}`);
      const row = counters.get(`${day}#${strategy}`) ?? {};
      row[key] = (row[key] ?? 0) + 1;
      counters.set(`${day}#${strategy}`, row);
    },
  };
}

describe("TKL-466: parsing what the app sends", () => {
  it("takes known events with a known detail, and drops anything else", () => {
    const batch = parseBatch({
      install, strategy: "hard", app: "1.0 (26)",
      events: [
        { name: "onboarding_screen_viewed", detail: "hero" },
        { name: "onboarding_screen_viewed", detail: "not_a_screen" },
        { name: "purchase_completed", detail: "lifter_yearly" },
        { name: "made_up" },
        { name: "paywall_viewed", detail: "Maxwell" },
      ],
    });
    expect(batch?.strategy).toBe("hard");
    expect(batch?.events).toEqual([
      { name: "onboarding_screen_viewed", detail: "hero" },
      { name: "purchase_completed", detail: "lifter_yearly" },
      // A detail that isn't allowed for an event is dropped with it, never stored: free text could be a name.
      { name: "paywall_viewed" },
    ]);
  });

  it("refuses a batch without an install id, a strategy, or too many events", () => {
    expect(parseBatch({ install: "me", strategy: "hard", events: [] })).toBeUndefined();
    expect(parseBatch({ install, strategy: "weekly", events: [] })).toBeUndefined();
    expect(parseBatch({ install, strategy: "hard", events: Array(101).fill({ name: "paywall_viewed" }) })).toBeUndefined();
    expect(parseBatch("nope")).toBeUndefined();
  });

  it("counts an event on its own and with its detail", () => {
    expect(stepKeys({ name: "paywall_viewed" })).toEqual(["paywall_viewed"]);
    expect(stepKeys({ name: "purchase_completed", detail: "lifter_monthly" })).toEqual(["purchase_completed", "purchase_completed.lifter_monthly"]);
  });
});

describe("TKL-466: recording", () => {
  it("counts each install once per step, on the day and strategy it first launched with", async () => {
    const store = memory();
    await record({ install, strategy: "hard", events: [{ name: "onboarding_screen_viewed", detail: "hero" }, { name: "paywall_viewed" }] }, store, now);
    // Seen again the next day, after the switch went back to freemium: still the same cohort, and not counted twice.
    await record({ install, strategy: "freemium", events: [{ name: "paywall_viewed" }, { name: "purchase_completed", detail: "lifter_yearly" }] },
      store, new Date("2026-11-24T09:00:00.000Z"));
    expect(Object.fromEntries(store.counters)).toEqual({
      "2026-11-23#hard": {
        "onboarding_screen_viewed": 1, "onboarding_screen_viewed.hero": 1, "paywall_viewed": 1,
        "purchase_completed": 1, "purchase_completed.lifter_yearly": 1,
      },
    });
  });

  it("excludes a purchase from an older install with no recorded first launch", async () => {
    const store = memory();
    await record({ install, strategy: "hard", events: [{ name: "purchase_completed" }] }, store, now);
    expect(store.counters.size).toBe(0);
  });

  it("answers POST /events with 204, and anything else without writing", async () => {
    const store = memory();
    const body = JSON.stringify({ install, strategy: "freemium", events: [{ name: "onboarding_screen_viewed", detail: "hero" }, { name: "onboarding_started" }] });
    expect((await handleEvents({ method: "POST", path: "/events", body }, store, now)).statusCode).toBe(204);
    expect((await handleEvents({ method: "GET", path: "/events", body: undefined }, store, now)).statusCode).toBe(405);
    expect((await handleEvents({ method: "POST", path: "/events", body: "{" }, store, now)).statusCode).toBe(400);
    expect((await handleEvents({ method: "POST", path: "/events", body: "x".repeat(40_000) }, store, now)).statusCode).toBe(413);
    expect((await handleEvents({ method: "POST", path: "/other", body }, store, now)).statusCode).toBe(404);
    expect(store.counters.get("2026-11-23#freemium")).toMatchObject({ "onboarding_screen_viewed.hero": 1, onboarding_started: 1 });
  });
});

describe("TKL-466: the report", () => {
  const rows: FunnelRow[] = [
    { day: "2026-11-23", strategy: "hard", counts: { "onboarding_screen_viewed.hero": 40, onboarding_started: 30, paywall_viewed: 20, purchase_completed: 3 } },
    { day: "2026-11-24", strategy: "hard", counts: { "onboarding_screen_viewed.hero": 10, onboarding_started: 8, paywall_viewed: 6, purchase_completed: 2 } },
    { day: "2026-11-23", strategy: "freemium", counts: { "onboarding_screen_viewed.hero": 50, paywall_viewed: 25, purchase_completed: 1, paywall_dismissed: 20 } },
  ];

  it("reads first-launch-to-paid per strategy against the 11% benchmark, naming each denominator", () => {
    const report = funnelReport(rows);
    expect(BENCHMARK).toBe(0.11);
    expect(report.strategies.hard.firstLaunches).toBe(50);
    expect(report.strategies.hard.paid).toBe(5);
    expect(report.strategies.hard.rate).toBeCloseTo(0.1);
    expect(report.strategies.freemium.rate).toBeCloseTo(0.02);
    expect(report.text).toContain("hard: first-launch-to-paid 5/50 = 10.0% (benchmark 11%+ download-to-paid, AbMaxx; ours counts first launches, not downloads)");
    expect(report.text).toContain("freemium: first-launch-to-paid 1/50 = 2.0%");
  });

  it("lists every step to the paywall and the purchase, in order, as a share of first launches", () => {
    const { text } = funnelReport(rows);
    const lines = text.split("\n");
    const at = (label: string) => lines.findIndex((l) => l.includes(label));
    expect(at("First launch (hero)")).toBeGreaterThan(-1);
    expect(at("First launch (hero)")).toBeLessThan(at("Started"));
    expect(at("Started")).toBeLessThan(at("Screen: goal"));
    expect(at("Screen: name")).toBeLessThan(at("Paywall viewed"));
    expect(at("Paywall viewed")).toBeLessThan(at("Purchased"));
    expect(text).toMatch(/Paywall viewed\s+26\s+52\.0%/);
    expect(text).toMatch(/Not Now\s+20\s+40\.0%/);
  });

  it("says so when a strategy has no first launches yet", () => {
    expect(funnelReport([]).text).toContain("hard: no first launches yet");
  });
});
