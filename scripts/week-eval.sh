#!/bin/zsh
# FIT-426: a Pro lifter's week designed by a model against the code week, on six scenarios, scored by code and a judge.
# usage: scripts/week-eval.sh [designer, default claude-haiku-5-5] [judge, default gpt-6-astra]
#   The judge is another lab's model than the designer's, so Claude doesn't grade Claude (author, 2026-11-11).
#   EVAL_RUN=<label>: a repeat run, kept beside the others (week-results-<designer>-run-<label>.md).
# Writes Tests/Evals/week-results-<designer>.md. Keys come from .env.
cd "${0:A:h}/.."
[[ -f .env ]] && set -a && source .env && set +a
model=${1:-claude-haiku-5-5}
judge=${2:-gpt-6-astra}
out=Tests/Evals/week-results-$model${EVAL_RUN:+-run-$EVAL_RUN}.md
log=/tmp/aicoach-week-eval-$model${EVAL_RUN:+-$EVAL_RUN}.log
xcodegen generate >/dev/null
TEST_RUNNER_EVAL_MODEL=$model TEST_RUNNER_EVAL_JUDGE=$judge TEST_RUNNER_ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-} \
TEST_RUNNER_OPENAI_API_KEY=${OPENAI_API_KEY:-${OPEN_AI_API_KEY:-}} TEST_RUNNER_GEMINI_API_KEY=${GEMINI_API_KEY:-} \
  xcodebuild -scheme AICoachEvals -destination "platform=iOS Simulator,name=${EVAL_SIMULATOR:-iPhone 17 Pro}" -skipPackagePluginValidation \
  test '-only-testing:AICoachEvals/WeekDesignEvals/designedAgainstTheCodeWeek()' 2>&1 \
  | tee $log | grep -a '^WEEK§ ' | sed 's/^WEEK§ //' > $out
if [[ ! -s $out ]]; then
  rm -f $out
  grep -aE "error:|✘|Expectation failed|isn't available|No [A-Z_]+_API_KEY" $log | head -20
  exit 1
fi
sed -n 3,3p $out
