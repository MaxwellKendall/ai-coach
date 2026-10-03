import { readFileSync } from "node:fs";
import { App } from "aws-cdk-lib";
import { Match, Template } from "aws-cdk-lib/assertions";
import { beforeAll, describe, expect, it } from "vitest";
import { AICoachStack, type IdentityProvider, type Stage } from "../lib/stack.ts";

const synth = (stage: Stage, identityProviders: IdentityProvider[]) =>
  Template.fromStack(
    new AICoachStack(new App(), `AICoach-${stage}`, {
      env: { account: "111111111111", region: "us-east-1" },
      stage,
      identityProviders,
      alertEmail: "author@example.com",
    }),
  );

let dev: Template;
let prod: Template;
beforeAll(() => {
  dev = synth("dev", []);
  prod = synth("prod", ["apple", "google"]);
});

describe("table", () => {
  it("has the single-table keys, GSI1, TTL, stream and backups", () => {
    dev.hasResourceProperties("AWS::DynamoDB::Table", {
      TableName: "AICoach-dev",
      BillingMode: "PAY_PER_REQUEST",
      KeySchema: [
        { AttributeName: "PK", KeyType: "HASH" },
        { AttributeName: "SK", KeyType: "RANGE" },
      ],
      GlobalSecondaryIndexes: [
        Match.objectLike({
          IndexName: "GSI1",
          KeySchema: [
            { AttributeName: "GSI1PK", KeyType: "HASH" },
            { AttributeName: "GSI1SK", KeyType: "RANGE" },
          ],
        }),
      ],
      TimeToLiveSpecification: { AttributeName: "expiresAt", Enabled: true },
      StreamSpecification: { StreamViewType: "NEW_AND_OLD_IMAGES" },
      PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: true },
    });
  });

  it("is destroyed with dev but retained and protected in prod", () => {
    dev.hasResource("AWS::DynamoDB::Table", { DeletionPolicy: "Delete" });
    prod.hasResource("AWS::DynamoDB::Table", { DeletionPolicy: "Retain", Properties: Match.objectLike({ DeletionProtectionEnabled: true }) });
  });
});

describe("auth", () => {
  it("AppSync uses Cognito user pools only, no API keys", () => {
    for (const t of [dev, prod]) {
      t.hasResourceProperties("AWS::AppSync::GraphQLApi", {
        AuthenticationType: "AMAZON_COGNITO_USER_POOLS",
        AdditionalAuthenticationProviders: Match.absent(),
      });
      t.resourceCountIs("AWS::AppSync::ApiKey", 0);
    }
  });

  it("the iOS client allows only federated hosted-UI sign-in plus refresh", () => {
    prod.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      ClientName: "ios",
      ExplicitAuthFlows: ["ALLOW_REFRESH_TOKEN_AUTH"],
      SupportedIdentityProviders: ["SignInWithApple", "Google"],
      AllowedOAuthFlows: ["code"],
      CallbackURLs: ["aicoach://auth/callback"],
      GenerateSecret: false,
    });
    prod.resourceCountIs("AWS::Cognito::UserPoolIdentityProvider", 2);
  });

  it("dev without provider secrets deploys with no providers", () => {
    dev.resourceCountIs("AWS::Cognito::UserPoolIdentityProvider", 0);
    dev.hasResourceProperties("AWS::Cognito::UserPoolClient", { ClientName: "ios", SupportedIdentityProviders: Match.absent() });
  });

  it("the smoke-test client exists in dev and never in prod", () => {
    dev.hasResourceProperties("AWS::Cognito::UserPoolClient", { ClientName: "smoke-test", ExplicitAuthFlows: Match.arrayWith(["ALLOW_ADMIN_USER_PASSWORD_AUTH"]) });
    expect(Object.values(prod.findResources("AWS::Cognito::UserPoolClient")).map((r) => r.Properties.ClientName)).toEqual(["ios"]);
  });

  it("uses the Lite feature plan and a post-confirmation trigger", () => {
    dev.hasResourceProperties("AWS::Cognito::UserPool", {
      UserPoolTier: "LITE",
      LambdaConfig: { PostConfirmation: Match.anyValue() },
    });
  });
});

