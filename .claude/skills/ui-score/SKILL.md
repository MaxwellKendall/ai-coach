---
name: ui-score
description: Score the iOS app's UI from 0 to 100 against the Appllama app design skill's laws, adapted to SwiftUI and App/Theme.swift (FIT-364). Use when asked for the UI score, to check a UI change didn't lower it, or to raise it ("get the score to 90"). The automated 60 points come from score.py reading the Swift; the other 40 from a simulator pass over the key screens in light, dark and accessibility text sizes, recorded in sim.json.
---

# UI score

One number for how close the app is to the bar in `appllama-app-design-skill`: native fidelity, one design
system, accessibility, full state cycles, and the simulator loop. Run from the repo root.

```bash
python3 .claude/skills/ui-score/score.py            # the score and each part
python3 .claude/skills/ui-score/score.py --findings # every automated finding as check<TAB>file:line
```

## The rubric

**Automated, 60 points** (`score.py`). Each check is worth its points times the share of view files that pass it.

| Check | Pts | Passes when |
|---|---|---|
| `color-tokens` | 12 | Colours come from Theme's tokens (`Color.ink`, `.fill`, `.surface`, `.good`, `.warn`…), the plate (`Plate.current`, `.tint`) or semantic system colours. `.red` (destructive, errors), `.black`/`.white` (shadows, text on photos) are fine. A new colour is a token in Theme.swift with light and dark values. |
| `dynamic-type` | 14 | No `.system(size:)`: text styles, or `Font.display(size, weight:, relativeTo:)`, which scales. |
| `radius-scale` | 6 | Literal corner radii are 0, 8, 12, 18 or 24 (cards 24, rows and buttons 18, chips and inputs 12, small marks 8); pills are `Capsule`. No deprecated `.cornerRadius()`. |
| `icon-labels` | 8 | An icon-only `Button` has `.accessibilityLabel`, or is a `Label`. |
| `empty-states` | 8 | A view that loops over a `@Query` handles it being empty. |
| `modern-api` | 6 | No `NavigationView`, `.foregroundColor`, `.navigationBarTitle`, `.actionSheet`, `UIScreen.main`, `Text + Text`, or `.animation(x)` without `value:`. |
| `reduce-motion` | 6 | A file with a moving, sliding, scaling or looping transition reads `accessibilityReduceMotion` and falls back to a fade. |

Exemptions: `// ui-score: allow <check>: why` on the line or the one above, or `// ui-score: allow-file <check>: why`
for a whole file. Only for a reason the rule didn't foresee and that a reviewer would accept: an image rendered at a
fixed size for sharing, a brand's required colours (Sign in with Google), a glyph sized to a fixed frame. Never to
move the number. The score prints how many are exempt.

**Simulator, 40 points** (`sim.json`, written by the pass below).

| Item | Pts | Passes when |
|---|---|---|
| `<screen>-light`, `<screen>-dark`, `<screen>-xl` for `today`, `program`, `progress`, `you`, `welcome` | 2 each, 30 | The screenshot shows nothing clipped, overlapping or cut off by accident ("…" on a name that should wrap), the primary action whole and reachable, every text readable against its background, content clear of the Dynamic Island and home indicator, no blank or broken area. `xl` is `accessibility-extra-large`. Half points (1) for one minor flaw; 0 for more. |
| `taps-to-log` | 5 | Taps from launching on Today, with a planned workout, to one set saved: 2 or fewer 5, 3 is 4, 4 is 2, more 0. |
| `sheet-keyboard` | 5 | In a sheet with a text field (a log's note, an exercise search): with the keyboard up, the focused field and the sheet's Done/Cancel stay visible, and it dismisses cleanly. |

**Hard fail** (`"hard_fail": true` on the item): a crash, a dead end, a primary action you can't reach, text you
can't read. Any hard fail caps the score at 79, whatever else passes.

Grade strictly. Score what the screenshot shows, at full size, as a reviewer who wants to find the flaw would, not
what the code was meant to do.

## The simulator pass

The booted **iPhone 17 Pro** with the author's data installed is the device. Build and install the AICoach target,
then for each mode:

```bash
xcodegen generate
xcodebuild -scheme AICoach -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath <scratch>/dd build -quiet
xcrun simctl install booted <scratch>/dd/Build/Products/Debug-iphonesimulator/AICoach.app
xcrun simctl ui booted appearance light            # or dark
xcrun simctl ui booted content_size large           # or accessibility-extra-large for xl
xcrun simctl terminate booted com.maxwellkendall.aicoach; xcrun simctl launch booted com.maxwellkendall.aicoach
```

- `today`, `program`, `progress`: the three tabs. `you`: the person button at Today's top right. `welcome`: launch
  with `-welcome YES` (`xcrun simctl launch booted com.maxwellkendall.aicoach -welcome YES`).
- Screenshot each with the iOS Simulator tool (or `xcrun simctl io booted screenshot <scratch>/<id>.png`), open
  the image and look at it. Scroll a long screen and judge what's below the fold too.
- Put the device back afterwards: `appearance light`, `content_size large`.

Write `.claude/skills/ui-score/sim.json`:

```json
{"date": "2026-11-11", "commit": "<short sha>", "items": [
  {"id": "today-light", "max": 2, "points": 2, "note": "clean"},
  {"id": "today-xl", "max": 2, "points": 1, "note": "set row's weight wraps under the reps"}
]}
```

Every item is listed, with a note that says what failed. A rerun replaces the file.

## Per screen (FIT-367)

`score.py --screens` scores each screen in `screens.json` on its own, out of 100: the same automated 60 over only
that screen's view files, plus 40 for its simulator items. Each screen has `light`, `dark` and `xl` (2 points each,
graded as above) and `design` (4 points): judged against the design skill's laws, one primary action, native
patterns (toolbar buttons, large titles, standard sheets with Cancel and the action in the bar), progressive
disclosure, no duplicate paths to the same thing, nothing that reads as clutter above the content. A row of text
buttons over the screen's content is a design 0.

Screens cover the roles too: a coached client (`-coach Sam`) and a coach with a full roster (`-sampleClients YES`, 14
made-up clients, so search and long names show). Add a screen to `screens.json` with the files that draw it and how to
reach it (`how`), and set `commit` when the pass is done.

```bash
python3 .claude/skills/ui-score/score.py --screens            # each screen, LOW under 90, and what lost points
python3 .claude/skills/ui-score/score.py --screens --findings # plus each screen's automated findings
```

## Raising the score

1. Run `score.py --findings` and the simulator pass. Fix the biggest losses first.
2. Fix the cause, not the detector: a missing token goes into Theme.swift once and every file uses it; a fixed size
   becomes `Font.display`; a transition gets a Reduce Motion fallback. Keep the look (design system v2, FIT-297) and
   the author's rules: fewest taps, no new settings, nothing added that isn't needed to fix a finding.
3. After each slice: build **AICoach and Liftplan**, run the tests (CLAUDE.md §7), look at the changed screens in the
   simulator, and commit (`FIT-364: …`).
4. Re-run the score. Repeat until it's where it was asked to be; then rerun the full simulator pass once more on
   the final commit, and comment the score and its parts on the Linear issue.
