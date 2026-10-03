#!/bin/zsh
# FIT-48: score spoken workout edits on the on-device model (simulator; needs Apple Intelligence on this Mac).
# usage: scripts/eval.sh [runs per case, default 3] [only cases whose phrase contains this]
# EVAL_STRATEGY=changes compares the other editor. Writes Tests/Evals/results.md.
cd "${0:A:h}/.."
xcodegen generate >/dev/null
TEST_RUNNER_EVAL_RUNS=${1:-3} TEST_RUNNER_EVAL_FILTER=${2:-} TEST_RUNNER_EVAL_STRATEGY=${EVAL_STRATEGY:-} \
  xcodebuild -scheme AICoachEvals -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 \
  | tee /tmp/aicoach-eval.log | grep -a '^EVAL§ ' | sed 's/^EVAL§ //' > Tests/Evals/results.md
if [[ ! -s Tests/Evals/results.md ]]; then
  grep -aE "error:|✘" /tmp/aicoach-eval.log | head -20
  exit 1
fi
head -3 Tests/Evals/results.md | tail -1
