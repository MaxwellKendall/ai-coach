import { ConditionalCheckFailedException, DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import { APPLE_ROOT_G3, app, productOf, verifyJWS } from "./entitlement.ts";
import { planRecord, saveState, type Kind } from "./coachPlan.ts";
import { shownPlan, type AppStoreState, type AppStoreStatus, type CoachPlan } from "./plan.ts";

/**
 * FIT-437: Lifter Pro and Coach Pro bought in the iPhone app, kept in the same plan records as Stripe's (plan.ts).
 * Two ways in, both Apple-signed and checked by entitlement.ts's verifyJWS:
 *
 * - App Store Server Notifications v2 (appStoreNotifications.ts), for renewals, lapses and refunds.
 * - The app's registration of a transaction right after a purchase or restore (`registerAppStorePurchase`), so the
 *   plan is there at once without waiting for Apple's notification.
 *
 * Whose purchase: APPSTORETXN#originalTransactionId links a subscription to one account, made by the first of the two
 * to arrive. The app sets StoreKit's appAccountToken to the account's uid (a Cognito sub, already a UUID), so a
 * notification that arrives first finds the account from it. A subscription linked to one account is refused to
 * another (a restore while signed in as someone else).
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;

export interface Options {
  now?: Date;
  /** Apple Root CA - G3; tests pass their own chain's. */
  root?: string;
  /** The App Store environments this stage takes (APPSTORE_ENVIRONMENTS). */
  environments?: string[];
}

const environments = (options: Options) =>
  options.environments ?? (process.env.APPSTORE_ENVIRONMENTS ?? "Production").split(",").map((e) => e.trim()).filter(Boolean);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The notification types that say something about a subscription's state; any other is acknowledged and ignored. */
export const HANDLED = ["SUBSCRIBED", "DID_RENEW", "DID_CHANGE_RENEWAL_STATUS", "DID_CHANGE_RENEWAL_PREF", "OFFER_REDEEMED",
  "DID_FAIL_TO_RENEW", "GRACE_PERIOD_EXPIRED", "EXPIRED", "REFUND", "REVOKE", "REFUND_REVERSED"];

/** Apple's JWSTransactionDecodedPayload and JWSRenewalInfoDecodedPayload, the fields read here. */
export interface Transaction {
  originalTransactionId: string;
  productId: string;
  bundleId: string;
  environment: string;
  expiresDate?: number;
  revocationDate?: number;
  offerType?: number;
  offerDiscountType?: string;
  appAccountToken?: string;
  signedDate: number;
}
export interface Renewal {
  autoRenewStatus?: number;
  isInBillingRetryPeriod?: boolean;
  gracePeriodExpiresDate?: number;
}

/**
 * The subscription's state as of `at`: what the notification says first (a failed renewal, in grace or not, a lapse,
 * a refund), else the transaction and renewal info's own dates.
 */
export function statusOf(type: string | undefined, subtype: string | undefined, txn: Transaction, renewal: Renewal | undefined, at: Date): AppStoreStatus {
  if (type === "REFUND") return "refunded";
  if (type === "REVOKE") return "revoked";
  if (txn.revocationDate) return "refunded";
  if (type === "EXPIRED") return "expired";
  // Out of grace, Apple keeps retrying for a while; the plan ends meanwhile.
  if (type === "GRACE_PERIOD_EXPIRED") return "billing_retry";
  if (type === "DID_FAIL_TO_RENEW") return subtype === "GRACE_PERIOD" ? "in_grace" : "billing_retry";
  if (Number(txn.expiresDate) > at.getTime()) {
    const trial = txn.offerDiscountType === "FREE_TRIAL" || (txn.offerType === 1 && txn.offerDiscountType === undefined);
    return trial ? "trialing" : "active";
  }
  if (Number(renewal?.gracePeriodExpiresDate) > at.getTime()) return "in_grace";
  if (renewal?.isInBillingRetryPeriod) return "billing_retry";
  return "expired";
}

const iso = (ms?: number) => (ms ? new Date(Number(ms)).toISOString() : undefined);

