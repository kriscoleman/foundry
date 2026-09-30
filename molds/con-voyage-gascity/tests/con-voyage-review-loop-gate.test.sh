#!/usr/bin/env bash
# con-voyage-review-loop-gate.test.sh — structural test for fk-itiq6:
# main.con-voyage-review-loop.md's "reopen the completed review bead" re-run
# mechanics were prose only — nothing mechanically checked that this cycle's
# apply-review-findings bead had actually closed with a landed fix before
# lanes got reopened for the next cycle.
#
# CONFIRMED LIVE (fk-lhjn3 iteration 5, 2026-09-29): "iter6" lane review
# reports were (re)written 13-17 minutes after synthesis flagged a BLOCKING
# finding, while this cycle's own apply-review-findings bead (fk-f0z1n) did
# not even get claimed until ~4 hours later — 7 review lanes burned a full
# pass reviewing a commit nobody had touched yet.
#
# HOW IT WORKS: like con-voyage-sync-base.test.sh's "structural checks"
# section, this asserts the workflow markdown text itself (grep/line-order),
# since main.con-voyage-review-loop.md's body is interpreted by whichever
# agent runs the step, not executed as a standalone script.
#
# Run:  bash tests/con-voyage-review-loop-gate.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LOOP_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.con-voyage-review-loop.md"

if [ ! -f "$LOOP_MD" ]; then
  echo "FATAL: workflow file under test not found at ${LOOP_MD}" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

assert_md_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label (not found verbatim in ${file})"
  fi
}

md_line_of() {
  local file="$1" needle="$2"
  grep -nF -- "$needle" "$file" | head -1 | cut -d: -f1
}

start_case "review-loop.md: gates lane reopen on apply-review-findings closing pass + a landed fix (fk-itiq6)"
assert_md_contains "$LOOP_MD" '## Gate lane reopen on apply-review-findings landing a fix (fk-itiq6)' \
  "gate section exists"
assert_md_contains "$LOOP_MD" '[ "$apply_status" = "closed" ] && [ "$apply_outcome" = "pass" ]' \
  "gate requires the sibling apply-review-findings bead to be closed with gc.outcome=pass"
assert_md_contains "$LOOP_MD" '[ "$apply_verdict" = "done" ] || [ "$apply_fix_commit" != "-" ]' \
  "gate requires either a landed fix_commit or a genuine verdict=done no-op"
assert_md_contains "$LOOP_MD" 'gc mail send "$CV_LENS_ESCALATE_TARGET"' \
  "gate escalates via mail rather than reopening speculatively on timeout"

gate_line="$(md_line_of "$LOOP_MD" '## Gate lane reopen on apply-review-findings landing a fix')"
reopen_line="$(md_line_of "$LOOP_MD" 'gc bd reopen <review-bead>')"
if [ -n "$gate_line" ] && [ -n "$reopen_line" ] && [ "$gate_line" -lt "$reopen_line" ]; then
  pass "the gate (line ${gate_line}) precedes the actual reopen instruction (line ${reopen_line})"
else
  fail "expected the gate to precede the reopen instruction (gate=${gate_line:-<missing>}, reopen=${reopen_line:-<missing>})"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
