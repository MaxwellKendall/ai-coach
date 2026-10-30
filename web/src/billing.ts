import type { Config, User } from "./auth";
import { gql } from "./sync";

// FIT-144: the coach plan (FIT-133: $19.99/month or $199/year), bought and managed through Stripe. FIT-284: it's Pro,
// the exhaustive coach MCP; coaching itself is free.

export type CoachPlan = { onSale: boolean; status: string; interval: string | null; renews: string | null; cancelsAtEnd: boolean };

export const coachPlan = (config: Config) =>
  gql<{ coachPlan: CoachPlan }>(config, `query { coachPlan { onSale status interval renews cancelsAtEnd } }`).then((d) => d.coachPlan);

export const startCoachPlan = (config: Config, interval: "month" | "year") =>
  gql<{ startCoachPlan: string | null }>(config, `mutation($i: String!) { startCoachPlan(interval: $i) }`, { i: interval }).then((d) => d.startCoachPlan);

export const coachBillingPortal = (config: Config) =>
  gql<{ coachBillingPortal: string | null }>(config, `mutation { coachBillingPortal }`).then((d) => d.coachBillingPortal);

export const PRICES = { month: "$19.99/month", year: "$199/year" };

/** FIT-148: Stripe's statuses that still have the plan, as the server's check (coachPlan.ts HAS_PLAN). */
export const hasPlan = (plan: CoachPlan) => ["active", "trialing", "past_due"].includes(plan.status);

/** What Billing says about the plan, and which button it offers: start one, or manage the one there is. */
export function planView(plan: CoachPlan): { title: string; detail: string; action: "start" | "manage" | "none" } {
  const date = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) : "");
  const which = plan.interval === "year" ? "yearly" : "monthly";
  switch (plan.status) {
    case "trialing":
    case "active":
      return {
        title: `Pro, ${which}`,
        detail: plan.cancelsAtEnd ? `Ends ${date(plan.renews)}. You can renew it from Manage billing.` : `Renews ${date(plan.renews)}.`,
        action: "manage",
      };
    case "past_due":
    case "unpaid":
    case "incomplete":
      return { title: "Your last payment didn't go through", detail: "Update your card in Manage billing to keep Pro.", action: "manage" };
    case "canceled":
    case "incomplete_expired":
      return {
        title: "Your Pro has ended",
        detail: "Coaching here stays free, with all your clients. Start Pro again to coach them from Claude.",
        action: plan.onSale ? "start" : "none",
      };
    default:
      return plan.onSale
        ? { title: "Pro", detail: `${PRICES.month} or ${PRICES.year}. Coaching here is free, with any number of clients. Pro lets Claude program and review your whole roster.`, action: "start" }
        : { title: "Pro", detail: "Pro goes on sale soon. Coaching here is free, with any number of clients.", action: "none" };
  }
}

/**
 * FIT-241: the plan belongs to the account signed in here, and Claude must be connected with the same sign-in (or one
 * linked to it on Account); a different one is a second account without the plan.
 */
export function signedInAs(me: User) {
  const via = me.provider === "google" ? "Google" : me.provider === "apple" ? "Apple" : "email";
  const who = me.email ? `${me.email}, with ${via}` : `your ${via} sign-in`;
  return `This plan is for the account you're signed in to as ${who}. Connect Claude with the same sign-in, or link the two on Account.`;
}
