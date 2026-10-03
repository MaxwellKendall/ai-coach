import { util } from "@aws-appsync/utils";

export function request(ctx) {
  return {
    operation: "GetItem",
    key: util.dynamodb.toMapValues({ PK: `USER#${ctx.identity.sub}`, SK: "PROFILE" }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  ctx.stash.profile = ctx.result ?? null;
  return ctx.result ?? null;
}
