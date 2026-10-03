import { util } from "@aws-appsync/utils";

// First function of every group pipeline: the caller must be a member of args.groupId.
export function request(ctx) {
  return {
    operation: "GetItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${ctx.args.groupId}`, SK: `MEMBER#${ctx.identity.sub}` }),
    consistentRead: true,
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  if (!ctx.result) util.unauthorized();
  ctx.stash.member = ctx.result;
  return ctx.result;
}
