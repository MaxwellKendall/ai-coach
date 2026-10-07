#!/bin/zsh
# FIT-72: weeks designed by the on-device model (simulator; needs Apple Intelligence on this Mac).
# usage: scripts/program-eval.sh [probe weeks, default 12; 0 for the grid only] [only profiles whose name contains this]
# Writes Tests/Evals/program-results.md.
cd "${0:A:h}/.."
xcodegen generate >/dev/null
TEST_RUNNER_EVAL_WEEKS=${1:-12} TEST_RUNNER_EVAL_FILTER=${2:-} \
  xcodebuild -scheme AICoachEvals -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation \
  test '-only-testing:AICoachEvals/ProgramDesignerEvals/designedWeeks()' 2>&1 \
  | tee /tmp/aicoach-program-eval.log | grep -a '^PROGRAM§ ' | sed 's/^PROGRAM§ //' > Tests/Evals/program-results.md
if [[ ! -s Tests/Evals/program-results.md ]]; then
  grep -aE "error:|✘" /tmp/aicoach-program-eval.log | head -20
  exit 1
fi
sed -n 3p Tests/Evals/program-results.md
