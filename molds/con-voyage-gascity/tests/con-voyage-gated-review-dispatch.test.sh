#!/usr/bin/env bash
# con-voyage-gated-review-dispatch.test.sh — structural test for fk-jg6rm:
# a con-voyage whose build fails kept reviewing anyway, and a review loop
# whose root had already been abandoned mid-review kept minting fresh
# iterations (root fk-viqoe/fk-zoedy, 2026-10-03: 4 failed build attempts
# still dispatched code-review + security-review lanes with no review
# context on disk; the mayor's abandon at 00:46Z still left a loop
# controller minting iteration.2 at 00:42Z/claimed after).
#
# DO (per the bead):
#   (a) the review phase is gated on a PASSED build — a build that ends in
#       fail closes the whole workflow as a terminal state and mails the
#       mayor once, dispatching no review lanes.
#   (b) every step that dispatches or iterates (review-loop controller, lane
#       dispatch, synthesis, apply-findings) checks the root first; a
#       closed root means it closes itself (and sweeps pending
#       descendants) and mints nothing. The mayor also gets a one-call
#       abandon entry point (cv-abandon-workflow.sh, tested separately).
#
# HOW IT WORKS: like con-voyage-review-loop-gate.test.sh, this asserts the
# workflow markdown text itself (grep + line-order) — these files are
# interpreted by whichever agent runs the step, not executed as a script.
#
# Run:  bash tests/con-voyage-gated-review-dispatch.test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WF_DIR="${MOLD_DIR}/pack/assets/workflows/con-voyage"
BUILD_MD="${WF_DIR}/main.build.md"
SETUP_MD="${WF_DIR}/main.setup-con-voyage-review.md"
LOOP_MD="${WF_DIR}/main.con-voyage-review-loop.md"
SYNTH_MD="${WF_DIR}/main.synthesize-review.md"
APPLY_MD="${WF_DIR}/main.apply-review-findings.md"
REREVIEW_SEED_MD="${WF_DIR}/main.rereview-seed.md"

for f in "$BUILD_MD" "$SETUP_MD" "$LOOP_MD" "$SYNTH_MD" "$APPLY_MD" "$REREVIEW_SEED_MD"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: workflow file under test not found at ${f}" >&2
    exit 2
  fi
done

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label (not found verbatim in ${file})"
  fi
}

line_of() {
  local file="$1" needle="$2"
  grep -nF -- "$needle" "$file" | head -1 | cut -d: -f1
}

assert_order() {
  local file="$1" first="$2" second="$3" label="$4"
  local l1 l2
  l1="$(line_of "$file" "$first")"
  l2="$(line_of "$file" "$second")"
  if [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ]; then
    pass "$label (line ${l1} < ${l2})"
  else
    fail "$label (first=${l1:-<missing>}, second=${l2:-<missing>})"
  fi
}

# ===========================================================================
# (a) main.build.md: a terminal build failure abandons the whole workflow and
#     mails the mayor exactly once, instead of letting downstream steps
#     discover the failure on their own.
# ===========================================================================
start_case "build.md: closing with gc.outcome=fail abandons the workflow root (fk-jg6rm)"
assert_contains "$BUILD_MD" '## Abandon the workflow on a terminal build failure (fk-jg6rm)' \
  "a dedicated section exists for the fail path"
assert_contains "$BUILD_MD" "cv_close_workflow_root \"\$ROOT_ID\"" \
  "the fail path tears down the whole workflow tree via cv_close_workflow_root"
assert_contains "$BUILD_MD" 'gc.build.failure_mail_sent' \
  "the fail path dedups its mayor mail with its own metadata flag, not reusing the sync-conflict flag"
assert_order "$BUILD_MD" '## Abandon the workflow on a terminal build failure (fk-jg6rm)' '## Close' \
  "the abandon-on-fail section precedes the generic Close section"

