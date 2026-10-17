import { describe, expect, it } from "vitest";
import { planView, type CoachPlan } from "./billing";

// FIT-144: what the Billing page says about the coach plan.
const plan = (over: Partial<CoachPlan>): CoachPlan => ({ onSale: true, status: "none", interval: null, renews: null, cancelsAtEnd: false, ...over });

describe("the coach plan on Billing (FIT-144)", () => {
  it("isn't on sale before Stripe is set up", () => {
    expect(planView(plan({ onSale: false }))).toMatchObject({ action: "none", detail: expect.stringContaining("on sale soon") });
  });

  it("offers both prices without a plan", () => {
    expect(planView(plan({}))).toMatchObject({ action: "start", detail: expect.stringContaining("$19.99/month or $199/year") });
  });

  it("says when an active plan renews, or ends", () => {
    const renews = "2026-11-17T12:00:00.000Z";
    expect(planView(plan({ status: "active", interval: "year", renews }))).toMatchObject({ title: "Coach plan, yearly", action: "manage", detail: expect.stringMatching(/^Renews /) });
    expect(planView(plan({ status: "trialing", interval: "month", renews, cancelsAtEnd: true }))).toMatchObject({ title: "Coach plan, monthly", detail: expect.stringMatching(/^Ends /) });
  });

  it("asks for a new card when a payment failed, and offers a fresh start once it's ended", () => {
    expect(planView(plan({ status: "past_due" }))).toMatchObject({ action: "manage", title: "Your last payment didn't go through" });
    expect(planView(plan({ status: "canceled" }))).toMatchObject({ action: "start", title: "Your coach plan has ended" });
  });
});
