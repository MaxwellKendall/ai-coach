---
name: program-block
description: Write a multi-week training block or program for one of a strength coach's Barbrabell clients — lay out the weeks, phases and deloads, then plan the first weeks' sessions. Use when a coach asks to "program a 4-week block for Sam", "start a new block", "write Jess a 12-week program to her meet", "build a peaking phase", or to copy one client's block to another.
---

# Program a block

You're helping a strength coach write a client's program, working through the Barbrabell tools with `client`. The coach decides; you draft. Keep it short, and never apply until the coach says yes.

## 1. Know the client

`get_context` with `client` (use `list_clients` if the name is unclear). Note the goals and dates, schedule, minutes, equipment, injuries, never list, estimated maxes and the last few weeks' RPE and notes. `get_program` for any program already running.

If a goal lift has no max or starting set, ask the coach for one (`set_profile` `starting_sets`) before writing loads.

## 2. Agree the shape

Propose in a few lines, and adjust to what the coach says:

- Length: to the goal date, or the weeks the coach asks for.
- Phases (base, build, peak): each one's focus, its 2–4 main lifts with the goal lifts among them, main reps and accessory reps.
- Deload spacing, and any trips the coach mentions.

Then `set_program` with `client`. The last week is a light test week, and deload and travel weeks are light too; code lays them out. Show the weeks from `get_program` in a few lines.

## 3. Write the first weeks

`propose_week` with `client` for the first one or two weeks (up to 6 weeks a call if the coach wants the whole block now):

- Only the client's training days, each fitting their minutes.
- Main lifts loaded from their maxes: `percent_1rm` or `weight_lb`, with a target `rpe`; progress week to week inside each phase.
- Accessories that fit the phase, their equipment and injuries. Use `find_exercises` to map a name, `swap_options` around an injury, and `create_exercise` only for a variation the catalog lacks.
- Supersets share a number; put cues (tempo, rest, a rep range, AMRAP) in `note`.
- A race-time goal gets its runs too: mostly easy, one tempo or intervals day kept off the day of or before heavy legs.

Fix every plan-rule problem it reports, and check the names it matched loosely and the weights it worked out from percentages.

## 4. Show and apply

Show the coach each week as a short table (day, exercises, sets × reps @ load or RPE) and the reason line the client will see. `apply` with the same `client` once they agree; it's on the client's phone at its next sync.

## Copying a block from another client

`get_day` with the first client and `to` to read the block, then `propose_week` for the second client with loads from the second client's own maxes. Ask for a starting set if they have none.
