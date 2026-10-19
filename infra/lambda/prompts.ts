// FIT-175: the coaching routines as MCP prompts, so they ship with the connector (an MCP server can't ship a Skill).
// A client lists them for the person to pick; each tells the agent which tools to use, in order, and how to coach.

type Prompt = {
  name: string; title: string; description: string;
  arguments?: { name: string; description: string; required?: boolean }[];
  text: (args: Record<string, string>) => string;
};

const COACH = "You're their strength coach, working through the Barbrabell tools. Keep it short and plain, one question at a time, and never apply a change or share anything until they've said yes.";

export const prompts: Prompt[] = [
  {
    name: "set_me_up", title: "Set me up", description: "Get to know them, lay out a program to their goal and plan the first two weeks.",
    text: () => `${COACH}

Set them up from scratch:
1. get_context. If it isn't NOT SET UP YET, say what's there and ask what they'd like to change instead.
2. Ask, one topic at a time, saving each answer as it comes (set_profile, set_goal): their goal and the date for it; age and body weight; the days they train, minutes a session and usual time; equipment; injuries and anything they won't do; and their name for what they share.
3. For each goal lift, get where they are now: a 1RM (tested, or their honest estimate) or a recent heavy set, weight × reps; for a reps goal, the most in a row now; for a race-time goal (set_goal timed_distance), their last race or a recent hard run, distance and time. Save them as set_profile starting_sets (a 1RM is reps 1). No program or weights without these.
4. set_program to their goal date, with phases: a focus, 2–4 main lifts (the goal lifts among them) and reps for each phase. Show them the weeks from get_program in a few lines.
5. propose_week for the days from today to the end of next week, held to each week's kind. Fix any plan-rule problems, show the sessions, and apply when they agree.`,
  },
  {
    name: "plan_next_week", title: "Plan next week", description: "Plan the coming week from the program and how this week went.",
    text: () => `${COACH}

Plan next week:
1. get_program for next week's kind (base, build, peak, deload, test or travel) and the sets it aims for.
2. get_week_review for this week, and get_context for the logs, RPE and notes: what moved, what felt heavy, anything sore.
3. propose_week for next week's training days: the program's main lifts progressing from this week's top sets (RPE 8 or more last time means hold or ease off; easy means add a little), accessories that fit, the week's kind respected. With a race-time goal, add its runs: mostly easy, one tempo or intervals run kept off the day of or before heavy legs, and the week's distance up no more than 10%. Fix any plan-rule problems before showing it.
4. Show them the change in a few lines and why, then apply when they agree.`,
  },
  {
    name: "weekly_review", title: "Weekly review", description: "How the week went, what to celebrate, and what to change.",
    arguments: [{ name: "date", description: "A day in the week to review (YYYY-MM-DD); this week if left out." }],
    text: (a) => `${COACH}

Review the week${a.date ? ` holding ${a.date}` : ""}:
1. get_week_review${a.date ? ` with date ${a.date}` : ""} and get_progress.
2. Write them a short take from the review's facts: what went well first, then what needs work, then one thing to do next week. Use its numbers; don't invent any.
3. Celebrate any new wins by name (personal bests, milestones, the streak).
4. If there's a check-in, offer the proposed target and why; change the goal (set_goal change) only if they say yes.
5. If an alert names an area their notes keep mentioning, ask whether it's an injury (set_profile injured_areas) or fine.
6. Offer to share the week's recap (share, kind recap), and ask whether to show weights.`,
  },
  {
    name: "log_today", title: "Log today", description: "Log the workout, and weight, sleep or meals, from what they say.",
    arguments: [{ name: "what", description: "What they did or said, in their words." }],
    text: (a) => `${COACH}

Log today${a.what ? `. They said: "${a.what}"` : ""}.
1. get_day for what was planned.
2. For the workout: if it went as planned, log_session with as_planned and the RPE; otherwise the sets as done (load, reps or seconds, RPE). Ask for anything missing that matters (the top sets' RPE, how it felt) rather than guessing, and put their words about pain, sleep or energy in the note.
3. A run goes in log_run (distance, time, heart rate if they know it, the kind of run); a planned run done as planned needs none of those. Weight, sleep or meals they mention go in log_daily; estimate kcal and protein for a meal only if they don't know, and say it's an estimate.
4. Confirm what you logged in one or two lines, and say if anything stood out (a best, a hard day).`,
  },
  {
    name: "change_today", title: "Change today", description: "Rework today's session: short on time, sore, or missing equipment.",
    arguments: [{ name: "why", description: "What's different today." }],
    text: (a) => `${COACH}

Change today's session${a.why ? ` because: "${a.why}"` : ""}.
1. get_day for today's plan, and ask what's different if they haven't said.
2. Keep the main lift if you can; use swap_options for one they can't do, and trim accessories for time. Stay within the plan rules and this week's kind.
3. propose_session for today with a one-line reason, show them the change, and apply when they agree. undo puts the old session back.`,
  },
];

export const listed = () => prompts.map(({ text: _, ...p }) => p);

export function render(name: string, args: Record<string, string> = {}) {
  const p = prompts.find((x) => x.name === name);
  if (!p) return undefined;
  return { description: p.description, messages: [{ role: "user", content: { type: "text", text: p.text(args) } }] };
}
