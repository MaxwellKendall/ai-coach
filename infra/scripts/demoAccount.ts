// FIT-328 / TKL-749: the demo accounts' Cognito users, made with sign in with email and a permanent password, shared by
// coach-demo.ts and lifter-demo.ts.
//
// TKL-1003: when DEMO_PASSWORD is set (it is, in ~/dev/.secrets.env), every demo account gets that one shared
// password, so these runs no longer rotate the logins other tickets are using. Without it, or with --new-password,
// a random one is made as before. Either way it goes in infra/.demo-accounts.STAGE, which git ignores, and is
// never printed.
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import {
  AdminCreateUserCommand,
  AdminGetUserCommand,
  AdminSetUserPasswordCommand,
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import { PutCommand, type DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { loadDemoCredentials } from "./demoCredentials.ts";

export function demoAccounts(opts: {
  stage: string; region: string; userPoolId: string; db: DynamoDBDocumentClient; newPassword: boolean; since: string; now: string;
}) {
  const cognito = new CognitoIdentityProviderClient({ region: opts.region });
  // The standing password every ticket signs in with, unless this run was told to make a new one.
  const shared = opts.newPassword ? "" : loadDemoCredentials().password;
  const TABLE = `AICoach-${opts.stage}`;
  const file = new URL(`../.demo-accounts.${opts.stage}`, import.meta.url);
  const saved = new Map(existsSync(file) ? readFileSync(file, "utf8").trim().split("\n").map((l) => l.split(" ") as [string, string]) : []);

  /** The account's uid: made with a permanent password if it's new, so the first sign-in isn't asked to change it. */
  async function account(email: string, name: string) {
    let uid: string | undefined;
    try {
      const user = await cognito.send(new AdminGetUserCommand({ UserPoolId: opts.userPoolId, Username: email }));
      uid = user.UserAttributes?.find((a) => a.Name === "sub")?.Value;
    } catch (e) {
      if ((e as Error).name !== "UserNotFoundException") throw e;
    }
    const isNew = !uid;
    if (!uid) {
      // preSignUp allows admin-made users; MessageAction SUPPRESS sends no invitation email.
      const made = await cognito.send(new AdminCreateUserCommand({
        UserPoolId: opts.userPoolId,
        Username: email,
        MessageAction: "SUPPRESS",
        UserAttributes: [{ Name: "email", Value: email }, { Name: "email_verified", Value: "true" }, { Name: "name", Value: name }],
      }));
      uid = made.User?.Attributes?.find((a) => a.Name === "sub")?.Value;
      if (!uid) throw new Error("Cognito made the user without a sub.");
    }
    if (isNew || opts.newPassword || (shared && saved.get(email) !== shared)) {
      const password = shared || `Demo-${randomBytes(3).toString("hex")}-${randomBytes(3).toString("hex")}!`;
      await cognito.send(new AdminSetUserPasswordCommand({ UserPoolId: opts.userPoolId, Username: email, Password: password, Permanent: true }));
      saved.set(email, password);
    }
    // The same PROFILE item postConfirmation writes, which an admin-made user never triggers.
    await opts.db.send(new PutCommand({ TableName: TABLE, Item: { PK: `USER#${uid}`, SK: "PROFILE", uid, displayName: name, units: "lb", createdAt: opts.since, updatedAt: opts.now } }));
    return uid;
  }

  /** Writes every password made so far, keeping the ones already in the file. */
  const save = () => writeFileSync(file, [...saved].map(([email, password]) => `${email} ${password}`).join("\n") + "\n", { mode: 0o600 });

  return { account, save, TABLE };
}
