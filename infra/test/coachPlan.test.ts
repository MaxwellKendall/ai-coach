import { beforeEach, describe, expect, it, vi } from "vitest";

// FIT-144: the coach plan, a Stripe subscription. The table and the Stripe secret are stubbed; Stripe is a fetch stub.
const send = vi.fn();
vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return { ...actual, DynamoDBDocumentClient: { from: () => ({ send }) } };
});
const keys = vi.fn();
vi.mock("../lambda/gifts.ts", () => ({ stripeConfig: () => keys() }));

const { checkoutParams, kindOf, onSale, planPrices, portal, portalConfiguration, quizAnswers, recordFrom, replaces, saveSubscription, shownPlan, start, trainerPlan } = await import("../lambda/coachPlan.ts");
const { ConditionalCheckFailedException } = await import("@aws-sdk/client-dynamodb");
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

  it("FIT-189: won't start a second plan Stripe already has, though the webhook hasn't said so", async () => {
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    send.mockResolvedValue({ Item: { customer: "cus_1", status: "canceled", subscription: "sub_0", eventAt: 50 } });
    const calls: string[] = [];
    let listed: object[] = [{ ...sub, id: "sub_2", metadata: {} }];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      const path = url.replace("https://api.stripe.com/v1/", "");
      calls.push(`${init.method} ${path}`);
      const body = path.startsWith("subscriptions") ? { data: listed }
        : path.startsWith("prices") ? { data: [{ id: "price_m", lookup_key: "coach_monthly" }, { id: "price_y", lookup_key: "coach_yearly" }] }
        : { url: "https://checkout.stripe.com/c/3" };
      return new Response(JSON.stringify(body));
    });
    await expect(start("sam", "month")).rejects.toThrow("already have the coach plan");
    expect(calls).toEqual(["GET subscriptions?customer=cus_1&limit=100"]);
    // The record catches up with Stripe, for the uid the subscription's metadata lacked.
    const saved = send.mock.calls.at(-1)![0].input;
    expect(saved.Key).toEqual({ PK: "USER#sam", SK: "COACHPLAN" });
    expect(saved.ExpressionAttributeValues).toMatchObject({ ":subscription": "sub_2", ":status": "active" });
    // Pro's subscription, or one that has ended, isn't the coach plan.
    listed = [{ ...sub, id: "sub_3", status: "incomplete_expired" }, { ...sub, id: "sub_4", items: { data: [{ price: { lookup_key: "pro_monthly" } }] } }];
    expect(await start("sam", "month")).toBe("https://checkout.stripe.com/c/3");
    // A key that can't list them goes on to Checkout.
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    listed = undefined as never;
    vi.stubGlobal("fetch", async (url: string) => url.includes("subscriptions")
      ? new Response(JSON.stringify({ error: { message: "The provided key does not have the required permissions" } }), { status: 403 })
      : new Response(JSON.stringify(url.includes("prices") ? { data: [{ id: "price_m", lookup_key: "coach_monthly" }] } : { url: "https://checkout.stripe.com/c/4" })));
    expect(await start("sam", "month")).toBe("https://checkout.stripe.com/c/4");
    expect(error).toHaveBeenCalledWith("Couldn't list subscriptions", expect.any(String));
    error.mockRestore();
  });

  it("opens the plan's own customer portal back to Billing", async () => {
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    send.mockResolvedValue({ Item: { customer: "cus_1" } });
    let sent = "";
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      if (url.includes("configurations")) {
        return new Response(JSON.stringify({ data: [{ id: "bpc_pro", metadata: { plan: "pro" } }, { id: "bpc_coach", metadata: { plan: "coach" } }] }));
      }
      sent = String(init.body);
      return new Response(JSON.stringify({ url: "https://billing.stripe.com/p/1" }));
    });
    expect(await portal("sam", "https://app.example.com")).toBe("https://billing.stripe.com/p/1");
    expect(decodeURIComponent(sent)).toBe("customer=cus_1&configuration=bpc_coach&return_url=https://app.example.com/billing");
    send.mockResolvedValue({});
    expect(await portal("ann")).toBeUndefined();
  });
});

