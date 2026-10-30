import { describe, expect, it } from "vitest";
import { compareRoute, indexed, rivals } from "../lambda/comparePages.ts";
import type { Site } from "../lambda/sharePages.ts";

const site: Site = { appName: "Barbrabell", origin: "https://example.com", appId: "TEAM.com.example.app" };

describe("comparison pages (FIT-244)", () => {
  it("the hub links every comparison", () => {
    const page = compareRoute("/compare", site)!;
    expect(page.status).toBe(200);
    for (const r of rivals) expect(page.body).toContain(`href="/compare/${r.slug}"`);
  });

  it("each page says where the other tool is better, and carries FAQ data", () => {
    for (const r of rivals) {
      expect(r.better.length).toBeGreaterThan(0);
      const body = compareRoute(`/compare/${r.slug}`, site)!.body;
      expect(body).toContain(`Where ${r.name.replace(/&/g, "&amp;")} is better`);
      expect(body).toContain('"@type":"FAQPage"');
    }
  });

  it("puts prices side by side where the vendor gives them", () => {
    const body = compareRoute("/compare/trainera", site)!.body;
    expect(body).toContain("<th>20 clients</th><td>Free</td><td>$49.99</td>");
    expect(body).toContain("At 20 clients, Barbrabell is free and Trainera is $49.99.");
  });

  it("an unknown comparison falls through", () => {
    expect(compareRoute("/compare/nope", site)).toBeUndefined();
    expect(compareRoute("/w/bench", site)).toBeUndefined();
  });

  it("robots.txt points at the sitemap, which lists every public page and no shared ones", () => {
    expect(compareRoute("/robots.txt", site)!.body).toContain("Sitemap: https://example.com/sitemap.xml");
    const map = compareRoute("/sitemap.xml", site)!.body;
    for (const p of indexed) expect(map).toContain(`<loc>https://example.com${p}</loc>`);
    expect(map).not.toMatch(/\/(w|s|p|join|c)\//);
  });

  it("llms.txt says what it does, what it doesn't, and links each comparison", () => {
    const body = compareRoute("/llms.txt", site)!.body;
    expect(body).toMatch(/^# Barbrabell/);
    expect(body).toContain("Not included:");
    expect(body).toContain("https://example.com/compare/truecoach");
  });
});

describe("the site's main address (FIT-244)", () => {
  const shared: Site = { ...site, origin: "https://share.example.com", home: "https://example.com" };

  it("points search engines at it, whichever host served the file", () => {
    expect(compareRoute("/robots.txt", shared)!.body).toContain("Sitemap: https://example.com/sitemap.xml");
    expect(compareRoute("/sitemap.xml", shared)!.body).not.toContain("share.example.com");
    expect(compareRoute("/llms.txt", shared)!.body).toContain("https://example.com/compare/truecoach");
  });

  it("is every page's canonical link", () => {
    expect(compareRoute("/compare/trainera", shared)!.body).toContain('<link rel="canonical" href="https://example.com/compare/trainera">');
  });
});
