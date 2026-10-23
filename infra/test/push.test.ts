import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Push's stream handler, with the table, the APNs key and APNs stubbed.
const send = vi.fn();
vi.mock("@aws-sdk/lib-dynamodb", async (orig) => {
  const actual: any = await orig();
  return { ...actual, DynamoDBDocumentClient: { from: () => ({ send }) } };
});
vi.mock("@aws-sdk/client-secrets-manager", async (orig) => {
  const actual: any = await orig();
  return { ...actual, SecretsManagerClient: class { send = async () => ({ SecretString: "{}" }); } };
});
const sendAlerts = vi.fn(async () => new Map());
vi.mock("../lambda/apns.ts", () => ({ sendAlerts }));
const { handler, dayIn, firstUpcoming, offerText, replyText, weekText, WEEK_WINDOW_MS } = await import("../lambda/push.ts");
const { marshall } = await import("@aws-sdk/util-dynamodb");

const record = (eventName: string, item: Record<string, unknown>) => ({
  eventName, dynamodb: { Keys: marshall({ PK: item.PK, SK: item.SK }), NewImage: marshall(item) },
});
const reply = { PK: "USER#ann", SK: "COMMENT#2026-10-20#2026-10-20T18:00:00.000Z#sam", owner: "ann", by: "sam", byName: "Sam", day: "2026-10-20", text: "Nice work" };

beforeEach(() => {
  send.mockReset();
  sendAlerts.mockClear();
  send.mockResolvedValue({ Items: [{ token: "t1", PK: "USER#ann", SK: "DEVICE#t1" }] });
});

describe("a coach's reply", () => {
  it("is pushed once, when it's written", async () => {
    await handler({ Records: [record("INSERT", reply)] } as never);
    expect(sendAlerts).toHaveBeenCalledTimes(1);
  });

  it("opens the day it's on (FIT-220's payload)", async () => {
    await handler({ Records: [record("INSERT", reply)] } as never);
    expect((sendAlerts.mock.calls[0] as unknown[]).slice(2)).toEqual([["t1"], expect.anything(), { kind: "reply", day: "2026-10-20" }]);
  });

  it("isn't pushed again when it's edited (FIT-200)", async () => {
    await handler({ Records: [record("MODIFY", { ...reply, text: "Nice work, go lighter next week" })] } as never);
    expect(sendAlerts).not.toHaveBeenCalled();
  });
});

describe("FIT-220: the coach updated your week", () => {
  // Wednesday 2026-10-21, 15:00 UTC: 11:00 in New York.
  const NOW = new Date("2026-10-21T15:00:00Z");
  const plan = (day: string, by?: string) => ({ PK: "USER#ann", SK: `SYNC#plan#${day}`, key: `plan#${day}`, updatedAt: NOW.toISOString(), deleted: false, body: "[]", ...(by ? { by } : {}) });
  let lastSent: string | undefined;

  beforeEach(() => {
    vi.useFakeTimers({ now: NOW, toFake: ["Date"] });
    lastSent = undefined;
    send.mockImplementation(async (command: any) => {
      const name = command.constructor.name, input = command.input;
      if (name === "QueryCommand") return { Items: [{ token: "t1", PK: "USER#ann", SK: "DEVICE#t1", tz: "America/New_York" }] };
      if (name === "GetCommand") return input.Key.SK === "COACH#sam" ? { Item: { coachName: "Sam" } } : {};
      if (name === "PutCommand") {
        // The window: a put succeeds only when the last push is older than the cutoff.
        if (lastSent && lastSent >= input.ExpressionAttributeValues[":cutoff"]) throw Object.assign(new Error("no"), { name: "ConditionalCheckFailedException" });
        lastSent = input.Item.sentAt;
        return {};
      }
      return {};
    });
  });
  afterEach(() => vi.useRealTimers());

  it("is one push for a week applied at once, opening its first upcoming day", async () => {
    await handler({ Records: ["2026-10-19", "2026-10-23", "2026-10-22", "2026-10-26"].map((d) => record("MODIFY", plan(d, "sam"))) } as never);
    expect(sendAlerts).toHaveBeenCalledTimes(1);
    expect((sendAlerts.mock.calls[0] as unknown[]).slice(2)).toEqual([["t1"],
      { title: "Sam updated your week", body: "See what changed, starting Thursday." }, { kind: "plan", day: "2026-10-22" }]);
  });

  it("is one push for several edits within the window, and another after it", async () => {
    await handler({ Records: [record("MODIFY", plan("2026-10-22", "sam"))] } as never);
    vi.setSystemTime(new Date(NOW.getTime() + 3 * 60_000));
    await handler({ Records: [record("MODIFY", plan("2026-10-23", "sam"))] } as never);
    expect(sendAlerts).toHaveBeenCalledTimes(1);
    vi.setSystemTime(new Date(NOW.getTime() + WEEK_WINDOW_MS + 60_000));
    await handler({ Records: [record("MODIFY", plan("2026-10-23", "sam"))] } as never);
    expect(sendAlerts).toHaveBeenCalledTimes(2);
  });

  it("isn't sent for the client's own edits, past days, or someone who isn't their coach", async () => {
    await handler({ Records: [record("MODIFY", plan("2026-10-22")), record("MODIFY", plan("2026-10-22", "ann"))] } as never);
    await handler({ Records: [record("MODIFY", plan("2026-10-20", "sam"))] } as never);
    await handler({ Records: [record("MODIFY", plan("2026-10-22", "eve"))] } as never);
    expect(sendAlerts).not.toHaveBeenCalled();
  });

  it("knows today in the client's time zone", () => {
    expect(dayIn(new Date("2026-10-22T02:00:00Z"), "America/New_York")).toBe("2026-10-21");
    expect(dayIn(new Date("2026-10-22T02:00:00Z"), "Europe/London")).toBe("2026-10-22");
    // Unknown: the earliest today anywhere, so a day that's still today somewhere counts as upcoming.
    expect(dayIn(new Date("2026-10-22T02:00:00Z"), undefined)).toBe("2026-10-21");
    expect(dayIn(new Date("2026-10-22T02:00:00Z"), "Not/AZone")).toBe("2026-10-21");
    expect(firstUpcoming(["2026-10-25", "2026-10-20", "2026-10-21"], "2026-10-21")).toBe("2026-10-21");
    expect(firstUpcoming(["2026-10-20"], "2026-10-21")).toBeUndefined();
    expect(weekText(null, "2026-10-21", "2026-10-21")).toEqual({ title: "Your coach updated your week", body: "Today's session changed. Take a look before you start." });
  });

  it("titles read with the coach's name and without one (FIT-227)", () => {
    expect(weekText("Sam", "2026-10-21", "2026-10-21").title).toBe("Sam updated your week");
    expect(offerText("Sam", 4, "").title).toBe("Sam sent you a 4-week program");
    expect(offerText(null, 4, "").title).toBe("Your coach sent you a 4-week program");
    expect(replyText("Sam", "2026-10-21", "Nice").title).toBe("Sam replied on Wednesday's session");
    expect(replyText(undefined, "2026-10-21", "Nice").title).toBe("Your coach replied on Wednesday's session");
  });
});
