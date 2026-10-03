import { util } from "@aws-appsync/utils";

const DAY_SECONDS = 24 * 60 * 60;

// After requireMember. One item per member, overwritten every set (FIT-53): a live view, not a log.
export function request(ctx) {
  // FIT-53 privacy: live sharing is opt-in per group.
  if (!ctx.stash.member.shareLive) util.unauthorized();
  const uid = ctx.identity.sub;
  const { groupId } = ctx.args;
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: `LIVE#${uid}` }),
    attributeValues: util.dynamodb.toMapValues({
      ...ctx.args,
      groupId,
      uid,
      updatedAt: util.time.nowISO8601(),
      expiresAt: util.time.nowEpochSeconds() + DAY_SECONDS,
    }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
