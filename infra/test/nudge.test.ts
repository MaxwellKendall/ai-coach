import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// FIT-220's evening nudge, with the table and APNs stubbed.
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
const { localHour, missed, nudge, NUDGE_HOUR } = await import("../lambda/nudge.ts");

const workout = (slot: string) => ({ kind: "workout", slot, template: "back-squat" });
const PLAN = JSON.stringify([workout("Lower A"), workout("Lower A")]);

describe("the nudge's rules", () => {
  it("is for a planned session with nothing logged", () => {
    expect(missed(PLAN, undefined)).toBe("Lower A");
    expect(missed(PLAN, JSON.stringify([{ kind: "meal" }]))).toBe("Lower A");
  });

  it("is never on a rest day, nor once a session is logged", () => {
    expect(missed(undefined, undefined)).toBeUndefined();
    expect(missed(JSON.stringify([{ kind: "meal" }]), undefined)).toBeUndefined();
    expect(missed(PLAN, JSON.stringify([{ kind: "workout", template: "back-squat" }]))).toBeUndefined();
  });

  it("is at 7 pm where the client is", () => {
    expect(NUDGE_HOUR).toBe(19);
    expect(localHour(new Date("2026-10-21T23:00:00Z"), "America/New_York")).toBe(19);
    expect(localHour(new Date("2026-10-21T23:00:00Z"), "Not/AZone")).toBeUndefined();
  });
});

describe("the hourly run", () => {
  // 19:00 in New York on Wednesday 2026-10-21.
  const NOW = new Date("2026-10-21T23:00:00Z");
  let state: { coached: boolean; plan?: string; log?: string; nudged: Set<string>; devices: Record<string, unknown>[] };

  beforeEach(() => {
    sendAlerts.mockClear();
    state = {
      coached: true, plan: PLAN, nudged: new Set(),
      devices: [{ PK: "USER#ann", SK: "DEVICE#t1", token: "t1", tz: "America/New_York" }, { PK: "USER#ann", SK: "DEVICE#t2", token: "t2", tz: "America/New_York" }],
    };
    send.mockImplementation(async (command: any) => {
      const name = command.constructor.name, input = command.input;
      if (name === "QueryCommand" && input.IndexName === "GSI1") return { Items: state.devices };
      if (name === "QueryCommand") return { Items: state.coached ? [{ SK: "COACH#sam" }] : [] };
      if (name === "GetCommand") {
        const body = input.Key.SK === "SYNC#plan#2026-10-21" ? state.plan : input.Key.SK === "SYNC#log#2026-10-21" ? state.log : undefined;
        return body ? { Item: { body } } : {};
      }
      if (name === "PutCommand") {
        if (state.nudged.has(input.Item.SK)) throw Object.assign(new Error("no"), { name: "ConditionalCheckFailedException" });
        state.nudged.add(input.Item.SK);
      }
      return {};
    });
  });
  afterEach(() => send.mockReset());

  it("nudges each of the client's devices once, opening today", async () => {
    await nudge(NOW);
    expect(sendAlerts).toHaveBeenCalledTimes(1);
    expect((sendAlerts.mock.calls[0] as unknown[]).slice(2)).toEqual([["t1", "t2"],
      { title: "Log today's session?", body: "Lower A is planned for today. Your coach sees it once it's logged." }, { kind: "nudge", day: "2026-10-21" }]);
  });

  it("is at most one a day", async () => {
    await nudge(NOW);
    await nudge(NOW);
    expect(sendAlerts).toHaveBeenCalledTimes(1);
  });

  it("waits for the evening, and leaves alone someone without a coach or who logged", async () => {
    await nudge(new Date("2026-10-21T22:00:00Z"));
    state.coached = false;
    await nudge(NOW);
    state.coached = true;
    state.log = JSON.stringify([{ kind: "workout" }]);
    await nudge(NOW);
    expect(sendAlerts).not.toHaveBeenCalled();
  });
});
