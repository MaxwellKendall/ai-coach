import { addDays } from "./training.ts";

// FIT-210: do coaches stay? A coach's signup is their first real client link (or, with the plan and no clients yet,
// their account's first day). They're active at 30, 60 or 90 days when, in the week up to that day, a client logged a
// workout or they wrote a client's plan. Sample and demo clients (FIT-240, FIT-221) aren't real and don't count.
// scripts/coachStats.ts gathers the facts from the table; this works them out.

export const DAYS = [30, 60, 90] as const;
export const realClient = (uid: string) => !uid.startsWith("sample-") && !uid.startsWith("demo-");

export type ClientFacts = { uid: string; since: string; logged: string[]; coachWrote: string[] };
/** FIT-308: `invited`, an invite out now (one used becomes a client); `imported`, a program imported on the dashboard. */
export type CoachFacts = { coach: string; signup: string; paid: boolean; clients: ClientFacts[]; invited?: boolean; imported?: boolean };
export type CoachRow = {
  coach: string; signup: string; paid: boolean; clients: number; loggingNow: number; active: Record<number, boolean | undefined>;
  /** FIT-308: how far they got: invited a client, one accepted, imported a program, wrote a client's week. */
  steps: { invited: boolean; accepted: boolean; imported: boolean; planned: boolean };
  /** Clients four weeks in, and those still logging in the week up to it. */
  fourWeeks: { due: number; logging: number };
};

/** Business model v2's "Goal and checkpoint": an active coach has 5 or more clients logging in the last 7 days. */
export const ACTIVE_CLIENTS = 5;
export const TARGETS = { activeCoaches: 10, proCoaches: 3 };

/** Whether any day in `days` falls in the 7 days up to `day`. */
const inWeekTo = (days: string[], day: string) => days.some((d) => d > addDays(day, -7) && d <= day);

export function coachRow(f: CoachFacts, today: string): CoachRow {
  const clients = f.clients.filter((c) => realClient(c.uid));
  const active: Record<number, boolean | undefined> = {};
  for (const n of DAYS) {
    const day = addDays(f.signup, n);
    active[n] = day > today ? undefined : clients.some((c) => inWeekTo(c.logged, day) || inWeekTo(c.coachWrote, day));
  }
  const four = clients.filter((c) => addDays(c.since, 28) <= today);
  return {
    coach: f.coach, signup: f.signup, paid: f.paid, clients: clients.length, loggingNow: clients.filter((c) => inWeekTo(c.logged, today)).length, active,
    steps: { invited: !!f.invited || clients.length > 0, accepted: clients.length > 0, imported: !!f.imported, planned: clients.some((c) => c.coachWrote.length > 0) },
    fourWeeks: { due: four.length, logging: four.filter((c) => inWeekTo(c.logged, addDays(c.since, 28))).length },
  };
}

/** FIT-308: the Dec 31 checkpoint over every coach row, and lifters on Pro. */
export function checkpoint(rows: CoachRow[], liftersOnPro: number) {
  const active = rows.filter((r) => r.loggingNow >= ACTIVE_CLIENTS);
  const count = (step: keyof CoachRow["steps"]) => rows.filter((r) => r.steps[step]).length;
  return {
    coaches: rows.length,
    active: active.length, activeFree: active.filter((r) => !r.paid).length,
    proCoaches: rows.filter((r) => r.paid).length, liftersOnPro,
    steps: { invited: count("invited"), accepted: count("accepted"), imported: count("imported"), planned: count("planned") },
    fourWeeks: rows.reduce((sum, r) => ({ due: sum.due + r.fourWeeks.due, logging: sum.logging + r.fourWeeks.logging }), { due: 0, logging: 0 }),
  };
}

/** Of the coaches old enough for each mark, how many were active at it. */
export function retention(rows: CoachRow[]) {
  return Object.fromEntries(DAYS.map((n) => {
    const due = rows.filter((r) => r.active[n] !== undefined);
    return [n, { due: due.length, active: due.filter((r) => r.active[n]).length }];
  })) as Record<number, { due: number; active: number }>;
}