describe("FIT-190: Pro's checkout", () => {
  it("comes back to the site's pages, not the dashboard's billing", () => {
    const params = checkoutParams("sam", "cus_1", "price_1", "https://barbrabell.com", "pro");
    expect(params.success_url).toBe("https://barbrabell.com/pro/thanks");
    expect(params.cancel_url).toBe("https://barbrabell.com/claude");
  });

  it("looks up Pro's prices and keeps its customer on PROPLAN", async () => {
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    send.mockResolvedValueOnce({}).mockResolvedValueOnce({}).mockResolvedValueOnce({});
    const calls: string[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      const path = url.replace("https://api.stripe.com/v1/", "");
      calls.push(`${init.method} ${path}`);
      const body = path.startsWith("prices") ? { data: [{ id: "price_pm", lookup_key: "pro_monthly" }, { id: "price_py", lookup_key: "pro_yearly" }] } : path === "customers" ? { id: "cus_new" } : { url: "https://checkout.stripe.com/c/2" };
      return new Response(JSON.stringify(body));
    });
    expect(await start("sam", "month", undefined, "https://barbrabell.com", "pro")).toBe("https://checkout.stripe.com/c/2");
    expect(calls[0]).toBe("GET prices?active=true&lookup_keys[]=pro_monthly&lookup_keys[]=pro_yearly");
    expect(send.mock.calls[0][0].input.Key).toEqual({ PK: "USER#sam", SK: "PROPLAN" });
    expect(send.mock.calls[2][0].input.Key).toEqual({ PK: "USER#sam", SK: "PROPLAN" });
  });
});

describe("FIT-281: the consumer plan's checkout", () => {
  it("has the 7-day free trial and comes back to the quiz's pages", () => {
    const params = checkoutParams("sam", "cus_1", "price_t", "https://site.example.com/app", "trainer");
    expect(decodeURIComponent(form(params))).toContain("subscription_data[trial_period_days]=7");
    expect(params.success_url).toBe("https://site.example.com/app/start/thanks");
    expect(params.cancel_url).toBe("https://site.example.com/app/start");
    expect(decodeURIComponent(form(checkoutParams("sam", "cus_1", "price_1", "https://x")))).not.toContain("trial_period_days");
  });

  it("is yearly only, on sale with its one price, and kept on TRAINERPLAN", async () => {
    keys.mockResolvedValue({ secretKey: "sk_test_1" });
    const fetch = vi.fn(async (url: string) => {
      if (url.includes("/prices")) return Response.json({ data: [{ id: "price_t", lookup_key: "trainer_yearly" }] });
      if (url.includes("/customers")) return Response.json({ id: "cus_t" });
      if (url.includes("/subscriptions")) return Response.json({ data: [] });
      return Response.json({ url: "https://checkout.stripe.com/t" });
    });
    vi.stubGlobal("fetch", fetch);
    send.mockResolvedValue({});
    expect(await onSale("trainer")).toBe(true);
    await expect(start("sam", "month", undefined, "https://x", "trainer")).rejects.toThrow("yearly");
    expect(await start("sam", "year", undefined, "https://x", "trainer")).toBe("https://checkout.stripe.com/t");
    expect(send.mock.calls.some(([c]) => c.input.Key?.SK === "TRAINERPLAN")).toBe(true);
  });

  it("knows the plan's subscriptions by the lookup key", () => {
    expect(kindOf({ ...sub, items: { data: [{ price: { lookup_key: "trainer_yearly" } }] } })).toBe("trainer");
  });
});

