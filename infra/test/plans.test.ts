import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { PLANS, TRIAL_DAYS } from "../../shared/plans.ts";
import { legalRoute } from "../lambda/legalPages.ts";

type Product = { productId: string; priceUSD: string; introductoryOffer?: { mode: string; duration: string } };
const subscriptions = JSON.parse(readFileSync(new URL("../../appstore/subscriptions.json", import.meta.url), "utf8")) as {
  groups: { products: Product[] }[];
};
const product = (id: string) => subscriptions.groups.flatMap((g) => g.products).find((p) => p.productId === id)!;
const price = (id: string) => "$" + product(id).priceUSD;
const DURATION_DAYS: Record<string, number> = { THREE_DAYS: 3, ONE_WEEK: 7, TWO_WEEKS: 14, ONE_MONTH: 30 };

describe("the tiers the site describes (FIT-437)", () => {
  it("prices match the App Store products", () => {
    expect(PLANS.lifter.month).toBe(price("com.maxwellkendall.aicoach.pro.monthly"));
    expect(PLANS.lifter.year).toBe(price("com.maxwellkendall.aicoach.pro.yearly"));
    expect(PLANS.coach.month).toBe(price("com.maxwellkendall.aicoach.coach.monthly"));
    expect(PLANS.coach.year).toBe(price("com.maxwellkendall.aicoach.coach.yearly"));
  });

  // The connector's trial imports TRIAL_DAYS too (infra/lambda/mcp.ts).
  it("one trial length: the copy's and the App Store's free trial", () => {
    for (const id of ["com.maxwellkendall.aicoach.pro.monthly", "com.maxwellkendall.aicoach.pro.yearly"]) {
      const offer = product(id).introductoryOffer!;
      expect(offer.mode).toBe("FREE_TRIAL");
      expect(DURATION_DAYS[offer.duration]).toBe(TRIAL_DAYS);
    }
  });

  it("the terms price both plans, say they're sold in the app and on the web, and where each is cancelled", () => {
    const body = legalRoute("/terms", { appName: "Barbrabell", origin: "https://example.com", appId: "T.x" })!.body;
    expect(body).toContain("$5.99 a month or $39.99 a year");
    expect(body).toContain("$19.99 a month or $199 a year");
    expect(body).toContain(`${TRIAL_DAYS}-day free trial`);
    expect(body).toContain("App Store subscription");
    expect(body).toContain("Settings › your name › Subscriptions");
    expect(body).toContain("from Billing on the dashboard");
  });
});
