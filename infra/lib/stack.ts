import { fileURLToPath } from "node:url";
import { CfnOutput, Duration, RemovalPolicy, SecretValue, Stack, type StackProps } from "aws-cdk-lib";
import * as appsync from "aws-cdk-lib/aws-appsync";
import * as budgets from "aws-cdk-lib/aws-budgets";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as origins from "aws-cdk-lib/aws-cloudfront-origins";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as actions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { DynamoEventSource } from "aws-cdk-lib/aws-lambda-event-sources";
import { NodejsFunction } from "aws-cdk-lib/aws-lambda-nodejs";
import * as logs from "aws-cdk-lib/aws-logs";
import * as route53 from "aws-cdk-lib/aws-route53";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3deploy from "aws-cdk-lib/aws-s3-deployment";
import * as targets from "aws-cdk-lib/aws-route53-targets";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as sns from "aws-cdk-lib/aws-sns";
import * as subs from "aws-cdk-lib/aws-sns-subscriptions";
import type { Construct } from "constructs";

export type Stage = "dev" | "prod";
export type IdentityProvider = "apple" | "google";

export interface AICoachStackProps extends StackProps {
  stage: Stage;
  /** Federated providers to enable. Each needs its secret in Secrets Manager before deploy. */
  identityProviders: IdentityProvider[];
  alertEmail: string;
  /**
   * FIT-105: the share pages' domain, a Route 53 hosted zone in this account, and the hosts on it. A host
   * starting with "join." takes invite codes at its root (join.{domain}/CODE); the others serve every page.
   */
  web?: { zone: string; hosts: string[] };
  /** FIT-127: the web dashboard's host on a Route 53 zone, and its built files (web/dist). */
  app?: { zone: string; host: string; assets: string };
}

const path = (relative: string) => fileURLToPath(new URL(relative, import.meta.url));

