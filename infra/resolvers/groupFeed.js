import { util } from "@aws-appsync/utils";

// Group.feed: only reachable through group(groupId), which already checked membership.
export function request(ctx) {
  return {
    operation: "Query",
    query: {
      expression: "PK = :pk AND begins_with(SK, :f)",
      expressionValues: util.dynamodb.toMapValues({ ":pk": `GROUP#${ctx.source.id}`, ":f": "FEED#" }),
    },
    scanIndexForward: false,
    limit: Math.min(ctx.args.limit ?? 20, 100),
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result.items;
}
