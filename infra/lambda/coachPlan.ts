import { ConditionalCheckFailedException, DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import { stripeConfig } from "./gifts.ts";
import { stripe } from "./stripe.ts";
import { appStoreHas, effective, HAS_PLAN, shownPlan, stripeHas, supersedes, type AppStoreState, type PlanRecord } from "./plan.ts";

export { HAS_PLAN, shownPlan, type CoachPlan, type PlanRecord } from "./plan.ts";

/**
 * FIT-144: the coach plan (FIT-133, author 2026-10-17: $19.99/month or $199/year), sold on the web through Stripe.
 * Checkout makes the subscription; Stripe's subscription events (stripeWebhook) keep USER#uid COACHPLAN up to date;
 * the customer portal changes the card, the interval or cancels. During the beta coaching is free whatever this says
 * (FIT-148 ends that).
 *
 * FIT-190: Pro, sold to the connector's users the same way (author, 2026-10-21: $5.99/month or $39.99/year), kept in
 * USER#uid PROPLAN. Which plan a subscription is comes from its price's lookup key.
 *
 * FIT-327: Pro is on sale again for someone training themselves, bought from Billing on the dashboard.
 *
 * FIT-295: the consumer app's plan (FIT-281, trainer_yearly) is gone with the app; Barbrabell is free (business model v2).
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;

/** The prices' lookup keys, the same in test and live mode (FIT-143), and where each plan is kept. */
export const PLANS = {
  coach: { keys: { month: "coach_monthly", year: "coach_yearly" }, sk: "COACHPLAN" },
  pro: { keys: { month: "pro_monthly", year: "pro_yearly" }, sk: "PROPLAN" },
} as const;
export type Kind = keyof typeof PLANS;
export const LOOKUP_KEYS = PLANS.coach.keys;
export type Interval = keyof typeof LOOKUP_KEYS;

/** Where Checkout and the portal come back to. Pro's buyers come from Claude, so a purchase lands on the site's page that sends them back. */
const returns = (kind: Kind, origin: string) => kind === "coach"
  ? { success: `${origin}/billing?started=1`, cancel: `${origin}/billing`, portal: `${origin}/billing` }
  : { success: `${origin}/pro/thanks`, cancel: `${origin}/app/billing`, portal: `${origin}/app/billing` };

/** Checkout for the plan, as a subscription; the uid rides on the subscription so its events find the account. */
export function checkoutParams(uid: string, customer: string, price: string, origin: string, kind: Kind = "coach") {
  return {
    mode: "subscription",
    managed_payments: { enabled: true },
    customer,
    client_reference_id: uid,
    line_items: [{ price, quantity: 1 }],
    subscription_data: { metadata: { uid } },
    success_url: returns(kind, origin).success,
    cancel_url: returns(kind, origin).cancel,
  };
}

export interface Subscription {
  id: string;
  status: string;
  customer: string;
  cancel_at_period_end?: boolean;
  metadata?: Record<string, string> | null;
  items?: { data: { current_period_end?: number; price?: { lookup_key?: string | null; recurring?: { interval?: string } | null } }[] };
}

/** Which plan a subscription is, by its price's lookup key; a price without one is the coach plan's. */
export function kindOf(sub: Subscription): Kind | undefined {
  const key = sub.items?.data[0]?.price?.lookup_key;
  return !key ? "coach" : (Object.keys(PLANS) as Kind[]).find((k) => Object.values(PLANS[k].keys).includes(key as never));
}

/** What a subscription event says about the account's plans. */
export function recordFrom(sub: Subscription, eventAt: number): { uid: string; kind: Kind; record: PlanRecord } | undefined {
  const uid = sub.metadata?.uid;
  if (!uid) return undefined;
  const item = sub.items?.data[0];
  const kind = kindOf(sub);
  if (!kind) return undefined;
  return {
    uid,
    kind,
    record: {
      customer: sub.customer,
      subscription: sub.id,
      status: sub.status,
      interval: item?.price?.recurring?.interval,
      renews: item?.current_period_end ? new Date(item.current_period_end * 1000).toISOString() : undefined,
      cancelsAtEnd: sub.cancel_at_period_end ?? false,
      eventAt,
    },
  };
}

const planKey = (uid: string, kind: Kind = "coach") => ({ PK: `USER#${uid}`, SK: PLANS[kind].sk });

export async function planRecord(uid: string, kind: Kind = "coach"): Promise<PlanRecord | undefined> {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: planKey(uid, kind) }));
  return Item as PlanRecord | undefined;
}

