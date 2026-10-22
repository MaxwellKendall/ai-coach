import { createPublicKey, verify, type JsonWebKey } from "node:crypto";
import {
  AdminDeleteUserCommand,
  AdminLinkProviderForUserCommand,
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";

// FIT-137: one person, one account, whichever way they sign in (author, 2026-10-17: link all logins). Signed in as
// their account, someone signs in once more with the other provider; this checks that sign-in's ID token, removes the
// empty account Cognito made for it, and links that provider's identity to theirs, so signing in with it lands in
// their account from then on. An Apple identity is also recorded for the native sheet (FIT-138), which signs in by
// username: APPLELINK#<apple sub> names the account it belongs to.

const cognito = new CognitoIdentityProviderClient({});
const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = () => process.env.TABLE!;

export class LinkError extends Error {}

type Key = JsonWebKey & { kid: string };
let keys: Key[] = [];

export type Claims = { sub: string; "cognito:username": string; aud: string; iss: string; exp: number; token_use: string; identities?: { providerName: string; userId: string }[] };

/** A Cognito ID token from this pool and one of its clients, unexpired, signed with the pool's key. */
export function checkToken(token: string, jwks: Key[], issuer: string, clients: string[], now: Date): Claims {
  const [head, body, signature] = token.split(".");
  if (!signature) throw new LinkError("That sign-in couldn't be read.");
  const header = JSON.parse(Buffer.from(head, "base64url").toString());
  const claims = JSON.parse(Buffer.from(body, "base64url").toString()) as Claims;
  const key = jwks.find((k) => k.kid === header.kid);
  if (header.alg !== "RS256" || !key) throw new LinkError("That sign-in couldn't be checked.");
  const ok = verify("RSA-SHA256", Buffer.from(`${head}.${body}`), createPublicKey({ key, format: "jwk" }), Buffer.from(signature, "base64url"));
  if (!ok || claims.iss !== issuer || !clients.includes(claims.aud) || claims.token_use !== "id" || claims.exp * 1000 < now.getTime()) {
    throw new LinkError("That sign-in couldn't be checked. Try again.");
  }
  return claims;
}

/** Which provider identity an account stands for: the one Cognito made for a federated sign-in, or a native Apple one. */
export function identityOf(claims: Claims): { provider: string; userId: string } {
  const username = claims["cognito:username"];
  const linked = claims.identities?.find((i) => i.providerName === "Google" || i.providerName === "SignInWithApple");
  if (linked) return { provider: linked.providerName, userId: linked.userId };
  if (username.startsWith("apple_")) return { provider: "SignInWithApple", userId: username.slice("apple_".length) };
  throw new LinkError("That account isn't an Apple or Google sign-in.");
}

/** Whether an account has anything of its own: synced training, groups, clients or a coach, gifts or shares. */
export async function hasData(uid: string) {
  const own = await db.send(new QueryCommand({
    TableName: TABLE(),
    KeyConditionExpression: "PK = :pk",
    ExpressionAttributeValues: { ":pk": `USER#${uid}` },
    ProjectionExpression: "SK",
  }));
  // A new account has a profile, maybe a device and an AI count; those don't matter, nor do push bookkeeping (FIT-220).
  if ((own.Items ?? []).some((i) => !/^(PROFILE|DEVICE#|AIUSE#|AIFREE|NOTIFY#|NUDGE#)/.test(String(i.SK)))) return true;
  const indexed = await db.send(new QueryCommand({
    TableName: TABLE(),
    IndexName: "GSI1",
    KeyConditionExpression: "GSI1PK = :u",
    ExpressionAttributeValues: { ":u": `USER#${uid}` },
    Limit: 1,
  }));
  return (indexed.Items?.length ?? 0) > 0;
}

async function poolKeys(issuer: string) {
  if (!keys.length) keys = ((await (await fetch(`${issuer}/.well-known/jwks.json`)).json()) as { keys: Key[] }).keys;
  return keys;
}

/** The account the native Apple sheet signs in to for this Apple user, when they linked Apple to another account. */
export async function linkedApple(appleSub: string): Promise<string | undefined> {
  const { Item } = await db.send(new GetCommand({ TableName: TABLE(), Key: { PK: `APPLELINK#${appleSub}`, SK: "META" } }));
  return Item?.username as string | undefined;
}

export async function link(me: { sub: string; username: string }, otherToken: string, now = new Date()) {
  const issuer = `https://cognito-idp.${process.env.AWS_REGION}.amazonaws.com/${process.env.USER_POOL_ID}`;
  const other = checkToken(otherToken, await poolKeys(issuer), issuer, (process.env.CLIENT_IDS ?? "").split(","), now);
  if (other.sub === me.sub) throw new LinkError("That's this account already.");
  const identity = identityOf(other);
  if (await hasData(other.sub)) {
    throw new LinkError("That sign-in already has its own training or groups. Sign out, sign in with it instead, and link this one from its Account page.");
  }
  await cognito.send(new AdminDeleteUserCommand({ UserPoolId: process.env.USER_POOL_ID, Username: other["cognito:username"] }));
  await db.send(new DeleteCommand({ TableName: TABLE(), Key: { PK: `USER#${other.sub}`, SK: "PROFILE" } }));
  await cognito.send(new AdminLinkProviderForUserCommand({
    UserPoolId: process.env.USER_POOL_ID,
    DestinationUser: { ProviderName: "Cognito", ProviderAttributeValue: me.username },
    SourceUser: { ProviderName: identity.provider, ProviderAttributeName: "Cognito_Subject", ProviderAttributeValue: identity.userId },
  }));
  if (identity.provider === "SignInWithApple") {
    await db.send(new PutCommand({ TableName: TABLE(), Item: { PK: `APPLELINK#${identity.userId}`, SK: "META", username: me.username, uid: me.sub, at: now.toISOString() } }));
  }
  return identity.provider === "Google" ? "google" : "apple";
}

export async function handler(event: AppSyncResolverEvent<{ token: string }>) {
  const identity = event.identity as AppSyncIdentityCognito;
  try {
    return await link({ sub: identity.sub, username: identity.username }, event.arguments.token);
  } catch (e) {
    if (e instanceof LinkError) throw e;
    console.log("link failed", (e as Error).name, (e as Error).message);
    throw new LinkError("Couldn't link that sign-in. Try again.");
  }
}
