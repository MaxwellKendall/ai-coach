import { util } from "@aws-appsync/utils";

// After requireMember.
export function request(ctx) {
  const { groupId, kind, measurements } = ctx.args;
  const id = util.autoId();
  const now = util.time.nowISO8601();
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: `FEED#${now}#${id}` }),
    attributeValues: util.dynamodb.toMapValues({
      groupId,
      id,
      uid: ctx.identity.sub,
      kind,
      measurements: measurements ?? null,
      createdAt: now,
    }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
