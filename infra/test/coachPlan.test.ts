import { beforeEach, describe, expect, it, vi } from "vitest";

// FIT-144: the coach plan, a Stripe subscription. The table and the Stripe secret are stubbed; Stripe is a fetch stub.
const send = vi.fn();
vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return { ...actual, DynamoDBDocumentClient: { from: () => ({ send }) } };
});
const keys = vi.fn();
vi.mock("../lambda/gifts.ts", () => ({ stripeConfig: () => keys() }));

const { checkoutParams, onSale, planPrices, portal, recordFrom, saveSubscription, shownPlan, start } = await import("../lambda/coachPlan.ts");
const { form } = await import("../lambda/stripe.ts");

const sub = {
  id: "sub_1", status: "active", customer: "cus_1", cancel_at_period_end: false, metadata: { uid: "sam" },
  items: { data: [{ current_period_end: 1_795_000_000, price: { lookup_key: "coach_monthly", recurring: { interval: "month" } } }] },
};

beforeEach(() => {
  send.mockReset();
  keys.mockReset();
  vi.unstubAllGlobals();
});

describe("checkout for the coach plan", () => {
  it("is a subscription for the account's customer, with the uid on the subscription", () => {
    const params = checkoutParams("sam", "cus_1", "price_1", "https://app.example.com");
    const body = decodeURIComponent(form(params));
    expect(body).toContain("mode=subscription");
    expect(body).toContain("customer=cus_1");
    expect(body).toContain("line_items[0][price]=price_1");
    expect(body).toContain("subscription_data[metadata][uid]=sam");
    expect(body).toContain("managed_payments[enabled]=true");
    expect(params.success_url).toBe("https://app.example.com/billing?started=1");
  });

  it("finds the price by lookup key, makes the customer once, and returns Checkout's URL", async () => {
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    send.mockResolvedValueOnce({}).mockResolvedValueOnce({}).mockResolvedValueOnce({});
    const calls: string[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      calls.push(`${init.method} ${url.replace("https://api.stripe.com/v1/", "")}`);
      const path = url.replace("https://api.stripe.com/v1/", "");
      const body = path.startsWith("prices") ? { data: [{ id: "price_m", lookup_key: "coach_monthly" }, { id: "price_y", lookup_key: "coach_yearly" }] } : path === "customers" ? { id: "cus_new" } : { url: "https://checkout.stripe.com/c/1" };
      return new Response(JSON.stringify(body));
    });
    expect(await start("sam", "year", "sam@example.com", "https://app.example.com")).toBe("https://checkout.stripe.com/c/1");
    expect(calls).toEqual(["GET prices?active=true&lookup_keys[]=coach_monthly&lookup_keys[]=coach_yearly", "POST customers", "POST checkout/sessions"]);
    // The customer is saved only if the account has none yet.
    expect(send.mock.calls[2][0].input).toMatchObject({ UpdateExpression: "SET customer = :c", ConditionExpression: "attribute_not_exists(customer)" });
  });

  it("isn't on sale without the Stripe secret, and won't start a second plan", async () => {
    keys.mockResolvedValue(undefined);
    expect(await start("sam", "month")).toBeUndefined();
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    send.mockResolvedValue({ Item: { customer: "cus_1", status: "active" } });
    await expect(start("sam", "month")).rejects.toThrow("already have the coach plan");
    await expect(start("sam", "week")).rejects.toThrow("monthly or yearly");
  });

  it("opens the customer portal back to Billing", async () => {
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    send.mockResolvedValue({ Item: { customer: "cus_1" } });
    let sent = "";
    vi.stubGlobal("fetch", async (_: string, init: RequestInit) => {
      sent = String(init.body);
      return new Response(JSON.stringify({ url: "https://billing.stripe.com/p/1" }));
    });
    expect(await portal("sam", "https://app.example.com")).toBe("https://billing.stripe.com/p/1");
    expect(decodeURIComponent(sent)).toBe("customer=cus_1&return_url=https://app.example.com/billing");
    send.mockResolvedValue({});
    expect(await portal("ann")).toBeUndefined();
  });
});

describe("on sale", () => {
  it("needs the Stripe secret and both prices, looked up at most every 5 minutes", async () => {
    keys.mockResolvedValue(undefined);
    expect(await onSale()).toBe(false);
    // Later than the cache the checkout test left.
    const t = Date.now() + 3_600_000;
    let lookups = 0;
    const answer = (data: unknown[]) => vi.stubGlobal("fetch", async () => (lookups++, new Response(JSON.stringify({ data }))));
    answer([{ id: "price_m", lookup_key: "coach_monthly" }]);
    expect(await planPrices("sk", t)).toEqual({ month: "price_m" });
    answer([{ id: "price_m", lookup_key: "coach_monthly" }, { id: "price_y", lookup_key: "coach_yearly" }]);
    expect(await planPrices("sk", t + 60_000)).toEqual({ month: "price_m" });
    expect(await planPrices("sk", t + 6 * 60_000)).toEqual({ month: "price_m", year: "price_y" });
    expect(lookups).toBe(2);
  });
});

describe("subscription events", () => {
  it("say the plan's status, interval and renewal", () => {
    expect(recordFrom(sub, 100)).toEqual({
      uid: "sam",
      record: { customer: "cus_1", subscription: "sub_1", status: "active", interval: "month", renews: "2026-11-18T11:06:40.000Z", cancelsAtEnd: false, eventAt: 100 },
    });
  });

  it("ignore subscriptions that aren't the coach plan's or have no account", () => {
    expect(recordFrom({ ...sub, metadata: {} }, 100)).toBeUndefined();
    const other = { ...sub, items: { data: [{ price: { lookup_key: "something_else" } }] } };
    expect(recordFrom(other, 100)).toBeUndefined();
  });

  it("are saved unless a newer one already was", async () => {
    send.mockResolvedValue({});
    await saveSubscription({ ...sub, status: "past_due" }, 200);
    const input = send.mock.calls[0][0].input;
    expect(input.Key).toEqual({ PK: "USER#sam", SK: "COACHPLAN" });
    expect(input.ConditionExpression).toBe("attribute_not_exists(eventAt) OR eventAt <= :eventAt");
    expect(input.ExpressionAttributeValues[":status"]).toBe("past_due");
    expect(input.ExpressionAttributeValues[":eventAt"]).toBe(200);
  });
});

describe("the plan shown", () => {
  it("is none without a subscription", () => {
    expect(shownPlan(false)).toEqual({ onSale: false, status: "none", interval: undefined, renews: undefined, cancelsAtEnd: false });
    expect(shownPlan(true, { status: "active", interval: "year", renews: "2027-10-17T00:00:00.000Z", cancelsAtEnd: true }))
      .toMatchObject({ onSale: true, status: "active", interval: "year", cancelsAtEnd: true });
  });
});
