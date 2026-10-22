import { util } from "@aws-appsync/utils";

// FIT-200: change a reply I wrote. The key ends with my uid, so nobody else's reply can be reached; the thread is mine or
// a client's (uid), and a coach whose link has ended can still correct their own words.
export function request(ctx) {
  const text = (ctx.args.text ?? "").trim();
  if (!util.matches("^\\d{4}-\\d{2}-\\d{2}$", ctx.args.day)) util.error("Not a day.", "BadRequest");
  if (!text) util.error("Write something first, or delete the reply.", "BadRequest");
  if (text.length > 1000) util.error("That's too long for a reply (1,000 characters).", "BadRequest");
  const me = ctx.identity.sub;
  return {
    operation: "UpdateItem",
    key: util.dynamodb.toMapValues({ PK: `USER#${ctx.args.uid ?? me}`, SK: `COMMENT#${ctx.args.day}#${ctx.args.at}#${me}` }),
    update: {
      expression: "SET #text = :text, #editedAt = :now",
      expressionNames: { "#text": "text", "#editedAt": "editedAt" },
      expressionValues: util.dynamodb.toMapValues({ ":text": text, ":now": util.time.nowISO8601() }),
    },
    condition: { expression: "attribute_exists(PK)" },
  };
}

export function response(ctx) {
  if (ctx.error) {
    if (ctx.error.type === "DynamoDB:ConditionalCheckFailedException") util.error("That reply is gone.", "NotFound");
    util.error(ctx.error.message, ctx.error.type);
  }
  const c = ctx.result;
  return { day: c.day, at: c.at, by: c.by, byName: c.byName ?? null, text: c.text };
}
