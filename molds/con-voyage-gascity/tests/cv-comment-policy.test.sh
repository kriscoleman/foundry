#!/usr/bin/env bash
# cv-comment-policy.test.sh — hermetic, offline test that the shared
# code-comment policy reaches every code-writing con-voyage step, and that
# the reviewer side (floor lanes + standards-janitor) flags unwarranted new
# comments as BLOCKING.
#
# THE GAP (operator directive 2026-10-13, fk-qc3yua): con-voyage workers left
# far too many code comments. Policy: default to NO new comments; a comment
# is only warranted when the code does something exceedingly special or
# unexpected that isn't obvious from the code itself (the WHY, never the
# WHAT). Code-WRITING steps (main.build.md, main.apply-review-findings.md,
# main.ci-repair.md, and the PR-feedback worker body con-voyage-pr-watch.sh
# routes) carried no comment rule at all. On the reviewer side, only
# cv-standards-janitor's item 6 "Comment bloat" covered this, as an OPTIONAL
# lens graded LOW "unless egregious" — nothing in the DEFAULT roster sent
# comment noise back. This suite asserts: every writer surface carries the
# shared policy by reference (a single constant, not pasted per-surface, same
# DRY convention as CV_COMMUNAL_DUTY_REMINDER); the floor code-review and
# simplicity-review lanes flag an unwarranted new comment BLOCKING; and
# cv-standards-janitor's comment-bloat item is BLOCKING, not LOW.
#
# Run:  bash tests/cv-comment-policy.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
WORKFLOWS_DIR="${MOLD_DIR}/pack/assets/workflows/con-voyage"
CI_REPAIR_WORKFLOWS_DIR="${MOLD_DIR}/pack/assets/workflows/con-voyage-ci-repair"
AGENTS_DIR="${MOLD_DIR}/pack/agents"

BUILD_STEP="${WORKFLOWS_DIR}/main.build.md"
APPLY_REVIEW_STEP="${WORKFLOWS_DIR}/main.apply-review-findings.md"
CI_REPAIR_STEP="${CI_REPAIR_WORKFLOWS_DIR}/main.ci-repair.md"
CODE_REVIEW_LANE="${WORKFLOWS_DIR}/main.code-review.md"
SIMPLICITY_REVIEW_LANE="${WORKFLOWS_DIR}/main.simplicity-review.md"
STANDARDS_JANITOR="${AGENTS_DIR}/cv-standards-janitor/prompt.template.md"

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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $label ($file does not exist)" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  if grep -qF -- "$needle" "$file"; then
    echo "  FAIL: $label (still found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: $label"
  fi
}

start_case "the shared comment-policy constant is defined"
if [ -z "${CV_COMMENT_POLICY_REMINDER:-}" ]; then
  echo "  FAIL: CV_COMMENT_POLICY_REMINDER is not defined by ${LIB}" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: CV_COMMENT_POLICY_REMINDER is defined"
fi

start_case "the constant states the default-no-comments rule and the WHY-not-WHAT test"
if [ -n "${CV_COMMENT_POLICY_REMINDER:-}" ]; then
  case "$CV_COMMENT_POLICY_REMINDER" in
    *"NO new comments"*)
      echo "  PASS: constant states the default-no-new-comments rule" ;;
    *)
      echo "  FAIL: constant text missing the default-no-new-comments rule" >&2
      FAILURES=$((FAILURES+1)) ;;
  esac
  case "$CV_COMMENT_POLICY_REMINDER" in
    *"WHY"*"WHAT"*)
      echo "  PASS: constant states the WHY-never-WHAT test" ;;
    *)
      echo "  FAIL: constant text missing the WHY-never-WHAT test" >&2
      FAILURES=$((FAILURES+1)) ;;
  esac
fi

start_case "every code-writing step carries the shared comment policy"
if [ -n "${CV_COMMENT_POLICY_REMINDER:-}" ]; then
  assert_contains "$BUILD_STEP" "$CV_COMMENT_POLICY_REMINDER" \
    "main.build.md carries the comment policy"
  assert_contains "$APPLY_REVIEW_STEP" "$CV_COMMENT_POLICY_REMINDER" \
    "main.apply-review-findings.md carries the comment policy"
  assert_contains "$CI_REPAIR_STEP" "$CV_COMMENT_POLICY_REMINDER" \
    "main.ci-repair.md carries the comment policy"
fi

start_case "the routed PR-feedback bead body (con-voyage-pr-watch.sh) includes the comment policy"
if [ -n "${CV_COMMENT_POLICY_REMINDER:-}" ] && declare -f cv_build_pr_feedback_body >/dev/null 2>&1; then
  sample_body="$(cv_build_pr_feedback_body \
    "https://github.com/acme/widgets/pull/1" "fix/example" \
    "  [comment] @reviewer: an example finding  [id:1]" "test-key")"
  case "$sample_body" in
    *"${CV_COMMENT_POLICY_REMINDER}"*)
      echo "  PASS: cv_build_pr_feedback_body output includes the comment policy" ;;
    *)
      echo "  FAIL: cv_build_pr_feedback_body output is missing the comment policy" >&2
      FAILURES=$((FAILURES+1)) ;;
  esac
else
  echo "  FAIL: cv_build_pr_feedback_body is not defined by ${LIB}, or constant missing" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "the code-review floor lane flags an unwarranted new comment as BLOCKING with no optional lens required"
assert_contains "$CODE_REVIEW_LANE" "BLOCKING" "main.code-review.md still tags findings BLOCKING/LOW"
assert_contains "$CODE_REVIEW_LANE" "unwarranted" \
  "main.code-review.md names unwarranted new comments explicitly"

start_case "the simplicity-review floor lane also flags an unwarranted new comment as BLOCKING"
assert_contains "$SIMPLICITY_REVIEW_LANE" "unwarranted" \
  "main.simplicity-review.md names unwarranted new comments explicitly"

start_case "cv-standards-janitor's comment-bloat item is BLOCKING, not LOW"
assert_contains "$STANDARDS_JANITOR" "Comment bloat" \
  "cv-standards-janitor still carries the Comment bloat item"
assert_not_contains "$STANDARDS_JANITOR" \
  "LOW severity unless egregious" \
  "cv-standards-janitor no longer grades comment bloat LOW-unless-egregious"
BLOAT_BLOCK="$(awk '/Comment bloat/{flag=1} flag{print; if (/^[0-9]+\. \*\*/ && !/Comment bloat/) exit}' "$STANDARDS_JANITOR")"
case "$BLOAT_BLOCK" in
  *"BLOCKING"*)
    echo "  PASS: the Comment bloat item itself states BLOCKING" ;;
  *)
    echo "  FAIL: the Comment bloat item does not state BLOCKING" >&2
    FAILURES=$((FAILURES+1)) ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
