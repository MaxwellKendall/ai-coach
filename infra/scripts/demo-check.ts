// TKL-1003: are the standing test logins usable right now?
//
//   AWS_PROFILE=aicoach-dev npm run demo-check -- prod          report each account
//   AWS_PROFILE=aicoach-dev npm run demo-check -- prod --fix     and re-apply the shared password where it doesn't sign in
//
// Reports, per account, that the Cognito user exists and that the shared password signs in. --fix sets the shared
// password on an account that exists but doesn't take it; it touches no training data, so a run can fix sign-in
// without resetting anybody's weeks (that's coach-demo.ts and lifter-demo.ts). Passwords are never printed.
import {
  AdminGetUserCommand,
  AdminInitiateAuthCommand,
  AdminSetUserPasswordCommand,
  CognitoIdentityProviderClient,
  DescribeUserPoolClientCommand,
  InitiateAuthCommand,
  ListUserPoolClientsCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import {
  HOW_TO_SET,
  loadDemoCredentials,
  nextStep,
  passwordClient,
  savePasswords,
  type PasswordFlow,
  type PoolClient,
} from "./demoCredentials.ts";
import { stackOutputs } from "./stack.ts";

const fix = process.argv.includes("--fix");
const creds = loadDemoCredentials();
if (creds.missing.length) {
  console.error(`Not set: ${creds.missing.join(", ")}. ${HOW_TO_SET}`);
  process.exit(1);
}
const stage = process.argv.slice(2).find((a) => !a.startsWith("--")) ?? creds.stage;

const out = await stackOutputs(stage);
if (!out.UserPoolId) throw new Error(`AICoach-${stage} has no UserPoolId output. Is the stage deployed?`);
const cognito = new CognitoIdentityProviderClient({ region: out.Region });

const { UserPoolClients = [] } = await cognito.send(new ListUserPoolClientsCommand({ UserPoolId: out.UserPoolId, MaxResults: 60 }));
const clients: PoolClient[] = await Promise.all(
  UserPoolClients.map(async (c) => {
    const { UserPoolClient } = await cognito.send(
      new DescribeUserPoolClientCommand({ UserPoolId: out.UserPoolId, ClientId: c.ClientId }),
    );
    return { id: c.ClientId!, name: c.ClientName ?? "", flows: UserPoolClient?.ExplicitAuthFlows ?? [] };
  }),
);
const client = passwordClient(clients);
if (!client) throw new Error(`No user pool client on ${stage} allows a password sign-in, so the password can't be checked.`);

async function exists(email: string) {
  try {
    await cognito.send(new AdminGetUserCommand({ UserPoolId: out.UserPoolId, Username: email }));
    return true;
  } catch (e) {
    if ((e as Error).name === "UserNotFoundException") return false;
    throw e;
  }
}

/** True when the shared password signs the account in. A rejected password is an answer, not a failure. */
async function signsIn(email: string, id: string, flow: PasswordFlow) {
  const AuthParameters = { USERNAME: email, PASSWORD: creds.password };
  try {
    const result =
      flow === "USER_PASSWORD_AUTH"
        ? await cognito.send(new InitiateAuthCommand({ ClientId: id, AuthFlow: flow, AuthParameters }))
        : await cognito.send(new AdminInitiateAuthCommand({ UserPoolId: out.UserPoolId, ClientId: id, AuthFlow: flow, AuthParameters }));
    return Boolean(result.AuthenticationResult?.IdToken);
  } catch (e) {
    const name = (e as Error).name;
    if (name === "NotAuthorizedException" || name === "PasswordResetRequiredException" || name === "UserNotConfirmedException") return false;
    throw e;
  }
}

let allOk = true;
const working: [string, string][] = [];
for (const { role, email } of creds.accounts) {
  const there = await exists(email);
  const step = nextStep({ exists: there, signsIn: there && (await signsIn(email, client.id, client.flow)) }, fix);
  let said: string = step;
  if (step === "set the password") {
    await cognito.send(
      new AdminSetUserPasswordCommand({ UserPoolId: out.UserPoolId, Username: email, Password: creds.password, Permanent: true }),
    );
    const takes = await signsIn(email, client.id, client.flow);
    said = takes ? "ok (password set)" : "set the password, and it still doesn't sign in";
    if (!takes) allOk = false;
  } else if (step !== "ok") {
    allOk = false;
  }
  if (said.startsWith("ok")) working.push([email, creds.password]);
  const how = step === "missing" ? ` — run ${role === "lifter" ? "lifter-demo" : "coach-demo"} -- ${stage} to make it` : "";
  console.log(`${role.padEnd(7)} ${email.padEnd(24)} ${said}${how}`);
}

// So .demo-accounts.STAGE never tells a later run a password that no longer works.
if (fix) savePasswords(stage, working);

if (!allOk) {
  console.error(`\nSome accounts on ${stage} don't take the shared password.${fix ? "" : " Run again with --fix to set it."}`);
  process.exit(1);
}
console.log(`\nAll ${creds.accounts.length} standing test logins work on ${stage}. Any ticket may use them; no approval needed.`);
