import { util } from "@aws-appsync/utils";

// FIT-105, after getProfile: saves what the user shared (a win, a recap or a program) and returns its link.
// The name on the page is the sharer's own display name, never one sent with the payload.
const kinds = { win: "w", recap: "r", program: "p" };

export function request(ctx) {
  const { kind } = ctx.args;
  if (!kinds[kind]) util.error("Only a win, a recap or a program can be shared.", "BadRequest");
  const payload = typeof ctx.args.payload === "string" ? ctx.args.payload : JSON.stringify(ctx.args.payload);
  if (payload.length > 8000) util.error("That's too much to share.", "BadRequest");
  const uid = ctx.identity.sub;
  const id = util.autoId().split("-").join("").slice(0, 12);
  const now = util.time.nowISO8601();
  ctx.stash.share = { id, url: `${ctx.env.SHARE_ORIGIN}/${kinds[kind]}/${id}` };
  return {
    operation: "PutItem",
    key: util.dynamodb.toMapValues({ PK: `SHARE#${id}`, SK: "META" }),
    attributeValues: util.dynamodb.toMapValues({
      kind,
      uid,
      name: ctx.stash.profile?.displayName ?? null,
      payload,
      createdAt: now,
      // Found again through the user, so deleting the account deletes it (deleteAccount).
      GSI1PK: `USER#${uid}`,
      GSI1SK: `SHARE#${id}`,
    }),
    condition: { expression: "attribute_not_exists(PK)" },
  };
}

export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.stash.share;
}
