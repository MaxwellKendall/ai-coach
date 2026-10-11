import { util } from "@aws-appsync/utils";

// FIT-114, after requireMember: stop sharing my week with this group.
export function request(ctx) {
  return {
    operation: "DeleteItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${ctx.args.groupId}`, SK: `WEEK#${ctx.identity.sub}` }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return true;
}
