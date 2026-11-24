import { readFileSync } from "node:fs";
import { X509Certificate, createPrivateKey, sign } from "node:crypto";
import { describe, expect, it } from "vitest";
import { BENCHMARK, funnelReport, parseBatch, stepKeys, type FunnelRow } from "../../shared/funnel.ts";
import { appleVerifier, handleEvents, MAX_KEYS_PER_MINUTE, record, type FunnelStore } from "../lambda/funnel.ts";

// TKL-466: the first launch's funnel, each screen to the paywall and the purchase, read per monetization strategy.

const install = "3F2504E0-4F89-41D3-9A0C-0305E82C3301";
const now = new Date("2026-11-23T12:00:00.000Z");

// Apple's signed transactions, from the test chain shaped like Apple's (fixtures/storekit/make.sh, test-only keys).
const dir = new URL("./fixtures/storekit/", import.meta.url);
const pem = (name: string) => readFileSync(new URL(name, dir), "utf8");
const der = (name: string) => new X509Certificate(pem(name)).raw.toString("base64");
const x5c = [der("leaf.pem"), der("intermediate.pem"), der("root.pem")];
const root = new X509Certificate(pem("root.pem")).fingerprint256;
const leafKey = createPrivateKey(pem("leaf.pkcs8.key"));
function jws(payload: object) {
  const head = Buffer.from(JSON.stringify({ alg: "ES256", x5c })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = sign("sha256", Buffer.from(`${head}.${body}`), { key: leafKey, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${head}.${body}.${signature}`;
}
const txn = (over: Record<string, unknown> = {}) => jws({
  originalTransactionId: "2000", transactionId: "2000", productId: "com.maxwellkendall.aicoach.pro.yearly",
  bundleId: "com.maxwellkendall.aicoach", environment: "Production", purchaseDate: now.getTime(),
  expiresDate: now.getTime() + 7 * 86_400_000, signedDate: now.getTime(), ...over,
});
const trial = () => txn({ offerType: 1, offerDiscountType: "FREE_TRIAL" });
const verify = appleVerifier(["Production"], root);

/** The table as maps: each install's cohort, each install's first steps, the day's counters, purchases' owners. */
function memory(): FunnelStore & { counters: Map<string, Record<string, number>>; budget: Map<string, number> } {
  const cohorts = new Map<string, { day: string; strategy: "hard" | "freemium" }>();
  const seen = new Set<string>();
  const counters = new Map<string, Record<string, number>>();
  const owners = new Map<string, string>();
  const budget = new Map<string, number>();
  return {
    counters,
    budget,
    async admit(at, cost) {
      const minute = at.toISOString().slice(0, 16);
      const used = budget.get(minute) ?? 0;
      if (used >= MAX_KEYS_PER_MINUTE) return false;
      budget.set(minute, used + cost);
      return true;
    },
    async claim(original, id) {
      if (!owners.has(original)) owners.set(original, id);
      return owners.get(original) === id;
    },
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
        { name: "purchase_completed", detail: "lifter_yearly", jws: "a.b.c" },
        { name: "onboarding_answer_submitted", detail: "name" },
        { name: "onboarding_answer_submitted", detail: "Maxwell" },
        { name: "made_up" },
        { name: "paywall_viewed", detail: "Maxwell" },
      ],
    });
    expect(batch?.strategy).toBe("hard");
    expect(batch?.events).toEqual([
      { name: "onboarding_screen_viewed", detail: "hero" },
      // A purchase counts only with Apple's signed transaction, which the server checks (record).
      { name: "purchase_completed", detail: "lifter_yearly", jws: "a.b.c" },
      // A question's id says it was answered, never what the answer was.
      { name: "onboarding_answer_submitted", detail: "name" },
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
    await record({ install, strategy: "hard", events: [{ name: "onboarding_screen_viewed", detail: "hero" }, { name: "paywall_viewed" }] }, store, now, verify);
    // Seen again the next day, after the switch went back to freemium: still the same cohort, and not counted twice.
    await record({ install, strategy: "freemium", events: [{ name: "paywall_viewed" }, { name: "purchase_completed", detail: "lifter_yearly", jws: txn() }] },
      store, new Date("2026-11-24T09:00:00.000Z"), verify);
    expect(Object.fromEntries(store.counters)).toEqual({
      "2026-11-23#hard": {
        "onboarding_screen_viewed": 1, "onboarding_screen_viewed.hero": 1, "paywall_viewed": 1,
        "purchase_completed": 1, "purchase_completed.lifter_yearly": 1,
      },
    });
  });

  it("excludes a purchase from an older install with no recorded first launch", async () => {
    const store = memory();
    await record({ install, strategy: "hard", events: [{ name: "purchase_completed", jws: txn() }] }, store, now, verify);
    expect(store.counters.size).toBe(0);
  });

  const hero = { name: "onboarding_screen_viewed", detail: "hero" };

  it("counts a free trial as a trial, and paid only once Apple's transaction is a paid one", async () => {
    const store = memory();
    // The app says purchase_completed for a trial: the transaction says otherwise, and the transaction wins.
    await record({ install, strategy: "hard", events: [hero, { name: "purchase_completed", detail: "lifter_yearly", jws: trial() }] }, store, now, verify);
    expect(store.counters.get("2026-11-23#hard")).toMatchObject({ trial_started: 1, "trial_started.lifter_yearly": 1 });
    expect(store.counters.get("2026-11-23#hard")?.purchase_completed).toBeUndefined();
    // A week later the trial renews into the first paid year: now it's paid, on the install's first-launch day.
    await record({ install, strategy: "hard", events: [{ name: "purchase_completed", detail: "lifter_yearly", jws: txn({ transactionId: "2001" }) }] },
      store, new Date("2026-11-30T12:00:00.000Z"), verify);
    expect(store.counters.get("2026-11-23#hard")).toMatchObject({ purchase_completed: 1, "purchase_completed.lifter_yearly": 1 });
    expect(funnelReport([{ day: "2026-11-23", strategy: "hard", counts: store.counters.get("2026-11-23#hard")! }]).strategies.hard.paid).toBe(1);
  });

  it("names the product from Apple's transaction, not from what the app said", async () => {
    const store = memory();
    await record({ install, strategy: "hard", events: [hero,
      { name: "purchase_completed", detail: "coach_yearly", jws: txn({ productId: "com.maxwellkendall.aicoach.pro.monthly" }) }] }, store, now, verify);
    expect(store.counters.get("2026-11-23#hard")).toMatchObject({ "purchase_completed.lifter_monthly": 1 });
    expect(store.counters.get("2026-11-23#hard")?.["purchase_completed.coach_yearly"]).toBeUndefined();
  });

  it("never counts a purchase Apple didn't sign, from another app or environment, or already another install's", async () => {
    const store = memory();
    const other = "9b2e1f40-1111-4222-8333-944455556666";
    const forged = txn().replace(/\.[^.]+$/, ".AAAA");
    await record({ install, strategy: "hard", events: [hero,
      { name: "purchase_completed", detail: "lifter_yearly", jws: forged },
      { name: "purchase_completed", detail: "lifter_yearly", jws: txn({ bundleId: "com.example.other", originalTransactionId: "3000" }) },
      { name: "purchase_completed", detail: "lifter_yearly", jws: txn({ environment: "Sandbox", originalTransactionId: "3001" }) },
      { name: "purchase_completed", detail: "lifter_yearly", jws: txn({ revocationDate: now.getTime(), originalTransactionId: "3002" }) },
    ] }, store, now, verify);
    expect(store.counters.get("2026-11-23#hard")?.purchase_completed).toBeUndefined();
    // One real transaction, replayed from a second made-up install: it's the first install's, and only counts there.
    await record({ install, strategy: "hard", events: [{ name: "purchase_completed", jws: txn() }] }, store, now, verify);
    await record({ install: other, strategy: "hard", events: [hero, { name: "purchase_completed", jws: txn() }] }, store, now, verify);
    expect(store.counters.get("2026-11-23#hard")).toMatchObject({ "onboarding_screen_viewed.hero": 2, purchase_completed: 1 });
  });

  it("stops writing for the minute once anonymous traffic uses up its budget, and answers 429 so the app sends again", async () => {
    const store = memory();
    const batch = (id: string) => JSON.stringify({ install: id, strategy: "hard", events: [hero, { name: "paywall_viewed" }] });
    const ids = Array.from({ length: MAX_KEYS_PER_MINUTE }, (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`);
    const answers = [];
    for (const id of ids) answers.push((await handleEvents({ method: "POST", path: "/events", body: batch(id) }, store, now, verify)).statusCode);
    expect(answers).toContain(429);
    const counted = store.counters.get("2026-11-23#hard")!["onboarding_screen_viewed.hero"];
    expect(counted).toBeLessThan(ids.length);
    expect(counted * 3).toBeLessThanOrEqual(MAX_KEYS_PER_MINUTE + 3);
    // The next minute takes writes again.
    const later = new Date(now.getTime() + 60_000);
    expect((await handleEvents({ method: "POST", path: "/events", body: batch(ids[ids.length - 1]) }, store, later, verify)).statusCode).toBe(204);
  });

  it("answers POST /events with 204, and anything else without writing", async () => {
    const store = memory();
    const body = JSON.stringify({ install, strategy: "freemium", events: [{ name: "onboarding_screen_viewed", detail: "hero" }, { name: "onboarding_started" }] });
    expect((await handleEvents({ method: "POST", path: "/events", body }, store, now, verify)).statusCode).toBe(204);
    expect((await handleEvents({ method: "GET", path: "/events", body: undefined }, store, now, verify)).statusCode).toBe(405);
    expect((await handleEvents({ method: "POST", path: "/events", body: "{" }, store, now, verify)).statusCode).toBe(400);
    expect((await handleEvents({ method: "POST", path: "/events", body: "x".repeat(70_000) }, store, now, verify)).statusCode).toBe(413);
    expect((await handleEvents({ method: "POST", path: "/other", body }, store, now, verify)).statusCode).toBe(404);
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
    expect(report.text).toContain("hard: first-launch-to-paid 5/50 = 10.0% (benchmark 11%+ download-to-paid, AbMaxx; ours counts first launches, not downloads;");
    expect(report.text).toContain("freemium: first-launch-to-paid 1/50 = 2.0%");
    // Paid means Apple-verified paid transactions: a free trial isn't paid until it converts.
    expect(report.text).toContain("paid = Apple-verified paid transactions; a free trial counts once it converts");
  });

  it("lists every step to the paywall and the purchase, in order, as a share of first launches", () => {
    const { text } = funnelReport(rows);
    const lines = text.split("\n");
    const at = (label: string) => lines.findIndex((l) => l.includes(label));
    expect(at("First launch (hero)")).toBeGreaterThan(-1);
    expect(at("First launch (hero)")).toBeLessThan(at("Started"));
    expect(at("Started")).toBeLessThan(at("Screen: goal"));
    expect(at("Screen: name")).toBeLessThan(at("Paywall viewed"));
    expect(at("Paywall viewed")).toBeLessThan(at("Trial started"));
    expect(at("Trial started")).toBeLessThan(at("Paid (Apple-verified)"));
    expect(at("Answered: goal")).toBeGreaterThan(at("Screen: goal"));
    expect(at("Answered: goal")).toBeLessThan(at("Screen: gender"));
    expect(text).toMatch(/Paywall viewed\s+26\s+52\.0%/);
    expect(text).toMatch(/Not Now\s+20\s+40\.0%/);
  });

  it("says so when a strategy has no first launches yet", () => {
    expect(funnelReport([]).text).toContain("hard: no first launches yet");
  });
});
