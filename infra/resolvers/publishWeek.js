import { util } from "@aws-appsync/utils";

// FIT-114, after requireMember. Always keyed by the caller's uid; a week of days, each a session name.
export function request(ctx) {
  const uid = ctx.identity.sub;
  const { groupId, weekOf, days } = ctx.args;
  if (days.length > 7) util.error("A week has 7 days.", "BadRequest");
  for (const d of days) if (d.title.length > 40) util.error("A session's name is at most 40 characters.", "BadRequest");
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: `WEEK#${uid}` }),
    attributeValues: util.dynamodb.toMapValues({ groupId, uid, weekOf, days, updatedAt: util.time.nowISO8601() }),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
