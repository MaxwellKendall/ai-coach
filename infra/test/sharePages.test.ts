import { describe, expect, it } from "vitest";
import { associationFile, route, winWords, type Site, type Store, type Win } from "../lambda/sharePages.ts";

const site: Site = { appName: "Barbrabell", origin: "https://example.com", appId: "TEAM.com.example.app" };
const win: Win = {
  kind: "pr", name: "Max Kendall", date: "2026-10-08", metric: "Bench Press", unit: "lb", value: 205, previous: 190,
  trend: [190, 205], showNumbers: true, style: "dark", invite: "X7K2PQ",
};
const store: Store = {
  win: async (id) => ({ bench: win, evil: { ...win, name: `<script>alert(1)</script>` } })[id],
  recap: async () => undefined,
  program: async () => undefined,
  session: async (id) => (id === "leg" ? { name: "Max Kendall", title: "Lower body", date: "2026-10-15", minutes: 50,
    exercises: [{ name: "Back Squat", sets: 4, reps: 5 }, { name: "Plank", sets: 3, seconds: 45 }], invite: "X7K2PQ" } : undefined),
  invite: async (code) => (code === "X7K2PQ" ? { group: "Dawn Patrol", by: "Max", members: ["Max", "Jo"], recent: [] } : undefined),
  coachInvite: async (code) => ({ SAMCOACH22: { coach: "Sam Coach" }, NONAME2222: { coach: null }, K7M4QX: { coach: "Sam Coach" } })[code],
};

