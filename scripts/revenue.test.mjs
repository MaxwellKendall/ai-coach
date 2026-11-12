import assert from "node:assert/strict";
import test from "node:test";
import {
  BARBRABELL,
  REMIX_BUNDLE,
  classifyReportError,
  combinedMrr,
  dateDaysAgo,
  durationMonths,
  formatDashboardComment,
  matchesApp,
  num,
  parseTsv,
  reportWindow,
  stripeKeyMode,
  stripeMissingStatus,
  stripeMrr,
  summarizeSalesProceeds,
  summarizeSubscriptionEvents,
  summarizeSubscriptionSnapshot,
  usd,
} from "./revenue.mjs";

const barbrabell = { ...BARBRABELL };
const remix = { product: "Remix", bundleId: REMIX_BUNDLE, appleId: "6802880519" };
const targets = [barbrabell, remix];

test("reportWindow is the 30 days ending yesterday", () => {
  const window = reportWindow(new Date("2026-11-12T16:00:00Z"));
  assert.equal(dateDaysAgo("2026-11-11", 29), "2026-10-13");
  assert.equal(window.endDate, "2026-11-11");
  assert.equal(window.startDate, "2026-10-13");
});

test("parseTsv reads a Sales and Trends header row", () => {
  const { headers, rows } = parseTsv("App Apple ID\tApp Name\tUnits\n6821439066\tbarbrabell\t2\n");
  assert.deepEqual(headers, ["App Apple ID", "App Name", "Units"]);
  assert.equal(rows[0]["App Apple ID"], "6821439066");
  assert.equal(num(rows[0].Units), 2);
});

test("matchesApp uses Apple ID first and does not mix the two apps", () => {
  assert.equal(matchesApp({ "App Apple ID": "6821439066", "App Name": "barbrabell" }, barbrabell), true);
  assert.equal(matchesApp({ "App Apple ID": "6821439066" }, remix), false);
  assert.equal(matchesApp({ "App Apple ID": "6802880519", "App Name": "Remix Fit" }, remix), true);
});

test("durationMonths understands Apple period labels", () => {
  assert.equal(durationMonths("1 Month"), 1);
  assert.equal(durationMonths("1 Year"), 12);
  assert.equal(durationMonths(""), null);
});

test("subscription snapshot counts paid, trials, and USD MRR by plan", () => {
  const rows = [
    {
      "App Apple ID": "6821439066",
      "Subscription Name": "Lifter Pro Annual",
      "Standard Subscription Duration": "1 Year",
      "Customer Price": "39.99",
      "Customer Currency": "USD",
      "Active Standard Price Subscriptions": "2",
      "Active Free Trial Introductory Offers": "1",
    },
    {
      "App Apple ID": "6802880519",
      "Subscription Name": "Yearly",
      "Standard Subscription Duration": "1 Year",
      "Customer Price": "59.99",
      "Customer Currency": "USD",
      "Active Standard Price Subscriptions": "1",
      "Active Free Trial Introductory Offers": "0",
    },
  ];
  const byProduct = summarizeSubscriptionSnapshot(rows, targets);
  assert.equal(byProduct.Barbrabell.activeStandard, 2);
  assert.equal(byProduct.Barbrabell.activeFreeTrial, 1);
  assert.equal(byProduct.Barbrabell.byPlan["Lifter Pro Annual"].standard, 2);
  assert.equal(byProduct.Barbrabell.mrrCustomerUSD, (39.99 / 12) * 2);
  assert.equal(byProduct.Remix.activeStandard, 1);
  assert.equal(byProduct.Remix.mrrCustomerUSD, 59.99 / 12);
});

test("subscription events count trial starts and conversions in the window", () => {
  const rows = [
    { "App Apple ID": "6802880519", "Event Date": "2026-11-01", "Event Type": "Start Introductory Price", Quantity: "3" },
    { "App Apple ID": "6802880519", "Event Date": "2026-11-10", "Event Type": "Paid Subscription from Introductory Price", Quantity: "1" },
    { "App Apple ID": "6802880519", "Event Date": "2026-09-01", "Event Type": "Start Introductory Price", Quantity: "9" },
  ];
  const byProduct = summarizeSubscriptionEvents(rows, targets, "2026-10-13", "2026-11-11");
  assert.equal(byProduct.Remix.trialsStarted, 3);
  assert.equal(byProduct.Remix.trialConverted, 1);
  assert.equal(byProduct.Barbrabell.trialsStarted, 0);
});