/** FIT-56: accounts, groups and live workouts. One stack per stage. */
export class AICoachStack extends Stack {
  constructor(scope: Construct, id: string, props: AICoachStackProps) {
    super(scope, id, props);
    const { stage } = props;
    const isProd = stage === "prod";
    const removalPolicy = isProd ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;

    // ---- DynamoDB: single table (key design in FIT-56) ----
    const table = new dynamodb.Table(this, "Table", {
      tableName: `AICoach-${stage}`,
      partitionKey: { name: "PK", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "SK", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      // Old image too: the push Lambda compares startedAt to tell a new session from the next set.
      stream: dynamodb.StreamViewType.NEW_AND_OLD_IMAGES,
      timeToLiveAttribute: "expiresAt",
      deletionProtection: isProd,
      removalPolicy,
    });
    table.addGlobalSecondaryIndex({
      indexName: "GSI1",
      partitionKey: { name: "GSI1PK", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "GSI1SK", type: dynamodb.AttributeType.STRING },
    });

    const fn = (name: string, environment: Record<string, string>) =>
      new NodejsFunction(this, name, {
        entry: path(`../lambda/${name}.ts`),
        runtime: lambda.Runtime.NODEJS_22_X,
        architecture: lambda.Architecture.ARM_64,
        timeout: Duration.seconds(30),
        environment: { TABLE: table.tableName, ...environment },
        logGroup: new logs.LogGroup(this, `${name}Logs`, { retention: logs.RetentionDays.ONE_MONTH, removalPolicy }),
      });

    // ---- Cognito: federated sign-in only ----
    const postConfirmation = fn("postConfirmation", {});
    table.grant(postConfirmation, "dynamodb:PutItem");
    // FIT-138: native Sign in with Apple, as custom auth answered with Apple's identity token.
    const appleTrigger = (handler: string) =>
      new NodejsFunction(this, `Apple${handler}`, {
        entry: path("../lambda/appleAuth.ts"),
        handler,
        runtime: lambda.Runtime.NODEJS_22_X,
        architecture: lambda.Architecture.ARM_64,
        timeout: Duration.seconds(10),
        logGroup: new logs.LogGroup(this, `Apple${handler}Logs`, { retention: logs.RetentionDays.ONE_MONTH, removalPolicy }),
        environment: { TABLE: table.tableName },
      });
    const verifyAuthChallengeResponse = appleTrigger("verifyChallenge");
    // FIT-137: Verify accepts an account the Apple user linked their sign-in to.
    table.grant(verifyAuthChallengeResponse, "dynamodb:GetItem");

    const userPool = new cognito.UserPool(this, "Users", {
      userPoolName: `AICoach-${stage}`,
      featurePlan: cognito.FeaturePlan.LITE,
      // Federated users are created through sign-up, so it stays on; no client allows password sign-in.
      selfSignUpEnabled: true,
      accountRecovery: cognito.AccountRecovery.NONE,
      standardAttributes: {
        email: { required: false, mutable: true },
        fullname: { required: false, mutable: true },
      },
      lambdaTriggers: {
        postConfirmation,
        preSignUp: appleTrigger("preSignUp"),
        defineAuthChallenge: appleTrigger("define"),
        createAuthChallenge: appleTrigger("create"),
        verifyAuthChallengeResponse,
      },
      deletionProtection: isProd,
      removalPolicy,
    });

    const providers: cognito.UserPoolIdentityProvider[] = [];
    const clientProviders: cognito.UserPoolClientIdentityProvider[] = [];
    if (props.identityProviders.includes("apple")) {
      const secret = `aicoach/${stage}/apple-signin`;
      const field = (jsonField: string) => SecretValue.secretsManager(secret, { jsonField });
      providers.push(
        new cognito.UserPoolIdentityProviderApple(this, "Apple", {
          userPool,
          clientId: field("servicesId").unsafeUnwrap(),
          teamId: field("teamId").unsafeUnwrap(),
          keyId: field("keyId").unsafeUnwrap(),
          privateKeyValue: field("privateKey"),
          scopes: ["name", "email"],
          attributeMapping: {
            email: cognito.ProviderAttribute.APPLE_EMAIL,
            fullname: cognito.ProviderAttribute.APPLE_NAME,
          },
        }),
      );
      clientProviders.push(cognito.UserPoolClientIdentityProvider.APPLE);
    }
    if (props.identityProviders.includes("google")) {
      const secret = `aicoach/${stage}/google-oauth`;
      providers.push(
        new cognito.UserPoolIdentityProviderGoogle(this, "Google", {
          userPool,
          clientId: SecretValue.secretsManager(secret, { jsonField: "clientId" }).unsafeUnwrap(),
          clientSecretValue: SecretValue.secretsManager(secret, { jsonField: "clientSecret" }),
          scopes: ["openid", "email", "profile"],
          attributeMapping: {
            email: cognito.ProviderAttribute.GOOGLE_EMAIL,
            fullname: cognito.ProviderAttribute.GOOGLE_NAME,
          },
        }),
      );
      clientProviders.push(cognito.UserPoolClientIdentityProvider.GOOGLE);
    }

    const domainPrefix = isProd ? "aicoach" : `aicoach-${stage}`;
    userPool.addDomain("Domain", { cognitoDomain: { domainPrefix } });

    const appClient = userPool.addClient("App", {
      userPoolClientName: "ios",
      generateSecret: false,
      preventUserExistenceErrors: true,
      supportedIdentityProviders: clientProviders,
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: ["aicoach://auth/callback"],
        logoutUrls: ["aicoach://auth/signout"],
      },
    });
    // Hosted-UI federation, native Apple (custom auth, FIT-138) and refresh: no SRP or password flows on the public client.
    (appClient.node.defaultChild as cognito.CfnUserPoolClient).explicitAuthFlows = ["ALLOW_CUSTOM_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"];
    providers.forEach((p) => appClient.node.addDependency(p));

    // FIT-138: finds or creates the user for Apple's identity token before custom auth signs them in.
    const appleStart = fn("appleStart", {
      USER_POOL_ID: userPool.userPoolId,
      APPLE_PROVIDER: props.identityProviders.includes("apple") ? "SignInWithApple" : "",
    });
    table.grant(appleStart, "dynamodb:PutItem", "dynamodb:GetItem");
    appleStart.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ["cognito-idp:AdminGetUser", "cognito-idp:AdminCreateUser", "cognito-idp:AdminSetUserPassword", "cognito-idp:AdminLinkProviderForUser"],
        resources: [userPool.userPoolArn],
      }),
    );
    const appleStartUrl = appleStart.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });

    // FIT-149: the training as MCP tools for any agent, on the agent's own tokens. The URL carries the connection's
    // token (only its hash is stored); OAuth comes next.
    const mcp = fn("mcp", {});
    table.grant(mcp, "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query");
    const mcpUrl = mcp.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });

    // FIT-127: the web dashboard signs in through the same hosted UI, as a public client with PKCE.
    const webOrigins = [...(props.app ? [`https://${props.app.host}/`] : []), "http://localhost:5173/"];
    const webClient = userPool.addClient("Web", {
      userPoolClientName: "web",
      generateSecret: false,
      preventUserExistenceErrors: true,
      supportedIdentityProviders: clientProviders,
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: webOrigins,
        logoutUrls: webOrigins,
      },
    });
    (webClient.node.defaultChild as cognito.CfnUserPoolClient).explicitAuthFlows = ["ALLOW_REFRESH_TOKEN_AUTH"];
    providers.forEach((p) => webClient.node.addDependency(p));

    // Dev only: lets the smoke test sign in admin-created test users without a browser.
    const testClient = isProd
      ? undefined
      : userPool.addClient("Test", {
          userPoolClientName: "smoke-test",
          generateSecret: false,
          disableOAuth: true,
          authFlows: { adminUserPassword: true },
          supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.COGNITO],
        });

    // FIT-105: where shared links point. Without a domain (a stage not set up yet), the API still saves shares.
    const shareHost = props.web && (props.web.hosts.find((h) => h.startsWith("share.")) ?? props.web.hosts[0]);
    const shareOrigin = shareHost ? `https://${shareHost}` : "";

    // ---- AppSync ----
    const api = new appsync.GraphqlApi(this, "Api", {
      name: `AICoach-${stage}`,
      definition: appsync.Definition.fromFile(path("../graphql/schema.graphql")),
      authorizationConfig: {
        defaultAuthorization: {
          authorizationType: appsync.AuthorizationType.USER_POOL,
          userPoolConfig: { userPool },
        },
      },
      logConfig: { fieldLogLevel: appsync.FieldLogLevel.ERROR, retention: logs.RetentionDays.ONE_MONTH },
      environmentVariables: { TABLE: table.tableName, SHARE_ORIGIN: shareOrigin },
    });

    const tableSource = api.addDynamoDbDataSource("TableSource", table);

    const functions = new Map<string, appsync.AppsyncFunction>();
    const step = (name: string) => {
      if (!functions.has(name)) {
        functions.set(
          name,
          new appsync.AppsyncFunction(this, `Fn${name}`, {
            api,
            name,
            dataSource: tableSource,
            runtime: appsync.FunctionRuntime.JS_1_0_0,
            code: appsync.Code.fromAsset(path(`../resolvers/${name}.js`)),
          }),
        );
      }
      return functions.get(name)!;
    };
    const pipeline = (typeName: string, fieldName: string, steps: string[], code = "pipeline") =>
      new appsync.Resolver(this, `${typeName}${fieldName}`, {
        api,
        typeName,
        fieldName,
        runtime: appsync.FunctionRuntime.JS_1_0_0,
        code: appsync.Code.fromAsset(path(`../resolvers/${code}.js`)),
        pipelineConfig: steps.map(step),
      });

    pipeline("Query", "me", ["getProfile"]);
    pipeline("Query", "share", ["getShare"]);
    pipeline("Query", "myGroups", ["myGroups"]);
    pipeline("Query", "group", ["requireMember", "groupDetail"]);
    tableSource.createResolver("GroupFeed", {
      typeName: "Group",
      fieldName: "feed",
      runtime: appsync.FunctionRuntime.JS_1_0_0,
      code: appsync.Code.fromAsset(path("../resolvers/groupFeed.js")),
    });

    pipeline("Mutation", "updateProfile", ["updateProfile"]);
    pipeline("Mutation", "createGroup", ["getProfile", "createGroup"]);
    pipeline("Mutation", "joinGroup", ["getInvite", "getProfile", "joinGroup"]);
    pipeline("Mutation", "registerDevice", ["registerDevice"]);
    pipeline("Mutation", "createShare", ["getProfile", "createShare"]);
    // Every group operation checks membership first.
    for (const field of ["leaveGroup", "setShareLive", "addGroupGoal", "publishProgress", "publishLiveSet", "endLiveSession", "postFeed",
      "publishWeek", "clearWeek"]) {
      pipeline("Mutation", field, ["requireMember", field]);
    }
    // Creator-only: the step checks META.createdBy.
    for (const field of ["removeMember", "rotateInvite"]) {
      pipeline("Mutation", field, ["requireMember", "getGroupMeta", field]);
    }
    for (const field of ["onLiveSet", "onProgress", "onFeed"]) {
      pipeline("Subscription", field, ["requireMember"], "subscription");
    }

    // ---- FIT-107: shared cards' images, for link previews (served at /cards/* by the web distribution) ----
    const cards = new s3.Bucket(this, "Cards", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy,
      autoDeleteObjects: !isProd,
    });
    // The invite's link preview, the same for every group (assets/cards). Never pruned: users' cards live here too.
    new s3deploy.BucketDeployment(this, "CardAssets", {
      sources: [s3deploy.Source.asset(path("../assets/cards"))],
      destinationBucket: cards,
      destinationKeyPrefix: "cards/",
      prune: false,
    });
    const shares = fn("shares", { CARDS_BUCKET: cards.bucketName });
    table.grant(shares, "dynamodb:GetItem", "dynamodb:DeleteItem");
    cards.grantPut(shares, "cards/*");
    cards.grantDelete(shares, "cards/*");
    const sharesSource = api.addLambdaDataSource("SharesSource", shares);
    for (const fieldName of ["shareImageUpload", "deleteShare"]) {
      sharesSource.createResolver(`Shares${fieldName}`, { typeName: "Mutation", fieldName });
    }

    const deleteAccount = fn("deleteAccount", { USER_POOL_ID: userPool.userPoolId, CARDS_BUCKET: cards.bucketName });
    table.grant(deleteAccount, "dynamodb:Query", "dynamodb:BatchWriteItem");
    cards.grantDelete(deleteAccount, "cards/*");
    deleteAccount.addToRolePolicy(
      new iam.PolicyStatement({ actions: ["cognito-idp:AdminDeleteUser"], resources: [userPool.userPoolArn] }),
    );
    api.addLambdaDataSource("DeleteAccountSource", deleteAccount).createResolver("DeleteAccount", {
      typeName: "Mutation",
      fieldName: "deleteAccount",
    });

    // ---- FIT-122: gifts of Pro, sold on the web through Stripe; the author creates the secret ----
    const stripeSecret = secretsmanager.Secret.fromSecretNameV2(this, "StripeSecret", `aicoach/${stage}/stripe`);
    const giftEnv = { STRIPE_SECRET: stripeSecret.secretName, GIFT_PRICE_CENTS: "3999" };
    const gifts = fn("gifts", giftEnv);
    table.grant(gifts, "dynamodb:GetItem", "dynamodb:UpdateItem");
    stripeSecret.grantRead(gifts);
    const giftsSource = api.addLambdaDataSource("GiftsSource", gifts);
    giftsSource.createResolver("GiftsRedeem", { typeName: "Mutation", fieldName: "redeemGift" });
    giftsSource.createResolver("GiftsPro", { typeName: "Query", fieldName: "giftedPro" });
    // Stripe posts here directly: CloudFront's origin access control passes only GETs on to a function URL.
    const stripeWebhook = fn("stripeWebhook", giftEnv);
    table.grant(stripeWebhook, "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem");
    stripeSecret.grantRead(stripeWebhook);
    const webhookUrl = stripeWebhook.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });
    new CfnOutput(this, "StripeWebhookUrl", { value: webhookUrl.url });

    // ---- FIT-144: the coach plan, a Stripe subscription; the webhook above keeps it up to date ----
    const coachPlan = fn("coachPlan", { STRIPE_SECRET: stripeSecret.secretName, APP_ORIGIN: props.app ? `https://${props.app.host}` : "http://localhost:5173" });
    table.grant(coachPlan, "dynamodb:GetItem", "dynamodb:UpdateItem");
    stripeSecret.grantRead(coachPlan);
    const coachPlanSource = api.addLambdaDataSource("CoachPlanSource", coachPlan);
    coachPlanSource.createResolver("CoachPlanGet", { typeName: "Query", fieldName: "coachPlan" });
    coachPlanSource.createResolver("CoachPlanStart", { typeName: "Mutation", fieldName: "startCoachPlan" });
    coachPlanSource.createResolver("CoachPlanPortal", { typeName: "Mutation", fieldName: "coachBillingPortal" });

    // ---- FIT-102: Claude for the app, with the key kept here ----
    const anthropicSecret = secretsmanager.Secret.fromSecretNameV2(this, "AnthropicSecret", `aicoach/${stage}/anthropic`);
    // FIT-123: without Pro, a few requests per account for good; dev has room for testing with StoreKit's local
    // config, whose Xcode-signed transactions aren't Apple's.
    const aiProxy = fn("aiProxy", { ANTHROPIC_SECRET: anthropicSecret.secretName, FREE_REQUESTS: isProd ? "40" : "1000" });
    // Query: whether the account has a coach (FIT-130).
    table.grant(aiProxy, "dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:Query");
    anthropicSecret.grantRead(aiProxy);
    api.addLambdaDataSource("AiProxySource", aiProxy).createResolver("AiMessages", {
      typeName: "Mutation",
      fieldName: "aiMessages",
    });

    // ---- FIT-137: linking Apple and Google sign-ins into one account ----
    const accounts = fn("accounts", { USER_POOL_ID: userPool.userPoolId, CLIENT_IDS: [appClient.userPoolClientId, webClient.userPoolClientId].join(",") });
    table.grant(accounts, "dynamodb:Query", "dynamodb:PutItem", "dynamodb:DeleteItem");
    accounts.addToRolePolicy(new iam.PolicyStatement({
      actions: ["cognito-idp:AdminDeleteUser", "cognito-idp:AdminLinkProviderForUser"], resources: [userPool.userPoolArn],
    }));
    api.addLambdaDataSource("AccountsSource", accounts).createResolver("LinkAccount", { typeName: "Mutation", fieldName: "linkAccount" });

    // ---- FIT-126: the program and logs, synced both ways ----
    const sync = fn("sync", {});
    // GetItem also checks a coach's link (FIT-130).
    table.grant(sync, "dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query");
    const syncSource = api.addLambdaDataSource("SyncSource", sync);
    syncSource.createResolver("SyncPush", { typeName: "Mutation", fieldName: "syncPush" });
    syncSource.createResolver("SyncPull", { typeName: "Query", fieldName: "syncPull" });

    // ---- FIT-130: coaches and clients ----
    const coach = fn("coach", { SHARE_ORIGIN: shareOrigin || "https://example.invalid" });
    table.grant(coach, "dynamodb:GetItem", "dynamodb:Query", "dynamodb:PutItem", "dynamodb:DeleteItem");
    const coachSource = api.addLambdaDataSource("CoachSource", coach);
    for (const [typeName, fieldName] of [["Mutation", "createClientInvite"], ["Query", "coachInvite"], ["Mutation", "acceptCoach"],
      ["Query", "myCoaches"], ["Query", "myClients"], ["Mutation", "unlinkCoach"], ["Mutation", "removeClient"],
      ["Mutation", "postComment"], ["Query", "comments"]]) {
      coachSource.createResolver(`Coach${fieldName}`, { typeName, fieldName });
    }
    // FIT-131: programs a coach sends; starting one writes the client's synced plan.
    const programs = fn("programs", {});
    table.grant(programs, "dynamodb:GetItem", "dynamodb:Query", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:BatchGetItem");
    const programsSource = api.addLambdaDataSource("ProgramsSource", programs);
    for (const [typeName, fieldName] of [["Mutation", "sendProgram"], ["Query", "programOffers"], ["Mutation", "answerProgram"]]) {
      programsSource.createResolver(`Programs${fieldName}`, { typeName, fieldName });
    }
    api.addNoneDataSource("None").createResolver("OnSync", {
      typeName: "Subscription",
      fieldName: "onSync",
      runtime: appsync.FunctionRuntime.JS_1_0_0,
      code: appsync.Code.fromAsset(path("../resolvers/onSync.js")),
    });

    // ---- Push: stream → Lambda → APNs ----
    const apnsSecret = secretsmanager.Secret.fromSecretNameV2(this, "ApnsSecret", `aicoach/${stage}/apns`);
    const push = fn("push", {
      APNS_SECRET: apnsSecret.secretName,
      // Debug builds register sandbox tokens; TestFlight and App Store builds use production.
      APNS_HOST: isProd ? "api.push.apple.com" : "api.sandbox.push.apple.com",
    });
    table.grant(push, "dynamodb:Query", "dynamodb:DeleteItem");
    apnsSecret.grantRead(push);
    push.addEventSource(
      new DynamoEventSource(table, {
        startingPosition: lambda.StartingPosition.LATEST,
        batchSize: 10,
        retryAttempts: 2,
        filters: [
          lambda.FilterCriteria.filter({
            eventName: lambda.FilterRule.or("INSERT", "MODIFY"),
            dynamodb: { Keys: { SK: { S: lambda.FilterRule.beginsWith("LIVE#") } } },
          }),
          // FIT-132: a coach's reply on a session.
          lambda.FilterCriteria.filter({
            eventName: lambda.FilterRule.isEqual("INSERT"),
            dynamodb: { Keys: { SK: { S: lambda.FilterRule.beginsWith("COMMENT#") } } },
          }),
          // FIT-131: a program sent to a client.
          lambda.FilterCriteria.filter({
            eventName: lambda.FilterRule.isEqual("INSERT"),
            dynamodb: { Keys: { SK: { S: lambda.FilterRule.beginsWith("OFFER#") } } },
          }),
        ],
      }),
    );

    // ---- FIT-61: a group with no members left is deleted, with its invite ----
    const groupCleanup = fn("groupCleanup", {});
    table.grant(groupCleanup, "dynamodb:Query", "dynamodb:BatchWriteItem");
    groupCleanup.addEventSource(
      new DynamoEventSource(table, {
        startingPosition: lambda.StartingPosition.LATEST,
        batchSize: 25,
        retryAttempts: 2,
        filters: [
          lambda.FilterCriteria.filter({
            eventName: lambda.FilterRule.isEqual("REMOVE"),
            dynamodb: { Keys: { SK: { S: lambda.FilterRule.beginsWith("MEMBER#") } } },
          }),
        ],
      }),
    );

    // ---- FIT-105: the share pages, on the domain ----
    if (props.web) {
      const zone = route53.HostedZone.fromLookup(this, "Zone", { domainName: props.web.zone });
      const [primary, ...others] = props.web.hosts;
      const certificate = new acm.Certificate(this, "WebCertificate", {
        domainName: primary,
        subjectAlternativeNames: others,
        validation: acm.CertificateValidation.fromDns(zone),
      });
      const share = fn("share", {
        SHARE_ORIGIN: shareOrigin,
        APP_ID: "7GZKY29XJH.com.maxwellkendall.aicoach",
        APP_STORE_URL: "",
        ...giftEnv,
      });
      // PutItem: the thanks page saves a paid gift if Stripe's webhook hasn't yet.
      table.grant(share, "dynamodb:GetItem", "dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:PutItem");
      stripeSecret.grantRead(share);
      const url = share.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.AWS_IAM });
      // join.{domain}/CODE is the invite page, /join/CODE; Apple's file stays where Apple looks for it.
      const joinPaths = new cloudfront.Function(this, "JoinPaths", {
        runtime: cloudfront.FunctionRuntime.JS_2_0,
        code: cloudfront.FunctionCode.fromInline(`function handler(event) {
  var r = event.request, host = r.headers.host ? r.headers.host.value : "";
  if (host.indexOf("join.") === 0 && r.uri !== "/" && r.uri.indexOf("/.well-known/") !== 0 && r.uri.indexOf("/join/") !== 0) r.uri = "/join" + r.uri;
  return r;
}`),
      });
      const web = new cloudfront.Distribution(this, "Web", {
        domainNames: props.web.hosts,
        certificate,
        defaultBehavior: {
          origin: origins.FunctionUrlOrigin.withOriginAccessControl(url),
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
          // The Lambda's cache-control says how long; the path is the whole key.
          cachePolicy: new cloudfront.CachePolicy(this, "WebCache", {
            defaultTtl: Duration.minutes(5),
            minTtl: Duration.seconds(0),
            maxTtl: Duration.hours(1),
          }),
          functionAssociations: [{ function: joinPaths, eventType: cloudfront.FunctionEventType.VIEWER_REQUEST }],
        },
        additionalBehaviors: {
          "/cards/*": {
            origin: origins.S3BucketOrigin.withOriginAccessControl(cards),
            viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
            cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
          },
        },
        priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
      });
      // Function URLs behind CloudFront need InvokeFunction as well as the InvokeFunctionUrl that CDK grants.
      share.addPermission("WebInvoke", {
        principal: new iam.ServicePrincipal("cloudfront.amazonaws.com"),
        action: "lambda:InvokeFunction",
        sourceArn: `arn:aws:cloudfront::${this.account}:distribution/${web.distributionId}`,
      });
      for (const host of props.web.hosts) {
        const recordName = host === props.web.zone ? undefined : host;
        const target = route53.RecordTarget.fromAlias(new targets.CloudFrontTarget(web));
        new route53.ARecord(this, `Web${host}`, { zone, recordName, target });
        new route53.AaaaRecord(this, `Web6${host}`, { zone, recordName, target });
      }
      new CfnOutput(this, "ShareOrigin", { value: shareOrigin });
    }

    // ---- FIT-127: the web dashboard, a static app on its own host; config.json tells it where the API is ----
    const webConfig = {
      region: this.region,
      clientId: webClient.userPoolClientId,
      cognitoDomain: `${domainPrefix}.auth.${this.region}.amazoncognito.com`,
      graphqlUrl: api.graphqlUrl,
      providers: props.identityProviders,
    };
    if (props.app) {
      const zone = route53.HostedZone.fromLookup(this, "AppZone", { domainName: props.app.zone });
      const site = new s3.Bucket(this, "AppSite", {
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        enforceSSL: true,
        encryption: s3.BucketEncryption.S3_MANAGED,
        removalPolicy,
        autoDeleteObjects: !isProd,
      });
      const certificate = new acm.Certificate(this, "AppCertificate", {
        domainName: props.app.host,
        validation: acm.CertificateValidation.fromDns(zone),
      });
      // Every path is the app (it routes in the browser), so a missing file is index.html.
      const index = { responseHttpStatus: 200, responsePagePath: "/index.html", ttl: Duration.seconds(0) };
      const dashboard = new cloudfront.Distribution(this, "App", {
        domainNames: [props.app.host],
        certificate,
        defaultRootObject: "index.html",
        defaultBehavior: {
          origin: origins.S3BucketOrigin.withOriginAccessControl(site),
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
          responseHeadersPolicy: cloudfront.ResponseHeadersPolicy.SECURITY_HEADERS,
        },
        errorResponses: [{ httpStatus: 403, ...index }, { httpStatus: 404, ...index }],
        priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
      });
      new s3deploy.BucketDeployment(this, "AppFiles", {
        sources: [s3deploy.Source.asset(props.app.assets), s3deploy.Source.jsonData("config.json", webConfig)],
        destinationBucket: site,
        distribution: dashboard,
        distributionPaths: ["/index.html", "/config.json"],
      });
      const target = route53.RecordTarget.fromAlias(new targets.CloudFrontTarget(dashboard));
      new route53.ARecord(this, "AppRecord", { zone, recordName: props.app.host, target });
      new route53.AaaaRecord(this, "AppRecord6", { zone, recordName: props.app.host, target });
      new CfnOutput(this, "AppUrl", { value: `https://${props.app.host}` });
    }

    // ---- FIT-110: what the sharing flywheel makes, counted by day ----
    const shareStats = fn("shareStats", {});
    table.grant(shareStats, "dynamodb:UpdateItem");
    shareStats.addEventSource(
      new DynamoEventSource(table, {
        startingPosition: lambda.StartingPosition.LATEST,
        batchSize: 25,
        retryAttempts: 2,
        filters: [
          lambda.FilterCriteria.filter({ eventName: lambda.FilterRule.isEqual("INSERT"), dynamodb: { Keys: { PK: { S: lambda.FilterRule.beginsWith("SHARE#") } } } }),
          lambda.FilterCriteria.filter({
            eventName: lambda.FilterRule.isEqual("INSERT"),
            dynamodb: { Keys: { PK: { S: lambda.FilterRule.beginsWith("GROUP#") }, SK: { S: lambda.FilterRule.isEqual("META") } } },
          }),
          lambda.FilterCriteria.filter({
            eventName: lambda.FilterRule.isEqual("INSERT"),
            dynamodb: { Keys: { PK: { S: lambda.FilterRule.beginsWith("GROUP#") }, SK: { S: lambda.FilterRule.beginsWith("MEMBER#") } } },
          }),
        ],
      }),
    );

    // ---- Ops: one alarm, one budget ----
    const alerts = new sns.Topic(this, "Alerts", { topicName: `AICoach-${stage}-alerts` });
    alerts.addSubscription(new subs.EmailSubscription(props.alertEmail));

    const lambdas = { a: postConfirmation, b: deleteAccount, c: push, d: groupCleanup, e: gifts, f: stripeWebhook, g: appleStart, h: verifyAuthChallengeResponse, i: mcp };
    const errors = new cloudwatch.MathExpression({
      expression: "a + b + c + d + e + f + g + h + i + api",
      usingMetrics: {
        ...Object.fromEntries(Object.entries(lambdas).map(([k, f]) => [k, f.metricErrors({ period: Duration.minutes(5) })])),
        api: new cloudwatch.Metric({
          namespace: "AWS/AppSync",
          metricName: "5XXError",
          dimensionsMap: { GraphQLAPIId: api.apiId },
          statistic: "Sum",
          period: Duration.minutes(5),
        }),
      },
      label: "Lambda errors + AppSync 5xx",
      period: Duration.minutes(5),
    });
    new cloudwatch.Alarm(this, "ErrorsAlarm", {
      alarmName: `AICoach-${stage}-errors`,
      metric: errors,
      threshold: 1,
      evaluationPeriods: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    }).addAlarmAction(new actions.SnsAction(alerts));

    new budgets.CfnBudget(this, "Budget", {
      budget: {
        budgetName: `AICoach-${stage}`,
        budgetType: "COST",
        timeUnit: "MONTHLY",
        budgetLimit: { amount: 20, unit: "USD" },
      },
      notificationsWithSubscribers: (["ACTUAL", "FORECASTED"] as const).map((notificationType) => ({
        notification: { notificationType, comparisonOperator: "GREATER_THAN", threshold: 100, thresholdType: "PERCENTAGE" },
        subscribers: [{ subscriptionType: "EMAIL", address: props.alertEmail }],
      })),
    });

    // ---- Outputs read by scripts/outputs.ts and scripts/smoke.ts ----
    new CfnOutput(this, "Region", { value: this.region });
    new CfnOutput(this, "UserPoolId", { value: userPool.userPoolId });
    new CfnOutput(this, "AppClientId", { value: appClient.userPoolClientId });
    new CfnOutput(this, "AppleStartUrl", { value: appleStartUrl.url });
    new CfnOutput(this, "McpUrl", { value: mcpUrl.url });
    new CfnOutput(this, "WebClientId", { value: webClient.userPoolClientId });
    new CfnOutput(this, "CognitoDomain", { value: `${domainPrefix}.auth.${this.region}.amazoncognito.com` });
    new CfnOutput(this, "IdentityProviders", { value: props.identityProviders.join(",") || "none" });
    new CfnOutput(this, "GraphqlUrl", { value: api.graphqlUrl });
    if (testClient) new CfnOutput(this, "TestClientId", { value: testClient.userPoolClientId });
  }
}
