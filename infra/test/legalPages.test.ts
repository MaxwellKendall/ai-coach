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

  it("the policy says runs keep a GPS route and heart rate from Apple Health, which the coach sees and we never sell (FIT-224)", () => {
    const body = legalRoute("/privacy", site)!.body;
    expect(body).toContain("GPS route, which is your precise location");
    expect(body).toContain("reads from Apple Health");
    expect(body).toContain("runs (with their routes and heart rate)");
    expect(body).toContain("never for advertising or marketing, never sold");
  });

  it("the policy names the controller, the reasons, the rights and where data goes, for the GDPR (FIT-59)", () => {
    const body = legalRoute("/privacy", site)!.body;
    expect(body).toContain("its controller under the GDPR and the UK GDPR");
    expect(body).toContain("With your permission:</b> heart rate from Apple Health");
    expect(body).toContain("ask for a copy of your data");
    expect(body).toContain("complain to your local data protection authority");
    expect(body).toContain("include the EU Standard Contractual Clauses");
  });

  it("the pages the app opens don't link home, where the coach plan is sold (3.1.1(a), FIT-59)", async () => {
    for (const path of ["/privacy", "/terms", "/support"]) {
      const body = legalRoute(path, site)!.body;
      expect(body).toContain('<span class="brand">');
      expect(body).not.toContain('href="/"');
    }
    const claude = (await route("/claude", {} as Store, { ...site, mcpUrl: "https://example.com/mcp" })).body;
    expect(claude).not.toContain('href="/"');
    expect((await route("/nope", {} as Store, site)).body).toContain('<a href="/" class="brand">');
  });

  it("every page's footer links them", async () => {
    const body = (await route("/nope", {} as Store, site)).body;
    for (const path of ["/privacy", "/terms", "/support"]) expect(body).toContain(`href="${path}"`);
  });
});
