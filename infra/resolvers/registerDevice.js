import { util } from "@aws-appsync/utils";

export function request(ctx) {
  const { token, platform, tz, nudges } = ctx.args;
  const uid = ctx.identity.sub;
  const values = { token, platform, updatedAt: util.time.nowISO8601() };
  // FIT-220: a device that takes the evening nudge is listed under GSI1 NUDGE, which the nudge Lambda reads each hour.
  if (tz && nudges !== false) Object.assign(values, { tz, GSI1PK: "NUDGE", GSI1SK: `${uid}#${token}` });
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `USER#${uid}`, SK: `DEVICE#${token}` }),
    attributeValues: util.dynamodb.toMapValues(values),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return true;
}
