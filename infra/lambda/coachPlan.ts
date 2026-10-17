import { ConditionalCheckFailedException, DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import { stripeConfig } from "./gifts.ts";
import { stripe } from "./stripe.ts";

/**
 * FIT-144: the coach plan (FIT-133, author 2026-10-17: $19.99/month or $199/year), sold on the web through Stripe.
 * Checkout makes the subscription; Stripe's subscription events (stripeWebhook) keep USER#uid COACHPLAN up to date;
 * the customer portal changes the card, the interval or cancels. During the beta coaching is free whatever this says
 * (FIT-148 ends that).
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;

/** The prices' lookup keys, the same in test and live mode (FIT-143). */
export const LOOKUP_KEYS = { month: "coach_monthly", year: "coach_yearly" } as const;
export type Interval = keyof typeof LOOKUP_KEYS;

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
export function checkoutParams(uid: string, customer: string, price: string, origin: string) {
  return {
    mode: "subscription",
    managed_payments: { enabled: true },
    customer,
    client_reference_id: uid,
    line_items: [{ price, quantity: 1 }],
    subscription_data: { metadata: { uid } },
    success_url: `${origin}/billing?started=1`,
    cancel_url: `${origin}/billing`,
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

/** What a subscription event says about the account's plan. */
export function recordFrom(sub: Subscription, eventAt: number): { uid: string; record: PlanRecord } | undefined {
  const uid = sub.metadata?.uid;
  if (!uid) return undefined;
  const item = sub.items?.data[0];
  const key = item?.price?.lookup_key;
  if (key && !Object.values(LOOKUP_KEYS).includes(key as never)) return undefined;
  return {
    uid,
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

const planKey = (uid: string) => ({ PK: `USER#${uid}`, SK: "COACHPLAN" });

export async function planRecord(uid: string): Promise<PlanRecord | undefined> {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: planKey(uid) }));
  return Item as PlanRecord | undefined;
}

/** Saves a subscription event, unless a newer one already has (Stripe doesn't promise their order). */
export async function saveSubscription(sub: Subscription, eventAt: number): Promise<void> {
  const made = recordFrom(sub, eventAt);
  if (!made) return;
  const fields = Object.entries(made.record).filter(([, v]) => v !== undefined);
  const removed = (["interval", "renews"] as const).filter((k) => made.record[k] === undefined);
  await db.send(new UpdateCommand({
    TableName: TABLE(),
    Key: planKey(made.uid),
    UpdateExpression: `SET ${fields.map(([k]) => `#${k} = :${k}`).join(", ")}${removed.length ? ` REMOVE ${removed.map((k) => `#${k}`).join(", ")}` : ""}`,
    ConditionExpression: "attribute_not_exists(eventAt) OR eventAt <= :eventAt",
    ExpressionAttributeNames: Object.fromEntries([...fields.map(([k]) => k), ...removed].map((k) => [`#${k}`, k])),
    ExpressionAttributeValues: Object.fromEntries(fields.map(([k, v]) => [`:${k}`, v])),
  })).catch((error) => {
    if (!(error instanceof ConditionalCheckFailedException)) throw error;
  });
}

export class PlanError extends Error {}

/** The account's Stripe customer, made once and kept. */
async function customerFor(key: string, uid: string, email?: string): Promise<string> {
  const known = (await planRecord(uid))?.customer;
  if (known) return known;
  const made = await stripe<{ id: string }>(key, "customers", { email, metadata: { uid } });
  try {
    await db.send(new UpdateCommand({
      TableName: TABLE(),
      Key: planKey(uid),
      UpdateExpression: "SET customer = :c",
      ConditionExpression: "attribute_not_exists(customer)",
      ExpressionAttributeValues: { ":c": made.id },
    }));
    return made.id;
  } catch (error) {
    // Two clicks at once: keep the first one's customer.
    if (error instanceof ConditionalCheckFailedException) return (await planRecord(uid))!.customer!;
    throw error;
  }
}

/** A Checkout URL for the plan, or undefined while it isn't on sale. */
export async function start(uid: string, interval: string, email?: string, origin = process.env.APP_ORIGIN!): Promise<string | undefined> {
  if (interval !== "month" && interval !== "year") throw new PlanError("Choose monthly or yearly.");
  const keys = await stripeConfig();
  if (!keys) return undefined;
  const current = await planRecord(uid);
  if (current?.status && !["canceled", "incomplete_expired"].includes(current.status)) {
    throw new PlanError("You already have the coach plan. Use Manage billing to change it.");
  }
  const lookup = LOOKUP_KEYS[interval];
  const prices = await stripe<{ data: { id: string }[] }>(keys.secretKey, `prices?active=true&lookup_keys[]=${lookup}`);
  if (!prices.data[0]) {
    console.error("No price with lookup key", lookup);
    return undefined;
  }
  const customer = await customerFor(keys.secretKey, uid, email);
  const session = await stripe<{ url: string }>(keys.secretKey, "checkout/sessions", checkoutParams(uid, customer, prices.data[0].id, origin));
  return session.url;
}

/** Stripe's customer portal for the account, or undefined without a customer. */
export async function portal(uid: string, origin = process.env.APP_ORIGIN!): Promise<string | undefined> {
  const keys = await stripeConfig();
  const customer = (await planRecord(uid))?.customer;
  if (!keys || !customer) return undefined;
  const session = await stripe<{ url: string }>(keys.secretKey, "billing_portal/sessions", { customer, return_url: `${origin}/billing` });
  return session.url;
}

export async function handler(event: AppSyncResolverEvent<{ interval?: string }>) {
  const identity = event.identity as AppSyncIdentityCognito | null;
  if (!identity?.sub) throw new Error("Sign in first.");
  switch (event.info.fieldName) {
    case "coachPlan":
      return shownPlan(Boolean(await stripeConfig()), await planRecord(identity.sub));
    case "startCoachPlan":
      return (await start(identity.sub, event.arguments.interval ?? "", identity.claims?.email as string | undefined)) ?? null;
    case "coachBillingPortal":
      return (await portal(identity.sub)) ?? null;
    default:
      throw new Error(`No field ${event.info.fieldName}`);
  }
}