describe("share pages (FIT-105)", () => {
  it("a win page shows the card and leads to the app and the sharer's group", async () => {
    const page = await route("/w/bench", store, site);
    expect(page.status).toBe(200);
    expect(page.body).toContain("Max set a bench press best");
    expect(page.body).toContain('href="/join/X7K2PQ"');
    expect(page.body).toContain('<meta property="og:title" content="Max set a bench press best">');
    // FIT-107: the uploaded card is the link preview.
    expect(page.body).toContain('<meta property="og:image" content="https://example.com/cards/bench.png">');
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

  it("Apple's association file opens the app for invites, sessions, programs, gifts and coach invites", async () => {
    const page = await route("/.well-known/apple-app-site-association", store, site);
    expect(page.type).toBe("application/json");
    expect(JSON.parse(page.body)).toEqual(associationFile(site));
    expect(associationFile(site).applinks.details[0].components.map((c) => c["/"])).toEqual(["/join/*", "/????????", "/s/*", "/p/*", "/g/*", "/c/*"]);
  });

  it("ChatGPT's domain token is the plain token, only once one is set (FIT-237)", async () => {
    expect((await route("/.well-known/openai-apps-challenge", store, site)).status).toBe(404);
    const page = await route("/.well-known/openai-apps-challenge", store, { ...site, openaiAppsChallenge: "abc123" });
    expect(page).toMatchObject({ status: 200, type: "text/plain; charset=utf-8", body: "abc123" });
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

describe("sessions (FIT-113)", () => {
  it("a session page shows the day and the exercises, and offers the calendar", async () => {
    const page = await route("/s/leg", store, site);
    expect(page.status).toBe(200);
    expect(page.body).toContain("Train with Max: Lower body, Thursday, Oct 15");
    expect(page.body).toContain("4 × 5");
    expect(page.body).toContain('href="/s/leg.ics"');
  });

  it("its calendar file is an all-day event on that day", async () => {
    const ics = await route("/s/leg.ics", store, site);
    expect(ics.type).toContain("text/calendar");
    expect(ics.body).toContain("DTSTART;VALUE=DATE:20261015");
    expect(ics.body).toContain("DTEND;VALUE=DATE:20261016");
    expect(ics.body).toContain("SUMMARY:Lower body with Max");
  });

  it("reads only a well-formed session", async () => {
    const { readSession } = await import("../lambda/sharePages.ts");
    expect(readSession({ title: "Legs", date: "2026-10-15", exercises: [{ name: "Squat", sets: "<b>" }] }, "Max")).toBeUndefined();
    expect(readSession({ title: "Legs", date: "2026-10-15", exercises: [{ name: "Squat", sets: 4, reps: 5 }] }, "Max")?.exercises[0].sets).toBe(4);
  });
});

describe("view counts (FIT-110)", () => {
  it("a page asks to be counted once it's open, and only known kinds count", async () => {
    const counted: string[] = [];
    const counting = { ...store, count: async (kind: string) => { counted.push(kind); } };
    expect((await route("/w/bench", counting, site)).body).toContain('fetch("/v/w"');
    expect((await route("/v/w", counting, site)).status).toBe(204);
    expect((await route("/v/nope", counting, site)).status).toBe(404);
    expect(counted).toEqual(["w"]);
  });
});

describe("Train with Claude (FIT-152)", () => {
  const store = {} as Store;
  it("shows the connector address to copy and the steps, and the home page links to it", async () => {
    const withMcp = { ...site, mcpUrl: "https://example.com/mcp" };
    const page = await route("/claude", store, withMcp);
    expect(page.status).toBe(200);
    expect(page.body).toContain('data-copy="https://example.com/mcp"');
    expect(page.body).toContain("Add custom connector");
    expect(page.body).toContain("Set me up");
    expect((await route("/", store, withMcp)).body).toContain('href="/claude"');
    expect((await route("/claude", store, site)).status).toBe(404);
    // FIT-214: Pro isn't sold, so no page prices or offers it; a Checkout already under way still lands somewhere.
    const thanks = await route("/pro/thanks", store, withMcp);
    expect(thanks).toMatchObject({ status: 200, noStore: true });
    for (const p of [page, thanks]) {
      expect(p.body.split("<main>")[1]).not.toMatch(/\$\d|\bPro\b|trial|subscribe/);
    }
  });
});

describe("the coach landing page (FIT-217)", () => {
  it("is the home page: the value proposition, the price, and Start coaching to the dashboard's billing", async () => {
    for (const path of ["/", "/coaches"]) {
      const page = await route(path, {} as Store, { ...site, mcpUrl: "https://example.com/mcp" });
      expect(page.status).toBe(200);
      expect(page.body).toContain("Your clients log in a free app. You coach them from Claude.");
      expect(page.body).toContain("$19.99");
      expect(page.body).toContain("$199 a year");
      expect(page.body).toContain("Clients are free");
      expect(page.body).toContain('<a class="button primary" href="/app/billing">Start coaching</a>');
      expect(page.body).toContain('href="/claude"');
      // Someone training themselves has a way in too: free, through Claude.
      expect(page.body).toContain("Training yourself?");
      expect(page.body).toContain('<a class="button" href="/claude">Connect Claude</a>');
    }
  });

  it("links the App Store for clients once there's a listing", async () => {
    const listed = await route("/", {} as Store, { ...site, appStoreUrl: "https://apps.apple.com/app/id1" });
    expect(listed.body).toContain('href="https://apps.apple.com/app/id1"');
  });
});

describe("a coach's invite page (FIT-130)", () => {
  it("names the coach by first name", async () => {
    const page = await route("/c/samcoach22", store, site);
    expect(page.body).toContain("<title>Sam invited you to train with them</title>");
    expect(page.body).toContain("Train with Sam as your coach");
  });

  it("reads naturally when the coach has no name (FIT-227)", async () => {
    const page = await route("/c/NONAME2222", store, site);
    expect(page.body).toContain("<title>You&#39;re invited to train with a coach on Barbrabell</title>");
    expect(page.body).toContain("Train with a coach on Barbrabell");
    expect(page.body).toContain("Your coach writes your program");
    expect(page.body).not.toMatch(/\bYour invited\b|with Your as/);
  });

  it("takes the 6-letter codes of FIT-234", async () => {
    expect((await route("/c/k7m4qx", store, site)).body).toContain("Train with Sam as your coach");
  });

  it("is a 404 once it's used up or expired", async () => {
    expect((await route("/c/GONE222222", store, site)).status).toBe(404);
  });
});
