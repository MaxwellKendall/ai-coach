// TKL-466: the first launch's funnel, from the hero to the paywall and the purchase, read per monetization strategy
// (shared/monetization.ts) against AbMaxx's 11%+ download-to-paid.
//
// The app sends events to barbrabell.com/events with a random install id and the strategy it's running; no sign-in, no
// name, no age, no answers. The server counts each install once per step, on the day and strategy of the install's
// first event, so a cohort's conversion keeps filling in on its own row. `npm run funnel -- STAGE` (infra/) reads it.
//
// Denominator (decided by default on TKL-466, 2026-11-21): first launches, the installs that saw the hero. The App
// Store's downloads can't be split by strategy, so the 11% benchmark (per download) is labelled with its own.

import { isStrategy, STRATEGIES, type Strategy } from "./monetization.ts";

/** The spec's stable screen ids ("Barbrabell onboarding: AbMaxx-style hard paywall", Analytics events). */
export const SCREENS = [
  "hero", "goal", "gender", "comparison_chart", "age", "height", "weight", "frequency", "body_type", "activity_level",
  "where_train", "equipment", "holding_back", "name", "strength_invite", "strength_steps", "select_lifts", "enter_lifts",
  "analysis", "results", "setup", "plan_ready", "paywall",
] as const;

export const PRODUCTS = ["lifter_yearly", "lifter_monthly", "coach_yearly", "coach_monthly"] as const;
export const PATHS = ["purchase", "restore", "not_now"] as const;
export const FAILURES = ["cancelled", "pending", "error"] as const;

/** Each event, and the details it may carry. Anything else is dropped: free text could be someone's name. */
const EVENTS: Record<string, readonly string[]> = {
  onboarding_started: [],
  onboarding_screen_viewed: SCREENS,
  strength_check_started: [],
  strength_check_skipped: SCREENS,
  strength_check_completed: [],
  strength_results_viewed: [],
  plan_generation_started: [],
  plan_generation_completed: [],
  plan_generation_failed: [],
  plan_ready_viewed: [],
  paywall_viewed: [],
  paywall_plan_selected: PRODUCTS,
  purchase_started: PRODUCTS,
  purchase_completed: PRODUCTS,
  purchase_failed: FAILURES,
  purchase_restored: [],
  paywall_dismissed: [],
  onboarding_completed: PATHS,
};

export const MAX_EVENTS = 100;
export const BENCHMARK = 0.11;

export type FunnelEvent = { name: string; detail?: string };
export type Batch = { install: string; strategy: Strategy; events: FunnelEvent[] };
export type FunnelRow = { day: string; strategy: Strategy; counts: Record<string, number> };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function parseBatch(body: unknown): Batch | undefined {
  if (typeof body !== "object" || body === null) return undefined;
  const { install, strategy, events } = body as Record<string, unknown>;
  if (typeof install !== "string" || !UUID.test(install) || !isStrategy(strategy)) return undefined;
  if (!Array.isArray(events) || events.length > MAX_EVENTS) return undefined;
  const kept: FunnelEvent[] = [];
  for (const event of events) {
    const { name, detail } = (event ?? {}) as Record<string, unknown>;
    if (typeof name !== "string" || !Object.hasOwn(EVENTS, name)) continue;
    const allowed = EVENTS[name];
    if (detail === undefined || detail === null) kept.push({ name });
    else if (typeof detail === "string" && allowed.includes(detail)) kept.push({ name, detail });
    else if (allowed.length === 0) kept.push({ name });
  }
  return { install: install.toLowerCase(), strategy, events: kept };
}

/** What an event counts toward: the event, and the event with its detail (which screen, which plan). */
export function stepKeys(event: FunnelEvent): string[] {
  return event.detail ? [event.name, `${event.name}.${event.detail}`] : [event.name];
}

const SCREEN_LABEL = (screen: string) => [`Screen: ${screen}`, `onboarding_screen_viewed.${screen}`] as const;

/** The report's rows in the order a first launch goes through them. */
export const STEPS: readonly (readonly [string, string])[] = [
  ["First launch (hero)", "onboarding_screen_viewed.hero"],
  ["Started", "onboarding_started"],
  ...SCREENS.slice(1, SCREENS.indexOf("strength_invite")).map(SCREEN_LABEL),
  ["Strength check started", "strength_check_started"],
  ["Strength check skipped", "strength_check_skipped"],
  ["Strength check completed", "strength_check_completed"],
  ...SCREENS.slice(SCREENS.indexOf("strength_invite"), SCREENS.indexOf("paywall")).map(SCREEN_LABEL),
  ["Strength results viewed", "strength_results_viewed"],
  ["Plan generation started", "plan_generation_started"],
  ["Plan generation completed", "plan_generation_completed"],
  ["Plan generation failed", "plan_generation_failed"],
  ["Plan ready viewed", "plan_ready_viewed"],
  ["Paywall viewed", "paywall_viewed"],
  ["Plan changed", "paywall_plan_selected"],
  ["Purchase started", "purchase_started"],
  ["Purchase failed or cancelled", "purchase_failed"],
  ["Purchased", "purchase_completed"],
  ...PRODUCTS.map((p) => [`  ${p}`, `purchase_completed.${p}`] as const),
  ["Restored", "purchase_restored"],
  ["Not Now", "paywall_dismissed"],
  ["Into the app", "onboarding_completed"],
];

const percent = (n: number, of: number) => (of ? `${((n / of) * 100).toFixed(1)}%` : "-");

/** Sums the rows per strategy; paid is purchases (restores are people who'd already paid). */
export function funnelReport(rows: FunnelRow[]) {
  const strategies = Object.fromEntries(STRATEGIES.map((strategy) => {
    const counts: Record<string, number> = {};
    for (const row of rows.filter((r) => r.strategy === strategy)) {
      for (const [key, n] of Object.entries(row.counts)) counts[key] = (counts[key] ?? 0) + n;
    }
    const firstLaunches = counts["onboarding_screen_viewed.hero"] ?? 0;
    const paid = counts.purchase_completed ?? 0;
    return [strategy, { counts, firstLaunches, paid, rate: firstLaunches ? paid / firstLaunches : null }];
  })) as Record<Strategy, { counts: Record<string, number>; firstLaunches: number; paid: number; rate: number | null }>;

  const width = Math.max(...STEPS.map(([label]) => label.length)) + 2;
  const lines: string[] = [];
  for (const strategy of STRATEGIES) {
    const s = strategies[strategy];
    if (!s.firstLaunches) {
      lines.push(`${strategy}: no first launches yet`, "");
      continue;
    }
    lines.push(`${strategy}: first-launch-to-paid ${s.paid}/${s.firstLaunches} = ${percent(s.paid, s.firstLaunches)}` +
      ` (benchmark ${BENCHMARK * 100}%+ download-to-paid, AbMaxx; ours counts first launches, not downloads)`);
    for (const [label, key] of STEPS) {
      const n = s.counts[key] ?? 0;
      lines.push(`  ${label.padEnd(width)}${String(n).padStart(6)}  ${percent(n, s.firstLaunches).padStart(6)}`);
    }
    lines.push("");
  }
  return { strategies, text: lines.join("\n") };
}