describe("FIT-281: the quiz's answers", () => {
  const gym = ["barbell", "rack", "bench", "dumbbells"];
  it("are kept as the program, the known equipment and the days in order", () => {
    expect(quizAnswers(JSON.stringify({ slug: "full-body-3", have: [...gym, "laser"], days: [4, 0, 2, 2] })))
      .toEqual({ slug: "full-body-3", have: gym, days: [0, 2, 4] });
  });
  it("keep the goal, whether they've lifted, and a recent set of the program's main lift", () => {
    const recent = { exercise: "back-squat", weight: 225, reps: 5 };
    expect(quizAnswers({ slug: "full-body-3", have: gym, days: [0, 2, 4], goal: "strength", lifted: true, recent }))
      .toEqual({ slug: "full-body-3", have: gym, days: [0, 2, 4], goal: "strength", lifted: true, recent });
    // Another lift, reps past the quiz's 12, someone new, or an unknown goal: left out.
    for (const odd of [{ ...recent, exercise: "curl" }, { ...recent, reps: 20 }, { ...recent, weight: -5 }]) {
      expect(quizAnswers({ slug: "full-body-3", have: gym, days: [0, 2, 4], lifted: true, recent: odd }).recent).toBeUndefined();
    }
    expect(quizAnswers({ slug: "full-body-3", have: gym, days: [0, 2, 4], lifted: false, recent }).recent).toBeUndefined();
    expect(quizAnswers({ slug: "full-body-3", have: gym, days: [0, 2, 4], goal: "fame" }).goal).toBeUndefined();
  });
  it("must fit the program", () => {
    expect(() => quizAnswers({ slug: "nope", have: gym, days: [0, 2, 4] })).toThrow("quiz");
    expect(() => quizAnswers({ slug: "full-body-3", have: gym, days: [0, 2] })).toThrow("3 days");
    expect(() => quizAnswers({ slug: "full-body-3", have: ["dumbbells"], days: [0, 2, 4] })).toThrow("equipment");
    expect(() => quizAnswers("{not json")).toThrow("quiz");
  });
  it("come back with the plan for the app", async () => {
    send.mockImplementation(async (c: { input: { Key: { SK: string } } }) =>
      c.input.Key.SK === "QUIZ" ? { Item: { answers: { slug: "full-body-3", have: gym, days: [0, 2, 4] } } } : { Item: { status: "trialing" } });
    const plan = await trainerPlan("sam");
    expect(plan.status).toBe("trialing");
    expect(JSON.parse(plan.answers!)).toEqual({ slug: "full-body-3", have: gym, days: [0, 2, 4] });
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
      kind: "coach",
      record: { customer: "cus_1", subscription: "sub_1", status: "active", interval: "month", renews: "2026-11-18T11:06:40.000Z", cancelsAtEnd: false, eventAt: 100 },
    });
  });

  it("ignore subscriptions that aren't the coach plan's or have no account", () => {
    expect(recordFrom({ ...sub, metadata: {} }, 100)).toBeUndefined();
    const other = { ...sub, items: { data: [{ price: { lookup_key: "something_else" } }] } };
    expect(recordFrom(other, 100)).toBeUndefined();
  });

  it("FIT-190: say which plan by the price's lookup key, Pro's kept apart from the coach plan", async () => {
    const pro = { ...sub, items: { data: [{ price: { lookup_key: "pro_yearly", recurring: { interval: "year" } } }] } };
    expect(recordFrom(pro, 100)).toMatchObject({ uid: "sam", kind: "pro", record: { status: "active", interval: "year" } });
    send.mockResolvedValue({});
    await saveSubscription(pro, 100);
    expect(send.mock.calls.at(-1)![0].input.Key).toEqual({ PK: "USER#sam", SK: "PROPLAN" });
  });

  it("FIT-212: don't start a second plan for a subscription kept as the other one", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const pro = { ...sub, items: { data: [{ price: { lookup_key: "pro_monthly", recurring: { interval: "month" } } }] } };
    send.mockResolvedValueOnce({ Item: { subscription: "sub_1", status: "active" } });
    await saveSubscription(pro, 300);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0].input.Key).toEqual({ PK: "USER#sam", SK: "COACHPLAN" });
    expect(error).toHaveBeenCalledWith("Subscription switched plans", "sub_1", "coach", "to", "pro");
    error.mockRestore();
  });

  it("are saved unless a newer one already was, if the record is still the one read", async () => {
    send.mockResolvedValue({});
    await saveSubscription({ ...sub, status: "past_due" }, 200);
    let input = send.mock.calls.at(-1)![0].input;
    expect(input.Key).toEqual({ PK: "USER#sam", SK: "COACHPLAN" });
    expect(input.ConditionExpression).toBe("attribute_not_exists(eventAt)");
    expect(input.ExpressionAttributeValues[":status"]).toBe("past_due");
    expect(input.ExpressionAttributeValues[":eventAt"]).toBe(200);
    send.mockReset();
    // The other two plans' records first (FIT-212), then this plan's.
    send.mockResolvedValueOnce({}).mockResolvedValueOnce({}).mockResolvedValueOnce({ Item: { subscription: "sub_1", status: "active", eventAt: 100 } }).mockResolvedValueOnce({});
    await saveSubscription({ ...sub, status: "past_due" }, 200);
    input = send.mock.calls.at(-1)![0].input;
    expect(input.ConditionExpression).toBe("eventAt = :seen");
    expect(input.ExpressionAttributeValues[":seen"]).toBe(100);
  });

  it("FIT-189: read again when another event saved first", async () => {
    send.mockResolvedValueOnce({}).mockResolvedValueOnce({})
      .mockResolvedValueOnce({ Item: { subscription: "sub_1", status: "active", eventAt: 100 } })
      .mockRejectedValueOnce(new ConditionalCheckFailedException({ message: "changed", $metadata: {} }))
      .mockResolvedValueOnce({ Item: { subscription: "sub_1", status: "active", eventAt: 300 } });
    await saveSubscription({ ...sub, status: "past_due" }, 200);
    // The newer event saved in between wins: no second write.
    expect(send).toHaveBeenCalledTimes(5);
  });

  it("FIT-189: an ended duplicate's event leaves the active plan alone", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    send.mockResolvedValueOnce({}).mockResolvedValueOnce({}).mockResolvedValueOnce({ Item: { subscription: "sub_2", status: "active", eventAt: 100 } });
    await saveSubscription({ ...sub, id: "sub_1", status: "canceled" }, 300);
    expect(send).toHaveBeenCalledTimes(3);
    expect(error).toHaveBeenCalledWith("Kept the plan's subscription", "sub_2", "over", "sub_1", "canceled");
    error.mockRestore();
  });
});

