import { beforeEach, describe, expect, it, vi } from "vitest";

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
const { handler } = await import("../lambda/push.ts");
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

  it("isn't pushed again when it's edited (FIT-200)", async () => {
    await handler({ Records: [record("MODIFY", { ...reply, text: "Nice work, go lighter next week" })] } as never);
    expect(sendAlerts).not.toHaveBeenCalled();
  });
});
