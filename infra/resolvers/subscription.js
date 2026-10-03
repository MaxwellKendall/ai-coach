import { util, extensions } from "@aws-appsync/utils";

// Subscribe-time resolver, after requireMember: only that group's events reach this subscriber.
export function request() {
  return {};
}

export function response(ctx) {
  extensions.setSubscriptionFilter(util.transform.toSubscriptionFilter({ groupId: { eq: ctx.args.groupId } }));
  return null;
}
