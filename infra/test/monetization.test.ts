import { describe, expect, it } from "vitest";
import { DEFAULT_STRATEGY, hardFor, monetizationOf, switched } from "../../shared/monetization.ts";
import { monetizationRoute } from "../lambda/monetization.ts";

describe("FIT-454: the monetization switch", () => {
  const now = new Date("2026-11-14T12:00:00.000Z");

  it("reads a missing or odd row as freemium, what was live before", () => {
    expect(DEFAULT_STRATEGY).toBe("freemium");
    expect(monetizationOf(undefined)).toEqual({ strategy: "freemium", since: null });
    expect(monetizationOf({ strategy: "weekly" })).toEqual({ strategy: "freemium", since: null });
    expect(monetizationOf({ strategy: "hard", since: "2026-11-01T00:00:00.000Z" })).toEqual({ strategy: "hard", since: "2026-11-01T00:00:00.000Z" });
  });

  it("keeps when hard was switched on while it stays on, so who's grandfathered never moves", () => {
    const on = switched({ strategy: "freemium", since: null }, "hard", now);
    expect(on.since).toBe(now.toISOString());
    expect(switched(on, "hard", new Date("2026-12-01T00:00:00.000Z")).since).toBe(now.toISOString());
    expect(switched(on, "freemium", now)).toEqual({ strategy: "freemium", since: null });
  });

  it("holds hard mode only for accounts made since it was switched on", () => {
    const hard = { strategy: "hard" as const, since: now.toISOString() };
    expect(hardFor(hard, "2026-11-15T00:00:00.000Z")).toBe(true);
    expect(hardFor(hard, "2026-11-01T00:00:00.000Z")).toBe(false);
    expect(hardFor({ strategy: "freemium", since: null }, "2026-11-15T00:00:00.000Z")).toBe(false);
  });

  it("serves the switch as JSON at /monetization.json only", async () => {
    const page = await monetizationRoute("/monetization.json", async () => ({ strategy: "hard", since: now.toISOString() }));
    expect(page?.status).toBe(200);
    expect(page?.type).toBe("application/json");
    expect(JSON.parse(page!.body)).toEqual({ strategy: "hard", since: now.toISOString() });
    expect(await monetizationRoute("/terms")).toBeUndefined();
  });
});
