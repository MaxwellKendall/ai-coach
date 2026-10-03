import { util } from "@aws-appsync/utils";

// After requireMember. Progress items stay but are hidden by groupDetail; deleteAccount removes them.
export function request(ctx) {
  const uid = ctx.identity.sub;
  const pk = `GROUP#${ctx.args.groupId}`;
  return {
    operation: "TransactWriteItems",
    transactItems: [
      { table: ctx.env.TABLE, operation: "DeleteItem", key: util.dynamodb.toMapValues({ PK: pk, SK: `MEMBER#${uid}` }) },
      { table: ctx.env.TABLE, operation: "DeleteItem", key: util.dynamodb.toMapValues({ PK: pk, SK: `LIVE#${uid}` }) },
    ],
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return true;
}
