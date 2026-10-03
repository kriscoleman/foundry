#!/usr/bin/env bash
# cv-severity-rubric.test.sh — hermetic, offline test that the shared BLOCKING
# vs. LOW severity rubric (fk-qbdta) reaches both the security and acceptance
# review lanes verbatim, and that the synthesizer carries the no-downgrade
# instruction.
#
# THE BUG: on replicatedhq/vandoor#10589 (sc-139247 slice 4), the security
# lane graded a collision-safety issue LOW because "the sole current caller
# passes zero-value options" (safety resting on an unenforced precondition,
# with a local, cheap fix), and the acceptance lane graded a "no warnings
# when unused" criterion LOW even though it was vacuously true (the wiring
# that would exercise it lands in another, unmerged slice). The operator
# judged both should have been BLOCKING.
#
# THE FIX: a shared severity rubric, carried verbatim by both lanes (like
# CV_REVIEW_LANE_WORKTREE_REMINDER), states that a finding is BLOCKING when
# (a) correctness/safety holds only because of an unenforced precondition,
# current caller behavior, or a promise about a future slice, and the fix is
# local; (b) an acceptance criterion is satisfied only vacuously; or (c) the
# change depends on an unmerged PR/slice and is not stacked on it. The
# synthesizer must not downgrade a lane's BLOCKING to LOW on "intentional per
# plan" grounds.
#
# Run:  bash tests/cv-severity-rubric.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
WORKFLOWS_DIR="${MOLD_DIR}/pack/assets/workflows/con-voyage"
SECURITY_LANE="${WORKFLOWS_DIR}/main.security-review.md"
ACCEPTANCE_LANE="${WORKFLOWS_DIR}/main.acceptance-review.md"
SYNTHESIS="${WORKFLOWS_DIR}/main.synthesize-review.md"

if [ ! -f "$LIB" ]; then
  echo "FATAL: shared lib not found at ${LIB}" >&2
  exit 2
fi

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $label ($file does not exist)" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  if grep -qF -- "$needle" "$file"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (not found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

start_case "the shared severity rubric constant is defined"
if [ -z "${CV_SEVERITY_RUBRIC_REMINDER:-}" ]; then
  echo "  FAIL: CV_SEVERITY_RUBRIC_REMINDER is not defined by ${LIB}" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: CV_SEVERITY_RUBRIC_REMINDER is defined"
fi

start_case "the rubric states the unenforced-precondition BLOCKING rule"
if [ -n "${CV_SEVERITY_RUBRIC_REMINDER:-}" ]; then
  case "$CV_SEVERITY_RUBRIC_REMINDER" in
    *"unenforced precondition"*"current caller behavior"*"fix is local"*)
      echo "  PASS: rubric names the unenforced-precondition BLOCKING condition"
      ;;
    *)
      echo "  FAIL: rubric text missing the unenforced-precondition BLOCKING condition" >&2
      FAILURES=$((FAILURES+1))
      ;;
  esac
  case "$CV_SEVERITY_RUBRIC_REMINDER" in
    *"vacuously"*)
      echo "  PASS: rubric names the vacuous-acceptance BLOCKING condition"
      ;;
    *)
      echo "  FAIL: rubric text missing the vacuous-acceptance BLOCKING condition" >&2
      FAILURES=$((FAILURES+1))
      ;;
  esac
  case "$CV_SEVERITY_RUBRIC_REMINDER" in
    *"unmerged"*"stacked"*)
      echo "  PASS: rubric names the unstacked-dependency BLOCKING condition"
      ;;
    *)
      echo "  FAIL: rubric text missing the unstacked-dependency BLOCKING condition" >&2
      FAILURES=$((FAILURES+1))
      ;;
  esac
fi

start_case "both the security and acceptance lanes carry the rubric verbatim"
if [ -n "${CV_SEVERITY_RUBRIC_REMINDER:-}" ]; then
  assert_contains "$SECURITY_LANE" "$CV_SEVERITY_RUBRIC_REMINDER" \
    "main.security-review.md carries the shared severity rubric"
  assert_contains "$ACCEPTANCE_LANE" "$CV_SEVERITY_RUBRIC_REMINDER" \
    "main.acceptance-review.md carries the shared severity rubric"
fi

start_case "the synthesizer must not downgrade a lane's BLOCKING to LOW on intentional-per-plan grounds"
assert_contains "$SYNTHESIS" "must not downgrade a lane's BLOCKING finding to LOW" \
  "main.synthesize-review.md states the no-downgrade rule"
assert_contains "$SYNTHESIS" "intentional per plan" \
  "main.synthesize-review.md names the specific rationale it must not accept"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
