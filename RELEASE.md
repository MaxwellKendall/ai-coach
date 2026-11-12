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
6. The demo video is recorded to `build/review/demo.mp4`. `https://barbrabell.com/review/demo.mp4` is not a route: CloudFront serves files only at `/cards/*`, `/exercises/*`, and `/app/*` (`infra/lib/stack.ts`). Nothing in the repo uploads `/review/`, so the command does not deploy the file. After a `/review/*` behavior points at the cards bucket, host the file the same way the exercise photos are hosted:

```bash
BUCKET=$(aws cloudformation describe-stacks --profile aicoach-dev --stack-name AICoach-prod \
  --query "Stacks[0].Outputs[?OutputKey=='CardsBucket'].OutputValue" --output text)
aws s3 cp build/review/demo.mp4 "s3://$BUCKET/review/demo.mp4" --profile aicoach-dev \
  --content-type video/mp4 --cache-control "public, max-age=300"
curl -sI https://barbrabell.com/review/demo.mp4 | head -1
```

Until that behavior exists, the curl is a 404 and the review notes' video link will not play. Put the file somewhere reviewers can open, or add the behavior in a prod deploy, before `submit`.

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
