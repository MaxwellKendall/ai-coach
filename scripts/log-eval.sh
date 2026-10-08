#!/bin/zsh
# FIT-26: spoken logs parsed by the on-device model (simulator; needs Apple Intelligence on this Mac).
# usage: scripts/program-eval.sh [runs per case, default 3] [only phrases containing this]
# Writes Tests/Evals/log-results.md.
cd "${0:A:h}/.."
xcodegen generate >/dev/null
TEST_RUNNER_EVAL_RUNS=${1:-3} TEST_RUNNER_EVAL_FILTER=${2:-} \
  xcodebuild -scheme AICoachEvals -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation \
  test '-only-testing:AICoachEvals/LogParserEvals/spokenLogs()' 2>&1 \
  | tee /tmp/aicoach-log-eval.log | grep -a '^LOG§ ' | sed 's/^LOG§ //' > Tests/Evals/log-results.md
if [[ ! -s Tests/Evals/log-results.md ]]; then
  grep -aE "error:|✘" /tmp/aicoach-log-eval.log | head -20
  exit 1
fi
sed -n 3p Tests/Evals/log-results.md
