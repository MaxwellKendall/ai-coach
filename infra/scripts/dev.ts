// Dev-only helpers shared by smoke.ts and buddy.ts: admin-created test users signed in through the
// smoke-test client (never created in prod), and a bare GraphQL call.
import { randomBytes } from "node:crypto";
import {
  AdminCreateUserCommand,
  AdminInitiateAuthCommand,
  AdminSetUserPasswordCommand,
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import { stackOutputs } from "./stack.ts";

export const out = await stackOutputs("dev");
if (!out.TestClientId) throw new Error("No TestClientId output: the smoke test only runs against dev.");
export const cognito = new CognitoIdentityProviderClient({ region: out.Region });

export async function signIn(username: string) {
  const password = `Smoke-${randomBytes(12).toString("hex")}!`;
  try {
    await cognito.send(new AdminCreateUserCommand({ UserPoolId: out.UserPoolId, Username: username, MessageAction: "SUPPRESS" }));
  } catch (e) {
    if ((e as Error).name !== "UsernameExistsException") throw e;
  }
  await cognito.send(new AdminSetUserPasswordCommand({ UserPoolId: out.UserPoolId, Username: username, Password: password, Permanent: true }));
  const auth = await cognito.send(
    new AdminInitiateAuthCommand({
      UserPoolId: out.UserPoolId,
      ClientId: out.TestClientId,
      AuthFlow: "ADMIN_USER_PASSWORD_AUTH",
      AuthParameters: { USERNAME: username, PASSWORD: password },
    }),
  );
  return auth.AuthenticationResult!.IdToken!;
}

export type Gql = { data?: Record<string, any>; errors?: { message: string; errorType?: string }[] };
export async function gql(token: string, query: string, variables: Record<string, unknown> = {}): Promise<Gql> {
  const res = await fetch(out.GraphqlUrl, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: token },
    body: JSON.stringify({ query, variables }),
  });
  return res.json() as Promise<Gql>;
}
export const must = (r: Gql, what: string) => {
  if (r.errors?.length) throw new Error(`${what}: ${JSON.stringify(r.errors)}`);
  return r.data!;
};
export const rejected = (r: Gql) => Boolean(r.errors?.some((e) => /unauthori[sz]ed/i.test(`${e.errorType} ${e.message}`)));

