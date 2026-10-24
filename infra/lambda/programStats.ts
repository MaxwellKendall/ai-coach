import type { PlanRow } from "./training.ts";

// FIT-209: is what Claude writes any good? For each day an agent's apply wrote, whether the session there now is still
// what it wrote, was edited after (the dashboard's corrections, the app, a later proposal), removed, or undone; whether
// it was for a client (a coach's) or the person's own; and whether it was then logged. apply saves what it wrote
// (MCP#written#day, kept 180 days); scripts/programStats.ts reads it back against the plan and log.

export type Written = { day: string; at: string; by: string; owner: string; fp: string; undone?: boolean };
export type Fate = "kept" | "edited" | "removed" | "undone";

/** A session's content, as a coach would see a change: each exercise, its targets and note, in order. */
export function fingerprint(rows: PlanRow[]) {
  return JSON.stringify(rows.filter((r) => r.kind === "workout").map((r) => [r.template, r.targets.map((t) => [t.metric, t.value]), r.note]));
}

export function fateOf(written: Written, plan: string | undefined): Fate {
  if (written.undone) return "undone";
  if (!plan) return "removed";
  return fingerprint(JSON.parse(plan) as PlanRow[]) === written.fp ? "kept" : "edited";
}

export type Tally = { written: number; forClients: number; kept: number; edited: number; removed: number; undone: number; logged: number };

export function tally(days: { written: Written; plan: string | undefined; logged: boolean }[]): Tally {
  const t: Tally = { written: 0, forClients: 0, kept: 0, edited: 0, removed: 0, undone: 0, logged: 0 };
  for (const d of days) {
    t.written++;
    if (d.written.by !== d.written.owner) t.forClients++;
    t[fateOf(d.written, d.plan)]++;
    if (d.logged) t.logged++;
  }
  return t;
}
