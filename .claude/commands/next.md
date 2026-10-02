---
description: Pick up the next unblocked Linear issue for the AI Coach App and build it end to end
---

1. List open issues in Linear project `P-FIT-12` for the current milestone (lowest-numbered milestone with open issues). Pick the highest-priority issue whose blockers are all Done, following the build order in CLAUDE.md §9. If $ARGUMENTS names an issue (e.g. FIT-6), use that one instead.
2. Read the issue, its parent, its sub-issues and any related issues. Move it to In Progress.
3. Read the parts of the sibling repos (CLAUDE.md §6) that the issue references.
4. Build the smallest version that meets the issue's "done when". Write unit tests for all deterministic logic.
5. `xcodegen generate`, then build and test on the iPhone 17 Pro simulator. For UI changes, launch the app and screenshot it to verify.
6. Commit to `main` with the `FIT-N:` prefix.
7. Comment on the Linear issue: what shipped, how it was verified, anything deferred (as new Linear issues, linked). Move it to Done.
8. Report back in 3–5 lines, then continue with the next unblocked issue unless the user said to stop.
