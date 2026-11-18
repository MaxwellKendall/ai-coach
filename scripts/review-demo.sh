#!/bin/sh
# TKL-460: the review demo's invited-client and coach chapters, recorded in the Debug build's no-server demo mode, with a
# title card before each, then checked for coverage of the client and coach roles. Writes build/review/chapters.mp4.
#   scripts/review-demo.sh            (DEMO_SIMULATOR=<name or UDID> records on another simulator)
# The review path on the demo accounts is still `npm run demo-video`.
set -e
cd "$(dirname "$0")/.."
exec node scripts/demo-video.mjs --chapters "$@"
