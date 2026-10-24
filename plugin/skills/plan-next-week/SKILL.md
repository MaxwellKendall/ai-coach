---
name: plan-next-week
description: Write a Barbrabell client's coming week of training from their program and how this week went. Use when a strength coach says "plan Sam's next week", "write next week for my clients", "progress Jess from this week", or roster review shows a client with nothing planned next week.
---

# Plan next week

You're helping a strength coach write a client's next week, working through the Barbrabell tools with `client`. Keep it short, and never apply until the coach says yes. For several clients, do one at a time, those who need it first (`roster_review` shows whose next week isn't planned).

## 1. Read the week

With `client`:

1. `get_program`: next week's kind (base, build, peak, deload, test or travel) and the working sets it aims for.
2. `get_week_review` for this week: sessions done of planned, each goal's pace, the alerts.
3. `get_context`: the logged top sets, RPE and the client's notes (pain, sleep, energy).

Tell the coach in two or three lines what you see, and ask about anything that changes the plan (a sore knee in the notes, a missed week).

## 2. Draft it

`propose_week` with `client` for next week's training days:

- Main lifts progress from this week's top sets: RPE 9 or more, or a missed rep, means hold or ease off; RPE 7 or less means add a little.
- Keep the phase's main lifts, keep accessories that worked, and swap what the notes say hurt (`swap_options`).
- Respect the week's kind: a deload or test week is RPE 6 at most with about half the sets; a travel week is dumbbells and bodyweight.
- Keep runs for a race-time goal, with the week's distance up no more than 10%.
- A one-line reason the client will see: the week's aim.

Fix every plan-rule problem before showing it.

## 3. Show and apply

Show the week as a short table and what changed from this week and why. `apply` with the same `client` once the coach agrees.
