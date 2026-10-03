import { util } from "@aws-appsync/utils";

// After requireMember.
export function request(ctx) {
  const { groupId, metric, target, deadline, mode } = ctx.args;
  const goalId = util.autoId();
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: `GOAL#${goalId}` }),
    attributeValues: util.dynamodb.toMapValues({
      groupId,
      goalId,
      metric,
      target,
      deadline: deadline ?? null,
      mode,
      createdBy: ctx.identity.sub,
      createdAt: util.time.nowISO8601(),
    }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
