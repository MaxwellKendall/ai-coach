import { util } from "@aws-appsync/utils";

// After requireMember and getGroupMeta. FIT-59 (guideline 1.2): the group's creator can remove a member.
// groupCleanup (FIT-61) runs on the removed MEMBER# item like any other.
export function request(ctx) {
  const { groupId, uid } = ctx.args;
  if (ctx.stash.meta.createdBy !== ctx.identity.sub) util.unauthorized();
  if (uid === ctx.identity.sub) util.error("Use leaveGroup to leave", "BadRequest");
  const pk = `GROUP#${groupId}`;
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