/** What a verified transaction (and its renewal info, if any) says about its plan. */
export function stateFrom(type: string | undefined, subtype: string | undefined, txn: Transaction, renewal: Renewal | undefined, eventAt: number, at: Date):
  { kind: Kind; state: AppStoreState } | undefined {
  const product = productOf(txn.productId);
  if (!product || !txn.originalTransactionId) return undefined;
  const status = statusOf(type, subtype, txn, renewal, at);
  const state: AppStoreState = {
    originalTransactionId: String(txn.originalTransactionId),
    productId: txn.productId,
    status,
    interval: product.interval,
    expiresAt: iso(txn.expiresDate),
    graceUntil: status === "in_grace" ? iso(renewal?.gracePeriodExpiresDate) : undefined,
    // Without renewal info (a registration from the app), it renews unless a notification says otherwise.
    autoRenew: renewal?.autoRenewStatus === undefined ? true : renewal.autoRenewStatus === 1,
    environment: txn.environment,
    eventAt,
  };
  // DynamoDB's document client refuses undefined.
  for (const key of Object.keys(state) as (keyof AppStoreState)[]) if (state[key] === undefined) delete state[key];
  return { kind: product.kind, state };
}

/** A transaction Apple signed for this app, in this stage's environments; the reason if not. */
export function readTransaction(jws: string | undefined, options: Options): { txn: Transaction } | { why: string } {
  const verified = verifyJWS(jws, options.now ?? new Date(), options.root ?? APPLE_ROOT_G3);
  if (!verified.ok) return { why: verified.why };
  const txn = verified.payload as Transaction;
  if (txn.bundleId !== app.bundleId) return { why: "another app" };
  if (!environments(options).includes(txn.environment)) return { why: "environment" };
  if (!productOf(txn.productId)) return { why: "not a subscription of ours" };
  return { txn };
}

const linkKey = (originalTransactionId: string) => ({ PK: `APPSTORETXN#${originalTransactionId}`, SK: "APPSTORETXN" });

export async function linkedUid(originalTransactionId: string): Promise<string | undefined> {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: linkKey(originalTransactionId), ConsistentRead: true }));
  return Item?.uid;
}

/**
 * Links the subscription to the account unless it's another's; the account it's linked to. On GSI1 under the
 * account, so deleting the account deletes the link (deleteAccount).
 */
export async function link(originalTransactionId: string, uid: string, now = new Date()): Promise<string> {
  try {
    await db.send(new PutCommand({
      TableName: TABLE(),
      Item: { ...linkKey(originalTransactionId), uid, createdAt: now.toISOString(), GSI1PK: `USER#${uid}`, GSI1SK: `APPSTORETXN#${originalTransactionId}` },
      ConditionExpression: "attribute_not_exists(PK) OR #uid = :uid",
      ExpressionAttributeNames: { "#uid": "uid" },
      ExpressionAttributeValues: { ":uid": uid },
    }));
    return uid;
  } catch (error) {
    if (!(error instanceof ConditionalCheckFailedException)) throw error;
    return (await linkedUid(originalTransactionId))!;
  }
}

export type Outcome = { saved: boolean; uid?: string; kind?: Kind; ignored?: string };

