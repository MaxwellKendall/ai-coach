import { util } from "@aws-appsync/utils";

// One query for everything except the feed. Sort keys GOAL#, LIVE#, MEMBER#, META and PROGRESS#
// all sort at or after "G"; FEED# sorts before it and has its own paged field resolver.
export function request(ctx) {
  return {
    operation: "Query",
    query: {
      expression: "PK = :pk AND SK >= :g",
      expressionValues: util.dynamodb.toMapValues({ ":pk": `GROUP#${ctx.args.groupId}`, ":g": "G" }),
    },
    consistentRead: true,
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  const items = ctx.result.items;
  const meta = items.find((i) => i.SK === "META");
  if (!meta) return null;
  const members = items.filter((i) => i.SK.startsWith("MEMBER#"));
  const memberIds = members.map((m) => m.uid);
  return {
    id: ctx.args.groupId,
    name: meta.name,
    createdBy: meta.createdBy,
    inviteCode: meta.inviteCode,
    createdAt: meta.createdAt,
    updatedAt: meta.updatedAt,
    members,
    goals: items.filter((i) => i.SK.startsWith("GOAL#")),
    // Members who left keep their PROGRESS items until deleteAccount; don't show them.
    progress: items.filter((i) => i.SK.startsWith("PROGRESS#") && memberIds.indexOf(i.uid) >= 0),
    live: items.filter((i) => i.SK.startsWith("LIVE#") && memberIds.indexOf(i.uid) >= 0),
  };
}
