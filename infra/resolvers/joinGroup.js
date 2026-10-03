import { util } from "@aws-appsync/utils";

// After getInvite and getProfile. Joining twice is a no-op, so a shared link can be tapped again.
export function request(ctx) {
  const uid = ctx.identity.sub;
  const { groupId, groupName } = ctx.stash.invite;
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `GROUP#${groupId}`, SK: `MEMBER#${uid}` }),
    attributeValues: util.dynamodb.toMapValues({
      groupId,
      uid,
      groupName,
      displayName: ctx.stash.profile?.displayName ?? null,
      role: "member",
      shareLive: false,
      joinedAt: util.time.nowISO8601(),
      GSI1PK: `USER#${uid}`,
      GSI1SK: `GROUP#${groupId}`,
    }),
    condition: { expression: "attribute_not_exists(PK)" },
  };
}

export function response(ctx) {
  if (ctx.error && ctx.error.type !== "DynamoDB:ConditionalCheckFailedException") {
    util.error(ctx.error.message, ctx.error.type);
  }
  return { groupId: ctx.stash.invite.groupId, name: ctx.stash.invite.groupName, role: "member" };
}
