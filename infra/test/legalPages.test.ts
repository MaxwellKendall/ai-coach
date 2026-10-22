import { describe, expect, it } from "vitest";
import { legalRoute, SUPPORT_EMAIL } from "../lambda/legalPages.ts";
import { route, type Site, type Store } from "../lambda/sharePages.ts";

const site: Site = { appName: "Barbrabell", origin: "https://example.com", appId: "TEAM.com.example.app" };

describe("privacy, terms and support (FIT-158)", () => {
  it("serves the three pages, each with the support email", () => {
    for (const path of ["/privacy", "/terms", "/support"]) {
      const page = legalRoute(path, site)!;
      expect(page.status).toBe(200);
      expect(page.body).toContain(`mailto:${SUPPORT_EMAIL}`);
    }
    expect(legalRoute("/w/bench", site)).toBeUndefined();
  });

  it("the policy says what's kept, that we host no AI, who sees it, how to delete it, and how long tokens last", () => {
    const body = legalRoute("/privacy", site)!.body;
    expect(body).toContain("DynamoDB");
    expect(body).toContain("We don't host an AI model");
    expect(body).toContain("only after you sign in");
    expect(body).toContain("Your coach,</b> only after you accept their invite");
    expect(body).toContain("Delete Account");
    expect(body).toContain("an access token that lasts 1 hour and a refresh token that lasts 90 days");
  });

  it("every page's footer links them", async () => {
    const body = (await route("/nope", {} as Store, site)).body;
    for (const path of ["/privacy", "/terms", "/support"]) expect(body).toContain(`href="${path}"`);
  });
});
