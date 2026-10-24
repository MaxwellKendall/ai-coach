---
name: deploy-prod
description: Deploy main to production (the AICoach-prod stack on barbrabell.com, with the dashboard), after the tests and a read of the diff, then check the live site. Run only when the author asks for a prod deploy.
disable-model-invocation: true
---

# Deploy to prod

Deploys what's committed on `main` to the `AICoach-prod` stack (account 397614038040, profile `aicoach-dev`, us-east-1): the backend, the MCP server and its docs, the share pages, and the web dashboard at barbrabell.com/app. infra/README.md has the background; this is the routine.

Prod holds real users. Never deploy uncommitted work or a red build, and stop at anything below that says stop.

## 1. Preflight

From the repo root:

```bash
git --no-pager status --porcelain && git --no-pager log --oneline -1 && git rev-parse --abbrev-ref HEAD
```

- **Stop** unless the branch is `main` and the tree is clean. Ask whether to commit or stash first; don't do either unasked.
- Say which commit is going out.

Then the checks, from `infra/`:

```bash
npx tsc --noEmit -p . && npx vitest run
```

**Stop** on any failure and show it.

## 2. Build the dashboard

The stack uploads `web/dist`, so build it every time, even when the dashboard didn't change:

```bash
npm --prefix ../web run build
```

## 3. Read the diff

```bash
npx cdk diff --profile aicoach-dev -c stage=prod
```

Summarize it in a few lines: which Lambdas change, and any IAM, Cognito, CloudFront or DynamoDB changes.

**Stop and ask** if the diff:
- replaces or removes the DynamoDB table (`AWS::DynamoDB::Table`) or the user pool (`AWS::Cognito::UserPool`), or shows "requires replacement" on either; that would lose users and data;
- removes a user pool client, an identity provider, the CloudFront distribution or the certificate.

"There were no differences" means nothing to deploy: say so and stop.

## 4. Deploy

```bash
npx cdk deploy --profile aicoach-dev -c stage=prod --require-approval never
```

The diff was read in step 3, so it isn't asked again. This takes 2–3 minutes. It's done at `✅  AICoach-prod`.

If the deploy is blocked in this session, don't route it through another session or tool. Give the author the commands from steps 2 and 4 to run in their terminal, one per block, then carry on from step 5 once they say it's done.

## 5. Check the live site

```bash
for p in / /docs /claude /privacy /support /.well-known/oauth-authorization-server /app/; do curl -s -o /dev/null -w "%{http_code} $p\n" "https://barbrabell.com$p"; done
curl -s -o /dev/null -w "%{http_code} /mcp (401 expected without sign-in)\n" -X POST https://barbrabell.com/mcp
```

Every page should be 200, and `/mcp` 401. Then confirm the stack updated just now: its `LastUpdatedTime` (CloudFormation `DescribeStacks` for `AICoach-prod`, with the same profile) should be after the deploy started. A stale time means the deploy didn't happen, whatever the terminal showed.

Check whatever the deployed commits changed too: open the page or call the endpoint they touched.

## 6. App outputs

```bash
AWS_PROFILE=aicoach-dev npm run outputs prod
```

If `Resources/amplify_outputs.prod.json` changed, show the diff and commit it as `Prod outputs after deploying <short sha>`.

## 7. Report

In a few lines: the commit deployed, what changed (from the diff), the checks and their results, and anything that failed or was skipped.

## Rolling back

Check out the previous good commit, then run steps 2–5 from it, and return to `main` afterwards. Never restore data over the live table (infra/README.md, "Restore data").
