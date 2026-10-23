import { randomBytes } from "node:crypto";
import {
  AdminCreateUserCommand,
  AdminGetUserCommand,
  AdminLinkProviderForUserCommand,
  AdminSetUserPasswordCommand,
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import type { LambdaFunctionURLEvent, LambdaFunctionURLResult } from "aws-lambda";
import { linkedApple } from "./accounts.ts";
import { saveProfile } from "./postConfirmation.ts";
import { verifyAppleToken, type AppleClaims } from "./appleToken.ts";

/**
 * FIT-138: the step before native Sign in with Apple's custom auth, which can only sign in a user who exists. The app
 * posts Apple's identity token; this checks it and answers with the Cognito username to sign in as: the federated user
 * from before FIT-138 if there is one, else `apple_<sub>`, created the first time. A new user is linked to their Apple identity, so the web dashboard's Apple sign-in (Cognito's
 * hosted UI) is the same account.
 */

const cognito = new CognitoIdentityProviderClient({});

export const usernameFor = (sub: string) => `apple_${sub}`;

async function exists(username: string) {
  try {
    await cognito.send(new AdminGetUserCommand({ UserPoolId: process.env.USER_POOL_ID, Username: username }));
    return true;
  } catch (e) {
    if ((e as Error).name === "UserNotFoundException") return false;
    throw e;
  }
}

async function createUser(claims: AppleClaims, name: string | undefined) {
  const UserPoolId = process.env.USER_POOL_ID;
  const Username = usernameFor(claims.sub);
  const attributes = [
    ...(claims.email ? [{ Name: "email", Value: claims.email }, { Name: "email_verified", Value: "true" }] : []),
    ...(name ? [{ Name: "name", Value: name }] : []),
  ];
  const created = await cognito.send(new AdminCreateUserCommand({ UserPoolId, Username, UserAttributes: attributes, MessageAction: "SUPPRESS" }));
  // A password nobody knows, only to leave FORCE_CHANGE_PASSWORD. The iOS client allows SRP (FIT-229), so it must stay unguessable.
  await cognito.send(new AdminSetUserPasswordCommand({ UserPoolId, Username, Password: `${randomBytes(24).toString("base64url")}aA1!`, Permanent: true }));
  const uid = created.User?.Attributes?.find((a) => a.Name === "sub")?.Value;
  if (uid) await saveProfile(uid, name);
  if (process.env.APPLE_PROVIDER) {
    await cognito.send(new AdminLinkProviderForUserCommand({
      UserPoolId,
      DestinationUser: { ProviderName: "Cognito", ProviderAttributeValue: Username },
      SourceUser: { ProviderName: process.env.APPLE_PROVIDER, ProviderAttributeName: "Cognito_Subject", ProviderAttributeValue: claims.sub },
    }));
  }
}

const reply = (statusCode: number, body: unknown): LambdaFunctionURLResult => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

export async function handler(event: LambdaFunctionURLEvent): Promise<LambdaFunctionURLResult> {
  if (event.requestContext.http.method !== "POST") return reply(405, { error: "POST" });
  let input: { identityToken?: string; nonce?: string; name?: string };
  try {
    input = JSON.parse(event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString() : event.body ?? "");
  } catch {
    return reply(400, { error: "JSON" });
  }
  const result = await verifyAppleToken(input.identityToken ?? "", input.nonce ?? "");
  if (!result.ok) {
    console.log("refused", result.why);
    return reply(401, { error: "Apple's token wasn't accepted." });
  }
  // FIT-137: Apple linked to another account (a Google one) signs in to that account.
  const linked = await linkedApple(result.claims.sub);
  if (linked && (await exists(linked))) return reply(200, { username: linked });
  // Someone who signed in with Apple before FIT-138 is a federated user; custom auth signs them in as that user.
  const federated = `SignInWithApple_${result.claims.sub}`;
  if (await exists(federated)) return reply(200, { username: federated });
  const username = usernameFor(result.claims.sub);
  if (!(await exists(username))) {
    try {
      await createUser(result.claims, input.name?.trim().slice(0, 80) || undefined);
    } catch (e) {
      // Two sign-ins at once: the other one made the user.
      if ((e as Error).name !== "UsernameExistsException") throw e;
    }
  }
  return reply(200, { username });
}