/** FIT-437: whether the account has the plan now, from either store. */
export async function hasPlan(uid: string, kind: Kind, now = new Date()): Promise<boolean> {
  return effective(await planRecord(uid, kind), now).has;
}

/** FIT-189: whether a Stripe event replaces the Stripe subscription kept (plan.ts supersedes). */
export function replaces(kept: PlanRecord | undefined, event: PlanRecord): boolean {
  return supersedes(kept && { id: kept.subscription, has: stripeHas(kept), eventAt: kept.eventAt },
                    { id: event.subscription, has: stripeHas(event), eventAt: event.eventAt! });
}

/** FIT-437: the same guard for the App Store's subscription kept (by original transaction). */
export function replacesAppStore(kept: AppStoreState | undefined, event: AppStoreState, now = new Date()): boolean {
  return supersedes(kept && { id: kept.originalTransactionId, has: appStoreHas(kept, now), eventAt: kept.eventAt },
                    { id: event.originalTransactionId, has: appStoreHas(event, now), eventAt: event.eventAt });
}

export type StoreUpdate = { source: "stripe"; record: PlanRecord } | { source: "appstore"; state: AppStoreState };

/**
 * FIT-437: the one way either store's event reaches a plan's record. Each store writes only its own state (Stripe's
 * top-level fields, the App Store's `appStore`), so one store's event never takes the plan from the other; within a
 * store FIT-189's guard keeps the subscription that has the plan. Written only if the store's state is still the one
 * read (its eventAt), read again up to 3 times. Whether it was saved.
 */
export async function saveState(uid: string, kind: Kind, update: StoreUpdate, now = new Date()): Promise<boolean> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const kept = await planRecord(uid, kind);
    const keptAt = update.source === "stripe" ? kept?.eventAt : kept?.appStore?.eventAt;
    if (update.source === "stripe" ? !replaces(kept, update.record) : !replacesAppStore(kept?.appStore, update.state, now)) {
      const [keptId, id, status] = update.source === "stripe" ? [kept?.subscription, update.record.subscription, update.record.status]
        : [kept?.appStore?.originalTransactionId, update.state.originalTransactionId, update.state.status];
      if (keptId !== id) console.error("Kept the plan's subscription", keptId, "over", id, status);
      return false;
    }
    // Unchanged since read: the same event time, or none yet.
    const seen = keptAt !== undefined;
    const write = update.source === "stripe" ? stripeWrite(update.record, seen)
      : { UpdateExpression: "SET appStore = :appStore", ConditionExpression: seen ? "appStore.eventAt = :seen" : "attribute_not_exists(appStore.eventAt)",
          ExpressionAttributeValues: { ":appStore": update.state } as Record<string, unknown> };
    if (seen) write.ExpressionAttributeValues[":seen"] = keptAt;
    try {
      await db.send(new UpdateCommand({ TableName: TABLE(), Key: planKey(uid, kind), ...write }));
      return true;
    } catch (error) {
      if (!(error instanceof ConditionalCheckFailedException)) throw error;
    }
  }
  return false;
}

/** Stripe's fields, set where FIT-144 kept them; an interval or renewal the event doesn't have is removed. */
function stripeWrite(record: PlanRecord, seen: boolean) {
  const fields = Object.entries(record).filter(([k, v]) => v !== undefined && k !== "appStore");
  const removed = (["interval", "renews"] as const).filter((k) => record[k] === undefined);
  return {
    UpdateExpression: `SET ${fields.map(([k]) => `#${k} = :${k}`).join(", ")}${removed.length ? ` REMOVE ${removed.map((k) => `#${k}`).join(", ")}` : ""}`,
    ConditionExpression: seen ? "eventAt = :seen" : "attribute_not_exists(eventAt)",
    ExpressionAttributeNames: Object.fromEntries([...fields.map(([k]) => k), ...removed].map((k) => [`#${k}`, k])) as Record<string, string> | undefined,
    ExpressionAttributeValues: Object.fromEntries(fields.map(([k, v]) => [`:${k}`, v])) as Record<string, unknown>,
  };
}

/**
 * Saves a subscription event if it replaces the plan kept (saveState). FIT-212: a subscription already kept as the
 * other plan has switched plans outside our portals; saving it would start a second plan and leave the first at its
 * last status, so it's left for the author to sort out.
 */