test("sales proceeds multiply units by developer proceeds in USD", () => {
  const rows = [
    { "App Apple ID": "6821439066", Units: "2", "Developer Proceeds": "5.09", "Currency of Proceeds": "USD" },
  ];
  const byProduct = summarizeSalesProceeds(rows, targets);
  assert.equal(byProduct.Barbrabell.proceedsUSD, 10.18);
  assert.equal(byProduct.Remix.proceedsUSD, 0);
});

test("classifyReportError distinguishes 403, 404, and a missing vendor parameter", () => {
  const forbidden = classifyReportError(403, "403 FORBIDDEN_ERROR This request is forbidden for security reasons: The API key in use does not allow this request");
  assert.equal(forbidden.kind, "forbidden");
  assert.match(forbidden.message, /403/);
  assert.match(forbidden.message, /does not allow this request/);
  assert.equal(classifyReportError(404, "").kind, "empty");
  assert.equal(classifyReportError(400, "The parameter 'filter[vendorNumber]' is required but was not provided").kind, "missing_vendor_number");
});

test("Stripe is skipped cleanly when STRIPE_READONLY_KEY is unset", () => {
  const missing = stripeMissingStatus({});
  assert.equal(missing.available, false);
  assert.equal(missing.status, "missing");
  assert.match(missing.reason, /STRIPE_READONLY_KEY is unset/);
  assert.equal(stripeMissingStatus({ STRIPE_READONLY_KEY: "rk_live_example" }), null);
  assert.equal(stripeKeyMode("rk_live_example"), "live");
  assert.equal(stripeKeyMode("sk_test_example"), "test");
});

test("stripeMrr converts monthly and yearly items and ignores other statuses", () => {
  const summary = stripeMrr([
    { status: "active", items: { data: [{ quantity: 1, price: { unit_amount: 1999, currency: "usd", nickname: "coach_monthly", recurring: { interval: "month", interval_count: 1 } } }] } },
    { status: "active", items: { data: [{ quantity: 1, price: { unit_amount: 3999, currency: "usd", nickname: "lifter_yearly", recurring: { interval: "year", interval_count: 1 } } }] } },
    { status: "canceled", items: { data: [{ quantity: 1, price: { unit_amount: 1999, currency: "usd", recurring: { interval: "month", interval_count: 1 } } }] } },
  ]);
  assert.equal(summary.active, 2);
  assert.equal(summary.mrrUsd, 19.99 + 3999 / 100 / 12);
  assert.equal(summary.byPlan.coach_monthly, 1);
});

test("combinedMrr stays unknown when a source is missing and never invents a total", () => {
  const unknown = combinedMrr({
    appStore: { available: false, reason: "HTTP 403: The API key in use does not allow this request" },
    stripe: { available: false, status: "missing", reason: "STRIPE_READONLY_KEY is unset" },
  });
  assert.equal(unknown.total, null);
  assert.match(unknown.reason, /403/);
  assert.match(unknown.reason, /STRIPE_READONLY_KEY/);
  const ok = combinedMrr({
    appStore: { available: true, snapshotDate: "2026-11-11", byProduct: { Barbrabell: { mrrCustomerUSD: 10, mrrUnknownDurationRows: 0 }, Remix: { mrrCustomerUSD: 5, mrrUnknownDurationRows: 0 } } },
    stripe: { available: true, mode: "live", mrrUsd: 7 },
  });
  assert.equal(ok.total, 22);
});

test("the dashboard comment lists unknown MRR and the exact missing sources", () => {
  const comment = formatDashboardComment({
    generatedAt: "Nov 12, 2026, 11:31 AM America/New_York",
    window: { startDate: "2026-10-13", endDate: "2026-11-11" },
    metrics: {
      combinedMrr: combinedMrr({
        appStore: { available: false, reason: "HTTP 403: The API key in use does not allow this request" },
        stripe: { available: false, status: "missing", reason: "STRIPE_READONLY_KEY is unset. Skipping Stripe." },
      }),
    },
    asc: {
      sales: {
        status: "forbidden",
        message: "HTTP 403: 403 FORBIDDEN_ERROR This request is forbidden for security reasons: The API key in use does not allow this request",
      },
      catalogs: [],
    },
    stripe: { available: false, status: "missing", reason: "STRIPE_READONLY_KEY is unset. Skipping Stripe." },
  });
  assert.match(comment, /Combined current MRR: \*\*unknown\*\*/);
  assert.match(comment, /\$1,000 cannot be computed/);
  assert.match(comment, /does not allow this request/);
  assert.match(comment, /STRIPE_READONLY_KEY is unset/);
  assert.equal(comment.includes("$0.00"), false);
});
