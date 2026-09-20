#!/usr/bin/env bash
# agents-contract.test.sh — hermetic, offline test for the pack's AGENTS.md
# system contract (PR #45 human review, fk-8ymb). Review asked: how does the
# contract make sure agents/workers are aware of the larger system and know
# when to mail the mayor that something is wrong — and that this applies to
# every worker type the pack dispatches, not just the TDD implementor.
#
# Asserts the communal-duty section (a) names every worker type by the
# reviewer's own terms — one-off worker, formula, order, convoy — so none of
# them can read "the implementor" and conclude the duty is someone else's job,
# and (b) gives a concrete escalation mechanism (mail the mayor) instead of
# leaving "surface it" undefined.
#
# Run:  bash tests/agents-contract.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
AGENTS_MD="${MOLD_DIR}/AGENTS.md"

if [ ! -f "$AGENTS_MD" ]; then
  echo "FATAL: contract file not found at ${AGENTS_MD}" >&2
  exit 2
fi

FAILURES=0
assert_match() {
  local pattern="$1" msg="$2"
  if grep -q -E -- "$pattern" "$AGENTS_MD"; then
    echo "  PASS: $msg"
  else
    echo "  FAIL: $msg (no match for /${pattern}/ in ${AGENTS_MD})" >&2
    FAILURES=$((FAILURES+1))
  fi
}
start_case() { echo; echo "=== CASE: $1 ==="; }

start_case "communal duty names every worker type the pack dispatches"
assert_match 'one-off worker' "names the one-off worker"
assert_match 'formula' "names the formula"
assert_match '\border\b' "names the order"
assert_match 'convoy' "names the convoy"

start_case "communal duty gives a concrete escalation mechanism"
assert_match 'mayor' "mentions the mayor"
assert_match 'mail' "mentions mailing as the mechanism"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
