import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { fulfill, readCode, refund, stripeConfig, type CheckoutSession } from "./gifts.ts";
import { stripe, verifyWebhook } from "./stripe.ts";

/**
 * FIT-122: Stripe's events for gifts, at this Lambda's own URL (CloudFront's origin access only passes GETs on):
 * a paid Checkout Session makes the gift, a refunded charge ends it. Anything else is acknowledged and ignored.
 */
export async function handler(event: LambdaFunctionURLEvent): Promise<LambdaFunctionURLResult> {
  if (event.requestContext.http.method !== "POST") return { statusCode: 405, body: "" };
  const keys = await stripeConfig();
  if (!keys?.webhookSecret) return { statusCode: 503, body: "Not set up" };
  const body = event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString() : (event.body ?? "");
  if (!verifyWebhook(body, event.headers["stripe-signature"], keys.webhookSecret, new Date())) {
    return { statusCode: 400, body: "Bad signature" };
  }
  const { type, data } = JSON.parse(body) as { type: string; data: { object: Record<string, unknown> } };
  if (type === "checkout.session.completed") {
    await fulfill(data.object as unknown as CheckoutSession);
  } else if (type === "charge.refunded" && data.object.refunded === true && typeof data.object.payment_intent === "string") {
    // The code is on the payment intent (Checkout's payment_intent_data), not the charge.
    const intent = await stripe<{ metadata?: Record<string, string> }>(keys.secretKey, `payment_intents/${data.object.payment_intent}`);
    const code = readCode(intent.metadata?.gift ?? "");
    if (code) await refund(code);
  }
  return { statusCode: 200, body: "" };
}
