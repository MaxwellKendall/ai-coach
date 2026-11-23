# barbrabell (ai-coach-app): facts

## What it is
Strength coaching. Coaches are the customers: they program clients from the web dashboard (barbrabell.com/app) or from
Claude through the MCP connector (`https://barbrabell.com/mcp`); clients follow and log in a free iOS app.
Coaching is free with any number of clients; Pro is $19.99/mo, sold in the app (StoreKit/App Store) and on the web (Stripe), and adds planning from Claude (FIT-437 reversed the earlier web-only rule).
Linear project: **barbrabell** (team TKL): https://linear.app/software-studio/project/barbrabell-a83b6b0b9285

## Layout
- `App/`: `@main`, root views, `Theme.swift`, `Info.plist`. `Widgets/`: workout Live Activity.
- `Core/`: Model (SwiftData), Generators, Progress (pure Swift, no UI/persistence imports), AI (`AIModel.swift`: every LLM call), Import.
- `Features/`: SwiftUI screens. `Resources/`: assets, `Seed/` JSON (exercises, recipes, photos), `amplify_outputs.{dev,prod}.json`.
- `Tests/`: `CoreTests` (unit), `Evals` (real models, scored; results `*.md` are tracked), `UITests` (`ReviewDemoUITests.swift` + `DemoScreens.swift` for the review demo, `PaywallScreenshotUITests.swift`, `DemoModeUITests.swift`, `AIWeekScreenshotUITests.swift`, `DemoClipScreenshotUITests.swift` (scheme `ReviewDemo`; Back Squat's demo on the how-to sheet and set card → `build/screens/`), `HowToDemoUITests.swift` (TKL-793: demo tile one tap from Today, paging, full screen, Program's cards, offline; `TEST_RUNNER_APPEARANCE=dark` names the screenshots after `xcrun simctl ui <device> appearance dark`)), `Fixtures`.
- `infra/`: AWS CDK (TypeScript). `lib/stack.ts` is the whole stack; `lambda/` (MCP, sync, coach, Stripe, AI proxy, share pages…), `resolvers/`, `graphql/`, `scripts/`, `test/` (vitest). Background: `infra/README.md`.
- `web/`: coach dashboard, Vite + React + TS, served at `/app`. `shared/`: TS shared by web and infra.
- `plugin/`: the Claude plugin (skills + connector). `directories/`: ChatGPT, Claude, MCP-registry listing builds.
- `appstore/`: listing screenshots and headers. `scripts/`: eval runners and the review demo video.
- `project.yml`: XcodeGen spec (the `.xcodeproj` is generated and gitignored). `AICoach.storekit`: local StoreKit config.

## Setup
- Xcode 27 (iOS 26.0 target, Swift 6 strict concurrency), XcodeGen at `/opt/homebrew/bin/xcodegen`, simulator "iPhone 17 Pro".
- One SwiftPM dependency: amplify-swift (Cognito + AppSync). Otherwise Apple frameworks only.
- Package versions are pinned (TKL-768): `project.yml` gives amplify-swift an `exactVersion`, and the tracked root `Package.resolved` pins every transitive package. `xcodegen generate` copies it into the gitignored `AICoach.xcodeproj` (`postGenCommand`), so every checkout and worktree builds the same graph. To bump: change `exactVersion`, resolve in Xcode, copy `AICoach.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` back to the root, commit both. `npm run test:release` checks they agree. amplify-swift 2.63.1 doesn't build here (SmithyCBOR "switch must be exhaustive").
- Node + npm; `npm install` in `infra/` and `web/` (both have lockfiles). ffmpeg for the review video.
- AWS profile `aicoach-dev` (account 397614038040, us-east-1) for deploys and the AWS scripts.
- Bundle id `com.maxwellkendall.aicoach`, team `7GZKY29XJH`, automatic signing.

