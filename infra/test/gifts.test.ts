import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { giftRoute, type GiftCard, type GiftStore } from "../lambda/giftPages.ts";
import { ALPHABET, checkoutParams, giftFrom, newCode, proUntil, readCode, shown, yearAfter, yearBefore } from "../lambda/gifts.ts";
import { associationFile, type Site } from "../lambda/sharePages.ts";
import { form, verifyWebhook } from "../lambda/stripe.ts";

/** FIT-122: a year of Pro, bought as a gift on the web. */
const site: Site = { appName: "Rep & Recipe", origin: "https://example.com", appId: "TEAM.com.example.app" };
const now = new Date("2026-12-20T15:00:00Z");

describe("gift codes", () => {
  it("are 12 easy-to-read characters", () => {
    const code = newCode();
    expect(code).toMatch(/^[A-Z2-9]{12}$/);
    expect([...code].every((c) => ALPHABET.includes(c))).toBe(true);
    expect(ALPHABET).not.toMatch(/[01IO]/);
    expect(shown("ABCDEFGHJKLM")).toBe("ABCD-EFGH-JKLM");
  });

  it("are read however they're typed or pasted", () => {
    expect(readCode("abcd-efgh-jklm")).toBe("ABCDEFGHJKLM");
    expect(readCode(" ABCD EFGH JKLM ")).toBe("ABCDEFGHJKLM");
    expect(readCode("https://barbrabell.com/g/ABCDEFGHJKLM")).toBe("ABCDEFGHJKLM");
    expect(readCode("ABCD-EFGH-JKL0")).toBeUndefined();
    expect(readCode("ABCD")).toBeUndefined();
  });
});

describe("a gift's year", () => {
  it("starts when it's redeemed, and a second gift adds a year", () => {
    expect(proUntil(undefined, now)).toBe("2027-12-20T15:00:00.000Z");
    expect(proUntil("2027-06-01T00:00:00.000Z", now)).toBe("2028-06-01T00:00:00.000Z");
    // Pro that already ran out doesn't count.
    expect(proUntil("2026-01-01T00:00:00.000Z", now)).toBe("2027-12-20T15:00:00.000Z");
    expect(yearBefore(yearAfter(now)).toISOString()).toBe(now.toISOString());
  });
});

describe("buying with Stripe", () => {
  it("asks Checkout for the price, the name and note, and carries the code", () => {
    const params = checkoutParams("ABCDEFGHJKLM", "https://example.com");
    expect(params.line_items[0].price_data.unit_amount).toBe(3999);
    expect(params.custom_fields.map((f) => f.key)).toEqual(["for", "note"]);
    expect(params.metadata.gift).toBe("ABCDEFGHJKLM");
    expect(params.payment_intent_data.metadata.gift).toBe("ABCDEFGHJKLM");
    expect(params.success_url).toBe("https://example.com/gift/thanks/{CHECKOUT_SESSION_ID}");
    const body = decodeURIComponent(form(params));
    expect(body).toContain("line_items[0][price_data][unit_amount]=3999");
    expect(body).toContain("custom_fields[1][optional]=true");
    // Managed Payments: Stripe is the merchant of record, choosing payment methods and tax itself.
    expect(body).toContain("managed_payments[enabled]=true");
    expect(body).toContain("line_items[0][price_data][product_data][tax_code]=txcd_10103100");
    expect(body).not.toContain("payment_method_types");
    expect(body).not.toContain("automatic_tax");
  });

  it("makes a gift only from a paid session with a code", () => {
    const session = {
      id: "cs_test_1", payment_status: "paid", payment_intent: "pi_1", metadata: { gift: "ABCDEFGHJKLM" },
      custom_fields: [{ key: "for", text: { value: " Sam " } }, { key: "note", text: { value: "Go get it" } }],
    };
    expect(giftFrom(session, now)).toMatchObject({ code: "ABCDEFGHJKLM", for: "Sam", note: "Go get it", status: "unused", paymentIntent: "pi_1" });
    expect(giftFrom({ ...session, payment_status: "unpaid" }, now)).toBeUndefined();
    expect(giftFrom({ ...session, metadata: {} }, now)).toBeUndefined();
    expect(giftFrom({ ...session, custom_fields: [] }, now)?.for).toBe("you");
  });

  it("trusts a webhook only with Stripe's signature, recently", () => {
    const secret = "whsec_test";
    const body = JSON.stringify({ type: "checkout.session.completed" });
    const t = Math.floor(now.getTime() / 1000);
    const v1 = createHmac("sha256", secret).update(`${t}.${body}`).digest("hex");
    expect(verifyWebhook(body, `t=${t},v1=${v1}`, secret, now)).toBe(true);
    expect(verifyWebhook(body + " ", `t=${t},v1=${v1}`, secret, now)).toBe(false);
    expect(verifyWebhook(body, `t=${t},v1=${v1}`, "whsec_other", now)).toBe(false);
    expect(verifyWebhook(body, `t=${t},v1=${v1}`, secret, new Date(now.getTime() + 10 * 60_000))).toBe(false);
    expect(verifyWebhook(body, undefined, secret, now)).toBe(false);
  });
});

