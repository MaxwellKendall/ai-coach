import { util } from "@aws-appsync/utils";

// FIT-200: delete a reply I wrote; as editComment, the key ends with my uid.
export function request(ctx) {
  if (!util.matches("^\\d{4}-\\d{2}-\\d{2}$", ctx.args.day)) util.error("Not a day.", "BadRequest");
  const me = ctx.identity.sub;
  return {
    operation: "DeleteItem",
    key: util.dynamodb.toMapValues({ PK: `USER#${ctx.args.uid ?? me}`, SK: `COMMENT#${ctx.args.day}#${ctx.args.at}#${me}` }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return true;
}
