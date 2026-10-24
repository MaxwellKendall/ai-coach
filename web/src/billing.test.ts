import { describe, expect, it } from "vitest";
import { hasPlan, needsPlan, planView, signedInAs, type CoachPlan } from "./billing";

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

describe("FIT-148: coaching needs the plan", () => {
  it("is had while Stripe still has it: active, trialing, or a payment being retried", () => {
    for (const status of ["active", "trialing", "past_due"]) expect(hasPlan(plan({ status }))).toBe(true);
    for (const status of ["none", "canceled", "unpaid", "incomplete", "incomplete_expired"]) expect(hasPlan(plan({ status }))).toBe(false);
  });

  it("knows the server's refusal", () => {
    expect(needsPlan(new Error("Coaching needs the coach plan, $19.99 a month or $199 a year. Start it on the Billing page."))).toBe(true);
    expect(needsPlan(new Error("You don't coach this person."))).toBe(false);
  });

  it("no longer says coaching is free", () => {
    for (const status of ["none", "canceled"]) {
      for (const onSale of [true, false]) expect(planView(plan({ status, onSale })).detail).not.toMatch(/free/);
    }
  });
});

describe("FIT-241: Billing says which account the plan is for", () => {
  it("names the sign-in, so Claude is connected with the same one", () => {
    expect(signedInAs({ uid: "u", email: "max@example.com", provider: "google", linked: ["google"] }))
      .toBe("This plan is for the account you're signed in to as max@example.com, with Google. Connect Claude with the same sign-in, or link the two on Account.");
    expect(signedInAs({ uid: "u", provider: "apple", linked: ["apple"] })).toMatch(/as your Apple sign-in\./);
  });
});
