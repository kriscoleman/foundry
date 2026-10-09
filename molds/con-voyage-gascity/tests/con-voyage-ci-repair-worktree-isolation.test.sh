#!/usr/bin/env bash
# con-voyage-ci-repair-worktree-isolation.test.sh — content-check proof that
# ci-repair runs in a dedicated worktree, never the rig root (fk-bjn2ba).
#
# THE BUG (seen live 2026-10-09 ~21:50Z, repair va-pcqwf): ci-repair's Step 3
# told the worker to "work in the rig root" and `git checkout {branch}`
# there directly. That left rigs/vandoor (the rig ROOT checkout) on the PR
# branch with a stray commit, broke the sync-with-main invariant every other
# worker in the rig depends on, blocked the next con-voyage-rereview seed's
# `git worktree add -B <branch>` (fk-zhyz68 class — the branch was already
# checked out elsewhere), and left a `.beads/metadata.json` stash unpopped
# because the operator had to hand-stash local state to even switch branches.
#
# THE FIX: Step 3 now attaches a dedicated worktree under
# <rig-root>/worktrees/ keyed to this repair step's own bead id instead of
# checking out the PR branch in place, and Step 7 tears that worktree down on
# every terminal close path. This is a pure CONTENT check — main.ci-repair.md
# is an LLM prompt, not a script, so there is nothing to execute (same
# approach as con-voyage-ci-repair-lifecycle.test.sh).
#
# Run:  bash tests/con-voyage-ci-repair-worktree-isolation.test.sh   (exit 0 => pass)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
CI_REPAIR_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage-ci-repair/main.ci-repair.md"

if [ ! -f "$CI_REPAIR_MD" ]; then
  echo "FATAL: prompt file under test not found at ${CI_REPAIR_MD}" >&2
  exit 2
fi

FAILURES=0
CASE_NAME=""
start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

start_case "1: Step 3 no longer instructs working in the rig root"
if grep -Eqi '^Work in the rig root' "$CI_REPAIR_MD"; then
  fail "main.ci-repair.md still tells the worker to work in the rig root"
else
  pass "no 'Work in the rig root' instruction found"
fi

start_case "2: Step 3 attaches a dedicated worktree under <rig-root>/worktrees/"
if grep -q 'worktrees/ci-repair-' "$CI_REPAIR_MD" && grep -q 'git worktree add' "$CI_REPAIR_MD"; then
  pass "a dedicated worktrees/ci-repair-<id> worktree is created via git worktree add"
else
  fail "no dedicated worktrees/ci-repair-<id> worktree creation found"
fi

start_case "3: never instructs stashing local state to free up a checkout"
if grep -q 'git stash' "$CI_REPAIR_MD"; then
  fail "main.ci-repair.md instructs 'git stash' — a dedicated worktree should never need this"
else
  pass "no 'git stash' instruction found"
fi

start_case "4: Step 7 tears the dedicated worktree down on close"
if grep -q 'git worktree remove' "$CI_REPAIR_MD"; then
  pass "a 'git worktree remove' cleanup step is present"
else
  fail "no 'git worktree remove' cleanup found — the dedicated worktree would accumulate under worktrees/"
fi

start_case "5: worktree path is resolved from the rig root, not hardcoded"
if grep -q 'cv_default_rig_root' "$CI_REPAIR_MD"; then
  pass "cv_default_rig_root is used to resolve the rig root"
else
  fail "cv_default_rig_root not referenced — worktree path may be hardcoded/wrong for this rig"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "${FAILURES} CASE(S) FAILED" >&2
  exit 1
fi
