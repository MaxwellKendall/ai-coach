import type { Unit } from "./sync";

/**
 * FIT-242: where the dashboard opens. Coaches are the customer, so it's Clients (for someone new, the coach start: the
 * sample client and Start the coach plan, FIT-240). Only someone without the coach plan who trains with a program of
 * their own opens on it.
 */
export function homePath(paid: boolean, units: Map<string, Unit> | undefined) {
  if (paid || !units) return "/clients";
  return [...units.values()].some((u) => u.key.startsWith("plan#") && !u.deleted) ? "/program" : "/clients";
}
