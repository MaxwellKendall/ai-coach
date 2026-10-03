import { createVerify, generateKeyPairSync } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { providerToken } from "../lambda/apns.ts";
import { alertText, startsSession } from "../lambda/push.ts";

describe("push: when does a live item start a session?", () => {
  const live = { groupId: "g1", uid: "a", exercise: "Bench press", state: "working", startedAt: "2026-10-03T11:50:00Z" };

  it("on the first set", () => expect(startsSession(undefined, live)).toBe(true));
  it("not on the next set of the same session", () => expect(startsSession(live, { ...live, state: "resting" })).toBe(false));
  it("on a new session overwriting yesterday's item", () => expect(startsSession({ ...live, state: "done", startedAt: "2026-10-02T07:00:00Z" }, live)).toBe(true));
  it("never when the session ends", () => expect(startsSession(undefined, { ...live, state: "done" })).toBe(false));

  it("names the workout when there is one", () => {
    expect(alertText("Dad", { ...live, workout: "Push day" }).body).toBe("Dad started Push day");
    expect(alertText(undefined, live).body).toBe("Someone started Bench press");
  });
});

describe("APNs provider token", () => {
  it("is an ES256 JWT that verifies with the key", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const key = { teamId: "TEAM123456", keyId: "KEY1234567", bundleId: "com.example", privateKey: privateKey.export({ type: "pkcs8", format: "pem" }).toString() };
    const jwt = providerToken(key, 1_790_000_000_000);
    const [h, c, s] = jwt.split(".");
    expect(JSON.parse(Buffer.from(h, "base64url").toString())).toEqual({ alg: "ES256", kid: "KEY1234567" });
    expect(JSON.parse(Buffer.from(c, "base64url").toString())).toEqual({ iss: "TEAM123456", iat: 1_790_000_000 });
    const ok = createVerify("SHA256").update(`${h}.${c}`).verify({ key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url"));
    expect(ok).toBe(true);
    expect(providerToken(key, 1_790_000_000_000 + 10 * 60_000)).toBe(jwt);
  });
});

vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return {
    ...actual,
    paginateQuery: async function* (_: unknown, input: any) {
      const v = input.ExpressionAttributeValues;
      if (input.IndexName === "GSI1") yield { Items: [{ PK: "GROUP#g1", SK: "MEMBER#a" }] };
      else if (v[":pk"] === "USER#a") yield { Items: [{ PK: "USER#a", SK: "PROFILE" }, { PK: "USER#a", SK: "DEVICE#tok" }] };
      else if (v[":p"] === "PROGRESS#a#") yield { Items: [{ PK: "GROUP#g1", SK: "PROGRESS#a#goal1", pct: 50 }] };
      else if (v[":f"] === "FEED#") yield { Items: [{ PK: "GROUP#g1", SK: "FEED#t#1", uid: "a" }] };
    },
  };
});

describe("deleteAccount", () => {
  it("collects the user's own partition and their items in each group", async () => {
    process.env.TABLE = "AICoach-test";
    const { itemsToDelete } = await import("../lambda/deleteAccount.ts");
    expect(await itemsToDelete("a")).toEqual([
      { PK: "USER#a", SK: "PROFILE" },
      { PK: "USER#a", SK: "DEVICE#tok" },
      { PK: "GROUP#g1", SK: "MEMBER#a" },
      { PK: "GROUP#g1", SK: "LIVE#a" },
      { PK: "GROUP#g1", SK: "PROGRESS#a#goal1" },
      { PK: "GROUP#g1", SK: "FEED#t#1" },
    ]);
  });
});
