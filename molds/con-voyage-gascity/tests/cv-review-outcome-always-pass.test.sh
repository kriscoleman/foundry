#!/usr/bin/env bash
# cv-review-outcome-always-pass.test.sh — every review-lane and the
# synthesize-review workflow step must close through the deterministic
# cv-review-lane-close.sh enforcement point (fk-7w9y6 widened scope,
# 10-08 11:00Z) — never a bare `bd update`/`bd close` pair that merely
# recites gc.outcome=pass in prose or as a caller-supplied literal — and the
# close instruction must still say explicitly that gc.outcome stays 'pass'
# regardless of the lane's own verdict.
#
# Three live incidents motivate this:
#   1. design-ux lane (fk-jvr9z) closed with gc.outcome=iterate, matching its
#      own verdict instead of the required constant. The file already had a
#      literal `--set-metadata 'gc.outcome=pass'` bash line, but nothing told
#      the agent that value never changes with the verdict.
#   2. synthesize-review bead fk-xyz7gb closed with NO gc.outcome key at all.
#      main.synthesize-review.md's pass-path close instruction was PROSE
#      ONLY ("Close with gc.outcome=pass, ...") with no literal bash command
#      to execute.
#   3. fk-2l3c8i reproduced the same class of bug a third time after a
#      prose-only fix for (1)/(2) had already landed — a hardcoded callout is
#      still just text an agent can fail to apply. The only enforcement this
#      repo can own deterministically is to route every close through a
#      script that hardcodes gc.outcome=pass in its own body, so the stamped
#      value no longer depends on what bash the agent happens to type (see
#      tests/cv-review-lane-close.test.sh for the script's own unit coverage:
#      missing gc.outcome, a verdict-valued gc.outcome, and a genuine
#      failure that must still abort).
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

assert_deterministic_close() {
  local file="$1"
  if grep -qE "cv-review-lane-close\.sh" "$file"; then
    echo "  PASS: $(basename "$file") closes through cv-review-lane-close.sh (gc.outcome=pass is hardcoded there, not agent-typed)"
  else
    echo "  FAIL: $(basename "$file") does not invoke cv-review-lane-close.sh — a bare bd update/bd close here depends on the agent remembering to type gc.outcome=pass" >&2
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

start_case "every review-lane and synthesize-review file closes through cv-review-lane-close.sh"
for f in "${FILES[@]}"; do
  path="${WORKFLOW_DIR}/${f}"
  if [ ! -f "$path" ]; then
    echo "  FAIL: ${f} does not exist at ${path}" >&2
    FAILURES=$((FAILURES+1))
    continue
  fi
  assert_deterministic_close "$path"
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