describe("gift pages", () => {
  const gifts: Record<string, GiftCard> = {
    ABCDEFGHJKLM: { code: "ABCDEFGHJKLM", for: "Sam", note: "For the <b>squat</b> goal", status: "unused" },
    USEDUSEDUSED: { code: "USEDUSEDUSED", for: "Jo", status: "redeemed" },
    BACKBACKBACK: { code: "BACKBACKBACK", for: "Al", status: "refunded" },
  };
  const store = (onSale = true): GiftStore => ({
    gift: async (code) => gifts[code],
    checkout: async () => (onSale ? "https://checkout.stripe.com/c/pay/cs_test_1" : undefined),
    thanks: async (id) => (id === "cs_test_paid" ? gifts.ABCDEFGHJKLM : undefined),
  });

  it("sells the gift, and goes to Stripe", async () => {
    const page = (await giftRoute("/gift", store(), site, 3999))!;
    expect(page.body).toContain("$39.99");
    expect(page.body).toContain('href="/gift/buy"');
    expect(await giftRoute("/gift/buy", store(), site, 3999)).toMatchObject({ status: 303, location: "https://checkout.stripe.com/c/pay/cs_test_1", noStore: true });
    const notYet = (await giftRoute("/gift/buy", store(false), site, 3999))!;
    expect(notYet.status).toBe(200);
    expect(notYet.body).toContain("Gifts go on sale soon");
  });

  it("goes from Stripe to the gift once it's paid, and waits otherwise", async () => {
    expect(await giftRoute("/gift/thanks/cs_test_paid", store(), site, 3999)).toMatchObject({ status: 303, location: "/g/ABCDEFGHJKLM" });
    const waiting = (await giftRoute("/gift/thanks/cs_test_open", store(), site, 3999))!;
    expect(waiting.body).toContain("on its way");
    expect(waiting.noStore).toBe(true);
  });

  it("shows the card with its code, escaped, and how to redeem it", async () => {
    const page = (await giftRoute("/g/ABCDEFGHJKLM", store(), site, 3999))!;
    expect(page.status).toBe(200);
    expect(page.noStore).toBe(true);
    expect(page.body).toContain("ABCD-EFGH-JKLM");
    expect(page.body).toContain("A year of coaching, for Sam");
    expect(page.body).toContain("&lt;b&gt;squat&lt;/b&gt;");
    expect(page.body).not.toContain("<b>squat</b>");
    expect((await giftRoute("/g/USEDUSEDUSED", store(), site, 3999))!.body).toContain("has been redeemed");
    expect((await giftRoute("/g/BACKBACKBACK", store(), site, 3999))!.status).toBe(404);
    expect((await giftRoute("/g/nope", store(), site, 3999))!.status).toBe(404);
    expect(await giftRoute("/w/bench", store(), site, 3999)).toBeUndefined();
  });

  it("opens in the app when it's installed", () => {
    expect(associationFile(site).applinks.details[0].components).toContainEqual({ "/": "/g/*" });
  });
});
