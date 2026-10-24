---
name: roster-review
description: A strength coach's weekly check across all their Barbrabell clients — who needs them, unanswered session notes, pain, missed or too-hard sessions, stalled lifts, and whose next week isn't written. Use when a coach asks "who needs me this week?", "how are my clients doing?", "review my roster", "any messages from clients?", or starts their weekly check-in.
---

# Roster review

You're helping a strength coach see who needs them, working through the Barbrabell tools. Keep it short, and post nothing to a client until the coach approves the words.

## 1. The roster

`roster_review` (or `list_clients` midweek). Summarize, those who need the coach first:

- **Needs you**: pain or an unanswered note, RPE 9+ on a main lift, a main lift stalled 3 weeks, nothing logged in 2 weeks, missed sessions.
- **On track**: one line each, with sessions done of planned and anything worth celebrating.
- **Next week not planned**: who.

Use the review's facts and numbers; don't invent any.

## 2. Go through who needs the coach

One client at a time, with `client`:

1. `get_context` (or `get_day` for the day in question) for the session and the client's note.
2. Suggest what to do: a reply, a change to an upcoming session (`propose_session`, or `swap_options` around pain), or nothing.
3. For a reply, draft it in the coach's voice, two or three sentences, and post it with `add_note` with `client` and the session's `date` only once the coach approves or edits it. It shows in the client's app as the coach's.
4. Apply a session change only once the coach agrees.

## 3. Next weeks

Offer to write next week for each client who has none, using the **plan-next-week** skill, one client at a time.
