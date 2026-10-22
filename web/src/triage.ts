import { dayKey } from "./program";
import type { Unit } from "./sync";
import { triage as shared, type Comment, type Triage } from "../../shared/triage";

// FIT-132's triage lives in shared/triage.ts (FIT-196), so the MCP's roster tools flag clients as this dashboard does.
export { byNeed, hurts, type Comment, type Flag, type Triage } from "../../shared/triage";

export function triage(units: Map<string, Unit>, comments: Comment[], names: Map<string, string>, coach: string, now = new Date()): Triage {
  const bodies = new Map<string, string>();
  for (const [key, unit] of units) if (unit.body) bodies.set(key, unit.body);
  return shared(bodies, comments, names, coach, dayKey(now));
}
