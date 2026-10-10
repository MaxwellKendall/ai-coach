#!/bin/zsh
# FIT-72, FIT-92: weeks designed by a model, scored. Simulator; the on-device model needs Apple Intelligence on this Mac.
# usage: scripts/program-eval.sh [model, default on-device] [probe weeks, default 12; 0 for the grid only] [only profiles whose name contains this]
#   model: on-device, or a Claude model id (claude-opus-5-5) with ANTHROPIC_API_KEY set; EVAL_THINKING=<tokens> adds thinking.
#   EVAL_PROBE=author,strength: the profiles to plan a whole program for (default: the author).
#   EVAL_BRIEF_MODEL=<model>: the model that writes the program brief (default: the same model).
# Writes Tests/Evals/program-results-<model>.md, then Tests/Evals/program-compare.md from every model's latest results.
cd "${0:A:h}/.."
# API keys, gitignored.
[[ -f .env ]] && set -a && source .env && set +a
model=${1:-on-device}
out=Tests/Evals/program-results-$model${EVAL_THINKING:+-thinking-$EVAL_THINKING}${EVAL_BRIEF_MODEL:+-brief-$EVAL_BRIEF_MODEL}.md
xcodegen generate >/dev/null
TEST_RUNNER_EVAL_MODEL=$model TEST_RUNNER_ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-} TEST_RUNNER_EVAL_THINKING=${EVAL_THINKING:-} \
TEST_RUNNER_EVAL_WEEKS=${2:-12} TEST_RUNNER_EVAL_FILTER=${3:-} TEST_RUNNER_EVAL_PROBE=${EVAL_PROBE:-} TEST_RUNNER_EVAL_BRIEF_MODEL=${EVAL_BRIEF_MODEL:-} \
  xcodebuild -scheme AICoachEvals -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation \
  test '-only-testing:AICoachEvals/ProgramDesignerEvals/designedWeeks()' 2>&1 \
  | tee /tmp/aicoach-program-eval.log | grep -a '^PROGRAM§ ' | sed 's/^PROGRAM§ //' > $out
if [[ ! -s $out ]]; then
  rm -f $out
  grep -aE "error:|✘|Expectation failed|isn't available|No ANTHROPIC" /tmp/aicoach-program-eval.log | head -20
  exit 1
fi
sed -n 3,7p $out
{
  echo "# Program designer evals: models compared"
  echo
  echo "Each row is the latest \`scripts/program-eval.sh <model>\` run; the details are in program-results-<model>.md."
  echo "A job passes when it meets every line of ProgramScore.Bar (weeks) or has no brief problems (brief). Cost is per week designed and per brief written."
  echo
  echo "| Weeks by | Brief by | Week design | Brief | Cost a week | Cost a brief | Weeks by the model | Repairs a week | Time a week | Copied sessions | Odd items | Main lifts up · held · dropped | Rises over 10% | Goals: planned estimate | Deloads lighter | Exercises changed between phases | Tokens (weeks) |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  grep -h '^<!-- compare: ' Tests/Evals/program-results-*.md | sed 's/^<!-- compare: //; s/ -->$//'
} > Tests/Evals/program-compare.md
