import { describe, expect, it, vi } from "vitest";

// FIT-189: the Stripe secret, read from Secrets Manager (stubbed).
const send = vi.fn();
vi.mock("@aws-sdk/client-secrets-manager", async (orig) => {
  const actual: any = await orig();
  return { ...actual, SecretsManagerClient: class { send = send; } };
});
const { stripeConfig } = await import("../lambda/gifts.ts");

describe("the Stripe secret", () => {
  it("is read again until it has the webhook secret, then kept", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    send.mockRejectedValueOnce(Object.assign(new Error("missing"), { name: "ResourceNotFoundException" }));
    expect(await stripeConfig()).toBeUndefined();
    send.mockResolvedValueOnce({ SecretString: JSON.stringify({ secretKey: "sk_test_1" }) });
    expect(await stripeConfig()).toEqual({ secretKey: "sk_test_1" });
    send.mockResolvedValueOnce({ SecretString: JSON.stringify({ secretKey: "sk_test_1", webhookSecret: "whsec_1" }) });
    expect(await stripeConfig()).toEqual({ secretKey: "sk_test_1", webhookSecret: "whsec_1" });
    expect(await stripeConfig()).toEqual({ secretKey: "sk_test_1", webhookSecret: "whsec_1" });
    expect(send).toHaveBeenCalledTimes(3);
    error.mockRestore();
  });

});
