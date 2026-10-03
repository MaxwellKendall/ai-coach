import { util } from "@aws-appsync/utils";

// After requireMember. Always keyed by the caller's uid.
export function request(ctx) {
  const uid = ctx.identity.sub;
  const { groupId, goalId } = ctx.args;
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: `PROGRESS#${uid}#${goalId}` }),
    attributeValues: util.dynamodb.toMapValues({
      ...ctx.args,
      groupId,
      uid,
      updatedAt: util.time.nowISO8601(),
    }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