export async function saveSubscription(sub: Subscription, eventAt: number): Promise<void> {
  const made = recordFrom(sub, eventAt);
  if (!made) return;
  for (const other of (Object.keys(PLANS) as Kind[]).filter((k) => k !== made.kind)) {
    if ((await planRecord(made.uid, other))?.subscription === sub.id) {
      console.error("Subscription switched plans", sub.id, other, "to", made.kind);
      return;
    }
  }
  await saveState(made.uid, made.kind, { source: "stripe", record: made.record });
}

export class PlanError extends Error {}

const prices: Partial<Record<Kind, { at: number; ids: Partial<Record<Interval, string>> }>> = {};
/** The plan's price ids by lookup key, looked up at most every 5 minutes; none until the author has made them (FIT-143). */
export async function planPrices(key: string, now = Date.now(), kind: Kind = "coach"): Promise<Partial<Record<Interval, string>>> {
  const cached = prices[kind];
  if (cached && now - cached.at <= 5 * 60_000) return cached.ids;
  const keys = PLANS[kind].keys;
  const query = Object.values(keys).map((k) => `lookup_keys[]=${k}`).join("&");
  const found = await stripe<{ data: { id: string; lookup_key: string | null }[] }>(key, `prices?active=true&${query}`);
  const ids: Partial<Record<Interval, string>> = {};
  for (const [interval, lookup] of Object.entries(keys) as [Interval, string][]) {
    const price = found.data.find((p) => p.lookup_key === lookup);
    if (price) ids[interval] = price.id;
  }
  prices[kind] = { at: now, ids };
  return ids;
}

/** On sale once there's a Stripe secret and every price the plan has. */
export async function onSale(kind: Kind = "coach"): Promise<boolean> {
  const keys = await stripeConfig();
  if (!keys) return false;
  const ids = await planPrices(keys.secretKey, Date.now(), kind);
  return (Object.keys(PLANS[kind].keys) as Interval[]).every((interval) => Boolean(ids[interval]));
}

/** The account's Stripe customer, made once and kept. */
async function customerFor(key: string, uid: string, email: string | undefined, kind: Kind): Promise<string> {
  const known = (await planRecord(uid, kind))?.customer;
  if (known) return known;
  const made = await stripe<{ id: string }>(key, "customers", { email, metadata: { uid } });
  try {
    await db.send(new UpdateCommand({
      TableName: TABLE(),
      Key: planKey(uid, kind),
      UpdateExpression: "SET customer = :c",
      ConditionExpression: "attribute_not_exists(customer)",
      ExpressionAttributeValues: { ":c": made.id },
    }));
    return made.id;
  } catch (error) {
    // Two clicks at once: keep the first one's customer.
    if (error instanceof ConditionalCheckFailedException) return (await planRecord(uid, kind))!.customer!;
    throw error;
  }
}

const already = (kind: Kind) => kind === "coach" ? "You already have the coach plan. Use Manage billing to change it."
  : "You already have Pro. Use Manage billing to change it.";

const alreadyInApp = (kind: Kind) => `You already have ${kind === "coach" ? "Coach Pro" : "Pro"} through the App Store. Manage it in your iPhone's Settings.`;

/** The customer's subscription to the plan that still has it, if Stripe has one (the list leaves out canceled ones). */
export async function activeSubscription(key: string, customer: string, kind: Kind): Promise<Subscription | undefined> {
  const found = await stripe<{ data: Subscription[] }>(key, `subscriptions?customer=${customer}&limit=100`);
  return found.data.find((s) => HAS_PLAN.includes(s.status) && kindOf(s) === kind);
}

/** A Checkout URL for the plan, or undefined while it isn't on sale. */
export async function start(uid: string, interval: string, email?: string, origin = process.env.APP_ORIGIN!, kind: Kind = "coach"): Promise<string | undefined> {
  if (!(interval in PLANS[kind].keys)) throw new PlanError("Choose monthly or yearly.");
  const keys = await stripeConfig();
  if (!keys) return undefined;
  const current = await planRecord(uid, kind);
  if (current?.status && !["canceled", "incomplete_expired"].includes(current.status)) throw new PlanError(already(kind));
  // FIT-437: bought in the App Store already; a second Checkout would pay twice for one plan.
  if (appStoreHas(current?.appStore)) throw new PlanError(alreadyInApp(kind));
  // FIT-189: a late or missed webhook leaves the record behind Stripe; ask Stripe before a second Checkout. A key that
  // can't read subscriptions (a restricted key without the permission) goes on to Checkout as before.
  const live = current?.customer && await activeSubscription(keys.secretKey, current.customer, kind).catch((error) => {
    console.error("Couldn't list subscriptions", (error as Error).message);
    return undefined;
  });
  if (live) {
    await saveSubscription({ ...live, metadata: { ...live.metadata, uid } }, 0);
    throw new PlanError(already(kind));
  }
  const price = (await planPrices(keys.secretKey, Date.now(), kind))[interval as Interval];
  if (!price) {
    console.error("No price with lookup key", (PLANS[kind].keys as Record<string, string>)[interval]);
    return undefined;
  }
  const customer = await customerFor(keys.secretKey, uid, email, kind);
  const session = await stripe<{ url: string }>(keys.secretKey, "checkout/sessions", checkoutParams(uid, customer, price, origin, kind));
  return session.url;
}

