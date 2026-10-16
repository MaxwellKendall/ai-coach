import { fileURLToPath } from "node:url";
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

  it("the iOS client allows federated hosted-UI sign-in, native Apple (custom auth, FIT-138) and refresh, no passwords", () => {
    prod.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      ClientName: "ios",
      ExplicitAuthFlows: ["ALLOW_CUSTOM_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
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
    expect(Object.values(prod.findResources("AWS::Cognito::UserPoolClient")).map((r) => r.Properties.ClientName)).toEqual(["ios", "web"]);
  });

  it("uses the Lite feature plan, a post-confirmation trigger, and custom auth for native Apple (FIT-138)", () => {
    dev.hasResourceProperties("AWS::Cognito::UserPool", {
      UserPoolTier: "LITE",
      LambdaConfig: {
        PostConfirmation: Match.anyValue(),
        PreSignUp: Match.anyValue(),
        DefineAuthChallenge: Match.anyValue(),
        CreateAuthChallenge: Match.anyValue(),
        VerifyAuthChallengeResponse: Match.anyValue(),
      },
    });
  });

  it("the web client stays on the hosted UI (FIT-127)", () => {
    prod.hasResourceProperties("AWS::Cognito::UserPoolClient", { ClientName: "web", ExplicitAuthFlows: ["ALLOW_REFRESH_TOKEN_AUTH"] });
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
    expect(groupFields.length).toBe(15);

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
        "Query.me", "Query.share", "Query.myGroups", "Query.group", "Group.feed",
        "Mutation.updateProfile", "Mutation.createGroup", "Mutation.joinGroup", "Mutation.leaveGroup",
        "Mutation.setShareLive", "Mutation.addGroupGoal", "Mutation.publishProgress", "Mutation.publishLiveSet",
        "Mutation.endLiveSession", "Mutation.postFeed", "Mutation.removeMember", "Mutation.rotateInvite", "Mutation.registerDevice", "Mutation.deleteAccount", "Mutation.aiMessages", "Mutation.publishWeek", "Mutation.clearWeek", "Mutation.createShare", "Mutation.shareImageUpload", "Mutation.deleteShare",
        "Mutation.redeemGift", "Query.giftedPro", "Mutation.syncPush", "Query.syncPull", "Subscription.onSync",
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

describe("groupCleanup (FIT-61)", () => {
  it("runs only when a MEMBER# item is removed", () => {
    dev.hasResourceProperties("AWS::Lambda::EventSourceMapping", {
      FilterCriteria: {
        Filters: [{ Pattern: JSON.stringify({ eventName: ["REMOVE"], dynamodb: { Keys: { SK: { S: [{ prefix: "MEMBER#" }] } } } }) }],
      },
    });
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
    expect(actionsOf(dev, /^groupCleanup/)).toEqual(expect.arrayContaining(["dynamodb:Query", "dynamodb:BatchWriteItem"]));
    expect(actionsOf(dev, /^groupCleanup/)).not.toContain("dynamodb:PutItem");
    // FIT-102: the AI proxy counts each user's requests and reads the Anthropic key; FIT-122: and reads a gift's Pro.
    expect(actionsOf(dev, /^aiProxy/).filter((a) => a.startsWith("dynamodb:")).sort()).toEqual(["dynamodb:GetItem", "dynamodb:UpdateItem"]);
    // FIT-122: gifts are redeemed and refunded, never scanned or deleted.
    for (const name of [/^gifts/, /^stripeWebhook/]) {
      expect(actionsOf(dev, name)).not.toContain("dynamodb:DeleteItem");
      expect(actionsOf(dev, name)).not.toContain("dynamodb:Scan");
      expect(actionsOf(dev, name)).toContain("secretsmanager:GetSecretValue");
    }
    expect(actionsOf(dev, /^aiProxy/)).toContain("secretsmanager:GetSecretValue");
    // FIT-126: sync writes and reads units, never deletes or scans.
    expect(actionsOf(dev, /^sync/).filter((a) => a.startsWith("dynamodb:")).sort()).toEqual(["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"]);
    // FIT-138: appleStart finds, creates and links users and writes their profile; it never deletes them.
    expect(actionsOf(dev, /^appleStart/).sort()).toEqual(["cognito-idp:AdminCreateUser", "cognito-idp:AdminGetUser", "cognito-idp:AdminLinkProviderForUser",
      "cognito-idp:AdminSetUserPassword", "dynamodb:PutItem"]);
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

describe("web dashboard (FIT-127)", () => {
  const synthApp = () => {
    const app = new App({
      context: { "hosted-zone:account=111111111111:domainName=example.com:region=us-east-1": { Id: "/hostedzone/Z1", Name: "example.com." } },
    });
    return Template.fromStack(new AICoachStack(app, "AICoach-dev", {
      env: { account: "111111111111", region: "us-east-1" }, stage: "dev", identityProviders: [], alertEmail: "a@example.com",
      app: { zone: "example.com", host: "app.example.com", assets: fileURLToPath(new URL("./fixtures/web", import.meta.url)) },
    }));
  };

  it("signs in with a public PKCE client that returns only to the dashboard or the local dev server", () => {
    const t = synthApp();
    t.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      ClientName: "web",
      GenerateSecret: false,
      AllowedOAuthFlows: ["code"],
      CallbackURLs: ["https://app.example.com/", "http://localhost:5173/"],
      ExplicitAuthFlows: ["ALLOW_REFRESH_TOKEN_AUTH"],
    });
  });

  it("is served from a private bucket on its own host, with every path falling back to the app", () => {
    const t = synthApp();
    t.hasResourceProperties("AWS::CloudFront::Distribution", {
      DistributionConfig: Match.objectLike({
        Aliases: ["app.example.com"],
        DefaultRootObject: "index.html",
        CustomErrorResponses: [
          Match.objectLike({ ErrorCode: 403, ResponseCode: 200, ResponsePagePath: "/index.html" }),
          Match.objectLike({ ErrorCode: 404, ResponseCode: 200, ResponsePagePath: "/index.html" }),
        ],
      }),
    });
    t.hasOutput("AppUrl", { Value: "https://app.example.com" });
  });

  it("isn't set up for a stage without a host", () => {
    dev.resourceCountIs("Custom::CDKBucketDeployment", 1); // the share cards only
  });
});

describe("share pages (FIT-105)", () => {
  const web = { zone: "example.com", hosts: ["example.com", "share.example.com", "join.example.com"] };
  const synthWeb = () => {
    const app = new App({
      context: { "hosted-zone:account=111111111111:domainName=example.com:region=us-east-1": { Id: "/hostedzone/Z1", Name: "example.com." } },
    });
    return Template.fromStack(new AICoachStack(app, "AICoach-prod", {
      env: { account: "111111111111", region: "us-east-1" }, stage: "prod", identityProviders: [], alertEmail: "a@example.com", web,
    }));
  };

  it("serve every host from one CDN, with a certificate for each, and the Lambda reachable only through it", () => {
    const t = synthWeb();
    t.hasResourceProperties("AWS::CertificateManager::Certificate", {
      DomainName: "example.com",
      SubjectAlternativeNames: ["share.example.com", "join.example.com"],
    });
    t.hasResourceProperties("AWS::CloudFront::Distribution", {
      DistributionConfig: Match.objectLike({ Aliases: web.hosts }),
    });
    t.hasResourceProperties("AWS::Lambda::Url", { AuthType: "AWS_IAM" });
    t.hasResourceProperties("AWS::Lambda::Permission", { Action: "lambda:InvokeFunction", Principal: "cloudfront.amazonaws.com" });
    t.resourceCountIs("AWS::Route53::RecordSet", 6);
    // FIT-107: cards come from the private bucket, through the same distribution.
    t.hasResourceProperties("AWS::CloudFront::Distribution", {
      DistributionConfig: Match.objectLike({ CacheBehaviors: [Match.objectLike({ PathPattern: "/cards/*" })] }),
    });
    t.hasResourceProperties("AWS::S3::Bucket", {
      PublicAccessBlockConfiguration: { BlockPublicAcls: true, BlockPublicPolicy: true, IgnorePublicAcls: true, RestrictPublicBuckets: true },
    });
    t.hasOutput("ShareOrigin", { Value: "https://share.example.com" });
  });

  it("aren't set up for a stage without a domain", () => {
    dev.resourceCountIs("AWS::CloudFront::Distribution", 0);
  });
});
