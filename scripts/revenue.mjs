/** Read-only revenue pull for Barbrabell and Remix (FIT-444).
 *
 * Loads secrets from ~/.config/agents/secrets.env first, then
 * ~/.config/secrets.env, then the gitignored worktree `.env`. Variables
 * already set in the process environment take precedence. Never prints,
 * copies, or returns the .p8 or API keys, and never fetches AWS secrets.
 *
 * Optional: ASC_VENDOR_NUMBER, ASC_FINANCE_KEY_ID, ASC_FINANCE_KEY_PATH
 * (Sales and Trends / finance reports only; same ASC_ISSUER_ID as the
 * release key). STRIPE_READONLY_KEY, STRIPE_ACCOUNT_BARBRABELL,
 * STRIPE_ACCOUNT_REMIX.
 *
 * GET only against Apple and Stripe. Writes JSON under revenue-out/ (gitignored).
 *
 *   node scripts/revenue.mjs
 *   npm run revenue
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, resolve } from "node:path";
import { gunzipSync } from "node:zlib";
import { loadAscEnv, signJwt } from "./asc.mjs";
import { loadEnv } from "./load-env.mjs";

export const ASC_BASE = "https://api.appstoreconnect.apple.com";
export const STRIPE_BASE = "https://api.stripe.com/v1";
export const STRIPE_API_VERSION = "2025-08-27.basil";
export const OUTPUT_DIR = "revenue-out";
export const STRIPE_ACCOUNT_ENV = {
  Barbrabell: "STRIPE_ACCOUNT_BARBRABELL",
  Remix: "STRIPE_ACCOUNT_REMIX",
};

export function secretEnvPaths(home = homedir(), cwd = process.cwd()) {
  return [
    resolve(home, ".config/agents/secrets.env"),
    resolve(home, ".config/secrets.env"),
    resolve(cwd, ".env"),
  ];
}

/** Load shared secrets first, then the worktree .env. Does not override existing env vars. Never prints values. */
export function loadRevenueEnv({ home = homedir(), cwd = process.cwd(), env = process.env } = {}) {
  const found = [];
  for (const path of secretEnvPaths(home, cwd)) {
    if (!existsSync(path)) continue;
    loadEnv(path, env);
    found.push(path);
  }
  return found;
}
/** Resolve an ASC .p8 path without logging it. Bare filenames are looked up under ~/.appstoreconnect/private_keys/. */
export function resolveAscKeyPath(keyPath, home = homedir()) {
  if (!keyPath) return keyPath;
  let expanded = String(keyPath).trim().replace(/\$\{HOME\}/g, home).replace(/\$HOME/g, home);
  if (expanded.startsWith("~/")) expanded = resolve(home, expanded.slice(2));
  else if (expanded === "~") expanded = home;
  if (isAbsolute(expanded)) return expanded;
  const standard = resolve(home, ".appstoreconnect", "private_keys", basename(expanded));
  if (existsSync(standard)) return standard;
  return resolve(expanded);
}

