#!/usr/bin/env bash
# cv-review-outcome-always-pass.test.sh — every review-lane and the
# synthesize-review workflow step must close with a HARDCODED, literal
# gc.outcome=pass bash command — never prose alone — and the close
# instruction must say explicitly that gc.outcome stays 'pass' regardless of
# the lane's own verdict (fk-7w9y6).
#
# Two live incidents motivate this:
#   1. design-ux lane (fk-jvr9z) closed with gc.outcome=iterate, matching its
#      own verdict instead of the required constant. The file already had a
#      literal `--set-metadata 'gc.outcome=pass'` bash line, but nothing told
#      the agent that value never changes with the verdict — this test pins
#      an explicit "regardless of verdict" callout next to it.
#   2. synthesize-review bead fk-xyz7gb closed with NO gc.outcome key at all.
#      main.synthesize-review.md's pass-path close instruction was PROSE
#      ONLY ("Close with gc.outcome=pass, ...") with no literal bash command
#      to execute — this test requires every file in scope to carry the same
#      literal `bd update ... --set-metadata 'gc.outcome=pass'` bash line the
#      review lanes already use.
#
# Run:  bash tests/cv-review-outcome-always-pass.test.sh   (exit 0 => pass)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WORKFLOW_DIR="${MOLD_DIR}/pack/assets/workflows/con-voyage"

FILES=(
  main.acceptance-review.md
  main.api-platform-review.md
  main.code-review.md
  main.compliance-review.md
  main.data-db-review.md
  main.design-ux-review.md
  main.dev-ex-review.md
  main.documentation-review.md
  main.founder-cto-review.md
  main.marketing-review.md
  main.product-owner-review.md
  main.qa-test-review.md
  main.security-review.md
  main.simplicity-review.md
  main.sre-review.md
  main.standards-janitor-review.md
  main.synthesize-review.md
  main.test-evidence-review.md
)

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_literal_outcome_pass() {
  local file="$1"
  if grep -qE "set-metadata '?gc\.outcome=pass'?" "$file"; then
    echo "  PASS: $(basename "$file") has a literal gc.outcome=pass close command"
  else
    echo "  FAIL: $(basename "$file") has no literal gc.outcome=pass close command (prose alone is not enough)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

assert_regardless_of_verdict() {
  local file="$1"
  if grep -qiE "gc\.outcome.*(regardless|always|never).*verdict|regardless of (the )?verdict" "$file"; then
    echo "  PASS: $(basename "$file") states gc.outcome=pass holds regardless of verdict"
  else
    echo "  FAIL: $(basename "$file") never states gc.outcome=pass regardless of verdict" >&2
    FAILURES=$((FAILURES+1))
  fi
}

start_case "every review-lane and synthesize-review file carries a literal gc.outcome=pass close command"
for f in "${FILES[@]}"; do
  path="${WORKFLOW_DIR}/${f}"
  if [ ! -f "$path" ]; then
    echo "  FAIL: ${f} does not exist at ${path}" >&2
    FAILURES=$((FAILURES+1))
    continue
  fi
  assert_literal_outcome_pass "$path"
done

start_case "every review-lane and synthesize-review file states the rule holds regardless of verdict"
for f in "${FILES[@]}"; do
  path="${WORKFLOW_DIR}/${f}"
  [ -f "$path" ] || continue
  assert_regardless_of_verdict "$path"
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILURES: $FAILURES"
  exit 1
fi
