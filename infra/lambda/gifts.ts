import { randomBytes } from "node:crypto";
import { DynamoDBClient, TransactionCanceledException, ConditionalCheckFailedException } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, TransactWriteCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import { stripe } from "./stripe.ts";

/**
 * FIT-122: a year of Pro, bought as a gift on the web by anyone (author, 2026-10-12). The gift page sends the buyer to
 * Stripe Checkout with a new code in the session's metadata; once Stripe says it's paid (the thanks page or the
 * webhook, whichever comes first) the code becomes a gift (GIFT#code). The recipient redeems it in the app, signed in:
 * their account has Pro until a year from then (USER#uid PRO), which the app and the proxy accept as they do the App
 * Store's. A refund ends the gift, and the year if it was redeemed.
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const secrets = new SecretsManagerClient({});
const TABLE = () => process.env.TABLE!;

// MARK: Codes

/** No 0/O, 1/I: easy to read off a printed card. 32 letters, so 12 are 60 bits. */
export const ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";

export function newCode(bytes: Buffer = randomBytes(12)): string {
  return [...bytes].map((b) => ALPHABET[b % 32]).join("");
}

/** A code as typed or pasted: any case, with or without dashes and spaces, or the gift link itself. */
export function readCode(input: string): string | undefined {
  const fromLink = /\/g\/([A-Za-z0-9-]+)\/?$/.exec(input.trim())?.[1];
  const code = (fromLink ?? input).replace(/[\s-]/g, "").toUpperCase();
  return code.length === 12 && [...code].every((c) => ALPHABET.includes(c)) ? code : undefined;
}

/** "ABCD-EFGH-JKLM". */
export const shown = (code: string) => code.match(/.{1,4}/g)!.join("-");

/** A year on: the same day and time next year (a Feb 29 lands on Mar 1). */
export function yearAfter(date: Date): Date {
  const next = new Date(date);
  next.setUTCFullYear(next.getUTCFullYear() + 1);
  return next;
}

export function yearBefore(date: Date): Date {
  const before = new Date(date);
  before.setUTCFullYear(before.getUTCFullYear() - 1);
  return before;
}

/** Pro until: a year from now, or a year after the Pro already given, so a second gift adds a year. */
export function proUntil(current: string | undefined, now: Date): string {
  const from = current && new Date(current) > now ? new Date(current) : now;
  return yearAfter(from).toISOString();
}

// MARK: Stripe

export interface StripeConfig {
  secretKey: string;
  webhookSecret?: string;
  /** Stripe Tax on in the account: Checkout adds sales tax or VAT where it's due. */
  automaticTax?: boolean;
}

let config: StripeConfig | undefined;
/** The Stripe secret, or undefined until the author has created it (the page then says gifts aren't on sale yet). */
export async function stripeConfig(): Promise<StripeConfig | undefined> {
  if (!config) {
    try {
      const secret = await secrets.send(new GetSecretValueCommand({ SecretId: process.env.STRIPE_SECRET! }));
      const parsed = JSON.parse(secret.SecretString ?? "{}") as Partial<StripeConfig>;
      if (parsed.secretKey) config = parsed as StripeConfig;
    } catch (error) {
      console.error("No Stripe secret", (error as Error).name);
    }
  }
  return config;
}

export const price = { cents: Number(process.env.GIFT_PRICE_CENTS ?? 3999), currency: "usd" };

/** The Checkout Session for one gift: its code travels in the metadata, the name and note are Checkout's own fields. */
export function checkoutParams(code: string, origin: string, automaticTax = false) {
  return {
    mode: "payment",
    "payment_method_types": ["card"],
    line_items: [{
      quantity: 1,
      price_data: {
        currency: price.currency,
        unit_amount: price.cents,
        product_data: { name: "A year of Rep & Recipe Pro, as a gift", description: "Redeemed in the app. It doesn't renew." },
      },
    }],
    custom_fields: [
      { key: "for", type: "text", label: { type: "custom", custom: "Who it's for (their first name)" }, text: { maximum_length: 40 } },
      { key: "note", type: "text", optional: true, label: { type: "custom", custom: "A note for the card" }, text: { maximum_length: 200 } },
    ],
    metadata: { gift: code },
    payment_intent_data: { metadata: { gift: code } },
    automatic_tax: { enabled: automaticTax },
    success_url: `${origin}/gift/thanks/{CHECKOUT_SESSION_ID}`,
    cancel_url: `${origin}/gift`,
  };
}

export interface CheckoutSession {
  id: string;
  payment_status: string;
  payment_intent?: string | null;
  metadata?: Record<string, string> | null;
  custom_fields?: { key: string; text?: { value?: string | null } | null }[];
}

export interface Gift {
  code: string;
  for: string;
  note?: string;
  status: "unused" | "redeemed" | "refunded";
  createdAt: string;
  redeemedAt?: string;
  until?: string;
}

/** The gift a paid session bought, or undefined while it isn't paid or isn't a gift. */
export function giftFrom(session: CheckoutSession, now: Date): (Gift & { sessionId: string; paymentIntent?: string }) | undefined {
  const code = readCode(session.metadata?.gift ?? "");
  if (!code || session.payment_status !== "paid") return undefined;
  const field = (key: string) => session.custom_fields?.find((f) => f.key === key)?.text?.value?.trim() || undefined;
  return {
    code,
    for: (field("for") ?? "you").slice(0, 40),
    note: field("note")?.slice(0, 200),
    status: "unused",
    createdAt: now.toISOString(),
    sessionId: session.id,
    paymentIntent: session.payment_intent ?? undefined,
  };
}

// MARK: The table

export async function gift(code: string): Promise<Gift | undefined> {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `GIFT#${code}`, SK: "META" } }));
  return Item as Gift | undefined;
}

