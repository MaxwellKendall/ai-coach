import { util } from "@aws-appsync/utils";

export function request(ctx) {
  return {
    operation: "GetItem",
    key: util.dynamodb.toMapValues({ PK: `INVITE#${ctx.args.inviteCode.toUpperCase()}`, SK: "META" }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  if (!ctx.result) util.error("Invite not found", "NotFound");
  ctx.stash.invite = ctx.result;
  return ctx.result;
}
