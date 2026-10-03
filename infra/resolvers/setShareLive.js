import { util } from "@aws-appsync/utils";

// After requireMember.
export function request(ctx) {
  return {
    operation: "UpdateItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${ctx.args.groupId}`, SK: `MEMBER#${ctx.identity.sub}` }),
    update: {
      expression: "SET shareLive = :s",
      expressionValues: util.dynamodb.toMapValues({ ":s": ctx.args.shareLive }),
    },
    condition: { expression: "attribute_exists(PK)" },
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
