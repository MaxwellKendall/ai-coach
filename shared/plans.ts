// FIT-437: Barbrabell's three tiers, as the site, the dashboard and the docs describe them. Both paid plans are sold in
// the iPhone app (App Store) and on the web (Stripe), and either one counts everywhere: the app, the dashboard and the
// connector. Prices match Stripe and appstore/subscriptions.json; tests hold them to it.

/** Lifter Pro's free trial. 14 days today, still to confirm with the author (FIT-437): change it here, nowhere else. */
export const TRIAL_DAYS = 14;

export const PLANS = {
  lifter: { name: "Lifter Pro", month: "$5.99", year: "$39.99" },
  coach: { name: "Coach Pro", month: "$19.99", year: "$199" },
} as const;

export type PlanKind = keyof typeof PLANS;

/** "$5.99 a month or $39.99 a year". */
export const priceLine = (kind: PlanKind) => `${PLANS[kind].month} a month or ${PLANS[kind].year} a year`;

/** Where someone manages or cancels Pro: wherever they bought it. */
export const MANAGE = {
  appStore: "on your iPhone, in Settings › your name › Subscriptions",
  web: "from Billing on the dashboard",
};