describe("FIT-189: which event replaces the plan kept", () => {
  const kept = { subscription: "sub_a", status: "active", eventAt: 100 };
  it("is the newest, for the same subscription", () => {
    expect(replaces(undefined, { subscription: "sub_a", status: "active", eventAt: 1 })).toBe(true);
    expect(replaces({ customer: "cus_1" }, { subscription: "sub_a", status: "active", eventAt: 1 })).toBe(true);
    expect(replaces(kept, { subscription: "sub_a", status: "canceled", eventAt: 200 })).toBe(true);
    expect(replaces(kept, { subscription: "sub_a", status: "canceled", eventAt: 50 })).toBe(false);
  });

  it("never takes away a plan another subscription still has", () => {
    expect(replaces(kept, { subscription: "sub_b", status: "canceled", eventAt: 200 })).toBe(false);
    expect(replaces({ ...kept, status: "past_due" }, { subscription: "sub_b", status: "unpaid", eventAt: 200 })).toBe(false);
  });

  it("gives the plan to a subscription that has it, newer or after the kept one ended", () => {
    expect(replaces(kept, { subscription: "sub_b", status: "active", eventAt: 200 })).toBe(true);
    expect(replaces(kept, { subscription: "sub_b", status: "trialing", eventAt: 50 })).toBe(false);
    const ended = { ...kept, status: "canceled" };
    expect(replaces(ended, { subscription: "sub_b", status: "active", eventAt: 0 })).toBe(true);
    expect(replaces(ended, { subscription: "sub_b", status: "incomplete_expired", eventAt: 200 })).toBe(true);
    expect(replaces(ended, { subscription: "sub_b", status: "incomplete_expired", eventAt: 50 })).toBe(false);
  });
});

describe("the plan shown", () => {
  it("is none without a subscription", () => {
    expect(shownPlan(false)).toEqual({ onSale: false, status: "none", interval: undefined, renews: undefined, cancelsAtEnd: false });
    expect(shownPlan(true, { status: "active", interval: "year", renews: "2027-10-17T00:00:00.000Z", cancelsAtEnd: true }))
      .toMatchObject({ onSale: true, status: "active", interval: "year", cancelsAtEnd: true });
  });
});

describe("FIT-212: each plan's portal", () => {
  // Last, and later than the other tests' times, since the price and portal lookups are cached per Lambda.
  it("is made once, switching only between the plan's own prices, then found by its metadata", async () => {
    const t = Date.now() + 7_200_000;
    const calls: string[] = [];
    let made = "";
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      const path = url.replace("https://api.stripe.com/v1/", "");
      calls.push(`${init.method} ${path}`);
      if (path.startsWith("billing_portal/configurations?")) return new Response(JSON.stringify({ data: [{ id: "bpc_default", metadata: {} }] }));
      if (path.startsWith("prices?")) return new Response(JSON.stringify({ data: [{ id: "price_pm", lookup_key: "pro_monthly" }, { id: "price_py", lookup_key: "pro_yearly" }] }));
      if (path.startsWith("prices/")) return new Response(JSON.stringify({ product: "prod_pro" }));
      made = decodeURIComponent(String(init.body));
      return new Response(JSON.stringify({ id: "bpc_new" }));
    });
    expect(await portalConfiguration("sk", t, "pro")).toBe("bpc_new");
    expect(calls.at(-1)).toBe("POST billing_portal/configurations");
    expect(made).toContain("metadata[plan]=pro");
    expect(made).toContain("features[subscription_update][products][0][product]=prod_pro");
    expect(made).toContain("features[subscription_update][products][0][prices][0]=price_pm&features[subscription_update][products][0][prices][1]=price_py");
    expect(made).not.toContain("products][1]");
    expect(made).toContain("features[subscription_cancel][mode]=at_period_end");
    const before = calls.length;
    expect(await portalConfiguration("sk", t + 60_000, "pro")).toBe("bpc_new");
    expect(calls.length).toBe(before);
  });

  it("is Stripe's default until the plan has both prices", async () => {
    vi.stubGlobal("fetch", async (url: string) => new Response(JSON.stringify({ data: url.includes("prices?") ? [{ id: "price_m", lookup_key: "coach_monthly" }] : [] })));
    expect(await portalConfiguration("sk", Date.now() + 10_800_000, "coach")).toBeUndefined();
  });
});