/** Saves a paid session's gift once; the thanks page and the webhook may both get here. */
export async function fulfill(session: CheckoutSession, now = new Date()): Promise<Gift | undefined> {
  const made = giftFrom(session, now);
  if (!made) return undefined;
  try {
    await db.send(new PutCommand({
      TableName: TABLE(),
      Item: { PK: `GIFT#${made.code}`, SK: "META", ...made },
      ConditionExpression: "attribute_not_exists(PK)",
    }));
    return made;
  } catch (error) {
    if (error instanceof ConditionalCheckFailedException) return gift(made.code);
    throw error;
  }
}

/** The account's Pro from gifts: until when, if it's still on. */
export async function giftedUntil(uid: string, now = new Date()): Promise<string | undefined> {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${uid}`, SK: "PRO" } }));
  const until = Item?.until as string | undefined;
  return until && new Date(until) > now ? until : undefined;
}

export class GiftError extends Error {}

/** Redeems a gift on an account: Pro until a year on. Redeeming your own gift again just says when it runs to. */
export async function redeem(uid: string, input: string, now = new Date()): Promise<string> {
  const code = readCode(input);
  if (!code) throw new GiftError("That doesn't look like a gift code. It's 12 letters and numbers, like ABCD-EFGH-JKLM.");
  const found = await gift(code);
  if (!found || found.status === "refunded") throw new GiftError("There's no gift with that code. Check it and try again.");
  const { Item: pro } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${uid}`, SK: "PRO" } }));
  if (found.status === "redeemed") {
    if ((pro?.gifts as Set<string> | undefined)?.has(code)) return pro!.until as string;
    throw new GiftError("This gift has already been redeemed.");
  }
  const until = proUntil(pro?.until as string | undefined, now);
  try {
    await db.send(new TransactWriteCommand({
      TransactItems: [
        {
          Update: {
            TableName: TABLE(),
            Key: { PK: `GIFT#${code}`, SK: "META" },
            UpdateExpression: "SET #s = :redeemed, redeemedBy = :uid, redeemedAt = :now, #u = :until",
            ConditionExpression: "#s = :unused",
            ExpressionAttributeNames: { "#s": "status", "#u": "until" },
            ExpressionAttributeValues: { ":redeemed": "redeemed", ":unused": "unused", ":uid": uid, ":now": now.toISOString(), ":until": until },
          },
        },
        {
          Update: {
            TableName: TABLE(),
            Key: { PK: `USER#${uid}`, SK: "PRO" },
            UpdateExpression: "SET #u = :until ADD gifts :code",
            ExpressionAttributeNames: { "#u": "until" },
            ExpressionAttributeValues: { ":until": until, ":code": new Set([code]) },
          },
        },
      ],
    }));
  } catch (error) {
    if (error instanceof TransactionCanceledException) throw new GiftError("This gift has already been redeemed.");
    throw error;
  }
  return until;
}

/** A refunded gift can't be redeemed; if it was, the year it gave comes off that account's Pro. */
export async function refund(code: string): Promise<void> {
  const { Attributes: before } = await db.send(new UpdateCommand({
    TableName: TABLE(),
    Key: { PK: `GIFT#${code}`, SK: "META" },
    UpdateExpression: "SET #s = :refunded",
    ConditionExpression: "attribute_exists(PK)",
    ExpressionAttributeNames: { "#s": "status" },
    ExpressionAttributeValues: { ":refunded": "refunded" },
    ReturnValues: "ALL_OLD",
  })).catch((error) => {
    if (error instanceof ConditionalCheckFailedException) return { Attributes: undefined };
    throw error;
  });
  if (before?.status !== "redeemed") return;
  const uid = before.redeemedBy as string;
  const { Item: pro } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `USER#${uid}`, SK: "PRO" } }));
  if (!pro?.until) return;
  await db.send(new UpdateCommand({
    TableName: TABLE(),
    Key: { PK: `USER#${uid}`, SK: "PRO" },
    UpdateExpression: "SET #u = :until DELETE gifts :code",
    ExpressionAttributeNames: { "#u": "until" },
    ExpressionAttributeValues: { ":until": yearBefore(new Date(pro.until as string)).toISOString(), ":code": new Set([code]) },
  }));
}

// MARK: Web: buying

/** A new Checkout Session for a gift; its URL, or undefined while gifts aren't on sale. */
export async function checkout(origin: string): Promise<string | undefined> {
  const stripeKeys = await stripeConfig();
  if (!stripeKeys) return undefined;
  const session = await stripe<{ url: string }>(stripeKeys.secretKey, "checkout/sessions",
                                                checkoutParams(newCode(), origin, stripeKeys.automaticTax));
  return session.url;
}

/** After paying: the session's gift, saved now if the webhook hasn't yet. */
export async function thanks(sessionId: string): Promise<Gift | undefined> {
  const stripeKeys = await stripeConfig();
  if (!stripeKeys || !/^cs_[A-Za-z0-9_]{10,200}$/.test(sessionId)) return undefined;
  const session = await stripe<CheckoutSession>(stripeKeys.secretKey, `checkout/sessions/${sessionId}`).catch(() => undefined);
  return session && fulfill(session);
}

// MARK: The app (AppSync)

export async function handler(event: AppSyncResolverEvent<{ code?: string }>) {
  const uid = (event.identity as AppSyncIdentityCognito | null)?.sub;
  if (!uid) throw new Error("Sign in to redeem a gift.");
  switch (event.info.fieldName) {
    case "redeemGift":
      return redeem(uid, event.arguments.code ?? "");
    case "giftedPro":
      return (await giftedUntil(uid)) ?? null;
    default:
      throw new Error(`No field ${event.info.fieldName}`);
  }
}
