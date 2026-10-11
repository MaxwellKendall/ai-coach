import { describe, expect, it } from "vitest";
import { associationFile, route, winWords, type Site, type Store, type Win } from "../lambda/sharePages.ts";

const site: Site = { appName: "Rep & Recipe", origin: "https://example.com", appId: "TEAM.com.example.app" };
const win: Win = {
  kind: "pr", name: "Max Kendall", date: "2026-10-08", metric: "Bench Press", unit: "lb", value: 205, previous: 190,
  trend: [190, 205], showNumbers: true, style: "dark", invite: "X7K2PQ",
};
const store: Store = {
  win: async (id) => ({ bench: win, evil: { ...win, name: `<script>alert(1)</script>` } })[id],
  recap: async () => undefined,
  program: async () => undefined,
  invite: async (code) => (code === "X7K2PQ" ? { group: "Dawn Patrol", by: "Max", members: ["Max", "Jo"], recent: [] } : undefined),
};

describe("share pages (FIT-105)", () => {
  it("a win page shows the card and leads to the app and the sharer's group", async () => {
    const page = await route("/w/bench", store, site);
    expect(page.status).toBe(200);
    expect(page.body).toContain("Max set a bench press best");
    expect(page.body).toContain('href="/join/X7K2PQ"');
    expect(page.body).toContain('<meta property="og:title" content="Max set a bench press best">');
  });

  it("hides weights the sharer chose not to show", () => {
    expect(winWords({ ...win, showNumbers: false })).toMatchObject({ big: "+8", unit: "%" });
    expect(JSON.stringify(winWords({ ...win, showNumbers: false }))).not.toContain("205");
  });

  it("escapes what users typed", async () => {
    const page = await route("/w/evil", store, site);
    expect(page.body).not.toContain("<script>alert");
    expect(page.body).toContain("&lt;script&gt;");
  });

  it("an invite code is read in any case", async () => {
    expect((await route("/join/x7k2pq", store, site)).body).toContain("Join Dawn Patrol");
  });

  it("an unknown or malformed link is a 404", async () => {
    expect((await route("/w/nope", store, site)).status).toBe(404);
    expect((await route("/w/../../etc", store, site)).status).toBe(404);
  });

  it("Apple's association file opens the app for invites only", async () => {
    const page = await route("/.well-known/apple-app-site-association", store, site);
    expect(page.type).toBe("application/json");
    expect(JSON.parse(page.body)).toEqual(associationFile(site));
    expect(associationFile(site).applinks.details[0].components.map((c) => c["/"])).toEqual(["/join/*", "/????????"]);
  });
});

describe("reading what users saved (FIT-105)", () => {
  it("keeps a well-formed win and takes the name from the profile", async () => {
    const { readWin } = await import("../lambda/sharePages.ts");
    const saved = { kind: "pr", name: "Impostor", date: "2026-10-08", metric: "Bench Press", unit: "lb", value: 205, previous: 190, trend: [190, 205], showNumbers: true, style: "paper" };
    expect(readWin(saved, "Max")).toMatchObject({ name: "Max", value: 205, style: "paper" });
  });

  it("drops anything that could carry markup or doesn't hold together", async () => {
    const { readWin, readRecap, readProgram } = await import("../lambda/sharePages.ts");
    const win = { kind: "pr", date: "2026-10-08", metric: "Bench", unit: "lb", value: 205 };
    expect(readWin({ ...win, value: "<script>" }, "Max")).toBeUndefined();
    expect(readWin({ ...win, kind: "<b>" }, "Max")).toBeUndefined();
    expect(readWin({ ...win, metric: "x".repeat(200) }, "Max")).toBeUndefined();
    expect(readWin({ ...win, invite: "<x>" }, "Max")?.invite).toBeUndefined();
    expect(readRecap({ week: "<i>", weeks: 12 }, "Max")).toBeUndefined();
    expect(readProgram("nope", "Max")).toBeUndefined();
  });
});