start_case "build.md: a root already closed before this build attempt even starts mints nothing (fk-jg6rm)"
assert_contains "$BUILD_MD" '## Fail fast if the workflow root is already closed (fk-jg6rm)' \
  "a root-closed entry guard exists"
assert_contains "$BUILD_MD" "cv_close_workflow_root \"\$ROOT_ID\" \"workflow root already closed" \
  "the entry guard sweeps any pending descendants instead of just exiting"
assert_order "$BUILD_MD" '## Fail fast if the workflow root is already closed (fk-jg6rm)' '## Sync the worktree to the current base' \
  "the root-closed entry guard runs before any worktree sync/build work"

# ===========================================================================
# (b) main.setup-con-voyage-review.md: the existing build-outcome skip now
#     also sweeps the whole tree (a freshly-minted later iteration can appear
#     after this bead's own existence, per the fk-viqoe precedent of a
#     closed root still spawning a fresh iteration-2 bead), plus its own
#     independent root-closed guard.
# ===========================================================================
start_case "setup-con-voyage-review.md: a root-closed guard exists ahead of any review-context gathering (fk-jg6rm)"
assert_contains "$SETUP_MD" '## Fail fast if the workflow root is already closed (fk-jg6rm)' \
  "a root-closed entry guard exists"
assert_order "$SETUP_MD" '## Fail fast if the workflow root is already closed (fk-jg6rm)' '## Resolve the journey'"'"'s base branch' \
  "the root-closed guard runs before resolving the journey base branch"

start_case "setup-con-voyage-review.md: the build-outcome skip now also abandons the whole tree, not just itself (fk-jg6rm)"
assert_contains "$SETUP_MD" "cv_close_workflow_root \"\$ROOT_ID\" \"build outcome=\${BUILD_OUTCOME}" \
  "the build-outcome skip now sweeps the whole workflow tree"

# ===========================================================================
# (b) main.con-voyage-review-loop.md: gated on a passed setup, checks the
#     root before every fan-out, and checks it again before reopening lanes
#     for the next cycle (the exact fk-viqoe iteration-2-after-abandon gap).
# ===========================================================================
start_case "con-voyage-review-loop.md: gated on setup-con-voyage-review having passed (fk-jg6rm)"
assert_contains "$LOOP_MD" '## Fail fast if the workflow root is already closed, or setup did not pass (fk-jg6rm)' \
  "an entry guard exists covering both a closed root and a failed/skipped setup"
assert_contains "$LOOP_MD" 'cv_dependency_outcome "$GC_BEAD_ID" "Prepare con-voyage review context"' \
  "the setup-outcome check reuses cv_dependency_outcome against setup's own title, same idiom as build.md/setup.md"
assert_contains "$LOOP_MD" "cv_close_workflow_root \"\$ROOT_ID\"" \
  "the entry guard abandons the workflow instead of letting lanes fan out anyway"
assert_order "$LOOP_MD" '## Fail fast if the workflow root is already closed, or setup did not pass (fk-jg6rm)' '## Gate lane reopen on apply-review-findings landing a fix (fk-itiq6)' \
  "the entry guard precedes the existing lane-reopen gate"

start_case "con-voyage-review-loop.md: a root abandoned mid-review stops the NEXT cycle's lane reopen, not just the first fan-out (fk-jg6rm)"
assert_contains "$LOOP_MD" '## Abort the cycle if the workflow root was abandoned mid-review (fk-jg6rm)' \
  "a dedicated mid-review abort check exists for the lane-reopen path"
assert_order "$LOOP_MD" '## Abort the cycle if the workflow root was abandoned mid-review (fk-jg6rm)' 'gc bd reopen <review-bead>' \
  "the mid-review root-closed check precedes the actual lane reopen instruction"
assert_order "$LOOP_MD" '## Gate lane reopen on apply-review-findings landing a fix (fk-itiq6)' '## Abort the cycle if the workflow root was abandoned mid-review (fk-jg6rm)' \
  "the mid-review check runs after the existing landed-fix gate (both must pass before reopening)"

