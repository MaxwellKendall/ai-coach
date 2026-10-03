import { util } from "@aws-appsync/utils";

// After requireMember.
export function request(ctx) {
  return {
    operation: "UpdateItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${ctx.args.groupId}`, SK: `LIVE#${ctx.identity.sub}` }),
    update: {
      expression: "SET #s = :done, updatedAt = :now",
      expressionNames: { "#s": "state" },
      expressionValues: util.dynamodb.toMapValues({ ":done": "done", ":now": util.time.nowISO8601() }),
    },
    condition: { expression: "attribute_exists(PK)" },
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
