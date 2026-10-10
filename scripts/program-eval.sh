#!/bin/zsh
# FIT-72, FIT-92: weeks designed by a model, scored. Simulator; the on-device model needs Apple Intelligence on this Mac.
# usage: scripts/program-eval.sh [model, default on-device] [probe weeks, default 12; 0 for the grid only] [only profiles whose name contains this]
#   model: on-device, or a Claude model id (claude-opus-5-5) with ANTHROPIC_API_KEY set; EVAL_THINKING=<tokens> adds thinking.
# Writes Tests/Evals/program-results-<model>.md.
cd "${0:A:h}/.."
model=${1:-on-device}
out=Tests/Evals/program-results-$model${EVAL_THINKING:+-thinking-$EVAL_THINKING}.md
xcodegen generate >/dev/null
TEST_RUNNER_EVAL_MODEL=$model TEST_RUNNER_ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-} TEST_RUNNER_EVAL_THINKING=${EVAL_THINKING:-} \
TEST_RUNNER_EVAL_WEEKS=${2:-12} TEST_RUNNER_EVAL_FILTER=${3:-} \
  xcodebuild -scheme AICoachEvals -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation \
  test '-only-testing:AICoachEvals/ProgramDesignerEvals/designedWeeks()' 2>&1 \
  | tee /tmp/aicoach-program-eval.log | grep -a '^PROGRAM§ ' | sed 's/^PROGRAM§ //' > $out
if [[ ! -s $out ]]; then
  rm -f $out
  grep -aE "error:|✘|Expectation failed|isn't available|No ANTHROPIC" /tmp/aicoach-program-eval.log | head -20
  exit 1
fi
sed -n 3p $out
