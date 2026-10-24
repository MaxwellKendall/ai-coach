import { describe, expect, it } from "vitest";
import { homePath } from "./home";
import type { Unit } from "./sync";

const units = (...keys: string[]) => new Map(keys.map((key) => [key, { key, body: "[]", deleted: false } as unknown as Unit]));

describe("FIT-242: the dashboard opens on Clients", () => {
  it("for a coach, and for someone new", () => {
    expect(homePath(true, units("plan#2026-10-24"))).toBe("/clients");
    expect(homePath(false, units())).toBe("/clients");
    expect(homePath(false, undefined)).toBe("/clients");
  });

  it("on their own program for someone training themselves without the coach plan", () => {
    expect(homePath(false, units("profile", "plan#2026-10-24"))).toBe("/program");
    const gone = units("plan#2026-10-24");
    (gone.get("plan#2026-10-24") as { deleted: boolean }).deleted = true;
    expect(homePath(false, gone)).toBe("/clients");
  });
});
