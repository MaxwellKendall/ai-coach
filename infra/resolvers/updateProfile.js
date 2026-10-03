import { util } from "@aws-appsync/utils";

export function request(ctx) {
  const now = util.time.nowISO8601();
  const names = { "#u": "updatedAt", "#c": "createdAt", "#id": "uid" };
  const values = { ":u": now, ":id": ctx.identity.sub };
  const sets = ["#u = :u", "#c = if_not_exists(#c, :u)", "#id = :id"];
  for (const field of ["displayName", "units"]) {
    if (ctx.args[field] != null) {
      names[`#${field}`] = field;
      values[`:${field}`] = ctx.args[field];
      sets.push(`#${field} = :${field}`);
    }
  }
  return {
    operation: "UpdateItem",
    key: util.dynamodb.toMapValues({ PK: `USER#${ctx.identity.sub}`, SK: "PROFILE" }),
    update: {
      expression: `SET ${sets.join(", ")}`,
      expressionNames: names,
      expressionValues: util.dynamodb.toMapValues(values),
    },
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
