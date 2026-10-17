import { generateKeyPairSync, sign } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

// FIT-137: linking a second sign-in to an account. Cognito and the table are fakes; the token checks are real.
const cognitoCalls: any[] = [];
vi.mock("@aws-sdk/client-cognito-identity-provider", async (orig) => {
  const actual: any = await orig();
  return { ...actual, CognitoIdentityProviderClient: class { send = async (c: any) => { cognitoCalls.push([c.constructor.name, c.input]); return {}; }; } };
});
const table = new Map<string, Record<string, any>>();
vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return {
    ...actual,
    DynamoDBDocumentClient: {
      from: () => ({
        send: async (c: any) => {
          const i = c.input;
          switch (c.constructor.name) {
            case "QueryCommand": {
              const v = i.ExpressionAttributeValues;
              if (i.IndexName) return { Items: [...table.values()].filter((x) => x.GSI1PK === v[":u"]) };
              return { Items: [...table.values()].filter((x) => x.PK === v[":pk"]) };
            }
            case "GetCommand": return { Item: table.get(`${i.Key.PK}|${i.Key.SK}`) };
            case "PutCommand": table.set(`${i.Item.PK}|${i.Item.SK}`, i.Item); return {};
            case "DeleteCommand": table.delete(`${i.Key.PK}|${i.Key.SK}`); return {};
          }
          throw new Error(c.constructor.name);
        },
      }),
    },
  };
});

process.env.TABLE = "AICoach-test";
process.env.USER_POOL_ID = "us-east-1_TEST";
process.env.AWS_REGION = "us-east-1";
process.env.CLIENT_IDS = "web,ios";
const accounts = await import("../lambda/accounts.ts");
const issuer = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_TEST";
const pair = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwks = [{ ...pair.publicKey.export({ format: "jwk" }), kid: "k1" }];
const now = new Date("2026-10-17T12:00:00Z");
const token = (claims: Record<string, unknown>, key = pair.privateKey) => {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = enc({ alg: "RS256", kid: "k1" });
  const body = enc({ iss: issuer, aud: "web", token_use: "id", exp: now.getTime() / 1000 + 600, ...claims });
  return `${head}.${body}.${sign("RSA-SHA256", Buffer.from(`${head}.${body}`), key).toString("base64url")}`;
};
const apple = { sub: "apple-user", "cognito:username": "SignInWithApple_001.abc", identities: [{ providerName: "SignInWithApple", userId: "001.abc" }] };

beforeEach(() => {
  table.clear();
  cognitoCalls.length = 0;
});

describe("the other sign-in's token (FIT-137)", () => {
  it("is this pool's, for one of its clients, an ID token, unexpired, signed by its key", () => {
    expect(accounts.checkToken(token(apple), jwks, issuer, ["web", "ios"], now).sub).toBe("apple-user");
    const refused = (t: string) => expect(() => accounts.checkToken(t, jwks, issuer, ["web", "ios"], now)).toThrow(accounts.LinkError);
    refused(token({ ...apple, aud: "elsewhere" }));
    refused(token({ ...apple, iss: "https://example.com" }));
    refused(token({ ...apple, token_use: "access" }));
    refused(token({ ...apple, exp: now.getTime() / 1000 - 1 }));
    refused(token(apple, generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey));
    refused("not-a-token");
  });

  it("names the provider identity: federated, or a native Apple account", () => {
    expect(accounts.identityOf(apple as any)).toEqual({ provider: "SignInWithApple", userId: "001.abc" });
    expect(accounts.identityOf({ sub: "x", "cognito:username": "apple_001.xyz" } as any)).toEqual({ provider: "SignInWithApple", userId: "001.xyz" });
    expect(() => accounts.identityOf({ sub: "x", "cognito:username": "smoke-a" } as any)).toThrow(/isn't an Apple or Google/);
  });
});

describe("linking (FIT-137)", () => {
  const me = { sub: "google-user", username: "Google_123" };
  const run = (t: string) => {
    vi.stubGlobal("fetch", async () => ({ json: async () => ({ keys: jwks }) }));
    return accounts.link(me, t, now);
  };

  it("removes the new, empty account and links its identity to mine; Apple is recorded for the native sheet", async () => {
    table.set("USER#apple-user|PROFILE", { PK: "USER#apple-user", SK: "PROFILE" });
    expect(await run(token(apple))).toBe("apple");
    expect(cognitoCalls.map((c) => c[0])).toEqual(["AdminDeleteUserCommand", "AdminLinkProviderForUserCommand"]);
    expect(cognitoCalls[1][1]).toMatchObject({
      DestinationUser: { ProviderName: "Cognito", ProviderAttributeValue: "Google_123" },
      SourceUser: { ProviderName: "SignInWithApple", ProviderAttributeName: "Cognito_Subject", ProviderAttributeValue: "001.abc" },
    });
    expect(await accounts.linkedApple("001.abc")).toBe("Google_123");
    expect(table.has("USER#apple-user|PROFILE")).toBe(false);
  });

  it("refuses an account with its own training, groups or clients, and itself", async () => {
    table.set("USER#apple-user|SYNC#plan#2026-10-16", { PK: "USER#apple-user", SK: "SYNC#plan#2026-10-16" });
    await expect(run(token(apple))).rejects.toThrow(/already has its own training/);
    table.clear();
    table.set("GROUP#g|MEMBER#apple-user", { PK: "GROUP#g", SK: "MEMBER#apple-user", GSI1PK: "USER#apple-user" });
    await expect(run(token(apple))).rejects.toThrow(/already has its own training/);
    await expect(run(token({ ...apple, sub: "google-user" }))).rejects.toThrow(/this account already/);
    expect(cognitoCalls).toEqual([]);
  });
});