# ===========================================================================
# (b) main.synthesize-review.md and main.apply-review-findings.md: each
#     checks the root before doing its own iterating work.
# ===========================================================================
start_case "synthesize-review.md: a root-closed guard exists ahead of reading review lane reports (fk-jg6rm)"
assert_contains "$SYNTH_MD" '## Fail fast if the workflow root is already closed (fk-jg6rm)' \
  "a root-closed entry guard exists"
assert_contains "$SYNTH_MD" "cv_close_workflow_root \"\$ROOT_ID\"" \
  "the guard abandons the workflow instead of synthesizing a review of nothing"
assert_order "$SYNTH_MD" '## Fail fast if the workflow root is already closed (fk-jg6rm)' 'Read all active review lane reports.' \
  "the guard runs before reading any lane reports"

start_case "apply-review-findings.md: a root-closed guard exists ahead of resolving the target worktree (fk-jg6rm)"
assert_contains "$APPLY_MD" '## Fail fast if the workflow root is already closed (fk-jg6rm)' \
  "a root-closed entry guard exists"
assert_contains "$APPLY_MD" "cv_close_workflow_root \"\$ROOT_ID\"" \
  "the guard abandons the workflow instead of applying findings to an abandoned run"
assert_order "$APPLY_MD" '## Fail fast if the workflow root is already closed (fk-jg6rm)' '## Resolve the target worktree (review fk-hbsmk B1)' \
  "the guard runs before resolving the target worktree"

start_case "rereview-seed.md: a SEED_FAIL closes the step bead and sweeps the workflow root unconditionally, not gated solely on CV_LIB resolving (fk-zhyz68)"
assert_contains "$REREVIEW_SEED_MD" 'bd close "$CLAIMED_BEAD_ID" --reason "Re-review seed failed: ${SEED_FAIL}"' \
  "the step bead is closed on SEED_FAIL"
assert_contains "$REREVIEW_SEED_MD" "cv_close_workflow_root \"\$ROOT_ID\"" \
  "a SEED_FAIL sweeps the whole workflow tree via cv_close_workflow_root when CV_LIB resolves"
assert_contains "$REREVIEW_SEED_MD" "con-voyage-lib.sh not resolved — cannot mail the mayor or run cv_close_workflow_root; falling back to a direct bd close sweep" \
  "an unresolved CV_LIB falls back to a direct bd close sweep of descendants instead of silently doing nothing"
assert_order "$REREVIEW_SEED_MD" 'bd close "$CLAIMED_BEAD_ID" --reason "Re-review seed failed: ${SEED_FAIL}"' 'cv_with_timeout 30 gc mail send mayor -s "con-voyage rereview-seed failed' \
  "the step bead's own close runs ahead of (outside) the CV_LIB-gated mail/sweep branch"

start_case "rereview-seed.md: the CV_LIB-unresolved fallback closes the workflow ROOT itself, not just its descendants (review fk-pwbxc7 BLOCKING-1)"
assert_contains "$REREVIEW_SEED_MD" 'bd close "$ROOT_ID" --reason "con-voyage rereview-seed failed (${CLAIMED_BEAD_ID}): ${SEED_FAIL}; closing workflow root (con-voyage-lib.sh unresolved, cv_close_workflow_root unavailable)"' \
  "the fallback branch closes the root bead, mirroring cv_close_workflow_root's own contract instead of leaving the gc.kind=workflow latch open"
assert_order "$REREVIEW_SEED_MD" 'con-voyage rereview-seed: WARNING: could not close descendant ${DESC_ID} during fallback sweep' 'bd close "$ROOT_ID" --reason "con-voyage rereview-seed failed (${CLAIMED_BEAD_ID}): ${SEED_FAIL}; closing workflow root' \
  "the root is closed only after the descendant sweep loop, matching cv_close_workflow_root's own 'close the root LAST' ordering"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
