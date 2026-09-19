#!/usr/bin/env bash
# con-voyage-ci-repair-lifecycle.test.sh — content-check proof that the
# ci-repair workflow drives the REPAIR BEAD's own lifecycle (fk-7mw7 FIX-A),
# not just the gc-internal {{convoy_id}} work-item.
#
# ROOT CAUSE this guards against: con-voyage-pr-watch.sh mints a human-facing
# "Repair GitHub PR ..." bead (repair_bead_id) and slings the con-voyage-ci-repair
# formula onto it, but the formula's OWN steps only ever read/close
# {{convoy_id}} — a DIFFERENT, gc-internal work-item id for this step, not the
# repair bead itself. Every exit path in {target}.ci-repair.md closed
# {{convoy_id}} and left the real "Repair GitHub PR ..." bead open forever —
# the #1 driver of a batch of orphaned ko-*/va-* repair beads found in a live
# sweep. The fix threads a KNOWN {{repair_bead}} var through the mint (see
# tests/con-voyage-pr-watch.test.sh for that half) and wires the workflow to
# claim it on start and close it on every terminal exit via the new
# cv_bead_mark_in_progress/cv_bead_close helpers in con-voyage-lib.sh.
#
# HOW IT WORKS: this is a pure CONTENT check — {target}.ci-repair.md is an LLM
# prompt, not a script, so there is nothing to execute or stub (same approach
# as con-voyage-ci-repair-guard.test.sh's R1/R4/R6-R8 cases). We grep/sed the
# real, shipped prompt and formula files for the required wiring and ordering.
#
# Run:  bash tests/con-voyage-ci-repair-lifecycle.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
CI_REPAIR_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage-ci-repair/{target}.ci-repair.md"
CI_REPAIR_FORMULA="${MOLD_DIR}/pack/formulas/con-voyage-ci-repair.formula.toml"
CV_LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

if [ ! -f "$CI_REPAIR_MD" ]; then
  echo "FATAL: prompt file under test not found at ${CI_REPAIR_MD}" >&2
  exit 2
fi
if [ ! -f "$CI_REPAIR_FORMULA" ]; then
  echo "FATAL: formula file under test not found at ${CI_REPAIR_FORMULA}" >&2
  exit 2
fi
if [ ! -f "$CV_LIB" ]; then
  echo "FATAL: shared lib under test not found at ${CV_LIB}" >&2
  exit 2
fi

FAILURES=0
CASE_NAME=""
start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

# ===========================================================================
# CASE 1 — con-voyage-lib.sh actually defines the two helpers this suite
# assumes exist (a real regression here should fail loud, not be masked by a
# typo'd grep elsewhere in this file).
# ===========================================================================
start_case "1: con-voyage-lib.sh defines cv_bead_mark_in_progress and cv_bead_close"
if grep -q '^cv_bead_mark_in_progress()' "$CV_LIB"; then
  pass "cv_bead_mark_in_progress is defined"
else
  fail "cv_bead_mark_in_progress() not found in con-voyage-lib.sh"
fi
if grep -q '^cv_bead_close()' "$CV_LIB"; then
  pass "cv_bead_close is defined"
else
  fail "cv_bead_close() not found in con-voyage-lib.sh"
fi

# ===========================================================================
# CASE 2 — the formula documents {{repair_bead}} as an injected variable, and
# the prompt's Context variables table surfaces it (so an implementor reading
# the prompt sees where the id comes from).
# ===========================================================================
start_case "2: repair_bead is a documented formula variable"
if grep -q 'repair_bead' "$CI_REPAIR_FORMULA"; then
  pass "formula description documents repair_bead"
else
  fail "con-voyage-ci-repair.formula.toml does not mention repair_bead"
fi

