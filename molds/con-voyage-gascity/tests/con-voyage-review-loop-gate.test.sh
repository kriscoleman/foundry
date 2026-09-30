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
# NOT 'gc mail send "$CV_LENS_ESCALATE_TARGET"' (fk-itiq6 review, BLOCKING-4):
# that literal string already existed pre-fix in the unrelated, pre-existing
# "Verify review-lane claims and re-dispatch stalled lenses" section further
# down this same file, so it would pass even if this gate's own escalation
# code were deleted outright. Match the gate's own escalation message text
# instead — unique to this section, so it only passes when the gate itself
# actually calls out to mail.
assert_md_contains "$LOOP_MD" 'has not landed a fix after' \
  "gate escalates via mail (its own escalation message) rather than reopening speculatively on timeout"

gate_line="$(md_line_of "$LOOP_MD" '## Gate lane reopen on apply-review-findings landing a fix')"
reopen_line="$(md_line_of "$LOOP_MD" 'gc bd reopen <review-bead>')"
if [ -n "$gate_line" ] && [ -n "$reopen_line" ] && [ "$gate_line" -lt "$reopen_line" ]; then
  pass "the gate (line ${gate_line}) precedes the actual reopen instruction (line ${reopen_line})"
else
  fail "expected the gate to precede the reopen instruction (gate=${gate_line:-<missing>}, reopen=${reopen_line:-<missing>})"
fi

start_case "review-loop.md: gate bead selection skips the paired scope-check latch bead (fk-itiq6 review, BLOCKING-1)"
assert_md_contains "$LOOP_MD" "meta.get('gc.kind') == 'scope-check'" \
  "gate selector explicitly skips gc.kind=scope-check beads before matching on gc.attempt/gc.step_id"
skip_line="$(md_line_of "$LOOP_MD" "meta.get('gc.kind') == 'scope-check'")"
select_line="$(md_line_of "$LOOP_MD" "meta.get('gc.attempt') != attempt or meta.get('gc.step_id') != step")"
if [ -n "$skip_line" ] && [ -n "$select_line" ] && [ "$skip_line" -lt "$select_line" ]; then
  pass "the scope-check skip (line ${skip_line}) runs before the attempt/step_id match (line ${select_line})"
else
  fail "expected the scope-check skip to precede the attempt/step_id match (skip=${skip_line:-<missing>}, match=${select_line:-<missing>})"
fi

start_case "review-loop.md: gate distinguishes a closed-without-a-landed-fix terminal state from still-waiting (fk-itiq6 review, BLOCKING-2)"
assert_md_contains "$LOOP_MD" 'closed without a landed fix' \
  "gate sends a distinct escalation when apply-review-findings closes without meeting the landed-fix condition"
terminal_line="$(md_line_of "$LOOP_MD" 'closed without a landed fix')"
landed_line="$(md_line_of "$LOOP_MD" 'safe to reopen lanes')"
if [ -n "$landed_line" ] && [ -n "$terminal_line" ] && [ "$landed_line" -lt "$terminal_line" ]; then
  pass "the landed-fix success check (line ${landed_line}) is evaluated before the terminal-failure branch (line ${terminal_line})"
else
  fail "expected the landed-fix check to precede the terminal-failure branch (landed=${landed_line:-<missing>}, terminal=${terminal_line:-<missing>})"
fi

start_case "review-loop.md: gate heartbeats its own bead and re-escalates periodically instead of once (fk-itiq6 review, BLOCKING-3)"
assert_md_contains "$LOOP_MD" 'gc bd update "$GC_BEAD_ID" --set-metadata "gc.review_gate.touched_at=' \
  "gate touches its own bead's metadata every poll (stall-watchdog heartbeat)"
assert_md_contains "$LOOP_MD" 'last_mailed_elapsed' \
  "gate tracks when it last mailed so it can re-escalate on an interval, not just once"
if grep -qF -- 'mailed=1' "$LOOP_MD"; then
  fail "gate must not fall back to a one-shot 'mailed=1' suppression flag"
else
  pass "gate does not use a one-shot 'mailed=1' suppression flag"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
