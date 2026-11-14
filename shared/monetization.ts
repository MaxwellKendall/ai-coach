// FIT-454 (author, 2026-11-14): how Barbrabell makes money from lifters on their own, switched on the server without an
// app release. `npm run monetization -- STAGE hard|freemium` (infra/) flips it; the app reads /monetization.json at
// launch and the connector reads it on every call.
//
// hard: the AbMaxx-style first launch ends on a paywall with no way past it but Lifter Pro (or Coach Pro, or a coach),
//   and the connector's own-training tools need Pro too. Only for people who arrive after it was switched on (`since`):
//   anyone already using the app or the connector stays as they were.
// freemium: the same first launch ends on the paywall with Not Now, into the free app; Lifter Pro is sold for AI
//   planning and the connector's planning tools, as since FIT-437.
// Coaching (the dashboard, the app's coach mode, and the coach tools' free part) is the same in both.

export const STRATEGIES = ["hard", "freemium"] as const;
export type Strategy = (typeof STRATEGIES)[number];

/** Without a saved choice: what was live before the switch existed. */
export const DEFAULT_STRATEGY: Strategy = "freemium";

export type Monetization = { strategy: Strategy; since: string | null };

export const isStrategy = (value: unknown): value is Strategy => STRATEGIES.includes(value as Strategy);

/** The saved row as the app and the connector see it; anything unreadable is the default. */
export function monetizationOf(item: Record<string, unknown> | undefined): Monetization {
  const strategy = isStrategy(item?.strategy) ? item.strategy : DEFAULT_STRATEGY;
  const since = strategy === "hard" && typeof item?.since === "string" ? item.since : null;
  return { strategy, since };
}

/** The new choice. `since` is when hard was switched on, kept while it stays on, so who's grandfathered never moves. */
export function switched(current: Monetization, strategy: Strategy, now: Date): Monetization {
  if (strategy !== "hard") return { strategy, since: null };
  return { strategy, since: current.strategy === "hard" && current.since ? current.since : now.toISOString() };
}

/** Hard mode holds for someone first seen at `firstSeen`: on or after it was switched on. */
export function hardFor(monetization: Monetization, firstSeen: string): boolean {
  return monetization.strategy === "hard" && monetization.since !== null && Date.parse(firstSeen) >= Date.parse(monetization.since);
}
