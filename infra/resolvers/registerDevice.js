import { util } from "@aws-appsync/utils";

export function request(ctx) {
  const { token, platform } = ctx.args;
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `USER#${ctx.identity.sub}`, SK: `DEVICE#${token}` }),
    attributeValues: util.dynamodb.toMapValues({ token, platform, updatedAt: util.time.nowISO8601() }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return true;
}
