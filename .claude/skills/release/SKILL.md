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

**Stop and ask** if it warns that Pro's subscriptions are attached to the version (FIT-386). Version 1.0 ships without them.

## 3. The video link

The file is `build/review/demo.mp4`. `https://barbrabell.com/review/demo.mp4` is not served until a `/review/*` behavior exists. RELEASE.md has the upload, and it is a manual step. **Stop** before submit if that URL does not return 200, unless the author has put the video somewhere else and the notes were updated.

## 4. Submit

Only when the author says to:

```bash
npm run release -- submit
```

That creates the review submission. There is no separate "are you sure" in the command; the author's request is the yes.