start_case "2b: ci-repair.md Context variables table lists repair_bead"
ctx_line=$(grep -n '^## Context variables' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
step0_line=$(grep -n '^## Step 0 ' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
if [ -n "$ctx_line" ] && [ -n "$step0_line" ]; then
  ctx_body="$(sed -n "${ctx_line},${step0_line}p" "$CI_REPAIR_MD")"
  if printf '%s' "$ctx_body" | grep -q '{{repair_bead}}'; then
    pass "Context variables table lists {{repair_bead}}"
  else
    fail "Context variables table does not list {{repair_bead}}"
  fi
else
  fail "cannot slice the Context variables table — missing markers"
fi

# ===========================================================================
# CASE 3 — the repair bead is claimed (marked in_progress) BEFORE Step 0, so
# it never sits at READY while a worker is actively evaluating/working it.
# ===========================================================================
start_case "3: repair bead is claimed before Step 0's author gate"
claim_call_line=$(grep -n 'cv_bead_mark_in_progress "{{repair_bead}}"' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
step0_line=$(grep -n '^## Step 0 ' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
if [ -z "$claim_call_line" ]; then
  fail "no cv_bead_mark_in_progress \"{{repair_bead}}\" call found anywhere in ci-repair.md"
elif [ -z "$step0_line" ]; then
  fail "cannot find '## Step 0 ' heading to order against"
elif [ "$claim_call_line" -lt "$step0_line" ]; then
  pass "cv_bead_mark_in_progress runs before Step 0 (line ${claim_call_line} < ${step0_line})"
else
  fail "cv_bead_mark_in_progress (line ${claim_call_line}) does not precede Step 0 (line ${step0_line})"
fi

# ===========================================================================
# CASE 4 — Step 0's TWO drop exits (invalid pr, author mismatch) each close
# the repair bead, in addition to the existing {{convoy_id}} close.
# ===========================================================================
start_case "4: Step 0's drop exits close {{repair_bead}} (not just {{convoy_id}})"
step0_line=$(grep -n '^## Step 0 ' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
step0b_line=$(grep -n '^## Step 0b' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
if [ -n "$step0_line" ] && [ -n "$step0b_line" ]; then
  step0_body="$(sed -n "${step0_line},${step0b_line}p" "$CI_REPAIR_MD")"
  n_convoy=$(printf '%s' "$step0_body" | grep -c 'gc bd close "{{convoy_id}}"')
  n_repair=$(printf '%s' "$step0_body" | grep -c 'cv_bead_close "{{repair_bead}}"')
  assert_eq "2" "$n_convoy" "Step 0 still closes {{convoy_id}} at both drop exits (unchanged)"
  assert_eq "2" "$n_repair" "Step 0 also closes {{repair_bead}} at both drop exits"
  if printf '%s' "$step0_body" | grep -q 'cv_bead_close "{{repair_bead}}" abandoned'; then
    pass "Step 0's drop exits use outcome=abandoned"
  else
    fail "Step 0's repair-bead close does not use outcome=abandoned"
  fi
else
  fail "cannot slice Step 0's body — missing Step 0/Step 0b markers"
fi

# ===========================================================================
# CASE 5 — Step 0b's silent close (awaiting human review only) also closes
# the repair bead, and Step 0b stays PR-silent (no comment/mail) as before.
# ===========================================================================
start_case "5: Step 0b closes {{repair_bead}} and stays silent on the PR"
step0b_line=$(grep -n '^## Step 0b' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
step1_line=$(grep -n '^## Step 1' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
if [ -n "$step0b_line" ] && [ -n "$step1_line" ]; then
  step0b_body="$(sed -n "${step0b_line},${step1_line}p" "$CI_REPAIR_MD")"
  if printf '%s' "$step0b_body" | grep -q 'cv_bead_close "{{repair_bead}}"'; then
    pass "Step 0b closes {{repair_bead}}"
  else
    fail "Step 0b does not close {{repair_bead}}"
  fi
  if printf '%s' "$step0b_body" | grep -qE 'gh pr comment|gh pr review|gc mail send'; then
    fail "Step 0b must stay silent on the PR — found a comment/review/mail command"
  else
    pass "Step 0b still takes no GitHub action (silent close preserved)"
  fi
else
  fail "cannot slice Step 0b's body — missing Step 0b/Step 1 markers"
fi

# ===========================================================================
# CASE 6 — Step 7 (the shared close point for 4a success, 4b/4c resolved, and
# 4d's pending-checks/blocked sub-paths) also closes {{repair_bead}}.
# ===========================================================================
start_case "6: Step 7 closes {{repair_bead}} alongside {{convoy_id}}"
step7_line=$(grep -n '^## Step 7' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
failure_line=$(grep -n '^## Failure / escalation' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
if [ -n "$step7_line" ] && [ -n "$failure_line" ]; then
  step7_body="$(sed -n "${step7_line},${failure_line}p" "$CI_REPAIR_MD")"
  if printf '%s' "$step7_body" | grep -q 'gc bd close "{{convoy_id}}"'; then
    pass "Step 7 still closes {{convoy_id}} (unchanged)"
  else
    fail "Step 7 no longer closes {{convoy_id}}"
  fi
  if printf '%s' "$step7_body" | grep -q 'cv_bead_close "{{repair_bead}}"'; then
    pass "Step 7 also closes {{repair_bead}}"
  else
    fail "Step 7 does not close {{repair_bead}}"
  fi
else
  fail "cannot slice Step 7's body — missing Step 7/Failure markers"
fi

# ===========================================================================
# CASE 7 — the generic Failure/escalation catch-all (mail + exit 1) is the
# path that CURRENTLY closes nothing at all. It must now close BOTH beads so
# a "blocked-escalation" terminal outcome never orphans either one.
# ===========================================================================
start_case "7: Failure/escalation path closes BOTH the convoy and the repair bead"
failure_line=$(grep -n '^## Failure / escalation' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
if [ -n "$failure_line" ]; then
  failure_body="$(sed -n "${failure_line},\$p" "$CI_REPAIR_MD")"
  if printf '%s' "$failure_body" | grep -q 'gc bd close "{{convoy_id}}"'; then
    pass "Failure/escalation now closes {{convoy_id}}"
  else
    fail "Failure/escalation still never closes {{convoy_id}}"
  fi
  if printf '%s' "$failure_body" | grep -q 'cv_bead_close "{{repair_bead}}" abandoned'; then
    pass "Failure/escalation closes {{repair_bead}} with outcome=abandoned"
  else
    fail "Failure/escalation does not close {{repair_bead}} with outcome=abandoned"
  fi
  # The escalation mail must still fire BEFORE the beads are closed (a closed
  # bead's mail thread is still readable, but the mail describes an in-flight
  # problem — sending it after close reads as stale/contradictory).
  mail_line=$(printf '%s\n' "$failure_body" | grep -n 'gc mail send' | head -1 | cut -d: -f1)
  close_line=$(printf '%s\n' "$failure_body" | grep -n 'cv_bead_close "{{repair_bead}}"' | head -1 | cut -d: -f1)
  if [ -n "$mail_line" ] && [ -n "$close_line" ] && [ "$mail_line" -lt "$close_line" ]; then
    pass "escalation mail is sent before the repair bead is closed"
  else
    fail "escalation mail does not precede the repair-bead close (mail_line=${mail_line:-?}, close_line=${close_line:-?})"
  fi
else
  fail "cannot find '## Failure / escalation' heading"
fi

# ===========================================================================
# CASE 8 — every {{repair_bead}}-closing call site is reachable without
# assuming shared shell state from an earlier fenced block (this file's own
# established convention — see the repeated cv-worktree-prep.sh/cv-pr-comment.sh
# lookups in Steps 3/6 — is that each block re-derives what it needs). Proxy
# check: con-voyage-lib.sh is located/sourced at least as many times as there
# are cv_bead_close call sites, not just once at the top.
# ===========================================================================
start_case "8: each close site is self-contained (re-sources con-voyage-lib.sh)"
n_close_sites=$(grep -c 'cv_bead_close "{{repair_bead}}"' "$CI_REPAIR_MD")
n_lib_sources=$(grep -c 'name con-voyage-lib.sh' "$CI_REPAIR_MD")
if [ "$n_lib_sources" -ge "$n_close_sites" ]; then
  pass "con-voyage-lib.sh is located at least once per close site (${n_lib_sources} >= ${n_close_sites})"
else
  fail "con-voyage-lib.sh is located fewer times (${n_lib_sources}) than there are close sites (${n_close_sites}) — a block may assume state from an earlier one"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
