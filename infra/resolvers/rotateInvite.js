import { util } from "@aws-appsync/utils";

// After requireMember and getGroupMeta. FIT-58: the creator revokes the invite code; a new one replaces it.
export function request(ctx) {
  const { groupId } = ctx.args;
  const meta = ctx.stash.meta;
  if (meta.createdBy !== ctx.identity.sub) util.unauthorized();
  const inviteCode = util.autoId().slice(0, 8).toUpperCase();
  const now = util.time.nowISO8601();
  const table = ctx.env.TABLE;
  ctx.stash.inviteCode = inviteCode;
  return {
    operation: "TransactWriteItems",
    transactItems: [
      {
        table,
        operation: "UpdateItem",
        key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: "META" }),
        update: {
          expression: "SET inviteCode = :c, updatedAt = :now",
          expressionValues: util.dynamodb.toMapValues({ ":c": inviteCode, ":now": now }),
        },
      },
      { table, operation: "DeleteItem", key: util.dynamodb.toMapValues({ PK: `INVITE#${meta.inviteCode}`, SK: "META" }) },
      {
        table,
        operation: "PutItem",
        key: util.dynamodb.toMapValues({ PK: `INVITE#${inviteCode}`, SK: "META" }),
        attributeValues: util.dynamodb.toMapValues({ groupId, groupName: meta.name, createdBy: meta.createdBy, createdAt: now }),
        condition: { expression: "attribute_not_exists(PK)" },
      },
    ],
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.stash.inviteCode;
}
