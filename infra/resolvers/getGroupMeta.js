import { util } from "@aws-appsync/utils";

// After requireMember: stashes the group's META for the creator-only operations.
export function request(ctx) {
  return {
    operation: "GetItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${ctx.args.groupId}`, SK: "META" }),
    consistentRead: true,
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  if (!ctx.result) util.error("Group not found", "NotFound");
  ctx.stash.meta = ctx.result;
  return ctx.result;
}