## Test
| Suite | Command (from repo root) | Runtime |
|---|---|---|
| iOS unit | `xcodegen generate && xcodebuild -scheme AICoach -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` | ~4.5 min cold (tests 43 s) |
| infra + MCP + Lambdas | `cd infra && npx tsc --noEmit -p . && npx vitest run` | ~45 s |
| dashboard | `npm --prefix web test` (vitest); type check + build: `npm --prefix web run build` | ~1 s each |
| demo-clip scripts | `python3 -m unittest discover -s scripts/tests` | <1 s |
| spoken-edit eval | `scripts/eval.sh [runs=3] [filter]` → `Tests/Evals/results.md` | ~4 min at 1 run |
| spoken-log eval | `scripts/log-eval.sh [runs=3] [filter]` → `Tests/Evals/log-results.md` | ~1.5 min at 1 run |
| program eval | `scripts/program-eval.sh [model=on-device] [weeks=12] [filter]` → `Tests/Evals/program-results-<model>.md` | ~4.5 min with weeks=0; longer with probes |
| week eval | `scripts/week-eval.sh [designer=claude-haiku-5-5] [judge=gpt-6-astra]` → `Tests/Evals/week-results-<designer>.md` | ~3 min, ~$0.16 of API credit |

Evals run the `AICoachEvals` scheme. On-device runs need Apple Intelligence on the host Mac; cloud models read keys from `.env`.
For program/week evals only: `EVAL_RUN=<label>` keeps a repeat run beside the others; `EVAL_SIMULATOR=<name>` runs on another simulator. The spoken-edit/log evals always overwrite their file on iPhone 17 Pro.

## Run
- App: `xcodegen generate && open AICoach.xcodeproj`, run `AICoach` on iPhone 17 Pro (Debug uses `amplify_outputs.dev.json` and `AICoach.storekit`).
  CLI: `xcodebuild -scheme AICoach -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`, then `xcrun simctl install/launch`. Debug builds accept `-units PATH` (a sync-units JSON) to load data without sign-in, and `-haptics YES` opens a debug list that plays each Core Haptics pattern (`Resources/Haptics/*.ahap`, TKL-393).
- Maxwell's iPhone: **only when he asks** (never after every landing; routine builds reach him on TestFlight), and then only `npm run device-install` (`scripts/device-install.mjs`, TKL-796), only after the change is on `origin/main`. It builds Release (prod backend, what he runs) and installs on the paired iPhone (`--device UDID` if several). It refuses a commit not on `origin/main` or a dirty tree unless `--branch-ok`, records sha + configuration per device in `$(git rev-parse --git-common-dir)/device-install.json`, and warns when an install replaces unmerged work or switches Debug/Release. `--dry-run` shows the plan. Never `devicectl install` by hand.
- Dashboard: `cd infra && AWS_PROFILE=aicoach-dev npm run dashboard-config` (writes `web/public/config.json` from AICoach-dev), then from the repo root `npm --prefix web run dev` → http://localhost:5173 (unverified).
- Share pages from sample data: `npm --prefix infra run web` → http://localhost:8787 (unverified).
- The MCP server and backend run only as Lambdas, on `AICoach-dev` (`dev.barbrabell.com/mcp`) and `AICoach-prod`; there is no local server. Test sessions: `AWS_PROFILE=aicoach-dev npm --prefix infra run buddy -- coach`.
- First-launch funnel (TKL-466): the app's `Core/Cloud/Funnel.swift` posts anonymous events (random install id + strategy, no name/age/answers) to `/events` (`infra/lambda/funnel.ts`, rules in `shared/funnel.ts`); `AWS_PROFILE=aicoach-dev npm --prefix infra run funnel -- STAGE [YYYY-MM-DD]` prints each step and first-launch-to-paid per strategy against the 11% benchmark. UI tests and `-demo` only write `funnel.log` in UserDefaults.
- Demo accounts (sign in with email; passwords in the gitignored `infra/.demo-accounts.STAGE`): `npm --prefix infra run coach-demo -- STAGE [--new-password]` makes coach@ (Coach Pro, 10 clients) and client@ (Sam); `npm --prefix infra run lifter-demo -- STAGE [--new-password]` makes lifter@ (Jordan, solo, Lifter Pro, 3 weeks logged). Both reset the accounts' training to today. App Review's review@ is coached by coach@ (`appstore/review.json`).

