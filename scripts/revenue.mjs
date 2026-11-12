/** Read-only revenue pull for Barbrabell and Remix (FIT-444).
 *
 * Reads ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH from the gitignored `.env`
 * at runtime (via load-env.mjs). Never prints, copies, or returns the .p8.
 * Optional: ASC_VENDOR_NUMBER (Sales and Trends), STRIPE_READONLY_KEY.
 *
 * GET only against Apple and Stripe. Writes JSON under revenue-out/ (gitignored).
 *
 *   node scripts/revenue.mjs
 *   npm run revenue
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { gunzipSync } from "node:zlib";
import { loadAscEnv, signJwt } from "./asc.mjs";
import { loadEnv } from "./load-env.mjs";

export const ASC_BASE = "https://api.appstoreconnect.apple.com";
export const STRIPE_BASE = "https://api.stripe.com/v1";
export const OUTPUT_DIR = "revenue-out";
export const NORTH_STAR_MRR = 1000;
export const NORTH_STAR_DATE = "2027-03-01";
export const BARBRABELL = { product: "Barbrabell", bundleId: "com.maxwellkendall.aicoach", appleId: "6821439066" };
export const REMIX_BUNDLE = "com.remix.app.Remix";

export const APPS = [BARBRABELL, { product: "Remix", bundleId: REMIX_BUNDLE, appleId: null }];

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
    mrrUnknownDurationRows: 0,
    byPlan: {},
    proceedsUSD: 0,
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
    const paid = standard + payUpFront + payAsYouGo;
    if (currency === "USD" && months && paid) bucket.mrrCustomerUSD += (price / months) * paid;
    else if (paid) bucket.mrrUnknownDurationRows += 1;
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
    if (curr === "USD" || curr === "US") bucket.proceedsUSD += proceeds * (units || 1);
  }
  return byProduct;
}

export function classifyReportError(status, detail) {
  const text = String(detail || "");
  if (status === 404) return { kind: "empty", message: "HTTP 404: no report for that date" };
  if (status === 403) return { kind: "forbidden", message: `HTTP 403: ${text || "The API key in use does not allow this request"}` };
  if (status === 401) return { kind: "unauthorized", message: `HTTP 401: ${text}` };
  if (status === 400 && /vendorNumber/i.test(text) && /required/i.test(text)) {
    return { kind: "missing_vendor_number", message: text };
  }
  return { kind: "error", message: `HTTP ${status}: ${text}` };
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

export function combinedMrr({ appStore, stripe }) {
  const parts = [];
  const missing = [];
  let total = 0;
  if (appStore?.available) {
    for (const product of ["Barbrabell", "Remix"]) {
      const b = appStore.byProduct?.[product];
      if (!b) continue;
      if (b.mrrUnknownDurationRows) missing.push(`App Store ${product} MRR not fully convertible`);
      else {
        parts.push(`App Store ${product} ${usd(b.mrrCustomerUSD || 0)} as of ${appStore.snapshotDate}`);
        total += b.mrrCustomerUSD || 0;
      }
    }
  } else {
    missing.push(appStore?.reason || "App Store subscription reports not available");
  }
  if (stripe?.available && stripe.mode === "live") {
    parts.push(`Stripe live ${usd(stripe.mrrUsd)}`);
    total += stripe.mrrUsd || 0;
  } else if (stripe?.available && stripe.mode === "test") {
    missing.push("Stripe key is test-mode; excluded from combined live MRR");
  } else {
    missing.push(stripe?.reason || "Stripe live MRR unavailable");
  }
  if (missing.length) return { total: null, reason: missing.join("; "), breakdown: parts.join(" + ") || "none" };
  return { total, reason: null, breakdown: parts.join(" + ") };
}

export function stripeKeyMode(key) {
  if (!key) return null;
  if (key.startsWith("sk_test") || key.startsWith("rk_test")) return "test";
  if (key.startsWith("sk_live") || key.startsWith("rk_live")) return "live";
  return "unknown";
}

export function stripeMissingStatus(env = process.env) {
  if (env.STRIPE_READONLY_KEY) return null;
  return {
    available: false,
    status: "missing",
    reason: "STRIPE_READONLY_KEY is unset. Skipping Stripe. Set a restricted live read-only key in the gitignored .env to enable this source.",
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
  lines.push("");
  lines.push("## App Store Connect Sales and Trends");
  const sales = report.asc?.sales;
  if (sales?.status === "missing_vendor_number") {
    lines.push(`Unavailable: ${sales.message}`);
  } else if (sales?.status === "forbidden") {
    lines.push(`Unavailable: the API key does not have access to Sales and Trends / Finance reports. Exact response: ${sales.message}`);
  } else if (sales?.status && sales.status !== "ok") {
    lines.push(`Unavailable: ${sales.message || sales.status}`);
  } else if (!sales) {
    lines.push("Unavailable: Sales and Trends were not requested.");
  } else {
    for (const typ of ["SUBSCRIPTION", "SUBSCRIPTION_EVENT", "SALES"]) {
      const block = sales.reports?.[typ];
      lines.push(`- ${typ}: ${block?.okDays ?? 0} daily report(s) downloaded, ${block?.emptyDays ?? 0} date(s) with no report (HTTP 404), version ${block?.versionUsed || "n/a"}, rows ${block?.rowCount ?? 0}.`);
      if (block?.error) lines.push(`  Error: ${block.error}`);
    }
    const snap = report.metrics?.ascSubscriptionSnapshot;
    if (snap) {
      lines.push("");
      lines.push(`Subscription snapshot: ${snap.date} (latest successful SUBSCRIPTION daily report in the window).`);
      for (const product of ["Barbrabell", "Remix"]) {
        const b = snap.byProduct?.[product] || {};
        const paid = (b.activeStandard || 0) + (b.activePayUpFrontIntro || 0) + (b.activePayAsYouGoIntro || 0);
        const plans = Object.entries(b.byPlan || {}).map(([name, v]) => `${name}: ${v.standard} paid, ${v.trial} trial`).join("; ") || "none";
        lines.push(`### ${product}`);
        lines.push(`- Active paid subscriptions: ${paid}`);
        lines.push(`- Active free trials: ${b.activeFreeTrial ?? 0}`);
        lines.push(`- By plan: ${plans}`);
        lines.push(`- Current MRR (customer price, USD, monthly equivalent): ${b.mrrUnknownDurationRows ? `unknown (${b.mrrUnknownDurationRows} paid row(s) not convertible); partial ${usd(b.mrrCustomerUSD)}` : usd(b.mrrCustomerUSD || 0)}`);
      }
    } else {
      lines.push("No successful SUBSCRIPTION daily report in the window, so active subscriptions and App Store MRR are unknown (not assumed to be zero).");
    }
    const ev = report.metrics?.ascEvents;
    if (ev) {
      lines.push("");
      lines.push("Subscription events in the window:");
      for (const product of ["Barbrabell", "Remix"]) {
        const b = ev.byProduct?.[product] || {};
        const counts = Object.entries(b.eventCounts || {}).map(([k, v]) => `${k}: ${v}`).join("; ") || "no events";
        lines.push(`- ${product}: trials started ${b.trialsStarted}, trial-to-paid ${b.trialConverted}, cancels ${b.cancels}, refunds ${b.refunds}. Events: ${counts}.`);
      }
    }
    const proceeds = report.metrics?.ascSales;
    if (proceeds) {
      lines.push("");
      lines.push("Developer proceeds (SALES report, USD, units × proceeds) in the window:");
      for (const product of ["Barbrabell", "Remix"]) {
        const b = proceeds.byProduct?.[product] || {};
        lines.push(`- ${product}: ${usd(b.proceedsUSD || 0)} across ${b.rows || 0} row(s).`);
      }
    }
  }
  lines.push("");
  lines.push("## Stripe");
  const st = report.stripe;
  if (!st?.available) {
    lines.push(`Unavailable: ${st?.reason || "no access"} (status: ${st?.status || "missing"}).`);
  } else {
    if (st.warning) lines.push(`Warning: ${st.warning}`);
    lines.push(`Mode: ${st.mode}. Active (incl. past_due): ${st.active}. Trialing: ${st.trialing}. MRR from price amounts (USD): ${usd(st.mrrUsd)}.`);
    if (st.byPlan) lines.push(`By plan: ${Object.entries(st.byPlan).map(([k, v]) => `${k}: ${v}`).join("; ")}.`);
    if (st.last30Days) {
      lines.push(`Last 30 days: created ${st.last30Days.created}, canceled ${st.last30Days.canceled}, trials started ${st.last30Days.trialsStarted}, trial converted to active ${st.last30Days.trialConvertedToActive}.`);
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
  if (status === 404) return { status, empty: true, version };
  if (status < 200 || status >= 300) {
    const json = parseJsonSafe(buf);
    const detail = errorDetail(json, buf.toString("utf8").slice(0, 400));
    return { status, error: detail, classification: classifyReportError(status, detail), version };
  }
  const tsv = parseTsv(gunzipMaybe(buf));
  return { status, empty: tsv.rows.length === 0, headers: tsv.headers, rows: tsv.rows, version };
}

export async function downloadSalesReportWithVersions(token, spec, versions) {
  const tried = [];
  for (const version of versions) {
    const result = await downloadSalesReport(token, { ...spec, version });
    tried.push({ version, status: result.status, error: result.error || null });
    if (result.status === 200) return { ...result, tried };
    const msg = `${result.error || ""}`;
    if (result.status === 400 && /version/i.test(msg)) continue;
    return { ...result, tried };
  }
  return { status: tried.at(-1)?.status, error: tried.at(-1)?.error, classification: classifyReportError(tried.at(-1)?.status, tried.at(-1)?.error), tried };
}

export async function listTargetApps(token) {
  const apps = await pages(token, "/v1/apps");
  const remix = apps.find((a) => a.attributes?.bundleId === REMIX_BUNDLE);
  const barbrabell = apps.find((a) => a.attributes?.bundleId === BARBRABELL.bundleId || String(a.id) === BARBRABELL.appleId);
  const targets = [];
  if (barbrabell) {
    targets.push({ product: "Barbrabell", bundleId: barbrabell.attributes.bundleId, appleId: String(barbrabell.id), name: barbrabell.attributes.name, id: barbrabell.id });
  }
  if (remix) {
    targets.push({ product: "Remix", bundleId: remix.attributes.bundleId, appleId: String(remix.id), name: remix.attributes.name, id: remix.id });
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
    { reportType: "SUBSCRIPTION", reportSubType: "SUMMARY", frequency: "DAILY", versions: ["1_4", "1_3"] },
    { reportType: "SUBSCRIPTION_EVENT", reportSubType: "SUMMARY", frequency: "DAILY", versions: ["1_4", "1_3"] },
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
        allRows.push(...(got.rows || []).map((r) => ({ ...r, _reportDate: reportDate })));
        dayStatus[reportDate] = { status: 200, rows: (got.rows || []).length, version: got.version };
      } else if (got.status === 404 || got.empty) {
        dayStatus[reportDate] = { status: 404, empty: true };
      } else {
        dayStatus[reportDate] = { status: got.status, error: got.error, kind: classified.kind };
        if (classified.kind === "forbidden" || classified.kind === "unauthorized" || classified.kind === "missing_vendor_number") {
          overall = classified.kind;
          overallMessage = classified.message;
          stopped = classified;
          break;
        }
      }
    }
    const days = Object.values(dayStatus);
    reports[typ.reportType] = {
      versionUsed: sawSuccess ? versionLocked : null,
      okDays: days.filter((d) => d.status === 200).length,
      emptyDays: days.filter((d) => d.status === 404 || d.empty).length,
      rowCount: allRows.length,
      dayStatus,
      rows: allRows,
      error: stopped ? stopped.message : null,
    };
    if (stopped) break;
  }
  return { status: overall, message: overallMessage, reports };
}

export function stripeMrr(subscriptions) {
  let mrrUsd = 0;
  let active = 0;
  let trialing = 0;
  const byPlan = {};
  const unknown = [];
  for (const sub of subscriptions) {
    if (sub.status === "trialing") trialing += 1;
    if (sub.status === "active" || sub.status === "past_due") active += 1;
    if (sub.status === "active" || sub.status === "trialing" || sub.status === "past_due") {
      for (const item of sub.items?.data || []) {
        const price = item.price || {};
        const amount = (price.unit_amount ?? 0) / 100;
        const interval = price.recurring?.interval;
        const count = price.recurring?.interval_count || 1;
        const qty = item.quantity || 1;
        const nickname = price.nickname || price.id || "unknown price";
        if (price.currency && price.currency !== "usd") {
          unknown.push({ id: sub.id, reason: `non-usd ${price.currency}` });
          continue;
        }
        let monthly = 0;
        if (interval === "month") monthly = (amount / count) * qty;
        else if (interval === "year") monthly = (amount / (12 * count)) * qty;
        else if (interval === "week") monthly = (amount * (52 / count) / 12) * qty;
        else if (interval === "day") monthly = (amount * (365 / count) / 12) * qty;
        else unknown.push({ id: sub.id, reason: `interval ${interval || "none"}` });
        mrrUsd += monthly;
        byPlan[nickname] = (byPlan[nickname] || 0) + 1;
      }
    }
  }
  return { mrrUsd, active, trialing, byPlan, unknownCount: unknown.length };
}

async function stripeGet(key, path) {
  const res = await fetch(STRIPE_BASE + path, { headers: { Authorization: `Bearer ${key}` } });
  const json = await res.json();
  if (!res.ok) {
    const err = new Error(`Stripe GET ${path} failed: ${json?.error?.message || res.status}`);
    err.status = res.status;
    throw err;
  }
  return json;
}

async function stripeAll(key, path) {
  const items = [];
  let startingAfter = null;
  for (let i = 0; i < 50; i++) {
    const url = path + (path.includes("?") ? "&" : "?") + "limit=100" + (startingAfter ? `&starting_after=${startingAfter}` : "");
    const page = await stripeGet(key, url);
    items.push(...(page.data || []));
    if (!page.has_more) break;
    startingAfter = items.at(-1)?.id;
    if (!startingAfter) break;
  }
  return items;
}

export async function pullStripe(env = process.env) {
  const missing = stripeMissingStatus(env);
  if (missing) return missing;
  const key = env.STRIPE_READONLY_KEY;
  const mode = stripeKeyMode(key);
  try {
    const subscriptions = await stripeAll(key, "/subscriptions?status=all");
    const windowStart = Math.floor(Date.now() / 1000) - 30 * 24 * 3600;
    const summary = stripeMrr(subscriptions);
    return {
      available: true,
      status: "ok",
      mode,
      warning: mode === "test" ? "These numbers are from a test-mode key and are not a live revenue baseline." : null,
      subscriptionCount: subscriptions.length,
      ...summary,
      last30Days: {
        created: subscriptions.filter((s) => (s.created || 0) >= windowStart).length,
        canceled: subscriptions.filter((s) => s.status === "canceled" && (s.canceled_at || 0) >= windowStart).length,
        trialsStarted: subscriptions.filter((s) => (s.trial_start || 0) >= windowStart).length,
        trialConvertedToActive: subscriptions.filter((s) => s.trial_end && s.trial_end <= Math.floor(Date.now() / 1000) && s.status === "active" && (s.trial_start || 0) >= windowStart).length,
      },
    };
  } catch (e) {
    return { available: false, status: "error", mode, reason: e.message };
  }
}

export async function runPull({ env = process.env, now = new Date() } = {}) {
  loadEnv();
  const generatedAt = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    dateStyle: "medium",
    timeStyle: "short",
  }).format(now) + " America/New_York";
  const window = reportWindow(now);
  const report = {
    generatedAt,
    window,
    sources: {
      ascKeyIdSet: Boolean(env.ASC_KEY_ID),
      ascIssuerIdSet: Boolean(env.ASC_ISSUER_ID),
      ascKeyPathSet: Boolean(env.ASC_KEY_PATH),
      vendorNumberSet: Boolean(env.ASC_VENDOR_NUMBER),
      stripeKeySet: Boolean(env.STRIPE_READONLY_KEY),
    },
    asc: {},
    stripe: {},
    metrics: {},
  };
  try {
    const auth = loadAscEnv(env);
    const token = signJwt(auth);
    const listed = await listTargetApps(token);
    report.asc.unmatched = listed.unmatched;
    report.asc.catalogs = await loadCatalog(token, listed.targets);
    const sales = await pullSalesReports(token, env.ASC_VENDOR_NUMBER, window.startDate, window.endDate);
    report.asc.sales = {
      status: sales.status,
      message: sales.message,
      reports: Object.fromEntries(Object.entries(sales.reports || {}).map(([k, v]) => [k, { ...v }])),
    };
    const sub = sales.reports?.SUBSCRIPTION;
    const okSubDates = Object.entries(sub?.dayStatus || {}).filter(([, v]) => v.status === 200).map(([d]) => d).sort();
    if (okSubDates.length) {
      const date = okSubDates.at(-1);
      const latestRows = (sub.rows || []).filter((r) => r._reportDate === date);
      report.metrics.ascSubscriptionSnapshot = { date, byProduct: summarizeSubscriptionSnapshot(latestRows, listed.targets) };
    }
    const ev = sales.reports?.SUBSCRIPTION_EVENT;
    if (Object.values(ev?.dayStatus || {}).some((v) => v.status === 200)) {
      report.metrics.ascEvents = { byProduct: summarizeSubscriptionEvents(ev.rows || [], listed.targets, window.startDate, window.endDate) };
    }
    const salesBlock = sales.reports?.SALES;
    if (Object.values(salesBlock?.dayStatus || {}).some((v) => v.status === 200)) {
      report.metrics.ascSales = { byProduct: summarizeSalesProceeds(salesBlock.rows || [], listed.targets) };
    }
    report.metrics.appStore = report.metrics.ascSubscriptionSnapshot
      ? { available: true, snapshotDate: report.metrics.ascSubscriptionSnapshot.date, byProduct: report.metrics.ascSubscriptionSnapshot.byProduct }
      : { available: false, reason: sales.message || "App Store subscription reports not available" };
  } catch (e) {
    report.asc.catalogError = e.message;
    report.metrics.appStore = { available: false, reason: e.message };
  }
  report.stripe = await pullStripe(env);
  report.metrics.combinedMrr = combinedMrr({ appStore: report.metrics.appStore, stripe: report.stripe });
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
  return { jsonPath, mdPath };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname);
if (isMain) {
  const report = await runPull();
  const { jsonPath, mdPath } = writeReport(report);
  console.log(report.comment);
  console.log(`\nWrote ${jsonPath}\nWrote ${mdPath}`);
}
