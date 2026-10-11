import { util } from "@aws-appsync/utils";

// FIT-113: any signed-in user can read a share by its id; the same is on its public page.
export function request(ctx) {
  if (!util.matches("^[0-9a-f]{12}$", ctx.args.id)) util.error("No such share.", "NotFound");
  return { operation: "GetItem", key: util.dynamodb.toMapValues({ PK: `SHARE#${ctx.args.id}`, SK: "META" }) };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  const item = ctx.result;
  if (!item) return null;
  // Stored as text; parsed so AppSync encodes the AWSJSON once, not a string of it.
  return { id: ctx.args.id, kind: item.kind, name: item.name ?? null, payload: JSON.parse(item.payload) };
}
