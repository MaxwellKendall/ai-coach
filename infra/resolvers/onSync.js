import { util, extensions } from "@aws-appsync/utils";

// FIT-126: subscribe-time resolver: only my own uid, and only my own pushes reach me.
export function request(ctx) {
  if (ctx.args.uid !== ctx.identity.sub) util.unauthorized();
  return {};
}

export function response(ctx) {
  extensions.setSubscriptionFilter(util.transform.toSubscriptionFilter({ uid: { eq: ctx.identity.sub } }));
  return null;
}
