---
name: release
description: Take main to an App Store Connect version ready for review, including the review demo video. Run only when the author asks for a release. submit is a separate yes.
disable-model-invocation: true
---

# Release to the App Store

`npm run release` is the routine. RELEASE.md has the one-time steps and the manual video upload. This is the check before running it.

Prod and App Store Connect hold the live app. Never release uncommitted work or a red build, and stop at anything below that says stop.

## 1. Preflight

From the repo root:

```bash
git --no-pager status --porcelain && git --no-pager log --oneline -1 && git rev-parse --abbrev-ref HEAD
```

**Stop** unless the branch is `main` and the tree is clean.

Say which commit would go out. A dry run, which changes nothing, is:

```bash
npm run release -- --dry-run
```

## 2. Release

```bash
npm run release
```

It bumps `CURRENT_PROJECT_VERSION`, commits, archives, uploads, refreshes the prod review account, records the demo video, and sets the listing from `appstore/`. It then stops.

**Stop** if it says the Paid Apps agreement is not active. The Account Holder signs that under Business. Apple does not expose the signature through the API.

**Stop before submit** if a subscription is not ready to submit, or a paywall screenshot is missing. The command attaches Coach Pro and Lifter Pro to the version; it does not remove products. Submit waits for the author's yes.

`npm run release -- products` is the products-only write. Run it only when the author has explicitly said to apply the subscription plan. It still does not upload a build, edit the listing, mint invites, upload paywall screenshots, or submit.

## 3. The video link

The file is `build/review/demo.mp4`. `https://barbrabell.com/review/demo.mp4` is not served until a `/review/*` behavior exists. RELEASE.md has the upload, and it is a manual step. **Stop** before submit if that URL does not return 200, unless the author has put the video somewhere else and the notes were updated.

## 4. Submit

Only when the author says to:

```bash
npm run release -- submit
```

That creates the review submission. There is no separate "are you sure" in the command; the author's request is the yes.
