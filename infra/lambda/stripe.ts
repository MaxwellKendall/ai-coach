import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * FIT-122: the little of Stripe's API the gift needs, over fetch (no SDK): a Checkout Session to pay for a gift, reading
 * one back, and checking that a webhook came from Stripe.
 */

type Params = { [key: string]: string | number | boolean | undefined | Params | Params[] | string[] };

/** Stripe's form encoding: nested objects as a[b], lists as a[0][b]. */
export function form(params: Params, prefix = ""): string {
  const parts: string[] = [];
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined) continue;
    const name = prefix ? `${prefix}[${key}]` : key;
    if (Array.isArray(value)) {
      value.forEach((item, i) => {
        if (typeof item === "object") parts.push(form(item, `${name}[${i}]`));
        else parts.push(`${encodeURIComponent(`${name}[${i}]`)}=${encodeURIComponent(item)}`);
      });
    } else if (typeof value === "object") {
      parts.push(form(value, name));
    } else {
      parts.push(`${encodeURIComponent(name)}=${encodeURIComponent(String(value))}`);
    }
  }
  return parts.filter(Boolean).join("&");
}

/** Pinned, so Stripe's answers keep their shape; Managed Payments needs 2025-03-31.basil or later. */
export const API_VERSION = "2026-04-22.dahlia";

export async function stripe<T = Record<string, unknown>>(key: string, path: string, params?: Params): Promise<T> {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: params ? "POST" : "GET",
    headers: { authorization: `Bearer ${key}`, "content-type": "application/x-www-form-urlencoded", "stripe-version": API_VERSION },
    body: params ? form(params) : undefined,
  });
  const body = (await response.json()) as T & { error?: { message?: string } };
  if (!response.ok) throw new Error(`Stripe ${path}: ${body.error?.message ?? response.status}`);
  return body;
}

/**
 * Whether a webhook's body was signed with the endpoint's secret, within five minutes (Stripe's own check: an HMAC
 * of "t.body" in the Stripe-Signature header's v1).
 */
export function verifyWebhook(payload: string, header: string | undefined, secret: string, now: Date, tolerance = 300): boolean {
  if (!header) return false;
  const fields = header.split(",").map((part) => part.split("=", 2) as [string, string]);
  const t = Number(fields.find(([k]) => k === "t")?.[1]);
  if (!Number.isFinite(t) || Math.abs(now.getTime() / 1000 - t) > tolerance) return false;
  const expected = createHmac("sha256", secret).update(`${t}.${payload}`).digest();
  return fields.some(([k, v]) => {
    if (k !== "v1" || !/^[0-9a-f]{64}$/.test(v)) return false;
    return timingSafeEqual(Buffer.from(v, "hex"), expected);
  });
}
