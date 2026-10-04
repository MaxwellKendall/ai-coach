# AICoach infra (FIT-56)

AWS CDK app for accounts, groups and live workouts: Cognito (Apple/Google sign-in), one DynamoDB
table, AppSync GraphQL with real-time subscriptions, and a push Lambda that calls APNs. One stack per
stage: `AICoach-dev`, `AICoach-prod`. All changes go through CDK; nothing is created in the console.

```
bin/app.ts           entry; stage comes from `-c stage=…`, the account from the AWS profile
lib/stack.ts         the whole stack
graphql/schema.graphql
resolvers/*.js       APPSYNC_JS pipeline functions (requireMember runs first for every group op)
lambda/*.ts          postConfirmation (PROFILE item), deleteAccount, push (+ apns.ts)
scripts/outputs.ts   writes ../Resources/amplify_outputs.json for the app
scripts/smoke.ts     end-to-end test against deployed dev
test/                vitest: CDK template assertions, resolver and Lambda unit tests
```

## Accounts

One AWS Organization with a separate account per stage, so nothing done in dev can touch prod:

| Profile | Account | Stack |
|---|---|---|
| `aicoach-dev` | AICoach dev | `AICoach-dev` |
| `aicoach-prod` | AICoach prod | `AICoach-prod` (FIT-57) |

Each account is bootstrapped once: `npx cdk bootstrap --profile aicoach-dev`.

## Secrets (created by hand once, never in git)

| Name | JSON | Needed for |
|---|---|---|
| `aicoach/{stage}/apple-signin` | `{ teamId, keyId, servicesId, privateKey }` | Sign in with Apple |
| `aicoach/{stage}/google-oauth` | `{ clientId, clientSecret }` | Google sign-in |
| `aicoach/{stage}/apns` | `{ teamId, keyId, privateKey, bundleId }` | push (read at runtime) |

A provider is only created when it's listed under `stages.{stage}.identityProviders` in `cdk.json`.
Dev has both. Google: Cloud project `aicoach-dev-mnk`, a Web client redirecting to the Cognito
domain's `/oauth2/idpresponse`. Apple: Services ID `com.maxwellkendall.aicoach.signin` with the same
return URL, and one `.p8` key (Sign in with Apple + APNs) shared by both Apple secrets.

## Commands

```bash
npm test                                         # unit tests, no AWS needed
npx cdk deploy --profile aicoach-dev             # deploy dev
AWS_PROFILE=aicoach-dev npm run smoke            # end-to-end against dev
AWS_PROFILE=aicoach-dev npm run outputs          # write Resources/amplify_outputs.json
npx cdk destroy --profile aicoach-dev            # dev is fully removable
```

After the first deploy, confirm the SNS email subscription sent to the alert address, or alarms
won't arrive. The budget email needs no confirmation.

## Rollback and restore

- **Roll back code:** check out the previous commit and `cdk deploy` it.
- **Restore data:** the table has point-in-time recovery (35 days). Restore into a new table with
  `RestoreTableToPointInTime`, check it, then copy the items back. Never restore over the live table.
