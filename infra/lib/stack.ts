import { fileURLToPath } from "node:url";
import { CfnOutput, Duration, RemovalPolicy, SecretValue, Stack, type StackProps } from "aws-cdk-lib";
import * as appsync from "aws-cdk-lib/aws-appsync";
import * as budgets from "aws-cdk-lib/aws-budgets";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as actions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { DynamoEventSource } from "aws-cdk-lib/aws-lambda-event-sources";
import { NodejsFunction } from "aws-cdk-lib/aws-lambda-nodejs";
import * as logs from "aws-cdk-lib/aws-logs";
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
      lambdaTriggers: { postConfirmation },
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
    // Hosted-UI federation plus refresh only: no SRP or password flows on the public client.
    (appClient.node.defaultChild as cognito.CfnUserPoolClient).explicitAuthFlows = ["ALLOW_REFRESH_TOKEN_AUTH"];
    providers.forEach((p) => appClient.node.addDependency(p));

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
      environmentVariables: { TABLE: table.tableName },
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
    // Every group operation checks membership first.
    for (const field of ["leaveGroup", "setShareLive", "addGroupGoal", "publishProgress", "publishLiveSet", "endLiveSession", "postFeed"]) {
      pipeline("Mutation", field, ["requireMember", field]);
    }
    for (const field of ["onLiveSet", "onProgress", "onFeed"]) {
      pipeline("Subscription", field, ["requireMember"], "subscription");
    }

    const deleteAccount = fn("deleteAccount", { USER_POOL_ID: userPool.userPoolId });
    table.grant(deleteAccount, "dynamodb:Query", "dynamodb:BatchWriteItem");
    deleteAccount.addToRolePolicy(
      new iam.PolicyStatement({ actions: ["cognito-idp:AdminDeleteUser"], resources: [userPool.userPoolArn] }),
    );
    api.addLambdaDataSource("DeleteAccountSource", deleteAccount).createResolver("DeleteAccount", {
      typeName: "Mutation",
      fieldName: "deleteAccount",
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
        ],
      }),
    );

    // ---- Ops: one alarm, one budget ----
    const alerts = new sns.Topic(this, "Alerts", { topicName: `AICoach-${stage}-alerts` });
    alerts.addSubscription(new subs.EmailSubscription(props.alertEmail));

    const lambdas = { a: postConfirmation, b: deleteAccount, c: push };
    const errors = new cloudwatch.MathExpression({
      expression: "a + b + c + api",
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
    new CfnOutput(this, "CognitoDomain", { value: `${domainPrefix}.auth.${this.region}.amazoncognito.com` });
    new CfnOutput(this, "IdentityProviders", { value: props.identityProviders.join(",") || "none" });
    new CfnOutput(this, "GraphqlUrl", { value: api.graphqlUrl });
    if (testClient) new CfnOutput(this, "TestClientId", { value: testClient.userPoolClientId });
  }
}
