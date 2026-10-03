// Minimal stand-in for the APPSYNC_JS runtime's util and extensions.
export class Unauthorized extends Error {}
export class ResolverError extends Error {
  constructor(message: string, public type?: string) {
    super(message);
  }
}

export const util = {
  error(message: string, type?: string): never {
    throw new ResolverError(message, type);
  },
  unauthorized(): never {
    throw new Unauthorized("Unauthorized");
  },
  autoId: () => "11111111-2222-3333-4444-555555555555",
  time: { nowISO8601: () => "2026-10-03T12:00:00.000Z", nowEpochSeconds: () => 1_790_000_000 },
  // Identity, so tests read plain values instead of DynamoDB attribute maps.
  dynamodb: { toMapValues: <T>(v: T) => v },
  transform: { toSubscriptionFilter: <T>(f: T) => ({ filter: f }) },
};

export const subscriptionFilters: unknown[] = [];
export const extensions = {
  setSubscriptionFilter: (f: unknown) => subscriptionFilters.push(f),
};
