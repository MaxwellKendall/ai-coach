---
name: business-model
description: Read Barbrabell's business model and distribution plan from Linear before answering or deciding anything about who pays, pricing, revenue, the coach and athlete roles, positioning and pitch, market size, competitors, costs, go-to-market, distribution (Kickoff, coach outreach and signals, Claude/ChatGPT directory and MCP registry listings, self-serve coach onboarding, the New Year's launch timeline), or whether a feature fits the strategy. Use it for strategy questions, iterating on either plan, landing-page, listing or App Store copy, Stripe/pricing work, and scoping calls that hinge on the business.
---

# Business model and distribution

**[Business model v2: free tools, paid intelligence and reach](https://linear.app/custom-voice-app/document/business-model-v2-free-tools-paid-intelligence-and-reach-a0ad450abe02)** (`2b642c59-17ea-480b-81c1-a8f3cb76c4bf`, approved 2026-10-29) is the business model. Coaching and the athlete app are free with no client cap; Pro is referrals plus the exhaustive coach MCP; the paid consumer app is discarded. Read it first. The two docs below carry a banner saying where v2 overrides them; their competitor research, interview questions and distribution channels still apply.

| Doc | Covers | ID |
|---|---|---|
| [Business model v2](https://linear.app/custom-voice-app/document/business-model-v2-free-tools-paid-intelligence-and-reach-a0ad450abe02) | The model now: free vs Pro, pitch, pricing, checkpoint, gaps | `2b642c59-17ea-480b-81c1-a8f3cb76c4bf` |
| [Barbrabell: Coach-First Business Model](https://linear.app/custom-voice-app/document/barbrabell-coach-first-business-model-bf0cd2c8a646) | Vision, roles, pitch, revenue, costs, market, competitors, build plan | `21803109-fe0a-42dd-87d2-d07ded11aa68` |
| [Distribution engine: Coaches using Barbrabell](https://linear.app/custom-voice-app/document/distribution-engine-coaches-using-barbrabell-6fc6334a2c0f) | Kickoff: coach signal engine, agent-channel listings, automated onboarding, metrics, requirements, timeline to Jan 1 | `f6a769e0-e455-452a-b734-20c7e772d90d` |

## Steps

1. Fetch the doc(s) the question touches with the Linear `get_document` tool. Read both when the question spans them (pricing, pitch, the checkpoint, competitors, onboarding) or when editing either one. Don't answer from memory or from this file: the docs change.
2. If an ID no longer resolves, search with `list_documents` by title ("business model" or "distribution") and tell the user the link moved. The business model sits in project `P-FIT-12`; the distribution doc sits on the Fitness Planner team, not the project.
3. If Linear tools aren't available, stop and say so (CLAUDE.md §1).
4. Ground the answer in the docs and cite the doc and section you used. Where the two docs disagree with each other, or the code, the active milestone or a recent decision disagrees with them, say so instead of picking one silently.
5. If a decision changes either plan, propose the edit and make it only once the user agrees. When an edit changes something both docs state (price, pitch, checkpoint, competitors), update both.
