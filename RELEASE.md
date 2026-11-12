# Releasing to the App Store

`npm run release` takes `main` to an App Store Connect version that is ready for review, then stops. `npm run release -- submit` creates the review submission. `npm run release -- --dry-run` runs the local steps and the read-only App Store Connect calls, and does not upload a build, change the listing, refresh the prod review account, deploy the video, or submit.

`npm run release -- products` writes only the subscriptions in `appstore/subscriptions.json`, then stops. It does not bump the build, upload, change the version or the listing, mint invites, refresh the review account, record the video, upload paywall screenshots, or submit. It runs when this commit is `origin/main` and the tree is clean. `npm run release -- --dry-run products` prints the plan and writes nothing.

The command is plain `xcodebuild` plus a small App Store Connect client (`scripts/asc.mjs`) that signs its own JWT. Fastlane is not used.

## One-time steps

1. In App Store Connect, Users and Access › Integrations › App Store Connect API, make a key with the App Manager role. Save the `.p8` at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`.
2. In the gitignored `.env` at the repo root, set `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH` (the path to that `.p8`). The release command reads the key at runtime and does not print, copy, or commit it.
3. In the same `.env`, set `DEMO_COACH_EMAIL`, `DEMO_CLIENT_EMAIL`, and `DEMO_PASSWORD` for the two FIT-328 demo accounts. Review notes sent to Apple include this login. It is not written into the repo.
4. Set `ASC_CONTACT_PHONE` in `.env` if the version's review contact has no phone yet. The command reuses a phone already on the version and never prints it.
5. Sign the Paid Apps agreement and enter tax and banking under Business in App Store Connect. Apple does not offer that signature through the API. The command stops if a read fails with the missing-agreement error. It cannot see the agreement row itself, so confirm Paid Apps is Active before the first real run.
6. The demo video is recorded to `build/review/demo.mp4`. The stack defines a `/review/*` CloudFront behavior pointing at the cards bucket (`infra/lib/stack.ts`); deploying that behavior is a later, separate step. Nothing in the repo uploads `/review/`, so the release command does not deploy the file. After the behavior is deployed, upload the file by hand, the same way the exercise photos are hosted. Resolve the cards bucket from the stack outputs:

```bash
BUCKET=$(aws cloudformation describe-stacks --profile aicoach-dev --stack-name AICoach-prod \
  --query "Stacks[0].Outputs[?OutputKey=='CardsBucket'].OutputValue" --output text)
aws s3 cp build/review/demo.mp4 "s3://$BUCKET/review/demo.mp4" --profile aicoach-dev \
  --content-type video/mp4 --cache-control "public, max-age=300"
curl -sI https://barbrabell.com/review/demo.mp4 | head -1
```

The upload's `--content-type video/mp4` sets the S3 object metadata used to serve the video. The behavior uses the default GET/HEAD methods and `CACHING_OPTIMIZED`, which support byte-range GETs from the cached S3 object. Before `submit`, deploy the behavior in a separate prod deployment, upload the video, and verify that `https://barbrabell.com/review/demo.mp4` is accessible to reviewers. The stack definition alone does not make the URL live in production.

## What the command does

From a clean `main`, with the unit tests green:

1. Bumps `CURRENT_PROJECT_VERSION` in `project.yml` and commits it.
2. Archives with `xcodebuild` and uploads with `-exportArchive` (`destination` `upload`), authenticated by the API key. Polls until that build is processed.
3. Refreshes the prod review account: `npm run review-account -- prod <coach uid> --coach --athlete` in `infra/`. The coach uid is `appstore/review.json`. Weeks are rewritten; a password is printed by that script only when the account is new, and this command keeps it out of its own log. It is included in the notes sent to Apple.
4. Ensures the review coach has invite codes with more than two days left (`npm run review-invites`), since a code lasts 14 days.
5. Records the review demo (`npm run demo-video`): an XCUITest signs in as the demo client, shows the coached week, logs today's session when it is still open, shows Delete Account without using it, then signs in as the demo coach and shows the roster. `simctl io recordVideo` records it and ffmpeg writes `build/review/demo.mp4`.
6. Creates or updates the subscriptions in `appstore/subscriptions.json`: Lifter Pro reuses `com.maxwellkendall.aicoach.pro.monthly` and `pro.yearly` (the existing Pro Monthly and Pro Annual), and Coach Pro is two new products. Prices use the nearest USA tier and are equalized for other territories. Lifter Pro gets a 14-day free trial. Names, descriptions, subscription review notes, and the paywall screenshots are set when they differ. An en-US localization that already exists is updated. Nothing is deleted. A product that already exists stays in its group.
7. Creates the version record if it is missing, attaches the build, and sets the description, What's New, promotional text, keywords, URLs, and review details from `appstore/metadata/` and `appstore/review.json`. Listing screenshots are left as they are. The description ends with the Terms of Use link. What's New is omitted if App Store Connect refuses it on the first version. The review notes explain how to reach the Lifter Pro and Coach Pro paywalls.
8. Prints what is ready, including any subscription that is not ready to submit. `npm run release -- submit` then puts the version and the subscription versions in one review submission, reusing an open submission and skipping an item that is already on it. The note to App Review says the Terms of Use link was added and the subscriptions are offered in the app. Submit waits until every subscription is ready and both paywall screenshots exist.

Paywall screenshots belong in `appstore/screenshots/lifter-pro.png` and `coach-pro.png`. `PaywallScreenshotUITests` captures them once FIT-437 shows the paywalls. Until those files exist, the command warns and will not upload a screenshot.

`npm run demo-video` runs step 5 on its own. It resets the iPhone 17 Pro simulator's keychain and uninstalls the app, so the recording starts signed out at the first launch. A signed-in session lives in the keychain and would skip Welcome.

Listing copy lives in `appstore/metadata/`. The App Store name in those files is `barbrabell`.

## Revenue pull (FIT-444)

`npm run revenue` is a read-only pull of App Store Connect catalog data and, when access allows, Sales and Trends plus Stripe. It never writes to Apple or Stripe, and it never prints, copies, or commits the `.p8` or API keys.

From a checkout of this repo (the agent worktree is fine; do not use Maxwell's `~/dev/ai-coach-app` tree):

```bash
npm run revenue
```

That is `node scripts/revenue.mjs`. It loads the gitignored `.env` at the repo root the same way the release command does (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`).

Secrets are loaded in this order (already-set environment variables win; values are never printed):

1. `~/.config/agents/secrets.env` (preferred shared file)
2. `~/.config/secrets.env` (fallback shared file)
3. the gitignored `.env` at the repo root (same file the release command uses for `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH`)

Optional variables:

* `ASC_VENDOR_NUMBER` — the vendor number from App Store Connect → Payments and Financial Reports. Required to download Sales, Subscription, and Subscription Event reports. The API key also needs the Sales and Trends / Finance role; a 403 is reported exactly and is not treated as zero revenue.
* `STRIPE_READONLY_KEY` — a restricted organization or live read-only key. Organization keys (`sk_org_…`) are sent with a `Stripe-Context` header per account (`Stripe-Account` is tried only if that fails). When this is unset, Stripe is skipped and the output records status `missing`. Do not put the full `aicoach/prod/stripe` secret here, and do not fetch it from AWS.
* `STRIPE_ACCOUNT_BARBRABELL` and `STRIPE_ACCOUNT_REMIX` — the Stripe account ids to query, one request set per app.

Output (gitignored):

* `revenue-out/YYYY-MM-DD.json`
* `revenue-out/YYYY-MM-DD.md`

Dates are America/New_York. The markdown is the body to post on [FIT-444](https://linear.app/custom-voice-app/issue/FIT-444/revenue-dashboard). Tests: `npm run test:release` (includes `scripts/revenue.test.mjs`).
