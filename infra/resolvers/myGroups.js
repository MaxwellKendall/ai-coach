import { util } from "@aws-appsync/utils";

export function request(ctx) {
  return {
    operation: "Query",
    index: "GSI1",
    query: {
      expression: "GSI1PK = :pk",
      expressionValues: util.dynamodb.toMapValues({ ":pk": `USER#${ctx.identity.sub}` }),
    },
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result.items.map((m) => ({ groupId: m.groupId, name: m.groupName, role: m.role }));
}