/** A notification's signedPayload: verified, read, and saved to the account's plan. Anything not ours is ignored. */
export async function handleNotification(signedPayload: string | undefined, options: Options = {}): Promise<{ status: number; outcome: Outcome }> {
  const now = options.now ?? new Date();
  const root = options.root ?? APPLE_ROOT_G3;
  const verified = verifyJWS(signedPayload, now, root);
  if (!verified.ok) return { status: 400, outcome: { saved: false, ignored: verified.why } };
  const { notificationType: type, subtype, data, signedDate } = verified.payload as
    { notificationType?: string; subtype?: string; signedDate?: number; data?: { bundleId?: string; environment?: string; signedTransactionInfo?: string; signedRenewalInfo?: string } };
  if (type === "TEST") return { status: 200, outcome: { saved: false, ignored: "test" } };
  if (!type || !HANDLED.includes(type)) return { status: 200, outcome: { saved: false, ignored: `type ${type}` } };
  if (data?.bundleId !== app.bundleId) return { status: 200, outcome: { saved: false, ignored: "another app" } };
  if (!environments(options).includes(data.environment ?? "")) return { status: 200, outcome: { saved: false, ignored: "environment" } };
  const read = readTransaction(data.signedTransactionInfo, options);
  if ("why" in read) return { status: read.why === "environment" || read.why === "not a subscription of ours" ? 200 : 400, outcome: { saved: false, ignored: read.why } };
  const { txn } = read;
  if (txn.environment !== data.environment) return { status: 400, outcome: { saved: false, ignored: "environment" } };
  let renewal: Renewal | undefined;
  if (data.signedRenewalInfo) {
    const info = verifyJWS(data.signedRenewalInfo, now, root);
    if (!info.ok) return { status: 400, outcome: { saved: false, ignored: `renewal ${info.why}` } };
    if (info.payload.originalTransactionId !== undefined && String(info.payload.originalTransactionId) !== String(txn.originalTransactionId)) {
      return { status: 400, outcome: { saved: false, ignored: "renewal of another subscription" } };
    }
    renewal = info.payload as Renewal;
  }
  const eventAt = Number(signedDate ?? txn.signedDate);
  const made = stateFrom(type, subtype, txn, renewal, eventAt, new Date(eventAt));
  if (!made) return { status: 200, outcome: { saved: false, ignored: "product" } };
  const otid = made.state.originalTransactionId;
  let uid = await linkedUid(otid);
  if (!uid) {
    const token = txn.appAccountToken?.toLowerCase();
    // Until the app registers it, a purchase without the account's token can't be placed; registering saves its state then.
    if (!token || !UUID.test(token)) {
      console.error("App Store subscription with no account", otid, type);
      return { status: 200, outcome: { saved: false, ignored: "no account" } };
    }
    uid = await link(otid, token, now);
  }
  const saved = await saveState(uid, made.kind, { source: "appstore", state: made.state }, now);
  return { status: 200, outcome: { saved, uid, kind: made.kind } };
}

export class PurchaseError extends Error {}

/**
 * The app's transaction (StoreKit 2's jwsRepresentation), and its renewal info's if it has it, registered for the
 * signed-in account: linked to it, unless another account's, and saved to its plan. The plan as the app shows it.
 */
export async function registerPurchase(uid: string, transaction: string | undefined, renewalInfo: string | undefined, options: Options = {}):
  Promise<{ kind: Kind; plan: CoachPlan }> {
  const now = options.now ?? new Date();
  const read = readTransaction(transaction, options);
  if ("why" in read) throw new PurchaseError(`That purchase couldn't be checked (${read.why}).`);
  const { txn } = read;
  let renewal: Renewal | undefined;
  if (renewalInfo) {
    const info = verifyJWS(renewalInfo, now, options.root ?? APPLE_ROOT_G3);
    if (info.ok && String(info.payload.originalTransactionId) === String(txn.originalTransactionId)) renewal = info.payload as Renewal;
  }
  const made = stateFrom(undefined, undefined, txn, renewal, Number(txn.signedDate), now)!;
  const otid = made.state.originalTransactionId;
  const owner = (await linkedUid(otid)) ?? txn.appAccountToken?.toLowerCase();
  if (owner && owner !== uid) throw new PurchaseError("That subscription belongs to another Barbrabell account. Sign in with that account to use it.");
  if ((await link(otid, uid, now)) !== uid) throw new PurchaseError("That subscription belongs to another Barbrabell account. Sign in with that account to use it.");
  await saveState(uid, made.kind, { source: "appstore", state: made.state }, now);
  // On sale: it was just sold in the App Store, whatever Stripe has.
  return { kind: made.kind, plan: shownPlan(true, await planRecord(uid, made.kind), now) };
}

export async function handler(event: AppSyncResolverEvent<{ transaction?: string; renewalInfo?: string | null }>) {
  const uid = (event.identity as AppSyncIdentityCognito | null)?.sub;
  if (!uid) throw new Error("Sign in first.");
  if (event.info.fieldName !== "registerAppStorePurchase") throw new Error(`No field ${event.info.fieldName}`);
  return registerPurchase(uid, event.arguments.transaction, event.arguments.renewalInfo ?? undefined);
}