/** Redact key paths and .p8 names so errors can be shown in the dashboard. */
export function sanitizePublicError(message) {
  return String(message || "")
    .replace(/AuthKey_[A-Za-z0-9]+\.p8/g, "AuthKey_<redacted>.p8")
    .replace(/(?:\/[^\s:'"]+)?\/\.appstoreconnect[^\s:'"]*/g, "~/.appstoreconnect/<redacted>");
}

function signJwtQuiet(auth) {
  try {
    return signJwt(auth);
  } catch (e) {
    throw new Error(`Failed to sign ASC JWT (${e.code || e.name || "error"}; key path and .p8 contents are not logged)`);
  }
}

/** Finance key is used only for Sales and Trends / finance reports. Never returns the path or .p8. */
export function financeAuthStatus(env = process.env, { home = homedir() } = {}) {
  const missing = ["ASC_FINANCE_KEY_ID", "ASC_FINANCE_KEY_PATH", "ASC_ISSUER_ID"].filter((k) => !env[k]);
  if (missing.length) {
    return { available: false, reason: `Finance key not configured: ${missing.join(", ")} unset` };
  }
  const keyPath = resolveAscKeyPath(env.ASC_FINANCE_KEY_PATH, home);
  if (!keyPath || !existsSync(keyPath)) {
    return { available: false, reason: "ASC_FINANCE_KEY_PATH does not resolve to a readable .p8 under ~/.appstoreconnect (path not logged)" };
  }
  return {
    available: true,
    auth: { keyId: env.ASC_FINANCE_KEY_ID, issuerId: env.ASC_ISSUER_ID, keyPath },
    vendorNumber: env.ASC_VENDOR_NUMBER || null,
  };
}

export function daysBetween(start, end) {
  const [sy, sm, sd] = String(start).split("-").map(Number);
  const [ey, em, ed] = String(end).split("-").map(Number);
  return Math.round((Date.UTC(ey, em - 1, ed) - Date.UTC(sy, sm - 1, sd)) / 86400000);
}

/** Sundays on or before endDate, most recent first, that overlap the window. */
export function sundaysOnOrBefore(endDate, { count = 3, startDate } = {}) {
  const Sundays = [];
  let cur = endDate;
  while (Sundays.length < count) {
    const [y, m, d] = cur.split("-").map(Number);
    const dt = new Date(Date.UTC(y, m - 1, d));
    if (dt.getUTCDay() === 0) {
      if (!startDate || cur >= dateDaysAgo(startDate, 6)) Sundays.push(cur);
      cur = dateDaysAgo(cur, 7);
    } else {
      cur = dateDaysAgo(cur, 1);
    }
    if (cur < "2000-01-01") break;
  }
  return Sundays;
}

export const NORTH_STAR_MRR = 1000;
export const NORTH_STAR_DATE = "2027-03-01";
export const BARBRABELL = { product: "Barbrabell", bundleId: "com.maxwellkendall.aicoach", appleId: "6821439066" };
export const REMIX_BUNDLE = "com.remix.app.Remix";

export const APPS = [BARBRABELL, { product: "Remix", bundleId: REMIX_BUNDLE, appleId: "6802880519" }];

export function todayISO(now = new Date(), tz = "America/New_York") {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

export function dateDaysAgo(iso, days) {
  const [y, m, d] = iso.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() - days);
  return dt.toISOString().slice(0, 10);
}

export function reportWindow(now = new Date()) {
  const endDate = dateDaysAgo(todayISO(now), 1);
  return { startDate: dateDaysAgo(endDate, 29), endDate };
}

export function eachDateInclusive(start, end) {
  const dates = [];
  for (let cur = start; cur <= end; cur = dateDaysAgo(cur, -1)) dates.push(cur);
  return dates;
}

export function parseTsv(text) {
  const lines = String(text).replace(/^\uFEFF/, "").split(/\r?\n/).filter((l) => l.length);
  if (!lines.length) return { headers: [], rows: [] };
  const headers = lines[0].split("\t");
  const rows = lines.slice(1).map((line) => {
    const cols = line.split("\t");
    const row = {};
    headers.forEach((h, i) => { row[h] = cols[i] ?? ""; });
    return row;
  });
  return { headers, rows };
}

export function gunzipMaybe(buf) {
  if (buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b) return gunzipSync(buf).toString("utf8");
  return Buffer.from(buf).toString("utf8");
}

export function col(row, names) {
  for (const name of names) {
    if (row[name] !== undefined && row[name] !== "") return row[name];
  }
  const keys = Object.keys(row);
  for (const name of names) {
    const found = keys.find((k) => k.toLowerCase() === name.toLowerCase());
    if (found && row[found] !== "") return row[found];
  }
  return "";
}

export function num(value) {
  if (value === undefined || value === null || value === "") return 0;
  const n = Number(String(value).replace(/,/g, ""));
  return Number.isFinite(n) ? n : 0;
}

export function durationMonths(raw) {
  const s = String(raw || "").toLowerCase().replace(/\s+/g, " ").trim();
  if (!s) return null;
  if (s === "1 month" || s === "1m" || s.includes("one month") || s === "p1m") return 1;
  if (s === "2 months" || s.includes("two month")) return 2;
  if (s === "3 months" || s.includes("three month") || s.includes("1 quarter")) return 3;
  if (s === "6 months" || s.includes("six month") || s.includes("1 half")) return 6;
  if (s === "1 year" || s === "1y" || s.includes("one year") || s === "p1y" || s.includes("12 month")) return 12;
  const m = s.match(/(\d+)\s*month/);
  if (m) return Number(m[1]);
  const y = s.match(/(\d+)\s*year/);
  if (y) return Number(y[1]) * 12;
  return null;
}

export function matchesApp(row, target) {
  const appleId = String(col(row, ["App Apple ID", "Apple Identifier"]) || "");
  if (target.appleId && appleId && appleId === String(target.appleId)) return true;
  const sku = col(row, ["SKU", "Parent Identifier"]);
  if (target.bundleId && sku && sku === target.bundleId) return true;
  const name = col(row, ["App Name", "Title"]).toLowerCase();
  if (!appleId && name) {
    if (target.product === "Barbrabell" && (name.includes("barbrabell") || name.includes("rep & recipe") || name.includes("rep and recipe"))) return true;
    if (target.product === "Remix" && name.includes("remix")) return true;
  }
  return false;
}

export function emptyProductMetrics() {
  return {
    rows: 0,
    activeStandard: 0,
    activeFreeTrial: 0,
    activePayUpFrontIntro: 0,
    activePayAsYouGoIntro: 0,
    billingRetry: 0,
    gracePeriod: 0,
    mrrCustomerUSD: 0,
    mrrProceedsUSD: 0,
    mrrUSD: 0,
    mrrBasis: "no_paid_subscriptions",
    mrrUnknownDurationRows: 0,
    byPlan: {},
    proceedsUSD: 0,
    units: 0,
    trialsStarted: 0,
    trialConverted: 0,
    cancels: 0,
    refunds: 0,
    eventCounts: {},
  };
}

export function summarizeSubscriptionSnapshot(rows, targets) {
  const byProduct = Object.fromEntries(targets.map((t) => [t.product, emptyProductMetrics()]));
  for (const row of rows) {
    const target = targets.find((t) => matchesApp(row, t));
    if (!target) continue;
    const bucket = byProduct[target.product];
    bucket.rows += 1;
    const standard = num(col(row, ["Active Standard Price Subscriptions"]));
    const trial = num(col(row, ["Active Free Trial Introductory Offer Subscriptions", "Active Free Trial Introductory Offers"]));
    const payUpFront = num(col(row, ["Active Pay Up Front Introductory Offer Subscriptions", "Active Pay Up Front Introductory Offers"]));
    const payAsYouGo = num(col(row, ["Active Pay As You Go Introductory Offer Subscriptions", "Active Pay As You Go Introductory Offers"]));
    bucket.activeStandard += standard;
    bucket.activeFreeTrial += trial;
    bucket.activePayUpFrontIntro += payUpFront;
    bucket.activePayAsYouGoIntro += payAsYouGo;
    bucket.billingRetry += num(col(row, ["Billing Retry"]));
    bucket.gracePeriod += num(col(row, ["Grace Period"]));
    const plan = col(row, ["Subscription Name"]) || col(row, ["SKU"]) || "(unnamed)";
    if (!bucket.byPlan[plan]) bucket.byPlan[plan] = { standard: 0, trial: 0, duration: col(row, ["Standard Subscription Duration", "Subscription Duration"]) };
    bucket.byPlan[plan].standard += standard;
    bucket.byPlan[plan].trial += trial;
    const months = durationMonths(col(row, ["Standard Subscription Duration", "Subscription Duration"]));
    const price = num(col(row, ["Customer Price"]));
    const currency = col(row, ["Customer Currency"]) || "USD";
    const proceedsRaw = col(row, ["Developer Proceeds"]);
    const proceedsCurrency = col(row, ["Proceeds Currency", "Currency of Proceeds"]) || currency;
    const paid = standard + payUpFront + payAsYouGo;
    const planBucket = bucket.byPlan[plan];
    planBucket.paid = (planBucket.paid || 0) + paid;
    if (paid) {
      if (!months) bucket.mrrUnknownDurationRows += 1;
      else {
        if (currency === "USD" || currency === "US") {
          const customer = (price / months) * paid;
          bucket.mrrCustomerUSD += customer;
          planBucket.mrrCustomerUSD = (planBucket.mrrCustomerUSD || 0) + customer;
        }
        if (proceedsRaw !== "") {
          if (proceedsCurrency === "USD" || proceedsCurrency === "US") {
            const proceedsMrr = (num(proceedsRaw) / months) * paid;
            bucket.mrrProceedsUSD += proceedsMrr;
            planBucket.mrrProceedsUSD = (planBucket.mrrProceedsUSD || 0) + proceedsMrr;
          } else {
            bucket.mrrUnknownDurationRows += 1;
          }
        }
      }
    }
  }
  for (const bucket of Object.values(byProduct)) {
    const paid = bucket.activeStandard + bucket.activePayUpFrontIntro + bucket.activePayAsYouGoIntro;
    if (!paid) {
      bucket.mrrUSD = 0;
      bucket.mrrBasis = "no_paid_subscriptions";
    } else if (bucket.mrrUnknownDurationRows) {
      bucket.mrrUSD = null;
      bucket.mrrBasis = "unknown";
    } else if (bucket.mrrProceedsUSD) {
      bucket.mrrUSD = bucket.mrrProceedsUSD;
      bucket.mrrBasis = "developer_proceeds";
    } else {
      bucket.mrrUSD = bucket.mrrCustomerUSD;
      bucket.mrrBasis = "customer_price";
    }
  }
  return byProduct;
}

export function summarizeSubscriptionEvents(rows, targets, startDate, endDate) {
  const byProduct = Object.fromEntries(targets.map((t) => [t.product, emptyProductMetrics()]));
  for (const row of rows) {
    const target = targets.find((t) => matchesApp(row, t));
    if (!target) continue;
    const eventDate = col(row, ["Event Date", "Date"]);
    if (eventDate && startDate && endDate && (eventDate < startDate || eventDate > endDate)) continue;
    const bucket = byProduct[target.product];
    bucket.rows += 1;
    const event = col(row, ["Event Type", "Event"]) || "unknown";
    const quantity = num(col(row, ["Quantity", "Units"])) || 1;
    bucket.eventCounts[event] = (bucket.eventCounts[event] || 0) + quantity;
    const ev = event.toLowerCase();
    if (ev.includes("start introductory") || ev.includes("start trial") || ev.includes("introductory price start")) bucket.trialsStarted += quantity;
    if (ev.includes("paid subscription from introductory") || ev.includes("introductory price convert") || ev.includes("trial converted") || ev === "convert") bucket.trialConverted += quantity;
    if (ev.includes("cancel")) bucket.cancels += quantity;
    if (ev.includes("refund")) bucket.refunds += quantity;
  }
  return byProduct;
}

export function summarizeSalesProceeds(rows, targets) {
  const byProduct = Object.fromEntries(targets.map((t) => [t.product, emptyProductMetrics()]));
  for (const row of rows) {
    const target = targets.find((t) => matchesApp(row, t));
    if (!target) continue;
    const bucket = byProduct[target.product];
    bucket.rows += 1;
    const units = num(col(row, ["Units"]));
    const proceeds = num(col(row, ["Developer Proceeds"]));
    const curr = col(row, ["Currency of Proceeds", "Customer Currency"]) || "USD";
    bucket.units += units;
    if (curr === "USD" || curr === "US") bucket.proceedsUSD += proceeds * (units || 1);
  }
  return byProduct;
}

/** Other apps in a SALES report that are not Barbrabell or Remix. Used so excluded rows are visible. */
export function unmatchedSales(rows, targets) {
  const groups = new Map();
  for (const row of rows) {
    if (targets.find((t) => matchesApp(row, t))) continue;
    const appleId = String(col(row, ["App Apple ID", "Apple Identifier"]) || "unknown");
    const title = col(row, ["App Name", "Title"]) || "unknown";
    const key = `${appleId}|${title}`;
    const rec = groups.get(key) || { appleId, title, rows: 0, units: 0, proceedsUSD: 0 };
    rec.rows += 1;
    const units = num(col(row, ["Units"]));
    const proceeds = num(col(row, ["Developer Proceeds"]));
    const curr = col(row, ["Currency of Proceeds", "Customer Currency"]) || "USD";
    rec.units += units;
    if (curr === "USD" || curr === "US") rec.proceedsUSD += proceeds * (units || 1);
    groups.set(key, rec);
  }
  return [...groups.values()];
}

export function isAppleNoDataForDate(detail) {
  return /no (sales|subscriptions|subscription events|data) for the date specified/i.test(String(detail || ""));
}

export function classifyReportError(status, detail) {
  const text = String(detail || "");
  if (status === 404) {
    if (isAppleNoDataForDate(text)) {
      return { kind: "empty", message: `HTTP 404: ${text}` };
    }
    const suffix = text ? `: ${text}` : " (no Apple no-data message; not treated as zero)";
    return { kind: "error", message: `HTTP 404${suffix}` };
  }
  if (status === 403) return { kind: "forbidden", message: `HTTP 403: ${text || "The API key in use does not allow this request"}` };
  if (status === 401) return { kind: "unauthorized", message: `HTTP 401: ${text}` };
  if (status === 400 && /vendorNumber/i.test(text) && /required/i.test(text)) {
    return { kind: "missing_vendor_number", message: text };
  }
  if (status === 400 && /invalid vendor number/i.test(text)) {
    return { kind: "invalid_vendor_number", message: `HTTP 400: ${text}` };
  }
  return { kind: "error", message: `HTTP ${status}: ${text}` };
}

export function summarizeUnknownDays(unknownDays, label = "") {
  if (!unknownDays?.length) return null;
  const prefix = label ? `${label} ` : "";
  const groups = new Map();
  for (const d of unknownDays) {
    const key = `HTTP ${d.status}${d.error ? ` ${d.error}` : ""}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(d.date);
  }
  return [...groups.entries()].map(([key, dates]) => {
    if (dates.length === 1) return `${prefix}${dates[0]} ${key}`;
    return `${prefix}${dates.length} date(s) (${dates[0]} through ${dates.at(-1)}) ${key}`;
  }).join("; ");
}

export function appStoreMrrAmount(bucket) {
  if (!bucket) return { value: null, basis: null, reason: "no App Store product bucket" };
  if (bucket.mrrUnknownDurationRows) {
    return {
      value: null,
      basis: bucket.mrrBasis || "unknown",
      reason: `${bucket.mrrUnknownDurationRows} paid subscription row(s) could not be converted to monthly USD`,
      partialCustomer: bucket.mrrCustomerUSD || 0,
      partialProceeds: bucket.mrrProceedsUSD || 0,
    };
  }
  const value = bucket.mrrUSD ?? (bucket.mrrProceedsUSD || bucket.mrrCustomerUSD || 0);
  return { value, basis: bucket.mrrBasis || "customer_price", reason: null };
}

export function errorDetail(json, fallback = "") {
  if (json?.errors?.length) {
    return json.errors.map((e) => `${e.status || ""} ${e.code || ""} ${e.title || ""}: ${e.detail || ""}`.trim()).join("; ");
  }
  return fallback;
}

export function usd(n) {
  if (n === null || n === undefined) return "unknown";
  return `$${Number(n).toFixed(2)}`;
}

export function productMrrParts({ appStore, stripe, product }) {
  const parts = [];
  const missing = [];
  let total = 0;
  if (appStore?.available) {
    const amount = appStoreMrrAmount(appStore.byProduct?.[product]);
    if (amount.value == null) missing.push(`App Store ${product} MRR unknown${amount.reason ? ` (${amount.reason})` : ""}`);
    else {
      const asOf = appStore.snapshotDate ? ` as of ${appStore.snapshotDate}` : "";
      const basis = amount.basis && amount.basis !== "no_paid_subscriptions" ? `, ${amount.basis.replaceAll("_", " ")}` : "";
      parts.push(`App Store ${product} ${usd(amount.value)}${asOf}${basis}`);
      total += amount.value;
    }
  } else {
    missing.push(appStore?.reason || "App Store subscription reports not available");
  }
  const a = stripe?.accounts?.[product];
  if (stripe?.mode === "test") {
    missing.push("Stripe key is test-mode; excluded from combined live MRR");
  } else if (!a) {
    if (!stripe?.available && !Object.keys(stripe?.accounts || {}).length) {
      missing.push(stripe?.reason || "Stripe live MRR unavailable");
    } else {
      missing.push(`Stripe ${product} not returned`);
    }
  } else if (!a.available || a.mrr == null) {
    missing.push(`Stripe ${product}: ${a.reason || a.mrrUnknownReason || "MRR unknown"}`);
  } else if ((a.currency || "usd") !== "usd") {
    missing.push(`Stripe ${product} MRR is ${a.currency}, not combined with USD`);
    parts.push(`Stripe ${product} ${a.mrr.toFixed(2)} ${a.currency}`);
  } else {
    parts.push(`Stripe ${product} ${usd(a.mrr)}`);
    total += a.mrr;
  }
  if (missing.length) return { product, total: null, reason: missing.join("; "), breakdown: parts.join(" + ") || "none" };
  return { product, total, reason: null, breakdown: parts.join(" + ") };
}

export function combinedMrr({ appStore, stripe }) {
  const byApp = {
    Barbrabell: productMrrParts({ appStore, stripe, product: "Barbrabell" }),
    Remix: productMrrParts({ appStore, stripe, product: "Remix" }),
  };
  const parts = [];
  const missing = [];
  let total = 0;
  for (const product of ["Barbrabell", "Remix"]) {
    const row = byApp[product];
    if (row.breakdown && row.breakdown !== "none") parts.push(row.breakdown);
    if (row.total == null) missing.push(row.reason);
    else total += row.total;
  }
  if (missing.length) return { total: null, reason: [...new Set(missing)].join("; "), breakdown: parts.join(" + ") || "none", byApp };
  return { total, reason: null, breakdown: parts.join(" + "), byApp };
}

/** Straight line from the first measured combined MRR to $1,000 by 2027-03-01. */
export function mrrPace({ current, today, firstMeasured, firstDate, target = NORTH_STAR_MRR, targetDate = NORTH_STAR_DATE }) {
  if (current == null) {
    return { available: false, reason: "Combined MRR is unknown, so pace cannot be computed." };
  }
  const isFirstMeasurement = firstMeasured == null || !firstDate;
  const startValue = isFirstMeasurement ? current : firstMeasured;
  const startDate = isFirstMeasurement ? today : firstDate;
  const span = daysBetween(startDate, targetDate);
  const elapsed = daysBetween(startDate, today);
  const remaining = daysBetween(today, targetDate);
  if (span <= 0) {
    return {
      available: false,
      reason: `Target date ${targetDate} is not after the first measurement (${startDate}).`,
      firstMeasured: startValue,
      firstDate: startDate,
      current,
      isFirstMeasurement,
    };
  }
  const requiredToday = startValue + (target - startValue) * (elapsed / span);
  const deltaVsRequired = current - requiredToday;
  return {
    available: true,
    firstMeasured: startValue,
    firstDate: startDate,
    isFirstMeasurement,
    current,
    requiredToday,
    target,
    targetDate,
    daysElapsed: elapsed,
    daysRemaining: remaining,
    onPace: deltaVsRequired >= -0.005,
    deltaVsRequired,
    gapToTarget: target - current,
  };
}

export function baselinePath(cwd = process.cwd()) {
  return resolve(cwd, OUTPUT_DIR, "baseline.json");
}

export function readFirstMeasured(cwd = process.cwd()) {
  const file = baselinePath(cwd);
  if (existsSync(file)) {
    try {
      const parsed = JSON.parse(readFileSync(file, "utf8"));
      if (parsed && parsed.firstMeasured != null && parsed.firstDate) {
        return { firstMeasured: Number(parsed.firstMeasured), firstDate: String(parsed.firstDate) };
      }
    } catch {
      return null;
    }
  }
  return null;
}

export function writeFirstMeasured(cwd, { firstMeasured, firstDate }) {
  const dir = resolve(cwd, OUTPUT_DIR);
  mkdirSync(dir, { recursive: true });
  const file = baselinePath(cwd);
  if (existsSync(file)) return file;
  writeFileSync(file, `${JSON.stringify({ firstMeasured, firstDate, target: NORTH_STAR_MRR, targetDate: NORTH_STAR_DATE }, null, 2)}
`);
  return file;
}

export function windowCoverage(dayStatus = {}) {
  const entries = Object.entries(dayStatus);
  const okDates = entries.filter(([, v]) => v.status === 200).map(([d]) => d).sort();
  const emptyCount = entries.filter(([, v]) => v.kind === "empty").length;
  const unknownDays = entries
    .filter(([, v]) => v.status !== 200 && v.kind !== "empty")
    .map(([date, v]) => ({ date, status: v.status, kind: v.kind || "error", error: v.error || null }));
  return {
    okDates,
    emptyCount,
    unknownDays,
    complete: unknownDays.length === 0 && entries.length > 0,
    requested: entries.length,
  };
}

export function subscriptionSnapshotFromReport(sub, targets, endDate) {
  const coverage = windowCoverage(sub?.dayStatus);
  if (coverage.okDates.length) {
    const date = coverage.okDates.at(-1);
    const rows = (sub.rows || []).filter((r) => r._reportDate === date);
    return {
      available: true,
      date,
      frequency: sub.dayStatus?.[date]?.frequency || "DAILY",
      assumedZero: false,
      byProduct: summarizeSubscriptionSnapshot(rows, targets),
      coverage,
    };
  }
  if (coverage.requested && !coverage.unknownDays.length) {
    return {
      available: true,
      date: endDate,
      frequency: "DAILY",
      assumedZero: true,
      reason: `All ${coverage.requested} daily SUBSCRIPTION reports in the window returned HTTP 404 with Apple's no-data message (no sales/subscriptions for that date); treated as zero active subscribers as of ${endDate}.`,
      byProduct: summarizeSubscriptionSnapshot([], targets),
      coverage,
    };
  }
  const reasons = summarizeUnknownDays(coverage.unknownDays) || "SUBSCRIPTION reports were not requested";
  return { available: false, reason: reasons, coverage };
}

export function stripeKeyMode(key) {
  if (!key) return null;
  if (key.startsWith("sk_test") || key.startsWith("rk_test")) return "test";
  if (key.startsWith("sk_live") || key.startsWith("rk_live") || key.startsWith("sk_org")) return "live";
  return "unknown";
}

export function stripeMissingStatus(env = process.env) {
  if (env.STRIPE_READONLY_KEY) return null;
  return {
    available: false,
    status: "missing",
    reason: "STRIPE_READONLY_KEY is unset. Skipping Stripe. Set a restricted organization or live read-only key in ~/.config/agents/secrets.env, ~/.config/secrets.env, or the gitignored .env.",
    accounts: {},
  };
}

export function stripeErrorSummary(json, status) {
  const err = json?.error || {};
  const type = err.type || "unknown_error";
  const code = err.code ? `, code: ${err.code}` : "";
  return `HTTP ${status} (Stripe error type: ${type}${code})`;
}

export function stripeHeaders(accountId, { headerName = "Stripe-Context", apiVersion = STRIPE_API_VERSION } = {}) {
  const headers = { "Stripe-Version": apiVersion };
  if (accountId) headers[headerName] = accountId;
  return headers;
}

export function couponFromDiscount(discount) {
  if (!discount || typeof discount === "string") return { coupon: null, unexpanded: Boolean(discount) };
  return { coupon: discount.coupon || discount.source?.coupon || null, unexpanded: false };
}

export function applyDiscounts(amountCents, discounts = []) {
  let amount = amountCents;
  let unexpanded = false;
  for (const discount of discounts) {
    const { coupon, unexpanded: missing } = couponFromDiscount(discount);
    if (missing || (discount && !coupon)) {
      unexpanded = true;
      continue;
    }
    if (!coupon) continue;
    if (coupon.percent_off != null) amount *= (1 - Number(coupon.percent_off) / 100);
    else if (coupon.amount_off != null) amount -= Number(coupon.amount_off);
  }
  return { amountCents: Math.max(0, amount), unexpanded };
}

export function collectDiscounts(subscription, item) {
  const list = [];
  if (Array.isArray(subscription?.discounts)) list.push(...subscription.discounts);
  else if (subscription?.discount) list.push(subscription.discount);
  if (Array.isArray(item?.discounts)) list.push(...item.discounts);
  return list;
}

export function monthlyCents({ unitAmount, interval, intervalCount = 1, quantity = 1, discounts = [] }) {
  const qty = quantity || 1;
  const count = intervalCount || 1;
  const { amountCents, unexpanded } = applyDiscounts((unitAmount ?? 0) * qty, discounts);
  let monthly = null;
  if (interval === "month") monthly = amountCents / count;
  else if (interval === "year") monthly = amountCents / (12 * count);
  else if (interval === "week") monthly = (amountCents * (52 / count)) / 12;
  else if (interval === "day") monthly = (amountCents * (365 / count)) / 12;
  return { monthlyCents: monthly, unexpanded, unknownInterval: monthly == null };
}

export function planName(item) {
  const price = item?.price || {};
  const product = price.product;
  if (product && typeof product === "object") return product.name || price.nickname || price.id || "unknown price";
  return price.nickname || price.id || "unknown price";
}

export function summarizeStripeSubscriptions(subscriptions, { nowSec = Math.floor(Date.now() / 1000), windowStart } = {}) {
  const start = windowStart ?? nowSec - 30 * 24 * 3600;
  let active = 0;
  let pastDue = 0;
  let trialing = 0;
  const byPlan = {};
  const byCurrency = {};
  const unknown = [];
  for (const sub of subscriptions) {
    if (sub.status === "trialing") trialing += 1;
    if (sub.status === "active") active += 1;
    if (sub.status === "past_due") pastDue += 1;
    const contributes = sub.status === "active" || sub.status === "past_due";
    for (const item of sub.items?.data || []) {
      const price = typeof item.price === "object" && item.price ? item.price : {};
      const name = planName(item);
      if (!byPlan[name]) byPlan[name] = { active: 0, pastDue: 0, trialing: 0, mrr: 0, currency: price.currency || "usd" };
      const plan = byPlan[name];
      if (sub.status === "active") plan.active += 1;
      if (sub.status === "past_due") plan.pastDue += 1;
      if (sub.status === "trialing") plan.trialing += 1;
      if (!contributes) continue;
      const currency = price.currency || "usd";
      plan.currency = currency;
      if (typeof item.price === "string") {
        unknown.push({ id: sub.id, reason: "price not expanded" });
        continue;
      }
      const { monthlyCents: monthly, unexpanded, unknownInterval } = monthlyCents({
        unitAmount: price.unit_amount,
        interval: price.recurring?.interval,
        intervalCount: price.recurring?.interval_count,
        quantity: item.quantity,
        discounts: collectDiscounts(sub, item),
      });
      if (unexpanded) unknown.push({ id: sub.id, reason: "discount not expanded" });
      if (unknownInterval) unknown.push({ id: sub.id, reason: `interval ${price.recurring?.interval || "none"}` });
      if (monthly == null || unexpanded) continue;
      const major = monthly / 100;
      plan.mrr += major;
      byCurrency[currency] = (byCurrency[currency] || 0) + major;
    }
  }
  const currencies = Object.keys(byCurrency);
  let currency = null;
  let mrr = 0;
  let mrrUnknownReason = null;
  if (unknown.length) {
    mrr = null;
    mrrUnknownReason = `${unknown.length} paid subscription item(s) could not be converted (${[...new Set(unknown.map((u) => u.reason))].join("; ")})`;
  } else if (currencies.length > 1) {
    mrr = null;
    currency = null;
    mrrUnknownReason = `mixed currencies: ${currencies.join(", ")}`;
  } else {
    currency = currencies[0] || "usd";
    mrr = byCurrency[currency] || 0;
  }
  return {
    active,
    pastDue,
    trialing,
    subscriptionCount: subscriptions.length,
    byPlan,
    byCurrency,
    currency,
    mrr,
    mrrUnknownReason,
    last30Days: {
      canceled: subscriptions.filter((s) => s.status === "canceled" && (s.canceled_at || 0) >= start).length,
    },
  };
}

/** @deprecated Use summarizeStripeSubscriptions. Kept for the paid-item math tests. */
export function stripeMrr(subscriptions) {
  const summary = summarizeStripeSubscriptions(subscriptions);
  return {
    mrrUsd: summary.currency === "usd" ? (summary.mrr ?? 0) : 0,
    active: summary.active + summary.pastDue,
    trialing: summary.trialing,
    byPlan: Object.fromEntries(Object.entries(summary.byPlan).map(([k, v]) => [k, v.active + v.pastDue + v.trialing])),
    unknownCount: summary.mrrUnknownReason ? 1 : 0,
  };
}

export function formatDashboardComment(report) {
  const lines = [];
  lines.push(`# Revenue pull — ${report.generatedAt}`);
  lines.push("");
  lines.push(`Window: ${report.window.startDate} through ${report.window.endDate} (America/New_York dates; daily Apple reports lag one day).`);
  lines.push(`North star: $${NORTH_STAR_MRR} MRR by ${NORTH_STAR_DATE}.`);
  lines.push("");
  lines.push("Numbers below come from API or report responses only. Unknowns are listed plainly. Nothing is estimated.");
  lines.push("");
  lines.push("## Combined MRR vs pace");
  const mrr = report.metrics?.combinedMrr;
  if (!mrr || mrr.total === null) {
    lines.push(`Combined current MRR: **unknown**. ${mrr?.reason || "One or more sources are missing."} Pace against $1,000 cannot be computed without a real MRR figure.`);
    if (mrr?.breakdown && mrr.breakdown !== "none") lines.push(`Partial breakdown: ${mrr.breakdown}.`);
  } else {
    lines.push(`Combined current MRR: **${usd(mrr.total)}** (${mrr.breakdown}). Gap to $1,000: ${usd(NORTH_STAR_MRR - mrr.total)}.`);
  }
  if (mrr?.byApp) {
    for (const product of ["Barbrabell", "Remix"]) {
      const row = mrr.byApp[product];
      if (!row) continue;
      if (row.total == null) lines.push(`- ${product} combined MRR: UNKNOWN (${row.reason})${row.breakdown && row.breakdown !== "none" ? `; partial ${row.breakdown}` : ""}.`);
      else lines.push(`- ${product} combined MRR: ${usd(row.total)} (${row.breakdown}).`);
    }
  }
  const pace = report.metrics?.pace;
  if (!pace || !pace.available) {
    lines.push(pace?.reason || "Pace against $1,000 cannot be computed without a real combined MRR figure.");
  } else {
    const firstNote = pace.isFirstMeasurement
      ? `This pull is the first measured combined MRR (${usd(pace.firstMeasured)} on ${pace.firstDate}).`
      : `First measured combined MRR: ${usd(pace.firstMeasured)} on ${pace.firstDate}.`;
    lines.push(`${firstNote} Straight-line required MRR today to reach ${usd(pace.target)} by ${pace.targetDate}: **${usd(pace.requiredToday)}**.`);
    lines.push(`Pace: **${pace.onPace ? "on pace" : "off pace"}** (${pace.deltaVsRequired >= 0 ? "ahead" : "behind"} by ${usd(Math.abs(pace.deltaVsRequired))}; ${pace.daysRemaining} day(s) remaining).`);
  }
  lines.push("");
  lines.push("## App Store Connect Sales and Trends");
  const sales = report.asc?.sales;
  if (report.asc?.finance && !report.asc.finance.available) {
    lines.push(`Finance key: ${report.asc.finance.reason}`);
  } else if (report.asc?.finance?.available) {
    lines.push("Sales and Trends were requested with the Finance-role key (not the release/catalog key).");
  }
  const blocked = ["missing_vendor_number", "missing_finance_key", "forbidden", "unauthorized"];
  if (blocked.includes(sales?.status)) {
    lines.push(`Unavailable: ${sales.message || sales.status}`);
  } else if (!sales) {
    lines.push("Unavailable: Sales and Trends were not requested.");
  } else {
    if (sales.status === "partial") lines.push(`Partial: at least one daily report failed. ${sales.message || ""}`.trim());
    for (const typ of ["SUBSCRIPTION", "SUBSCRIPTION_EVENT", "SALES"]) {
      const block = sales.reports?.[typ];
      const unknown = block?.unknownDays ? `, ${block.unknownDays} date(s) UNKNOWN` : "";
      lines.push(`- ${typ}: ${block?.okDays ?? 0} report(s) downloaded, ${block?.emptyDays ?? 0} date(s) with Apple no-data 404 (treated as zero)${unknown}, version ${block?.versionUsed || "n/a"}, rows ${block?.rowCount ?? 0}.`);
      if (block?.error) lines.push(`  Error: ${block.error}`);
    }
    const snap = report.metrics?.ascSubscriptionSnapshot;
    if (snap?.available !== false && snap?.byProduct) {
      lines.push("");
      const freq = (snap.frequency || "DAILY").toLowerCase();
      if (snap.assumedZero) {
        lines.push(`Subscription snapshot: ${snap.date} (${snap.reason})`);
      } else {
        lines.push(`Subscription snapshot: ${snap.date} (latest successful SUBSCRIPTION ${freq} report in the window).`);
      }
      for (const product of ["Barbrabell", "Remix"]) {
        const b = snap.byProduct?.[product] || {};
        const paid = (b.activeStandard || 0) + (b.activePayUpFrontIntro || 0) + (b.activePayAsYouGoIntro || 0);
        const plans = Object.entries(b.byPlan || {}).map(([name, v]) => `${name}: ${v.standard} paid, ${v.trial} trial`).join("; ") || "none";
        const amount = appStoreMrrAmount(b);
        let basis = "unknown";
        if (amount.basis === "developer_proceeds") basis = "developer proceeds, yearly normalized / 12";
        else if (amount.basis === "customer_price") basis = "customer price (developer proceeds not on these rows), yearly normalized / 12";
        else if (amount.basis === "no_paid_subscriptions") basis = "no paid subscriptions";
        lines.push(`### ${product}`);
        lines.push(`- Active paid subscriptions: ${paid}`);
        lines.push(`- Active free trials: ${b.activeFreeTrial ?? 0}`);
        lines.push(`- By plan: ${plans}`);
        lines.push(`- App Store MRR: ${amount.value == null ? `UNKNOWN (${amount.reason})` : usd(amount.value)} (basis: ${basis})`);
      }
    } else {
      lines.push(`No usable SUBSCRIPTION report in the window, so active subscriptions and App Store MRR are UNKNOWN${snap?.reason || sales?.message ? ` (${snap?.reason || sales.message})` : ""} and are not assumed to be zero.`);
    }
    const ev = report.metrics?.ascEvents;
    if (ev?.available === false) {
      lines.push("");
      lines.push(`Subscription events in the window: UNKNOWN (${ev.reason}).`);
    } else if (ev) {
      lines.push("");
      lines.push(ev.assumedZero
        ? "Subscription events in the window: all daily SUBSCRIPTION_EVENT reports were Apple no-data 404s, treated as zero events."
        : "Subscription events in the window:");
      for (const product of ["Barbrabell", "Remix"]) {
        const b = ev.byProduct?.[product] || {};
        const counts = Object.entries(b.eventCounts || {}).map(([k, v]) => `${k}: ${v}`).join("; ") || "no events";
        lines.push(`- ${product}: trials started ${b.trialsStarted}, trial-to-paid ${b.trialConverted}, cancels ${b.cancels}, refunds ${b.refunds}. Events: ${counts}.`);
      }
    }
    const proceeds = report.metrics?.ascSales;
    if (proceeds?.available === false) {
      lines.push("");
      lines.push(`Developer proceeds in the window: UNKNOWN (${proceeds.reason}).`);
    } else if (proceeds) {
      lines.push("");
      const extra = proceeds.complete === false
        ? ` UNKNOWN as a complete 30-day total (${proceeds.reason}). Partial downloaded:`
        : proceeds.assumedZero
          ? " All daily SALES reports were Apple no-data 404s, treated as zero."
          : "";
      lines.push(`Developer proceeds (SALES report, USD, units × proceeds) in the window:${extra}`);
      for (const product of ["Barbrabell", "Remix"]) {
        const b = proceeds.byProduct?.[product] || {};
        lines.push(`- ${product}: ${usd(b.proceedsUSD || 0)}, units ${b.units || 0}, across ${b.rows || 0} row(s).`);
      }
      if (proceeds.unmatched?.length) {
        const bits = proceeds.unmatched.map((u) => `${u.title} (Apple ID ${u.appleId}): ${usd(u.proceedsUSD || 0)}, units ${u.units || 0}, ${u.rows} row(s)`);
        lines.push(`- Other apps on this vendor account (excluded from Barbrabell/Remix totals): ${bits.join("; ")}.`);
      }
    }
  }
  lines.push("");
  lines.push("## Stripe");
  const st = report.stripe;
  if (st?.reason && !Object.keys(st.accounts || {}).length) {
    lines.push(`Unavailable: ${st.reason} (status: ${st.status || "missing"}).`);
  } else {
    if (st?.warning) lines.push(`Warning: ${st.warning}`);
    if (st?.headerUsed) lines.push(`Requests used the \`${st.headerUsed}\` header (API version ${st.apiVersion || STRIPE_API_VERSION}).`);
    for (const product of ["Barbrabell", "Remix"]) {
      const a = st?.accounts?.[product];
      lines.push(`### ${product}`);
      if (!a) {
        lines.push("- UNKNOWN: no Stripe result for this app.");
        continue;
      }
      if (!a.available) {
        lines.push(`- UNKNOWN: ${a.reason || "unavailable"} (status: ${a.status || "error"}).`);
        continue;
      }
      const mrrText = a.mrr == null
        ? `UNKNOWN (${a.mrrUnknownReason || "could not compute"})`
        : `${a.mrr.toFixed(2)} ${a.currency || "usd"}`;
      lines.push(`- MRR: ${mrrText}`);
      lines.push(`- Active subscriptions: ${a.active}${a.pastDue ? ` (plus ${a.pastDue} past_due, included in MRR)` : ""}`);
      lines.push(`- Trialing: ${a.trialing}`);
      const plans = Object.entries(a.byPlan || {});
      if (!plans.length) lines.push("- By plan: none");
      else {
        lines.push("- By plan/price:");
        for (const [name, v] of plans) {
          const planMrr = v.mrr != null ? `${Number(v.mrr).toFixed(2)} ${v.currency || a.currency || "usd"}` : "UNKNOWN";
          lines.push(`  - ${name}: ${v.active} active, ${v.trialing} trialing${v.pastDue ? `, ${v.pastDue} past_due` : ""}; MRR ${planMrr}`);
        }
      }
      if (a.last30Days) lines.push(`- Cancellations in the last 30 days: ${a.last30Days.canceled}`);
    }
  }
  lines.push("");
  lines.push("## Catalog (App Store Connect product state, not sales)");
  if (report.asc?.catalogError) lines.push(report.asc.catalogError);
  for (const app of report.asc?.catalogs || []) {
    lines.push(`### ${app.product} — ${app.name} (\`${app.bundleId}\`, Apple ID ${app.id})`);
    if (app.groupError) lines.push(`Subscription groups unavailable: ${app.groupError}`);
    else if (!app.groups?.length) lines.push("Subscription groups: none.");
    else {
      for (const g of app.groups) {
        const loc = g.localizations?.map((l) => l.name).filter(Boolean).join(", ") || g.referenceName;
        lines.push(`- Group: ${loc}`);
        for (const s of g.subscriptions || []) {
          const prices = (s.usaPrices || []).filter((p) => !p.error).map((p) => `${p.customerPrice ?? "?"} USD` + (p.startDate ? ` from ${p.startDate}` : " (current)")).join("; ") || "no USA price";
          const intros = s.introductoryOffers?.error
            ? `intro error: ${s.introductoryOffers.error}`
            : (s.introductoryOffers?.unique || []).map((u) => `${u.key} in ${u.territories} territories`).join("; ") || "no introductory offer";
          lines.push(`  - \`${s.productId}\` — ${s.name}, ${s.subscriptionPeriod}, state ${s.state}, versions ${(s.versions || []).join(", ") || "n/a"}, USA ${prices}, intros: ${intros}`);
        }
      }
    }
  }
  return lines.join("\n");
}

function parseJsonSafe(buf) {
  const text = Buffer.from(buf).toString("utf8");
  if (!text) return {};
  try { return JSON.parse(text); } catch { return { raw: text.slice(0, 400) }; }
}

export async function ascRequest(token, path, { accept } = {}, attempt = 0) {
  const res = await fetch(ASC_BASE + path, {
    method: "GET",
    headers: { Authorization: `Bearer ${token}`, Accept: accept || "application/json" },
  });
  if ((res.status === 429 || res.status === 503) && attempt < 5) {
    const wait = Number(res.headers.get("retry-after")) || 2 ** attempt;
    await new Promise((r) => setTimeout(r, wait * 1000));
    return ascRequest(token, path, { accept }, attempt + 1);
  }
  const buf = Buffer.from(await res.arrayBuffer());
  return { status: res.status, buf };
}

export async function ascGet(token, path) {
  const { status, buf } = await ascRequest(token, path);
  const json = parseJsonSafe(buf);
  if (status < 200 || status >= 300) {
    const err = new Error(`GET ${path} failed: ${errorDetail(json, buf.toString("utf8").slice(0, 400))}`);
    err.status = status;
    err.body = json;
    throw err;
  }
  return json;
}

export async function pages(token, path, limit = 50) {
  const items = [];
  let next = path.includes("?") ? `${path}&limit=${limit}` : `${path}?limit=${limit}`;
  while (next) {
    const json = await ascGet(token, next.startsWith("http") ? next.replace(ASC_BASE, "") : next);
    items.push(...(json.data || []));
    const n = json.links?.next;
    next = n ? n.replace(ASC_BASE, "") : null;
  }
  return items;
}

export async function downloadSalesReport(token, { vendorNumber, reportType, reportSubType, frequency, version, reportDate }) {
  const params = new URLSearchParams({
    "filter[vendorNumber]": vendorNumber,
    "filter[reportType]": reportType,
    "filter[reportSubType]": reportSubType,
    "filter[frequency]": frequency,
    "filter[version]": version,
    "filter[reportDate]": reportDate,
  });
  const { status, buf } = await ascRequest(token, `/v1/salesReports?${params}`, { accept: "application/a-gzip" });
  if (status < 200 || status >= 300) {
    const json = parseJsonSafe(buf);
    const detail = errorDetail(json, buf.toString("utf8").slice(0, 400));
    const classification = classifyReportError(status, detail);
    return { status, empty: classification.kind === "empty", error: detail, classification, version };
  }
  const tsv = parseTsv(gunzipMaybe(buf));
  return { status, empty: tsv.rows.length === 0, headers: tsv.headers, rows: tsv.rows, version };
}

export async function downloadSalesReportWithVersions(token, spec, versions) {
  const tried = [];
  for (const version of versions) {
    const result = await downloadSalesReport(token, { ...spec, version });
    tried.push({ version, status: result.status, error: result.error || null, kind: result.classification?.kind || null });
    if (result.status === 200) return { ...result, tried };
    if (result.classification?.kind === "empty" || result.status === 404) return { ...result, tried };
    if (result.classification?.kind === "forbidden" || result.classification?.kind === "unauthorized") {
      return { ...result, tried };
    }
    // Any other 400 (invalid version, or a misleading vendor error on an unsupported version) — try the next version.
    if (result.status === 400 && version !== versions.at(-1)) continue;
    if (version !== versions.at(-1) && result.status !== 403 && result.status !== 401) continue;
    return { ...result, tried };
  }
  const last = tried.at(-1) || {};
  return { status: last.status, error: last.error, classification: classifyReportError(last.status, last.error), tried };
}

export async function listTargetApps(token) {
  const apps = await pages(token, "/v1/apps");
  const remix = apps.find((a) => a.attributes?.bundleId === REMIX_BUNDLE);
  const barbrabell = apps.find((a) => a.attributes?.bundleId === BARBRABELL.bundleId || String(a.id) === BARBRABELL.appleId);
  const targets = [
    {
      product: "Barbrabell",
      bundleId: BARBRABELL.bundleId,
      appleId: BARBRABELL.appleId,
      name: barbrabell?.attributes?.name,
      id: barbrabell?.id || BARBRABELL.appleId,
    },
    {
      product: "Remix",
      bundleId: REMIX_BUNDLE,
      appleId: remix ? String(remix.id) : "6802880519",
      name: remix?.attributes?.name,
      id: remix?.id || "6802880519",
    },
  ];
  if (barbrabell) {
    targets[0].bundleId = barbrabell.attributes.bundleId;
    targets[0].appleId = String(barbrabell.id);
  }
  return {
    targets,
    unmatched: apps
      .filter((a) => a !== remix && a !== barbrabell)
      .map((a) => ({ id: a.id, name: a.attributes?.name, bundleId: a.attributes?.bundleId })),
  };
}

export async function loadCatalog(token, targets) {
  const catalogs = [];
  for (const app of targets) {
    const groups = [];
    let groupError = null;
    try {
      const groupItems = await pages(token, `/v1/apps/${app.id}/subscriptionGroups`);
      for (const group of groupItems) {
        const locs = await pages(token, `/v1/subscriptionGroups/${group.id}/subscriptionGroupLocalizations`).catch(() => []);
        const subsRaw = await pages(token, `/v1/subscriptionGroups/${group.id}/subscriptions`).catch(() => []);
        const subscriptions = [];
        for (const sub of subsRaw) {
          let introductoryOffers = { count: 0, unique: [], error: null };
          try {
            const introJson = await pages(token, `/v1/subscriptions/${sub.id}/introductoryOffers?include=territory`);
            const uniq = new Map();
            for (const o of introJson) {
              const key = [o.attributes?.offerMode, o.attributes?.duration, `x${o.attributes?.numberOfPeriods ?? 1}`, o.attributes?.startDate || "", o.attributes?.endDate || ""].join("|");
              uniq.set(key, (uniq.get(key) || 0) + 1);
            }
            introductoryOffers = { count: introJson.length, unique: [...uniq.entries()].map(([key, territories]) => ({ key, territories })) };
          } catch (e) {
            introductoryOffers = { count: 0, unique: [], error: e.message };
          }
          let usaPrices = [];
          try {
            const prices = await ascGet(token, `/v1/subscriptions/${sub.id}/prices?filter[territory]=USA&include=subscriptionPricePoint,territory&limit=50`);
            const included = prices.included || [];
            usaPrices = (prices.data || []).map((price) => {
              const pointId = price.relationships?.subscriptionPricePoint?.data?.id;
              const point = included.find((item) => item.id === pointId);
              return { startDate: price.attributes?.startDate || null, customerPrice: point?.attributes?.customerPrice || null, proceeds: point?.attributes?.proceeds || null };
            });
          } catch (e) {
            usaPrices = [{ error: e.message }];
          }
          let versions = [];
          try {
            const ver = await ascGet(token, `/v1/subscriptions/${sub.id}/versions?limit=10`);
            versions = (ver.data || []).map((item) => item.attributes?.state || "unknown");
          } catch (e) {
            versions = [`error: ${e.message}`];
          }
          subscriptions.push({
            id: sub.id,
            productId: sub.attributes?.productId,
            name: sub.attributes?.name,
            state: sub.attributes?.state,
            subscriptionPeriod: sub.attributes?.subscriptionPeriod,
            usaPrices,
            versions,
            introductoryOffers,
          });
        }
        groups.push({
          id: group.id,
          referenceName: group.attributes?.referenceName,
          localizations: locs.map((l) => ({ locale: l.attributes?.locale, name: l.attributes?.name })),
          subscriptions,
        });
      }
    } catch (e) {
      groupError = e.message;
    }
    catalogs.push({ ...app, groups, groupError });
  }
  return catalogs;
}

export async function pullSalesReports(token, vendorNumber, startDate, endDate) {
  if (!vendorNumber) {
    return {
      status: "missing_vendor_number",
      message: "ASC_VENDOR_NUMBER is unset, so Sales, Subscription, and Subscription Event reports were not requested. Add the vendor number from App Store Connect → Payments and Financial Reports to the gitignored .env. The API key must also have the Sales and Trends / Finance role; a 403 from Apple is reported exactly and is not treated as zero revenue.",
      reports: {},
    };
  }
  const types = [
    { reportType: "SALES", reportSubType: "SUMMARY", frequency: "DAILY", versions: ["1_1", "1_0"] },
    { reportType: "SUBSCRIPTION", reportSubType: "SUMMARY", frequency: "DAILY", versions: ["1_3", "1_4", "1_2"] },
    { reportType: "SUBSCRIPTION_EVENT", reportSubType: "SUMMARY", frequency: "DAILY", versions: ["1_3", "1_4", "1_2"] },
  ];
  const reports = {};
  let overall = "ok";
  let overallMessage = null;
  for (const typ of types) {
    let versionLocked = typ.versions[0];
    let sawSuccess = false;
    const allRows = [];
    const dayStatus = {};
    let stopped;
    for (const reportDate of eachDateInclusive(startDate, endDate)) {
      const versions = sawSuccess ? [versionLocked] : typ.versions;
      const got = await downloadSalesReportWithVersions(token, {
        vendorNumber,
        reportType: typ.reportType,
        reportSubType: typ.reportSubType,
        frequency: typ.frequency,
        reportDate,
      }, versions);
      const classified = got.classification || classifyReportError(got.status, got.error);
      if (got.status === 200) {
        sawSuccess = true;
        versionLocked = got.version;
        allRows.push(...(got.rows || []).map((r) => ({ ...r, _reportDate: reportDate, _frequency: typ.frequency })));
        dayStatus[reportDate] = { status: 200, rows: (got.rows || []).length, version: got.version, frequency: typ.frequency, kind: "ok" };
      } else if (classified.kind === "empty") {
        dayStatus[reportDate] = { status: got.status || 404, empty: true, kind: "empty", error: got.error || classified.message, frequency: typ.frequency };
      } else {
        dayStatus[reportDate] = { status: got.status, error: got.error || classified.message, kind: classified.kind, frequency: typ.frequency };
        if (classified.kind === "forbidden" || classified.kind === "unauthorized" || classified.kind === "missing_vendor_number") {
          overall = classified.kind;
          overallMessage = classified.message;
          stopped = classified;
          break;
        }
        if (classified.kind === "invalid_vendor_number") {
          // Don't retry every date with a vendor Apple already rejected for this report type.
          overall = overall === "ok" && !Object.values(reports).length ? classified.kind : "partial";
          overallMessage = classified.message;
          typ._stoppedType = classified;
          break;
        }
        if (overall === "ok") {
          overall = "partial";
          overallMessage = classified.message;
        }
      }
    }
    // Weekly fallback only when daily requests did not already fail closed (auth/vendor).
    if (!stopped && !typ._stoppedType && typ.reportType !== "SALES" && typ.frequency === "DAILY" && !sawSuccess) {
      const weeklyVersions = typ.versions;
      let weeklyNote = null;
      for (const reportDate of sundaysOnOrBefore(endDate, { count: 3, startDate })) {
        const got = await downloadSalesReportWithVersions(token, {
          vendorNumber,
          reportType: typ.reportType,
          reportSubType: typ.reportSubType,
          frequency: "WEEKLY",
          reportDate,
        }, weeklyVersions);
        const classified = got.classification || classifyReportError(got.status, got.error);
        if (got.status === 200) {
          sawSuccess = true;
          versionLocked = got.version;
          allRows.push(...(got.rows || []).map((r) => ({ ...r, _reportDate: reportDate, _frequency: "WEEKLY" })));
          dayStatus[reportDate] = { status: 200, rows: (got.rows || []).length, version: got.version, frequency: "WEEKLY", kind: "ok" };
          break;
        }
        if (got.status === 400 && /frequenc/i.test(got.error || classified.message || "")) {
          weeklyNote = classified.message;
          break;
        }
        if (classified.kind === "empty") {
          dayStatus[reportDate] = { status: got.status, empty: true, kind: "empty", error: got.error || classified.message, frequency: "WEEKLY" };
          continue;
        }
        weeklyNote = classified.message;
        dayStatus[reportDate] = { status: got.status, error: got.error || classified.message, kind: classified.kind, frequency: "WEEKLY" };
        break;
      }
      if (weeklyNote && !sawSuccess) {
        reports[typ.reportType] = reports[typ.reportType] || {};
        typ._weeklyNote = weeklyNote;
      }
    }
    const days = Object.values(dayStatus);
    reports[typ.reportType] = {
      versionUsed: sawSuccess ? versionLocked : null,
      okDays: days.filter((d) => d.status === 200).length,
      emptyDays: days.filter((d) => d.kind === "empty").length,
      unknownDays: days.filter((d) => d.status !== 200 && d.kind !== "empty").length,
      rowCount: allRows.length,
      dayStatus,
      rows: allRows,
      error: stopped ? stopped.message : (typ._stoppedType?.message || typ._weeklyNote || null),
    };
    if (stopped) break;
  }
  return { status: overall, message: overallMessage, reports };
}

export async function stripeRequest(key, path, { accountId, headerName = "Stripe-Context", apiVersion = STRIPE_API_VERSION } = {}) {
  const headers = {
    Authorization: `Bearer ${key}`,
    ...stripeHeaders(accountId, { headerName, apiVersion }),
  };
  const res = await fetch(STRIPE_BASE + path, { method: "GET", headers });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json, headerName };
}

export async function stripeRequestWithFallback(key, path, { accountId, apiVersion = STRIPE_API_VERSION } = {}) {
  const first = await stripeRequest(key, path, { accountId, headerName: "Stripe-Context", apiVersion });
  if (first.status >= 200 && first.status < 300) return { ...first, headerUsed: "Stripe-Context" };
  const second = await stripeRequest(key, path, { accountId, headerName: "Stripe-Account", apiVersion });
  if (second.status >= 200 && second.status < 300) return { ...second, headerUsed: "Stripe-Account" };
  return {
    ...first,
    headerUsed: "Stripe-Context",
    error: stripeErrorSummary(first.json, first.status),
  };
}

// price.product is a fourth expand level and Stripe rejects it (property_expansion_max_depth).
const SUB_EXPAND = "expand[]=data.items.data.price&expand[]=data.discounts&expand[]=data.items.data.discounts";

export async function stripeListSubscriptions(key, { accountId, apiVersion } = {}) {
  const items = [];
  let startingAfter = null;
  let headerUsed = "Stripe-Context";
  for (let i = 0; i < 50; i++) {
    const qs = `/subscriptions?status=all&limit=100&${SUB_EXPAND}` + (startingAfter ? `&starting_after=${startingAfter}` : "");
    const page = await stripeRequestWithFallback(key, qs, { accountId, apiVersion });
    if (page.status < 200 || page.status >= 300) {
      const err = new Error(page.error || stripeErrorSummary(page.json, page.status));
      err.status = page.status;
      err.headerUsed = page.headerUsed;
      throw err;
    }
    headerUsed = page.headerUsed;
    items.push(...(page.json.data || []));
    if (!page.json.has_more) break;
    startingAfter = items.at(-1)?.id;
    if (!startingAfter) break;
  }
  await attachProductNames(key, items, { accountId, apiVersion });
  return { subscriptions: items, headerUsed };
}

async function attachProductNames(key, subscriptions, { accountId, apiVersion } = {}) {
  const ids = new Set();
  for (const sub of subscriptions) {
    for (const item of sub.items?.data || []) {
      const product = item.price?.product;
      if (typeof product === "string") ids.add(product);
    }
  }
  const names = {};
  for (const id of ids) {
    const page = await stripeRequestWithFallback(key, `/products/${id}`, { accountId, apiVersion });
    if (page.status >= 200 && page.status < 300 && page.json?.name) names[id] = page.json.name;
  }
  for (const sub of subscriptions) {
    for (const item of sub.items?.data || []) {
      const product = item.price?.product;
      if (typeof product === "string" && names[product] && item.price) {
        item.price.product = { id: product, name: names[product] };
      }
    }
  }
}

export async function pullStripeAccount(key, { product, accountId, mode, nowSec, apiVersion } = {}) {
  if (!accountId) {
    return {
      product,
      available: false,
      status: "missing",
      reason: `${STRIPE_ACCOUNT_ENV[product] || "account id"} is unset for ${product}.`,
    };
  }
  try {
    const { subscriptions, headerUsed } = await stripeListSubscriptions(key, { accountId, apiVersion });
    const summary = summarizeStripeSubscriptions(subscriptions, { nowSec });
    return {
      product,
      available: true,
      status: "ok",
      mode,
      headerUsed,
      ...summary,
    };
  } catch (e) {
    return {
      product,
      available: false,
      status: e.status === 401 || e.status === 403 ? "forbidden" : "error",
      reason: e.message,
      httpStatus: e.status || null,
    };
  }
}

export async function pullStripe(env = process.env, { now = new Date(), apiVersion = env.STRIPE_API_VERSION || STRIPE_API_VERSION } = {}) {
  const missing = stripeMissingStatus(env);
  if (missing) return missing;
  const key = env.STRIPE_READONLY_KEY;
  const mode = stripeKeyMode(key);
  const nowSec = Math.floor(now.getTime() / 1000);
  const accounts = {};
  const headerUsed = new Set();
  for (const product of ["Barbrabell", "Remix"]) {
    const accountId = env[STRIPE_ACCOUNT_ENV[product]];
    const result = await pullStripeAccount(key, { product, accountId, mode, nowSec, apiVersion });
    accounts[product] = result;
    if (result.headerUsed) headerUsed.add(result.headerUsed);
  }
  const ok = Object.values(accounts).filter((a) => a.available);
  return {
    available: ok.length > 0,
    status: ok.length === 2 ? "ok" : ok.length ? "partial" : "error",
    mode,
    apiVersion,
    headerUsed: [...headerUsed].join(", ") || null,
    warning: mode === "test" ? "These numbers are from a test-mode key and are not a live revenue baseline." : null,
    accounts,
  };
}

function coverageReason(coverage, label) {
  return summarizeUnknownDays(coverage?.unknownDays, label);
}

export async function runPull({ env = process.env, now = new Date(), home, cwd } = {}) {
  const secretFilesFound = loadRevenueEnv({ home, cwd, env });
  const generatedAt = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    dateStyle: "medium",
    timeStyle: "short",
  }).format(now) + " America/New_York";
  const window = reportWindow(now);
  const workdir = cwd || process.cwd();
  const report = {
    generatedAt,
    window,
    sources: {
      secretFilesFound,
      ascKeyIdSet: Boolean(env.ASC_KEY_ID),
      ascIssuerIdSet: Boolean(env.ASC_ISSUER_ID),
      ascKeyPathSet: Boolean(env.ASC_KEY_PATH),
      financeKeyIdSet: Boolean(env.ASC_FINANCE_KEY_ID),
      financeKeyPathSet: Boolean(env.ASC_FINANCE_KEY_PATH),
      vendorNumberSet: Boolean(env.ASC_VENDOR_NUMBER),
      stripeKeySet: Boolean(env.STRIPE_READONLY_KEY),
      stripeAccountBarbrabellSet: Boolean(env.STRIPE_ACCOUNT_BARBRABELL),
      stripeAccountRemixSet: Boolean(env.STRIPE_ACCOUNT_REMIX),
    },
    asc: {},
    stripe: {},
    metrics: {},
  };
  let listed = { targets: APPS.map((a) => ({ ...a, id: a.appleId })), unmatched: [] };
  try {
    const auth = loadAscEnv(env);
    const token = signJwtQuiet(auth);
    listed = await listTargetApps(token);
    report.asc.unmatched = listed.unmatched;
    report.asc.catalogs = await loadCatalog(token, listed.targets);
  } catch (e) {
    report.asc.catalogError = sanitizePublicError(e.message);
  }

  const finance = financeAuthStatus(env, { home: home || homedir() });
  report.asc.finance = { available: finance.available, usedFor: "salesReports", reason: finance.reason || null };
  let sales;
  if (!finance.available) {
    sales = { status: "missing_finance_key", message: finance.reason, reports: {} };
  } else if (!env.ASC_VENDOR_NUMBER) {
    sales = {
      status: "missing_vendor_number",
      message: "ASC_VENDOR_NUMBER is unset, so Sales, Subscription, and Subscription Event reports were not requested. Add the vendor number from App Store Connect → Payments and Financial Reports to ~/.config/secrets.env or the gitignored .env.",
      reports: {},
    };
  } else {
    try {
      const financeToken = signJwtQuiet(finance.auth);
      sales = await pullSalesReports(financeToken, env.ASC_VENDOR_NUMBER, window.startDate, window.endDate);
    } catch (e) {
      sales = { status: "error", message: sanitizePublicError(e.message), reports: {} };
    }
  }
  report.asc.sales = {
    status: sales.status,
    message: sales.message,
    reports: Object.fromEntries(Object.entries(sales.reports || {}).map(([k, v]) => [k, { ...v }])),
  };

  const snapshot = subscriptionSnapshotFromReport(sales.reports?.SUBSCRIPTION, listed.targets, window.endDate);
  if (snapshot.available) {
    report.metrics.ascSubscriptionSnapshot = snapshot;
    report.metrics.appStore = {
      available: true,
      snapshotDate: snapshot.date,
      assumedZero: Boolean(snapshot.assumedZero),
      reason: snapshot.reason || null,
      byProduct: snapshot.byProduct,
    };
  } else {
    report.metrics.appStore = { available: false, reason: snapshot.reason || sales.message || "App Store subscription reports not available" };
  }

  const ev = sales.reports?.SUBSCRIPTION_EVENT;
  if (ev) {
    const coverage = windowCoverage(ev.dayStatus);
    if (coverage.okDates.length || (coverage.requested && !coverage.unknownDays.length)) {
      report.metrics.ascEvents = {
        available: true,
        assumedZero: !coverage.okDates.length,
        coverage,
        byProduct: summarizeSubscriptionEvents(coverage.okDates.length ? ev.rows || [] : [], listed.targets, window.startDate, window.endDate),
      };
    } else if (coverage.requested) {
      report.metrics.ascEvents = { available: false, reason: coverageReason(coverage, "SUBSCRIPTION_EVENT"), coverage };
    }
  }

  const salesBlock = sales.reports?.SALES;
  if (salesBlock) {
    const coverage = windowCoverage(salesBlock.dayStatus);
    if (coverage.okDates.length || (coverage.requested && !coverage.unknownDays.length)) {
      report.metrics.ascSales = {
        available: true,
        assumedZero: !coverage.okDates.length,
        complete: coverage.complete,
        reason: coverage.complete ? null : coverageReason(coverage, "SALES"),
        coverage,
        byProduct: summarizeSalesProceeds(coverage.okDates.length ? salesBlock.rows || [] : [], listed.targets),
        unmatched: unmatchedSales(coverage.okDates.length ? salesBlock.rows || [] : [], listed.targets),
      };
    } else if (coverage.requested) {
      report.metrics.ascSales = { available: false, complete: false, reason: coverageReason(coverage, "SALES"), coverage };
    }
  }

  report.stripe = await pullStripe(env, { now });
  report.metrics.combinedMrr = combinedMrr({ appStore: report.metrics.appStore, stripe: report.stripe });
  const prior = readFirstMeasured(workdir);
  report.metrics.pace = mrrPace({
    current: report.metrics.combinedMrr.total,
    today: todayISO(now),
    firstMeasured: prior?.firstMeasured,
    firstDate: prior?.firstDate,
  });
  report.comment = formatDashboardComment(report);
  return report;
}

export function writeReport(report, cwd = process.cwd()) {
  const dir = resolve(cwd, OUTPUT_DIR);
  mkdirSync(dir, { recursive: true });
  const stamp = todayISO();
  const jsonPath = resolve(dir, `${stamp}.json`);
  const mdPath = resolve(dir, `${stamp}.md`);
  const forFile = { ...report };
  writeFileSync(jsonPath, JSON.stringify(forFile, null, 2));
  writeFileSync(mdPath, report.comment);
  if (report.metrics?.combinedMrr?.total != null && report.metrics?.pace?.firstDate) {
    writeFirstMeasured(cwd, {
      firstMeasured: report.metrics.pace.firstMeasured,
      firstDate: report.metrics.pace.firstDate,
    });
  }
  return { jsonPath, mdPath };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname);
if (isMain) {
  const report = await runPull();
  const { jsonPath, mdPath } = writeReport(report);
  console.log(report.comment);
  console.log(`\nWrote ${jsonPath}\nWrote ${mdPath}`);
}
