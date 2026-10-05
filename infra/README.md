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

Decision (FIT-57, 2026-10-03, author): dev and prod share one account, `397614038040` (profile
`aicoach-dev`), as two stacks. Prod's table and user pool have `RETAIN` and deletion protection, so
destroying `AICoach-dev` can never touch them. Both stacks have their own $20 budget, but a budget
measures the whole account, so either alert means "look".

| Stack | Deploy | App build |
|---|---|---|
| `AICoach-dev` | `npx cdk deploy --profile aicoach-dev` | Debug → `Resources/amplify_outputs.dev.json` |
| `AICoach-prod` | `npx cdk deploy --profile aicoach-dev -c stage=prod` | Release (TestFlight, App Store) → `amplify_outputs.prod.json` |

The account was bootstrapped once: `npx cdk bootstrap --profile aicoach-dev`.

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
AWS_PROFILE=aicoach-dev npm run outputs          # write Resources/amplify_outputs.dev.json
AWS_PROFILE=aicoach-dev npm run outputs prod     # write Resources/amplify_outputs.prod.json
AWS_PROFILE=aicoach-dev npm run buddy -- join CODE   # a test member for trying groups on one simulator
npx cdk destroy --profile aicoach-dev            # dev is fully removable
```

After the first deploy, confirm the SNS email subscription sent to the alert address, or alarms
won't arrive. The budget email needs no confirmation.

## Prod runbook (FIT-57)

**First deploy**
1. Create the three prod secrets with the same JSON shapes as dev (the same Apple key and Services ID work).
2. Add the prod return URL `https://aicoach.auth.us-east-1.amazoncognito.com/oauth2/idpresponse` to the
   Apple Services ID and to the Google OAuth client.
3. `npx cdk deploy --profile aicoach-dev -c stage=prod`, then confirm the SNS email for `AICoach-prod-alerts`.
4. `AWS_PROFILE=aicoach-dev npm run outputs prod` and commit `Resources/amplify_outputs.prod.json`.

**Deploy a change:** `npx cdk diff --profile aicoach-dev -c stage=prod`, read it, then `cdk deploy` with the
same flags. Anything that replaces the table or user pool is a stop: it would lose users and data.

**Roll back:** check out the previous commit and `cdk deploy` it with the same flags.

**Restore data:** the table has point-in-time recovery (35 days). Never restore over the live table:
1. `aws dynamodb restore-table-to-point-in-time --source-table-name AICoach-prod --target-table-name AICoach-prod-restore-YYYYMMDD --restore-date-time <ISO time>`
2. Wait for `ACTIVE`, check the items you need are there.
3. Copy the needed items back with a one-off script (`BatchWriteItem`), then delete the restore table.

Dev's table has point-in-time recovery too, so the restore can be rehearsed there first.
