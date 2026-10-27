import { ConditionalCheckFailedException, DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import programs from "../../Resources/Seed/programs.json" with { type: "json" };
import { KIT, type ReadyProgram } from "../../shared/readyPrograms.ts";
import { stripeConfig } from "./gifts.ts";
import { stripe } from "./stripe.ts";

/**
 * FIT-144: the coach plan (FIT-133, author 2026-10-17: $19.99/month or $199/year), sold on the web through Stripe.
 * Checkout makes the subscription; Stripe's subscription events (stripeWebhook) keep USER#uid COACHPLAN up to date;
 * the customer portal changes the card, the interval or cancels. During the beta coaching is free whatever this says
 * (FIT-148 ends that).
 *
 * FIT-190: Pro, sold to the connector's users the same way (author, 2026-10-21: $5.99/month or $39.99/year), kept in
 * USER#uid PROPLAN. Which plan a subscription is comes from its price's lookup key.
 *
 * FIT-281: the consumer app's plan, bought from the web quiz: annual only, with a free trial (author, 2026-10-27), kept
 * in USER#uid TRAINERPLAN. The quiz's answers are kept with it (USER#uid QUIZ), so the app opens the plan revealed.
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;

/** The prices' lookup keys, the same in test and live mode (FIT-143), and where each plan is kept. */
export const PLANS = {
  coach: { keys: { month: "coach_monthly", year: "coach_yearly" }, sk: "COACHPLAN" },
  pro: { keys: { month: "pro_monthly", year: "pro_yearly" }, sk: "PROPLAN" },
  trainer: { keys: { year: "trainer_yearly" }, sk: "TRAINERPLAN" },
} as const;
/** FIT-281: the consumer plan's free trial, as the App Store's (Liftplan.storekit). */
export const TRAINER_TRIAL_DAYS = 7;
export type Kind = keyof typeof PLANS;
export const LOOKUP_KEYS = PLANS.coach.keys;
export type Interval = keyof typeof LOOKUP_KEYS;

/** Stripe's statuses that still have the plan: a payment that failed keeps it while Stripe retries. */
export const HAS_PLAN = ["active", "trialing", "past_due"];

/** Where Checkout and the portal come back to. Pro's buyers come from Claude, so they land on the site's pages. */
const returns = (kind: Kind, origin: string) => kind === "coach"
  ? { success: `${origin}/billing?started=1`, cancel: `${origin}/billing`, portal: `${origin}/billing` }
  : kind === "trainer"
  ? { success: `${origin}/start/thanks`, cancel: `${origin}/start`, portal: `${origin}/start/thanks` }
  : { success: `${origin}/pro/thanks`, cancel: `${origin}/claude`, portal: `${origin}/claude` };

export interface PlanRecord {
  customer?: string;
  subscription?: string;
  status?: string;
  interval?: string;
  renews?: string;
  cancelsAtEnd?: boolean;
  eventAt?: number;
}

export interface CoachPlan {
  onSale: boolean;
  /** "none", or Stripe's subscription status: trialing, active, past_due, unpaid, canceled, incomplete… */
  status: string;
  interval?: string;
  renews?: string;
  cancelsAtEnd: boolean;
}

export const shownPlan = (onSale: boolean, record?: PlanRecord): CoachPlan => ({
  onSale,
  status: record?.status ?? "none",
  interval: record?.interval,
  renews: record?.renews,
  cancelsAtEnd: record?.cancelsAtEnd ?? false,
});

/** Checkout for the plan, as a subscription; the uid rides on the subscription so its events find the account. */
export function checkoutParams(uid: string, customer: string, price: string, origin: string, kind: Kind = "coach") {
  return {
    mode: "subscription",
    managed_payments: { enabled: true },
    customer,
    client_reference_id: uid,
    line_items: [{ price, quantity: 1 }],
    subscription_data: { metadata: { uid }, ...(kind === "trainer" ? { trial_period_days: TRAINER_TRIAL_DAYS } : {}) },
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

/**
 * FIT-189: whether an event replaces the plan kept. For the same subscription the newest event wins (Stripe doesn't
 * promise their order). Another subscription's event (a duplicate the coach paid for twice) never takes away a plan
 * the kept one still has: one that has the plan replaces it if newer, or whenever the kept one has ended.
 */
export function replaces(kept: PlanRecord | undefined, event: PlanRecord): boolean {
  const newer = kept?.eventAt === undefined || kept.eventAt <= event.eventAt!;
  if (!kept?.subscription || kept.subscription === event.subscription) return newer;
  const keptHas = HAS_PLAN.includes(kept.status ?? "");
  if (!HAS_PLAN.includes(event.status ?? "")) return !keptHas && newer;
  return !keptHas || newer;
}

/**
 * Saves a subscription event if it replaces the plan kept, writing only if the record is still the one read. FIT-212:
 * a subscription already kept as the other plan has switched plans outside our portals; saving it would start a second
 * plan and leave the first at its last status, so it's left for the author to sort out.
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
  const fields = Object.entries(made.record).filter(([, v]) => v !== undefined);
  const removed = (["interval", "renews"] as const).filter((k) => made.record[k] === undefined);
  for (let attempt = 0; attempt < 3; attempt++) {
    const kept = await planRecord(made.uid, made.kind);
    if (!replaces(kept, made.record)) {
      if (kept?.subscription !== sub.id) console.error("Kept the plan's subscription", kept?.subscription, "over", sub.id, sub.status);
      return;
    }
    // Unchanged since read: the same event time, or none yet.
    const seen = kept?.eventAt !== undefined;
    try {
      await db.send(new UpdateCommand({
        TableName: TABLE(),
        Key: planKey(made.uid, made.kind),
        UpdateExpression: `SET ${fields.map(([k]) => `#${k} = :${k}`).join(", ")}${removed.length ? ` REMOVE ${removed.map((k) => `#${k}`).join(", ")}` : ""}`,
        ConditionExpression: seen ? "eventAt = :seen" : "attribute_not_exists(eventAt)",
        ExpressionAttributeNames: Object.fromEntries([...fields.map(([k]) => k), ...removed].map((k) => [`#${k}`, k])),
        ExpressionAttributeValues: { ...Object.fromEntries(fields.map(([k, v]) => [`:${k}`, v])), ...(seen ? { ":seen": kept.eventAt } : {}) },
      }));
      return;
    } catch (error) {
      if (!(error instanceof ConditionalCheckFailedException)) throw error;
    }
  }
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
  : kind === "trainer" ? "You already have the plan. Open the app and sign in with this account."
  : "They already have Pro: manage_subscription changes it.";

/** The customer's subscription to the plan that still has it, if Stripe has one (the list leaves out canceled ones). */
export async function activeSubscription(key: string, customer: string, kind: Kind): Promise<Subscription | undefined> {
  const found = await stripe<{ data: Subscription[] }>(key, `subscriptions?customer=${customer}&limit=100`);
  return found.data.find((s) => HAS_PLAN.includes(s.status) && kindOf(s) === kind);
}

/** A Checkout URL for the plan, or undefined while it isn't on sale. */
export async function start(uid: string, interval: string, email?: string, origin = process.env.APP_ORIGIN!, kind: Kind = "coach"): Promise<string | undefined> {
  if (!(interval in PLANS[kind].keys)) throw new PlanError(kind === "trainer" ? "The plan is yearly." : "Choose monthly or yearly.");
  const keys = await stripeConfig();
  if (!keys) return undefined;
  const current = await planRecord(uid, kind);
  if (current?.status && !["canceled", "incomplete_expired"].includes(current.status)) throw new PlanError(already(kind));
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

/** FIT-281: the quiz's answers the plan was bought with: the program, the equipment ticked and the training days. */
export interface QuizAnswers {
  slug: string;
  have: string[];
  days: number[];
}

/** The answers as the web sent them, checked against the program: its days a week and the equipment it needs. */
export function quizAnswers(value: unknown): QuizAnswers {
  let given: Partial<QuizAnswers> | undefined;
  try {
    given = (typeof value === "string" ? JSON.parse(value) : value) as Partial<QuizAnswers> | undefined;
  } catch {
    throw new PlanError("Take the quiz first.");
  }
  const program = (programs as ReadyProgram[]).find((p) => p.slug === given?.slug);
  if (!program) throw new PlanError("Take the quiz first.");
  const known = new Set(KIT.flatMap((k) => k.equipment));
  const have = [...new Set((Array.isArray(given?.have) ? given.have : []).filter((e) => typeof e === "string" && known.has(e)))];
  const days = [...new Set((Array.isArray(given?.days) ? given.days : []).filter((d) => Number.isInteger(d) && d >= 0 && d <= 6))]
    .sort((a, b) => a - b);
  if (!program.days.includes(days.length)) throw new PlanError(`${program.name} is ${program.days.join(" or ")} days a week.`);
  if (!program.equipment.every((e) => have.includes(e))) throw new PlanError(`${program.name} needs equipment you didn't tick.`);
  return { slug: program.slug, have, days };
}

const quizKey = (uid: string) => ({ PK: `USER#${uid}`, SK: "QUIZ" });

async function saveQuiz(uid: string, answers: QuizAnswers, now = new Date()) {
  await db.send(new UpdateCommand({
    TableName: TABLE(),
    Key: quizKey(uid),
    UpdateExpression: "SET answers = :a, updatedAt = :t",
    ExpressionAttributeValues: { ":a": answers, ":t": now.toISOString() },
  }));
}

/** FIT-281: the consumer plan as the app asks for it: Stripe's status, and the answers it was bought with. */
export async function trainerPlan(uid: string) {
  const [record, quiz] = await Promise.all([
    planRecord(uid, "trainer"),
    db.send(new GetCommand({ TableName: TABLE(), Key: quizKey(uid) })).then((r) => r.Item?.answers as QuizAnswers | undefined),
  ]);
  return { status: record?.status ?? "none", renews: record?.renews ?? null, answers: quiz ? JSON.stringify(quiz) : null };
}

export async function handler(event: AppSyncResolverEvent<{ interval?: string; answers?: string }>) {
  const identity = event.identity as AppSyncIdentityCognito | null;
  if (!identity?.sub) throw new Error("Sign in first.");
  switch (event.info.fieldName) {
    case "coachPlan":
      return shownPlan(await onSale(), await planRecord(identity.sub));
    case "startCoachPlan":
      return (await start(identity.sub, event.arguments.interval ?? "", identity.claims?.email as string | undefined)) ?? null;
    case "coachBillingPortal":
      return (await portal(identity.sub)) ?? null;
    case "trainerPlan":
      return trainerPlan(identity.sub);
    case "startTrainerPlan": {
      const answers = quizAnswers(event.arguments.answers);
      await saveQuiz(identity.sub, answers);
      return (await start(identity.sub, "year", identity.claims?.email as string | undefined, process.env.APP_ORIGIN, "trainer")) ?? null;
    }
    default:
      throw new Error(`No field ${event.info.fieldName}`);
  }
}
