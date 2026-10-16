import { fileURLToPath } from "node:url";
import { App } from "aws-cdk-lib";
import { AICoachStack, type IdentityProvider, type Stage } from "../lib/stack.ts";

const app = new App();
const stage = app.node.getContext("stage") as Stage;
const stages = app.node.getContext("stages") as Record<Stage, {
  identityProviders: IdentityProvider[];
  web?: { zone: string; hosts: string[] };
  app?: { zone: string; host: string };
}>;
const dashboard = stages[stage].app;

// The account is whichever one the AWS profile points at. Decision (FIT-57, 2026-10-03): dev and prod
// share account 397614038040 as separate stacks; prod's table and user pool are RETAIN with deletion
// protection, so `cdk destroy` on dev can't reach them.
new AICoachStack(app, `AICoach-${stage}`, {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: app.node.getContext("region") },
  stage,
  identityProviders: stages[stage].identityProviders,
  web: stages[stage].web,
  // FIT-127: build the dashboard first (npm --prefix ../web run build).
  app: dashboard && { ...dashboard, assets: fileURLToPath(new URL("../../web/dist", import.meta.url)) },
  alertEmail: app.node.getContext("alertEmail"),
});
