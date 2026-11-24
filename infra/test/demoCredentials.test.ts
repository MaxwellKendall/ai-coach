// TKL-1003: one standing set of test logins, readable by any run, and the checks demo-check.ts makes with them.
import { describe, expect, it } from "vitest";
import { demoCredentials, mergedLines, nextStep, passwordClient, ROLES } from "../scripts/demoCredentials.ts";

const full = {
  DEMO_COACH_EMAIL: "coach@barbrabell.com",
  DEMO_CLIENT_EMAIL: "client@barbrabell.com",
  DEMO_LIFTER_EMAIL: "lifter@barbrabell.com",
  DEMO_PASSWORD: "a-password",
};

describe("demoCredentials", () => {
  it("reads the three standing logins and the shared password", () => {
    const creds = demoCredentials(full);
    expect(creds.missing).toEqual([]);
    expect(creds.stage).toBe("prod");
    expect(creds.accounts).toEqual([
      { role: "coach", email: "coach@barbrabell.com" },
      { role: "client", email: "client@barbrabell.com" },
      { role: "lifter", email: "lifter@barbrabell.com" },
    ]);
  });

  it("names every variable that is missing, so a run knows what to set", () => {
    expect(demoCredentials({ DEMO_COACH_EMAIL: "coach@barbrabell.com" }).missing).toEqual([
      "DEMO_CLIENT_EMAIL",
      "DEMO_LIFTER_EMAIL",
      "DEMO_PASSWORD",
    ]);
  });

  it("takes the stage from DEMO_STAGE when it is set", () => {
    expect(demoCredentials({ ...full, DEMO_STAGE: "dev" }).stage).toBe("dev");
  });

  it("lowercases the emails, because Cognito usernames are lowercase", () => {
    expect(demoCredentials({ ...full, DEMO_COACH_EMAIL: "Coach@Barbrabell.com" }).accounts[0].email).toBe("coach@barbrabell.com");
  });

  it("covers a coach, a client and a solo lifter", () => {
    expect(ROLES).toEqual(["coach", "client", "lifter"]);
  });
});

describe("passwordClient", () => {
  it("picks a client that allows signing in with a password", () => {
    expect(
      passwordClient([
        { id: "a", name: "ios", flows: ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"] },
        { id: "b", name: "mcp", flows: ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"] },
      ]),
    ).toEqual({ id: "b", flow: "USER_PASSWORD_AUTH" });
  });

  it("falls back to a client that allows the admin password flow", () => {
    expect(
      passwordClient([
        { id: "a", name: "ios", flows: ["ALLOW_USER_SRP_AUTH"] },
        { id: "t", name: "Test", flows: ["ALLOW_ADMIN_USER_PASSWORD_AUTH"] },
      ]),
    ).toEqual({ id: "t", flow: "ADMIN_USER_PASSWORD_AUTH" });
  });

  it("is undefined when no client can check a password", () => {
    expect(passwordClient([{ id: "a", name: "ios", flows: ["ALLOW_USER_SRP_AUTH"] }])).toBeUndefined();
  });
});

describe("nextStep", () => {
  it("leaves an account that signs in alone", () => {
    expect(nextStep({ exists: true, signsIn: true }, false)).toBe("ok");
  });

  it("reports a wrong password, and only sets it with --fix", () => {
    expect(nextStep({ exists: true, signsIn: false }, false)).toBe("wrong password");
    expect(nextStep({ exists: true, signsIn: false }, true)).toBe("set the password");
  });

  it("never creates an account: a missing one is reported, --fix or not", () => {
    expect(nextStep({ exists: false, signsIn: false }, false)).toBe("missing");
    expect(nextStep({ exists: false, signsIn: false }, true)).toBe("missing");
  });
});

describe("mergedLines", () => {
  it("applies the shared password and keeps accounts it was not given", () => {
    expect(mergedLines("coach@barbrabell.com old-one\nreview@barbrabell.com keep-me\n", [["coach@barbrabell.com", "new-one"]])).toBe(
      "coach@barbrabell.com new-one\nreview@barbrabell.com keep-me\n",
    );
  });

  it("writes a file that had nothing in it", () => {
    expect(mergedLines("", [["lifter@barbrabell.com", "p"]])).toBe("lifter@barbrabell.com p\n");
  });
});
