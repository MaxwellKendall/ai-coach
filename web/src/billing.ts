import type { Config } from "./auth";
import { gql } from "./sync";

// FIT-144: the coach plan (FIT-133: $19.99/month or $199/year), bought and managed through Stripe.

export type CoachPlan = { onSale: boolean; status: string; interval: string | null; renews: string | null; cancelsAtEnd: boolean };

export const coachPlan = (config: Config) =>
  gql<{ coachPlan: CoachPlan }>(config, `query { coachPlan { onSale status interval renews cancelsAtEnd } }`).then((d) => d.coachPlan);

export const startCoachPlan = (config: Config, interval: "month" | "year") =>
  gql<{ startCoachPlan: string | null }>(config, `mutation($i: String!) { startCoachPlan(interval: $i) }`, { i: interval }).then((d) => d.startCoachPlan);

export const coachBillingPortal = (config: Config) =>
  gql<{ coachBillingPortal: string | null }>(config, `mutation { coachBillingPortal }`).then((d) => d.coachBillingPortal);

export const PRICES = { month: "$19.99/month", year: "$199/year" };

/** What Billing says about the plan, and which button it offers: start one, or manage the one there is. */
export function planView(plan: CoachPlan): { title: string; detail: string; action: "start" | "manage" | "none" } {
  const date = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) : "");
  const which = plan.interval === "year" ? "yearly" : "monthly";
  switch (plan.status) {
    case "trialing":
    case "active":
      return {
        title: `Coach plan, ${which}`,
        detail: plan.cancelsAtEnd ? `Ends ${date(plan.renews)}. You can renew it from Manage billing.` : `Renews ${date(plan.renews)}.`,
        action: "manage",
      };
    case "past_due":
    case "unpaid":
    case "incomplete":
      return { title: "Your last payment didn't go through", detail: "Update your card in Manage billing to keep the coach plan.", action: "manage" };
    case "canceled":
    case "incomplete_expired":
      return { title: "Your coach plan has ended", detail: "Coaching is free during the beta. You can start the plan again any time.", action: plan.onSale ? "start" : "none" };
    default:
      return plan.onSale
        ? { title: "Coach plan", detail: `${PRICES.month} or ${PRICES.year}. Coaching is free during the beta.`, action: "start" }
        : { title: "Coach plan", detail: "The coach plan goes on sale soon. Coaching is free during the beta.", action: "none" };
  }
}
