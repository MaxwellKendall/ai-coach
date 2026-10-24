import { addDays } from "./training.ts";

// FIT-210: do coaches stay? A coach's signup is their first real client link (or, with the plan and no clients yet,
// their account's first day). They're active at 30, 60 or 90 days when, in the week up to that day, a client logged a
// workout or they wrote a client's plan. Sample and demo clients (FIT-240, FIT-221) aren't real and don't count.
// scripts/coachStats.ts gathers the facts from the table; this works them out.

export const DAYS = [30, 60, 90] as const;
export const realClient = (uid: string) => !uid.startsWith("sample-") && !uid.startsWith("demo-");

export type ClientFacts = { uid: string; since: string; logged: string[]; coachWrote: string[] };
export type CoachFacts = { coach: string; signup: string; paid: boolean; clients: ClientFacts[] };
export type CoachRow = { coach: string; signup: string; paid: boolean; clients: number; loggingNow: number; active: Record<number, boolean | undefined> };

/** Whether any day in `days` falls in the 7 days up to `day`. */
const inWeekTo = (days: string[], day: string) => days.some((d) => d > addDays(day, -7) && d <= day);

export function coachRow(f: CoachFacts, today: string): CoachRow {
  const clients = f.clients.filter((c) => realClient(c.uid));
  const active: Record<number, boolean | undefined> = {};
  for (const n of DAYS) {
    const day = addDays(f.signup, n);
    active[n] = day > today ? undefined : clients.some((c) => inWeekTo(c.logged, day) || inWeekTo(c.coachWrote, day));
  }
  return { coach: f.coach, signup: f.signup, paid: f.paid, clients: clients.length, loggingNow: clients.filter((c) => inWeekTo(c.logged, today)).length, active };
}

/** Of the coaches old enough for each mark, how many were active at it. */
export function retention(rows: CoachRow[]) {
  return Object.fromEntries(DAYS.map((n) => {
    const due = rows.filter((r) => r.active[n] !== undefined);
    return [n, { due: due.length, active: due.filter((r) => r.active[n]).length }];
  })) as Record<number, { due: number; active: number }>;
}
