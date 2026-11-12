import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { handleNotification } from "./appStore.ts";

/**
 * FIT-437: App Store Server Notifications v2, at this Lambda's own URL (as Stripe's webhook: CloudFront passes only
 * GETs on). Apple posts {"signedPayload": JWS}; a payload Apple didn't sign is refused with 400 (Apple retries,
 * which a forgery doesn't deserve but costs nothing), anything signed but not ours or not a state change is
 * acknowledged with 200 so Apple stops sending it.
 */
export async function handler(event: LambdaFunctionURLEvent): Promise<LambdaFunctionURLResult> {
  if (event.requestContext.http.method !== "POST") return { statusCode: 405, body: "" };
  const body = event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString() : (event.body ?? "");
  let signedPayload: string | undefined;
  try {
    signedPayload = (JSON.parse(body) as { signedPayload?: string }).signedPayload;
  } catch {
    return { statusCode: 400, body: "Not JSON" };
  }
  const { status, outcome } = await handleNotification(signedPayload);
  if (outcome.ignored && status !== 200) console.error("App Store notification refused", outcome.ignored);
  return { statusCode: status, body: "" };
}
