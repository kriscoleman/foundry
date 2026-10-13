#!/usr/bin/env bash
# cv-pr-verdict-section.test.sh — hermetic unit tests for the PR-body review
# verdict renderer (fk-db9yc3). The "Con-voyage review verdict: APPROVED"
# section con-voyage writes into PR bodies used to be a loud H2 heading +
# roster paragraph + numbered LOW list + "Not auto-merged" line at full
# visibility. cv_render_pr_verdict_section/cv_set_pr_verdict_section collapse
# it into a single <details> block (verdict word stays in the <summary> so
# it's visible collapsed) without changing the content, and make a later
# round's update replace the existing block in place rather than duplicating
# it.
#
# Run:  bash tests/cv-pr-verdict-section.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: lib under test not found at ${LIB}" >&2
  exit 2
fi

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

FAILURES=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3 (=$1)"; else echo "  FAIL: $3 (expected '$1', got '$2')" >&2; FAILURES=$((FAILURES+1)); fi
}
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$1"; then echo "  PASS: $3"; else echo "  FAIL: $3 (expected to find '$1' in: $2)" >&2; FAILURES=$((FAILURES+1)); fi
}
assert_not_contains() {
  if printf '%s' "$2" | grep -qF -- "$1"; then echo "  FAIL: $3 (did not expect to find '$1' in: $2)" >&2; FAILURES=$((FAILURES+1)); else echo "  PASS: $3"; fi
}
start_case() { echo; echo "=== CASE: $1 ==="; }

ROSTER_CONTENT="Active reviewer roster: code-review, security, simplicity, qa-test.
Review cycles completed: 2.

1. [LOW] use a const instead of a magic number (qa-test)

Not auto-merged — a human lands this PR."

start_case "cv_render_pr_verdict_section: APPROVED wraps content in a single collapsed details block"
RENDERED="$(cv_render_pr_verdict_section "APPROVED" "$ROSTER_CONTENT")"
assert_contains "<summary>Con-voyage review verdict: APPROVED</summary>" "$RENDERED" "summary carries the verdict word so it is visible collapsed"
assert_contains "<details>" "$RENDERED" "wraps in a <details> block"
assert_contains "</details>" "$RENDERED" "closes the <details> block"
assert_not_contains "## Con-voyage review verdict" "$RENDERED" "no H2 heading remains"
assert_contains "Active reviewer roster: code-review, security, simplicity, qa-test." "$RENDERED" "roster line preserved as-is"
assert_contains "1. [LOW] use a const instead of a magic number (qa-test)" "$RENDERED" "numbered LOW list preserved as-is"
assert_contains "Not auto-merged" "$RENDERED" "not-auto-merged line preserved as-is"
assert_eq "1" "$(printf '%s' "$RENDERED" | grep -c '<details>')" "exactly one details block"

start_case "cv_render_pr_verdict_section: BLOCKED verdict uses the same collapsed pattern"
BLOCKED_RENDERED="$(cv_render_pr_verdict_section "BLOCKED" "Some blocking finding remains.")"
assert_contains "<summary>Con-voyage review verdict: BLOCKED</summary>" "$BLOCKED_RENDERED" "BLOCKED verdict renders in the summary"

start_case "cv_set_pr_verdict_section: first write appends the block once to a body with no existing marker"
PR_BODY_BASE="## Summary

Does the thing."
NEW_BODY="$(cv_set_pr_verdict_section "$PR_BODY_BASE" "APPROVED" "$ROSTER_CONTENT")"
assert_contains "## Summary" "$NEW_BODY" "original body content retained"
assert_contains "<summary>Con-voyage review verdict: APPROVED</summary>" "$NEW_BODY" "verdict section appended"
assert_eq "1" "$(printf '%s' "$NEW_BODY" | grep -c -- '<!-- con-voyage-pr-verdict:start -->')" "exactly one start marker after first write"

start_case "cv_set_pr_verdict_section: a later round replaces the existing block instead of duplicating it"
ROUND2_CONTENT="Active reviewer roster: code-review, security.
Review cycles completed: 3.

Not auto-merged — a human lands this PR."
REWRITTEN_BODY="$(cv_set_pr_verdict_section "$NEW_BODY" "APPROVED" "$ROUND2_CONTENT")"
assert_contains "## Summary" "$REWRITTEN_BODY" "original body content still retained across a re-write"
assert_eq "1" "$(printf '%s' "$REWRITTEN_BODY" | grep -c -- '<!-- con-voyage-pr-verdict:start -->')" "still exactly one start marker after a second write"
assert_eq "1" "$(printf '%s' "$REWRITTEN_BODY" | grep -c '<details>')" "still exactly one details block after a second write"
assert_contains "Review cycles completed: 3." "$REWRITTEN_BODY" "round 2 content present"
assert_not_contains "Review cycles completed: 2." "$REWRITTEN_BODY" "round 1 content fully replaced, not appended alongside"

start_case "cv_set_pr_verdict_section: a later round can change the verdict word itself"
REBLOCKED_BODY="$(cv_set_pr_verdict_section "$REWRITTEN_BODY" "BLOCKED" "A new blocking finding was raised.")"
assert_contains "<summary>Con-voyage review verdict: BLOCKED</summary>" "$REBLOCKED_BODY" "verdict word updates on re-write"
assert_not_contains "Con-voyage review verdict: APPROVED" "$REBLOCKED_BODY" "stale APPROVED summary is gone"
assert_eq "1" "$(printf '%s' "$REBLOCKED_BODY" | grep -c -- '<!-- con-voyage-pr-verdict:start -->')" "exactly one start marker after a verdict change"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
