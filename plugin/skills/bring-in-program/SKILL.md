---
name: bring-in-program
description: Turn a strength coach's existing client program — a spreadsheet, CSV, Google Sheet, PDF, doc or screenshot — into that client's program in Barbrabell, in the coach's own numbers (percentages, RPE or RIR, supersets, tempo). Use when a coach pastes or attaches a program, or says "load this program for Sam", "import my spreadsheet", "move my clients over from Excel/TrueCoach/Trainerize".
---

# Bring in a program

You're helping a coach move a client's existing program into Barbrabell, working through its tools with `client`. Keep it short, ask about anything unclear rather than guessing, and never apply until the coach says yes.

## 1. The program and the client

If they haven't attached or pasted it, ask for it. `get_context` with `client` (use `list_clients` if the name is unclear) for the client's profile, goals, maxes and what's planned.

## 2. Read it

Work out its weeks and days, and each exercise's sets, reps, load (a weight, % of max, RPE or RIR), supersets, and notes on tempo, rest or rep ranges. Note its length and how often it deloads. Ask about anything you can't read.

## 3. The maxes it's based on

For each lift loaded by percent, and each main lift with a weight, save the max the coach gives with `set_profile` `starting_sets` (a 1RM is reps 1). Add any equipment it needs to `set_profile` `equipment`.

## 4. The program

`set_program` with `client`: `start` on its first week, `weeks` its length plus one (the last week is a light test week), and `deload_every` its deload spacing (12 when it has none).

## 5. The days

`propose_week` with `client`, up to 6 weeks a call, in the coach's own numbers:

- `percent_1rm` for percentages, `rpe` for RPE (10 minus RIR).
- The same `superset` number for A1/A2.
- `reps` the low end of a range, with the range in `note`.
- `note` for tempo, rest or AMRAP.

Map a name with `find_exercises` when unsure, and `create_exercise` one the catalog lacks (a coach's named variation).

## 6. Check and apply

Check the names it matched loosely and the weights it worked out, and fix any plan-rule problems. Show the coach the weeks in a few lines, flagging anything you changed or guessed. `apply` with the same `client` when they agree; it's on the client's phone at its next sync.