/** FIT-212: a portal that switches only between the plan's own two prices, so a subscription can't cross plans. */
export function portalConfigParams(kind: Kind, product: string, prices: string[]) {
  return {
    name: kind === "coach" ? "Coach plan" : "Pro",
    metadata: { plan: kind },
    features: {
      payment_method_update: { enabled: true },
      invoice_history: { enabled: true },
      subscription_cancel: { enabled: true, mode: "at_period_end" },
      subscription_update: { enabled: true, default_allowed_updates: ["price"], proration_behavior: "create_prorations", products: [{ product, prices }] },
    },
  };
}

const configs: Partial<Record<Kind, { at: number; id: string }>> = {};
/**
 * The plan's portal configuration, found by its metadata and made the first time it's needed, so test and live mode
 * set themselves up alike; undefined (Stripe's default portal) until the plan has both prices.
 */
export async function portalConfiguration(key: string, now = Date.now(), kind: Kind = "coach"): Promise<string | undefined> {
  const cached = configs[kind];
  if (cached && now - cached.at <= 5 * 60_000) return cached.id;
  const found = await stripe<{ data: { id: string; metadata?: Record<string, string> | null }[] }>(key, "billing_portal/configurations?active=true&limit=100");
  let id = found.data.find((c) => c.metadata?.plan === kind)?.id;
  if (!id) {
    const ids = await planPrices(key, now, kind);
    if (!ids.month || !ids.year) return undefined;
    const { product } = await stripe<{ product: string }>(key, `prices/${ids.month}`);
    id = (await stripe<{ id: string }>(key, "billing_portal/configurations", portalConfigParams(kind, product, [ids.month, ids.year]))).id;
  }
  configs[kind] = { at: now, id };
  return id;
}

/** Stripe's customer portal for the account, or undefined without a customer. */
export async function portal(uid: string, origin = process.env.APP_ORIGIN!, kind: Kind = "coach"): Promise<string | undefined> {
  const keys = await stripeConfig();
  const customer = (await planRecord(uid, kind))?.customer;
  if (!keys || !customer) return undefined;
  // The default portal switches no plans in live (FIT-212), so it's a safe fallback, e.g. for a key without the permission.
  const configuration = await portalConfiguration(keys.secretKey, Date.now(), kind).catch((error) => {
    console.error("No portal configuration", kind, (error as Error).message);
    return undefined;
  });
  const session = await stripe<{ url: string }>(keys.secretKey, "billing_portal/sessions", { customer, configuration, return_url: returns(kind, origin).portal });
  return session.url;
}

/** APP_ORIGIN is the dashboard (…/app); Pro's returns are written from the site's root. */
const siteOrigin = () => new URL(process.env.APP_ORIGIN!).origin;

export async function handler(event: AppSyncResolverEvent<{ interval?: string }>) {
  const identity = event.identity as AppSyncIdentityCognito | null;
  if (!identity?.sub) throw new Error("Sign in first.");
  switch (event.info.fieldName) {
    case "coachPlan":
      return shownPlan(await onSale(), await planRecord(identity.sub));
    case "startCoachPlan":
      return (await start(identity.sub, event.arguments.interval ?? "", identity.claims?.email as string | undefined)) ?? null;
    case "coachBillingPortal":
      return (await portal(identity.sub)) ?? null;
    case "proPlan":
      return shownPlan(await onSale("pro"), await planRecord(identity.sub, "pro"));
    case "startProPlan":
      return (await start(identity.sub, event.arguments.interval ?? "", identity.claims?.email as string | undefined, siteOrigin(), "pro")) ?? null;
    case "proBillingPortal":
      return (await portal(identity.sub, siteOrigin(), "pro")) ?? null;
    default:
      throw new Error(`No field ${event.info.fieldName}`);
  }
}
