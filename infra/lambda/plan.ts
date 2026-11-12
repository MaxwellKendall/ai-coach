/**
 * FIT-437: one entitlement per plan, whichever store sold it. USER#uid PROPLAN (Lifter Pro) and USER#uid COACHPLAN
 * (Coach Pro) each keep two stores' states side by side, written separately so neither can overwrite the other:
 *
 * - Stripe's at the record's top level (customer, subscription, status, interval, renews, cancelsAtEnd, eventAt),
 *   where FIT-144 kept it, so records already saved need no migration.
 * - The App Store's in `appStores`, one AppStoreState per subscription (original transaction id), written from App
 *   Store Server Notifications and the transactions the app registers after a purchase or restore. Two Apple IDs can
 *   each subscribe for the same account; each keeps its own state, so one ending never hides another still paid.
 *
 * The plan is had while either store has it (`effective`). No module here talks to AWS, so scripts can use it.
 */

/** Stripe's statuses that still have the plan: a payment that failed keeps it while Stripe retries. */
export const HAS_PLAN = ["active", "trialing", "past_due"];

/**
 * The App Store's states: active, trialing (an introductory free trial), in_grace (a renewal failed and Apple's
 * billing grace period keeps the plan), billing_retry (failed, out of grace, Apple still retrying: no plan),
 * expired, refunded or revoked (Family Sharing taken back).
 */
export type AppStoreStatus = "active" | "trialing" | "in_grace" | "billing_retry" | "expired" | "refunded" | "revoked";

export interface AppStoreState {
  originalTransactionId: string;
  /** The transaction (one billing period) this state was read from. */
  transactionId?: string;
  productId: string;
  status: AppStoreStatus;
  interval?: string;
  /** When the transaction's period was bought (ISO): orders periods, so an older one's refund can't end a newer one. */
  purchasedAt?: string;
  /** When the current period ends (ISO). */
  expiresAt?: string;
  /** When the billing grace period ends (ISO), while in_grace. */
  graceUntil?: string;
  autoRenew: boolean;
  environment: string;
  /** Apple's signedDate (ms) of what this was read from: the newest wins for the same subscription. */
  eventAt: number;
}

export interface PlanRecord {
  customer?: string;
  subscription?: string;
  status?: string;
  interval?: string;
  renews?: string;
  cancelsAtEnd?: boolean;
  eventAt?: number;
  /** The App Store's subscriptions by original transaction id. */
  appStores?: Record<string, AppStoreState>;
  /** Bumped on every write of appStores, which is written only if unchanged since read. */
  appStoreVersion?: number;
}

/** FIT-437: kept under this key when an account is deleted, so its App Store subscriptions aren't saved to it again. */
export const deletedAccountKey = (uid: string) => ({ PK: `DELETEDACCOUNT#${uid}`, SK: "DELETEDACCOUNT" });

export type Source = "stripe" | "appstore";

export const stripeHas = (record?: PlanRecord) => HAS_PLAN.includes(record?.status ?? "");

/** Whether the App Store's state still has the plan now; a state past its date has it no more, though a notification was missed. */
export function appStoreHas(state: AppStoreState | undefined, now = new Date()): boolean {
  if (!state) return false;
  const until = (iso?: string) => iso === undefined || new Date(iso) > now;
  if (state.status === "active" || state.status === "trialing") return until(state.expiresAt);
  if (state.status === "in_grace") return until(state.graceUntil);
  return false;
}

export const appStoreStates = (record?: PlanRecord): AppStoreState[] => Object.values(record?.appStores ?? {});

/** Whether any of the account's App Store subscriptions has the plan now. */
export const appStoreHasAny = (record: PlanRecord | undefined, now = new Date()) => appStoreStates(record).some((s) => appStoreHas(s, now));

/** The App Store subscription to show: of those that have the plan, the one that runs longest; else the latest news. */
export function appStoreShown(record: PlanRecord | undefined, now = new Date()): AppStoreState | undefined {
  const ends = (s: AppStoreState) => Date.parse((s.status === "in_grace" ? s.graceUntil : s.expiresAt) ?? "") || Infinity;
  const having = appStoreStates(record).filter((s) => appStoreHas(s, now)).sort((a, b) => ends(b) - ends(a));
  return having[0] ?? appStoreStates(record).sort((a, b) => b.eventAt - a.eventAt)[0];
}

export interface Effective {
  has: boolean;
  /** The store that has it (Stripe's first, since the web can manage it), else none. */
  source?: Source;
  /** FIT-437: paying twice for the same plan (both stores, or two Apple IDs): Billing suggests cancelling one. */
  paidTwice: boolean;
}

export function effective(record: PlanRecord | undefined, now = new Date()): Effective {
  const stripe = stripeHas(record);
  const apple = appStoreStates(record).filter((s) => appStoreHas(s, now)).length;
  return { has: stripe || apple > 0, source: stripe ? "stripe" : apple ? "appstore" : undefined, paidTwice: Number(stripe) + apple > 1 };
}

/**
 * FIT-189's guard, for either store's subscriptions: for the same subscription the newest event wins. Another
 * subscription's event (a duplicate paid twice) never takes away a plan the kept one still has: one that has the
 * plan replaces it if newer, or whenever the kept one has ended.
 */
export function supersedes(kept: { id?: string; has: boolean; eventAt?: number } | undefined, event: { id?: string; has: boolean; eventAt: number }): boolean {
  const newer = kept?.eventAt === undefined || kept.eventAt <= event.eventAt;
  if (!kept?.id || kept.id === event.id) return newer;
  if (!event.has) return !kept.has && newer;
  return !kept.has || newer;
}

export interface CoachPlan {
  onSale: boolean;
  /** "none", or Stripe's subscription status: trialing, active, past_due, unpaid, canceled… (App Store states in the same words). */
  status: string;
  interval?: string;
  renews?: string;
  cancelsAtEnd: boolean;
  /** FIT-437: which store the status is from: stripe or appstore; none without a plan. */
  source?: Source;
  paidTwice: boolean;
}

/** The App Store's state in Stripe's words, which the app and the web already read (HAS_PLAN). */
const STRIPE_WORDS: Record<AppStoreStatus, string> = {
  active: "active", trialing: "trialing", in_grace: "past_due", billing_retry: "unpaid", expired: "canceled", refunded: "canceled", revoked: "canceled",
};

/** The plan as the app and Billing show it: the store that has it, or Stripe's last word, or the App Store's. */
export function shownPlan(onSale: boolean, record?: PlanRecord, now = new Date()): CoachPlan {
  const { source, paidTwice } = effective(record, now);
  const apple = appStoreShown(record, now);
  if (apple && (source === "appstore" || (!source && !record?.status))) {
    return {
      onSale,
      // Past its date without the notification that says so: ended.
      status: !source && HAS_PLAN.includes(STRIPE_WORDS[apple.status]) ? "canceled" : STRIPE_WORDS[apple.status],
      interval: apple.interval,
      renews: apple.expiresAt,
      cancelsAtEnd: !apple.autoRenew,
      source: "appstore",
      paidTwice,
    };
  }
  return {
    onSale,
    status: record?.status ?? "none",
    interval: record?.interval,
    renews: record?.renews,
    cancelsAtEnd: record?.cancelsAtEnd ?? false,
    source: record?.status ? "stripe" : undefined,
    paidTwice,
  };
}
