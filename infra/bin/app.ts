import { App } from "aws-cdk-lib";
import { AICoachStack, type IdentityProvider, type Stage } from "../lib/stack.ts";

const app = new App();
const stage = app.node.getContext("stage") as Stage;
const stages = app.node.getContext("stages") as Record<Stage, { identityProviders: IdentityProvider[] }>;

// The account is whichever one the AWS profile points at (aicoach-dev / aicoach-prod), so a dev
// profile can never deploy into prod.
new AICoachStack(app, `AICoach-${stage}`, {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: app.node.getContext("region") },
  stage,
  identityProviders: stages[stage].identityProviders,
  alertEmail: app.node.getContext("alertEmail"),
});
