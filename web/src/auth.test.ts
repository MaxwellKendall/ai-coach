import { describe, expect, it } from "vitest";
import { user } from "./auth";

const token = (claims: Record<string, unknown>) => `x.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.y`;

describe("the signed-in user (FIT-137)", () => {
  it("knows every sign-in on the account", () => {
    expect(user(token({ sub: "u", "cognito:username": "Google_1" })).linked).toEqual(["google"]);
    expect(user(token({ sub: "u", "cognito:username": "Google_1", identities: [{ providerName: "Google" }, { providerName: "SignInWithApple" }] })).linked)
      .toEqual(["google", "apple"]);
    expect(user(token({ sub: "u", "cognito:username": "apple_001.abc" }))).toMatchObject({ provider: "apple", linked: ["apple"] });
  });
});
