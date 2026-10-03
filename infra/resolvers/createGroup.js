import { util } from "@aws-appsync/utils";

// After getProfile. Writes the group, the creator's membership and the invite together.
export function request(ctx) {
  const uid = ctx.identity.sub;
  const groupId = util.autoId();
  const inviteCode = util.autoId().slice(0, 8).toUpperCase();
  const now = util.time.nowISO8601();
  const name = ctx.args.name;
  const table = ctx.env.TABLE;
  ctx.stash.created = { groupId, inviteCode };
  return {
    operation: "TransactWriteItems",
    transactItems: [
      {
        table,
        operation: "PutItem",
        key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: "META" }),
        attributeValues: util.dynamodb.toMapValues({ name, createdBy: uid, inviteCode, createdAt: now, updatedAt: now }),
        condition: { expression: "attribute_not_exists(PK)" },
      },
      {
        table,
        operation: "PutItem",
        key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: `MEMBER#${uid}` }),
        attributeValues: util.dynamodb.toMapValues({
          groupId,
          uid,
          groupName: name,
          displayName: ctx.stash.profile?.displayName ?? null,
          role: "member",
          shareLive: false,
          joinedAt: now,
          GSI1PK: `USER#${uid}`,
          GSI1SK: `GROUP#${groupId}`,
        }),
      },
      {
        table,
        operation: "PutItem",
        key: util.dynamodb.toMapValues({ PK: `INVITE#${inviteCode}`, SK: "META" }),
        attributeValues: util.dynamodb.toMapValues({ groupId, groupName: name, createdBy: uid, createdAt: now }),
        condition: { expression: "attribute_not_exists(PK)" },
      },
    ],
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return { ...ctx.stash.created, name: ctx.args.name, role: "member" };
}
