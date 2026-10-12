import { DynamoDBClient, ConditionalCheckFailedException } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import { checkEntitlement } from "./entitlement.ts";
import { giftedUntil } from "./gifts.ts";

/**
 * FIT-102: the app's one way to Claude. The app runs the conversation (the same code the evals run, `ClaudeModel`)
 * and sends each Messages API request here; this adds the key, which never ships in the app, and passes on only
 * what the app needs: Haiku, a capped answer, a capped prompt, and a daily allowance per signed-in user.
 * FIT-123: Claude is Pro's. With Apple's signed proof of Pro (`entitlement`) a request goes on; without it, an account
 * has a few for good (`limits.freeRequests`), enough for onboarding's brief and first week, the program it's offered.
 */

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const secrets = new SecretsManagerClient({});
const TABLE = process.env.TABLE!;
const SECRET = process.env.ANTHROPIC_SECRET!;

export const limits = {
  models: ["claude-haiku-5-5"],
  maxTokens: 8_000,
  /** The whole request as JSON; a 12-week program's week design is about 15k characters. */
  maxRequestChars: 60_000,
  /** Requests a user can send a day: a week's design is 2 to 6, so this leaves room for redesigns and the coach. */
  dailyRequests: 300,
  /** Requests an account without Pro ever gets: onboarding's brief and week 1, redesigned a few times as answers change. */
  freeRequests: Number(process.env.FREE_REQUESTS ?? 40),
};

/** What the app shows the offer for (ClaudeProxy). */
export const PRO_REQUIRED = "Pro required";

type Request = Record<string, unknown>;

/**
 * The request with only the fields the Messages API needs from the app, or why it can't go.
 * AppSync hands a Lambda an AWSJSON argument already parsed; a string is parsed here.
 */
export function allowedRequest(raw: unknown): { body: Request } | { error: string } {
  let request: Request;
  try {
    request = typeof raw === "string" ? JSON.parse(raw) : (raw as Request);
  } catch {
    return { error: "The request isn't JSON." };
  }
  if (JSON.stringify(request ?? null).length > limits.maxRequestChars) return { error: "The request is too long." };
  if (typeof request !== "object" || request === null || Array.isArray(request)) return { error: "The request isn't an object." };
  if (!limits.models.includes(request.model as string)) return { error: `Only ${limits.models.join(", ")} is available.` };
  if (!Array.isArray(request.messages) || request.messages.length === 0) return { error: "The request has no messages." };
  const body: Request = {
    model: request.model,
    max_tokens: Math.min(Number(request.max_tokens) || limits.maxTokens, limits.maxTokens),
    messages: request.messages,
  };
  if (typeof request.system === "string") body.system = request.system;
  if (Array.isArray(request.tools)) body.tools = request.tools;
  return { body };
}

/** "2026-10-10": a user's allowance resets each UTC day. */
export const day = (now: Date) => now.toISOString().slice(0, 10);

/** Counts one request against an allowance; false when it's used up. A day's expires; the free one doesn't. */
async function allowance(uid: string, sk: string, limit: number, expiresAt?: number): Promise<boolean> {
  try {
    await db.send(new UpdateCommand({
      TableName: TABLE,
      Key: { PK: `USER#${uid}`, SK: sk },
      UpdateExpression: "ADD #n :one" + (expiresAt ? " SET #expiresAt = :expiresAt" : ""),
      ConditionExpression: "attribute_not_exists(#n) OR #n < :limit",
      ExpressionAttributeNames: { "#n": "count", ...(expiresAt ? { "#expiresAt": "expiresAt" } : {}) },
      ExpressionAttributeValues: { ":one": 1, ":limit": limit, ...(expiresAt ? { ":expiresAt": expiresAt } : {}) },
    }));
    return true;
  } catch (error) {
    if (error instanceof ConditionalCheckFailedException) return false;
    throw error;
  }
}

let key: string | undefined;
async function apiKey() {
  if (!key) {
    const secret = await secrets.send(new GetSecretValueCommand({ SecretId: SECRET }));
    key = JSON.parse(secret.SecretString ?? "{}").apiKey;
    if (!key) throw new Error("The Anthropic secret has no apiKey.");
  }
  return key;
}

export async function handler(event: AppSyncResolverEvent<{ request: unknown; entitlement?: string | null }>) {
  const uid = (event.identity as AppSyncIdentityCognito | null)?.sub;
  if (!uid) throw new Error("Sign in to use the coach.");
  const allowed = allowedRequest(event.arguments.request);
  if ("error" in allowed) throw new Error(allowed.error);
  const now = new Date();
  // FIT-122: or Pro from a redeemed gift, on the account.
  const pro = checkEntitlement(event.arguments.entitlement, now).pro || (await giftedUntil(uid, now)) !== undefined;
  if (!pro && !(await allowance(uid, "AIFREE", limits.freeRequests))) {
    throw new Error(`${PRO_REQUIRED}: start your free trial so your coach can keep planning.`);
  }
  const expiresAt = Math.floor(now.getTime() / 1000) + 3 * 86_400;
  if (!(await allowance(uid, `AIUSE#${day(now)}`, limits.dailyRequests, expiresAt))) {
    throw new Error("You've reached today's limit for the coach. It resets tomorrow.");
  }
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": await apiKey(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify(allowed.body),
  });
  const text = await response.text();
  // The app reads Claude's own errors (a prompt too long, overload) as it does when it calls Claude directly.
  // An object, not a string: AppSync encodes an AWSJSON result itself, so a string would arrive encoded twice.
  return { status: response.status, body: JSON.parse(text || "{}") };
}