describe("resolvers", () => {
  const functionNames = (t: Template) =>
    Object.fromEntries(
      Object.entries(t.findResources("AWS::AppSync::FunctionConfiguration")).map(([id, r]) => [id, r.Properties.Name]),
    );

  it("every group operation runs requireMember first", () => {
    const schema = readFileSync(new URL("../graphql/schema.graphql", import.meta.url), "utf8");
    const groupFields = ["Mutation", "Subscription"].flatMap((type) => {
      const body = schema.match(new RegExp(`type ${type} \\{([\\s\\S]*?)\\n\\}`))![1];
      return [...body.matchAll(/^\s+(\w+)\(([^)]*)\)/gm)].filter(([, , args]) => /\bgroupId:/.test(args)).map(([, f]) => [type, f]);
    });
    groupFields.push(["Query", "group"]);
    expect(groupFields.length).toBe(11);

    const names = functionNames(dev);
    const resolvers = Object.values(dev.findResources("AWS::AppSync::Resolver")).map((r) => r.Properties);
    for (const [type, field] of groupFields) {
      const r = resolvers.find((p) => p.TypeName === type && p.FieldName === field);
      expect(r, `${type}.${field}`).toBeDefined();
      const first = r!.PipelineConfig.Functions[0]["Fn::GetAtt"][0];
      expect(names[first], `${type}.${field}`).toBe("requireMember");
    }
  });

  it("every schema field that needs a resolver has one", () => {
    const resolved = Object.values(dev.findResources("AWS::AppSync::Resolver")).map((r) => `${r.Properties.TypeName}.${r.Properties.FieldName}`);
    expect(resolved.sort()).toEqual(
      [
        "Query.me", "Query.myGroups", "Query.group", "Group.feed",
        "Mutation.updateProfile", "Mutation.createGroup", "Mutation.joinGroup", "Mutation.leaveGroup",
        "Mutation.setShareLive", "Mutation.addGroupGoal", "Mutation.publishProgress", "Mutation.publishLiveSet",
        "Mutation.endLiveSession", "Mutation.postFeed", "Mutation.registerDevice", "Mutation.deleteAccount",
        "Subscription.onLiveSet", "Subscription.onProgress", "Subscription.onFeed",
      ].sort(),
    );
  });

  it("logs field errors only", () => {
    dev.hasResourceProperties("AWS::AppSync::GraphQLApi", { LogConfig: Match.objectLike({ FieldLogLevel: "ERROR" }) });
  });
});

describe("push", () => {
  it("only runs for LIVE# items", () => {
    dev.hasResourceProperties("AWS::Lambda::EventSourceMapping", {
      FilterCriteria: {
        Filters: [{ Pattern: JSON.stringify({ eventName: ["INSERT", "MODIFY"], dynamodb: { Keys: { SK: { S: [{ prefix: "LIVE#" }] } } } }) }],
      },
    });
  });

  it("targets APNs sandbox in dev and production in prod", () => {
    dev.hasResourceProperties("AWS::Lambda::Function", { Environment: { Variables: Match.objectLike({ APNS_HOST: "api.sandbox.push.apple.com" }) } });
    prod.hasResourceProperties("AWS::Lambda::Function", { Environment: { Variables: Match.objectLike({ APNS_HOST: "api.push.apple.com" }) } });
  });
});

describe("least privilege", () => {
  const actionsOf = (t: Template, logical: RegExp) =>
    Object.entries(t.findResources("AWS::IAM::Policy"))
      .filter(([id]) => logical.test(id))
      .flatMap(([, p]) => p.Properties.PolicyDocument.Statement.flatMap((s: any) => [s.Action].flat()));

  it("each function gets only the table actions it uses", () => {
    expect(actionsOf(dev, /^postConfirmation/).filter((a) => a.startsWith("dynamodb:"))).toEqual(["dynamodb:PutItem"]);
    expect(actionsOf(dev, /^deleteAccount/)).toEqual(expect.arrayContaining(["dynamodb:Query", "dynamodb:BatchWriteItem", "cognito-idp:AdminDeleteUser"]));
    expect(actionsOf(dev, /^deleteAccount/)).not.toContain("dynamodb:PutItem");
    expect(actionsOf(dev, /^push/)).not.toContain("dynamodb:PutItem");
    expect(actionsOf(dev, /^push/)).toContain("secretsmanager:GetSecretValue");
  });
});

describe("ops", () => {
  it("keeps logs for 30 days", () => {
    const groups = Object.values(dev.findResources("AWS::Logs::LogGroup"));
    expect(groups.length).toBeGreaterThanOrEqual(3);
    for (const g of groups) expect(g.Properties.RetentionInDays).toBe(30);
  });

  it("emails the author on errors and above $20/month", () => {
    dev.hasResourceProperties("AWS::SNS::Subscription", { Protocol: "email", Endpoint: "author@example.com" });
    dev.hasResourceProperties("AWS::CloudWatch::Alarm", { AlarmActions: [Match.anyValue()], Threshold: 1 });
    dev.hasResourceProperties("AWS::Budgets::Budget", {
      Budget: Match.objectLike({ BudgetLimit: { Amount: 20, Unit: "USD" }, TimeUnit: "MONTHLY" }),
    });
  });
});