## Deploy (prod)
Stack `AICoach-prod` (CDK, profile `aicoach-dev`, us-east-1): Cognito, one DynamoDB table, AppSync, Lambdas (MCP, sync, push…), CloudFront serving barbrabell.com (+ share., join.) with the dashboard at `/app`. Dev is `AICoach-dev` on dev.barbrabell.com. From `infra/`, on a clean `main` (verified 2026-11-23 from a `git archive` export of `origin/main`, TKL-980). Set `AWS_PAGER=""` for the AWS CLI calls here; unattended runs otherwise hang in the pager:
```bash
npx tsc --noEmit -p . && npx vitest run
npm --prefix ../web run build                      # always: the stack uploads web/dist
npx cdk diff --profile aicoach-dev -c stage=prod    # see stop rules below; "no differences" = nothing to deploy
npx cdk deploy --profile aicoach-dev -c stage=prod --require-approval never   # 2–3 min, ends "✅  AICoach-prod"
AWS_PROFILE=aicoach-dev npm run outputs prod        # commit Resources/amplify_outputs.prod.json if it changed
```
Stop (don't deploy) if the diff replaces or removes the DynamoDB table or the Cognito user pool (any "requires replacement" on either), or removes a user pool client, an identity provider, the CloudFront distribution or the certificate. Deploy only a clean, green `main`.
Post-deploy: `/ /docs /claude /privacy /support /.well-known/oauth-authorization-server /app/` on https://barbrabell.com return 200, `POST /mcp` returns 401, and the stack's `LastUpdatedTime` is after the deploy started. Also hit whatever page or endpoint the deployed commits changed. Rollback: check out the last good commit and repeat build/diff/deploy. Never restore data over the live table (PITR 35 days; restore to a new table, see `infra/README.md`).

## Release (iOS)
Signing uses the Xcode account (the Apple ID signed in under Xcode › Settings › Accounts on this Mac); the API key in `.env` is only for App Store Connect API calls (TKL-760).
Version is `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` (now 1.0 / 24). Release builds use `amplify_outputs.prod.json`.
The release tooling is on `main`: `npm run release` (`scripts/release.mjs`), documented step by step in `RELEASE.md`; `npm run test:release` tests it:
- `npm run release -- --dry-run`: local steps + read-only App Store Connect calls.
- `npm run release`: bumps `CURRENT_PROJECT_VERSION` and commits, archives and uploads with `xcodebuild -exportArchive` (signed by the Xcode account on this Mac via `-allowProvisioningUpdates`, not the API key; lands the bump through a `release/build-N` PR right after the upload, then polls processing), refreshes the prod review account, records the demo video, sets subscriptions and listing from `appstore/`, then stops.
- `npm run release -- submit`: creates the review submission. Submission is Maxwell's.
- `npm run release -- products`: products-only write (subscriptions), only when Maxwell has said to apply the subscription plan.
- Stop if release reports the Paid Apps agreement inactive (the Account Holder signs it under Business; no API). Before submit: every subscription ready, paywall screenshots present, and the review video URL below returns 200.
Paywall screenshots: `npm run paywall-shots` regenerates `appstore/screenshots/{lifter,coach}-pro.png` with a clean status bar (`PAYWALL_SIMULATOR=<name or UDID>` to use another simulator).
Review demo video: `npm run demo-video` (`scripts/demo-video.mjs`): an XCUITest (`ReviewDemoUITests`) signs in as the demo client and then the demo coach; `simctl io recordVideo` + ffmpeg write `build/review/demo.mp4`, then it reports which screens of `appstore/review/screens.json` the video never showed (`-- --require-coverage` fails on gaps). `npm run screens` regenerates that inventory.
`https://barbrabell.com/review/demo.mp4` serves only after the `/review/*` behavior is deployed and the file is uploaded to the cards bucket by hand.

## Land
Through a pull request to `origin/main`, squash-merged (the history is `TKL-N: … (#PR)`; older commits use `FIT-N`). Branch from `origin/main` in a worktree, never the main checkout; push the branch, `gh pr create`, merge with `gh pr merge --squash`. Keep local `main` equal to `origin/main` (`git pull --ff-only`); never commit on local `main` directly.

## Verify checks
A change lands only with all of these green: the iOS unit tests (`AICoach` scheme), `infra` tsc + vitest, `web` vitest + `npm --prefix web run build`.
A UI change also gets a simulator screenshot. A change to model prompts or `ProgramDesigner` also gets the matching eval run and its results file.

## Secrets used (names only)
- Repo `.env` (gitignored): `ANTHROPIC_API_KEY`, `OPEN_AI_API_KEY` (or `OPENAI_API_KEY`), `GEMINI_API_KEY` for evals; `STRIPE_SECRET_KEY`, `STRIPE_WH_SEC`, `STRIPE_GIFTS_SECRET_KEY`, `STRIPE_WH_SEC_GIFTS`.
  Release branch adds `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`, `DEMO_COACH_EMAIL`, `DEMO_CLIENT_EMAIL`, `DEMO_PASSWORD`, `ASC_CONTACT_PHONE`.
- AWS Secrets Manager, per stage: `aicoach/{stage}/apple-signin`, `/google-oauth`, `/apns`, `/stripe`, `/anthropic` (read by the stack and Lambdas).
- App Store Connect `.p8` keys: `~/.appstoreconnect/private_keys/`; an `AuthKey_*.p8` also sits in the repo root (gitignored by `*.p8`).
- Shared keys: `~/dev/.secrets.env`. Demo account passwords: `.demo-accounts.*` (gitignored).

## Gotchas
- Never hand-edit `AICoach.xcodeproj`; change `project.yml` and run `xcodegen generate`.
- Evals are not in the `AICoach` scheme and overwrite tracked `Tests/Evals/*.md`; cloud-model evals spend API credit.
- Foundation Models in the simulator works only if the host Mac has Apple Intelligence; otherwise the app hides voice entry and on-device evals fail.
- Use the AWS CLI with `--profile aicoach-dev` (or `AWS_PROFILE=aicoach-dev`) for all AWS work here, not the aws-mcp server: aws-mcp is signed in to a different account (304945936761) and reports `AICoach-prod` as missing.
- Dev and prod share one AWS account; prod's table and user pool are `RETAIN` with deletion protection. Budget alerts cover the whole account.
- `cdk deploy` without a fresh `web` build ships a stale dashboard.
- `npm run demo-video` resets the iPhone 17 Pro simulator's keychain and uninstalls the app so it records from a signed-out first launch; don't run it while using that simulator. `DEMO_SIMULATOR=<name or UDID>` records on another one (the shared iPhone 17 Pro is often busy with other runs' tests, which steals the demo's taps).
- Importer data quirks (from `~/dev/fitness-planner`, read-only): `load` may be a string (`"BW"`, `"95 lb"`, `"24 kg/hand"`), `reps` a duration (`"50s"`), some logs `"reconstructed": true`.
- Exercises with a demo clip ship their start/end photos in `Resources/DemoPhotos` (the how-to's offline fallback, TKL-793). After changing `Resources/Seed/exercise-demos.json`, run `scripts/demo-photos.sh`; `ExercisePhotosTests.demoExercisesShipTheirPhotos` fails until you do.
- Units follow the user's setting; the author uses lb.
