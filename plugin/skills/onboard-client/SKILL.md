---
name: onboard-client
description: Bring a new client onto Barbrabell for a strength coach — make their invite, then set up their profile, goals, program and first two weeks once they've joined. Use when a coach says "invite a new client", "onboard Sam", "set up my new client", "I just signed someone", or a client they named isn't in their roster yet.
---

# Onboard a client

You're helping a strength coach take on a client, working through the Barbrabell tools. Keep it short, ask one thing at a time, and never apply a change until the coach says yes.

## 1. Invite them, if they haven't joined

`list_clients`. If the client isn't there yet:

1. `invite_client` and give the coach the link and the 6-character code, ready to paste into a text: the client opens the link on their iPhone, installs the Barbrabell app and allows the coach. The invite works once, for 14 days.
2. Say that once the client joins, the app asks them four quick questions (goals, equipment, a recent heavy set, schedule) that you'll be able to read, and to come back then. Stop here.

## 2. See what the client already said

`get_context` with `client`. Read what the app's questions saved: goals and dates, equipment, age and weight, starting sets, training days, minutes, injuries.

## 3. Fill the gaps with the coach

Ask the coach only for what's missing or doubtful, one topic at a time, and save each answer as it comes with `client`:

- Goals with a target and a date (`add_goal`): a lift max, reps in a row, body weight or a race time.
- Training days, minutes a session, equipment, injuries and anything the client won't do (`set_profile`).
- For each goal lift, where they are now: a 1RM or a recent heavy set, weight × reps (`set_profile` `starting_sets`, a 1RM is reps 1). No program or loads without these; if the coach doesn't know, suggest a light first week to find them.
- Their style if it isn't general strength (`set_profile` `style`).

The client's name is theirs to set in the app; don't ask the coach to change it.

## 4. The program and first weeks

Follow the **program-block** skill from its step 2: `set_program` to the goal date with phases, then `propose_week` from today to the end of next week, and apply when the coach agrees.

## 5. Wrap up

Tell the coach what the client will see on their phone and when (at the app's next sync), and that "Plan next week" or "Who needs me this week?" are the usual next asks.
