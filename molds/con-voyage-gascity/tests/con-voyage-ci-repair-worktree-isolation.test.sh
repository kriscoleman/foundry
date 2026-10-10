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
# review fk-80xk9s BLOCKING-3: the literal 'git worktree remove' call moved
# into con-voyage-lib.sh's shared cv_ci_repair_remove_worktree_if_owned —
# Step 7 now delegates to it instead of carrying its own inline removal.
if grep -q 'git worktree remove' "$CI_REPAIR_MD" \
  || grep -q 'cv_ci_repair_remove_worktree_if_owned "Step 7"' "$CI_REPAIR_MD"; then
  pass "a worktree cleanup step is present (inline or via the shared lib helper)"
else
  fail "no worktree cleanup found — the dedicated worktree would accumulate under worktrees/"
fi

start_case "5: worktree path is resolved from the rig root, not hardcoded"
if grep -q 'cv_default_rig_root' "$CI_REPAIR_MD"; then
  pass "cv_default_rig_root is used to resolve the rig root"
else
  fail "cv_default_rig_root not referenced — worktree path may be hardcoded/wrong for this rig"
fi

start_case "6: worktree path is keyed on {repair_bead}, not the never-substituted {convoy_id} token"
if grep -q 'worktrees/ci-repair-{repair_bead}' "$CI_REPAIR_MD"; then
  pass "worktree path is keyed on {repair_bead} (unique per repair, passed as a dispatch --var)"
else
  fail "worktree path is not keyed on {repair_bead} — may still use the never-substituted {convoy_id} token"
fi
if grep -q 'worktrees/ci-repair-{convoy_id}' "$CI_REPAIR_MD"; then
  fail "worktree path still contains the literal, never-substituted {convoy_id} token"
else
  pass "no lingering worktrees/ci-repair-{convoy_id} literal found"
fi

start_case "7: Step 3 detects and reuses an existing worktree already on {branch}"
if grep -q 'git worktree list --porcelain' "$CI_REPAIR_MD"; then
  pass "Step 3 inspects existing worktrees before attaching a new one"
else
  fail "Step 3 does not check for an existing worktree already on {branch} — git worktree add -B will collide with a long-lived source-anchor checkout"
fi

start_case "7b: Step 3's reuse match is default-deny, scoped to a dedicated ci-repair-* checkout (review fk-hbsmk BLOCKING-3, fk-9iqxnx BLOCKING-2)"
step3_section="$(awk '/^## Step 3/{p=1} /^## Step 4/{p=0} p' "$CI_REPAIR_MD")"
if printf '%s' "$step3_section" | grep -qF '"${RIG_ROOT}/worktrees/ci-repair-"*'; then
  pass "the accepted reuse pattern is scoped to \${RIG_ROOT}/worktrees/ci-repair-*, not any existing checkout"
else
  fail "Step 3's reuse match does not scope to \${RIG_ROOT}/worktrees/ci-repair-* — this would pass identically against the pre-fix, unscoped version"
fi
reuse_case_block="$(printf '%s' "$step3_section" | awk '/case "\$EXISTING_WORKTREE" in/{p=1} /esac/{print; p=0; next} p')"
if printf '%s' "$reuse_case_block" | grep -qF '*)' && printf '%s' "$reuse_case_block" | grep -A2 '^\s*\*)' | grep -q 'ci_repair_step3_fail'; then
  pass "the reuse case statement's default arm calls ci_repair_step3_fail, not a silent fallthrough"
else
  fail "the reuse case statement's default arm does not call ci_repair_step3_fail — an unrecognized existing checkout could be silently taken over"
fi

start_case "8: Step 3 failures route through bead close/escalation, not a bare exit"
# review fk-80xk9s BLOCKING-3: the literal cv_bead_close call moved into
# con-voyage-lib.sh's shared cv_ci_repair_abort — ci_repair_step3_fail now
# delegates to it (passing {repair_bead}) instead of calling cv_bead_close
# inline.
if printf '%s' "$step3_section" | grep -q 'cv_bead_close "{repair_bead}" abandoned' \
  || printf '%s' "$step3_section" | grep -q 'cv_ci_repair_abort "Step 3'; then
  pass "Step 3's failure path closes {repair_bead} as abandoned before exiting (inline or via the shared lib helper)"
else
  fail "Step 3's failure path does not close {repair_bead} — a Step 3 failure would strand the bead"
fi

start_case "8b: ci_repair_step3_fail and step4_abort both tear down a worktree they created, never one they reused (review fk-hbsmk BLOCKING-4)"
# review fk-80xk9s BLOCKING-3: the inline WORKTREE_REUSED-guarded
# `git worktree remove --force` was extracted into con-voyage-lib.sh's shared
# cv_ci_repair_abort / cv_ci_repair_remove_worktree_if_owned (verified against
# the actual guard logic in con-voyage-lib.test.sh) — this case now asserts
# each abort function delegates to it with its own WORKTREE/WORKTREE_REUSED,
# rather than re-asserting the guard text inline here.
step3_fail_body="$(printf '%s' "$step3_section" | awk '/^ci_repair_step3_fail\(\) \{/{p=1} p{print} p&&/^}/{exit}')"
if printf '%s' "$step3_fail_body" | grep -q 'cv_ci_repair_abort "Step 3' \
  && printf '%s' "$step3_fail_body" | grep -q '"\${WORKTREE:-}" "\${WORKTREE_REUSED:-false}"'; then
  pass "ci_repair_step3_fail delegates to the shared cv_ci_repair_abort with its own WORKTREE/WORKTREE_REUSED"
else
  fail "ci_repair_step3_fail does not delegate to cv_ci_repair_abort with WORKTREE/WORKTREE_REUSED — a Step 3 failure after worktree creation could leak it"
fi
step4_section_for_abort="$(awk '/^## Step 4/{p=1} /^## Step 7/{p=0} p' "$CI_REPAIR_MD")"
step4_abort_body="$(printf '%s' "$step4_section_for_abort" | awk '/^step4_abort\(\) \{/{p=1} p{print} p&&/^}/{exit}')"
if printf '%s' "$step4_abort_body" | grep -q 'cv_ci_repair_abort "Step 4' \
  && printf '%s' "$step4_abort_body" | grep -q '"\${WORKTREE:-}" "\${WORKTREE_REUSED:-false}"'; then
  pass "step4_abort delegates to the shared cv_ci_repair_abort with its own WORKTREE/WORKTREE_REUSED"
else
  fail "step4_abort does not delegate to cv_ci_repair_abort with WORKTREE/WORKTREE_REUSED — a Step 4 abort after Step 3 created a worktree could leak it"
fi

start_case "8c: step5_abort and step6_abort also delegate to the shared cv_ci_repair_abort (review fk-80xk9s BLOCKING-1/3)"
step5_section_for_abort="$(awk '/^## Step 5/{p=1} /^## Step 6/{p=0} p' "$CI_REPAIR_MD")"
step5_abort_body="$(printf '%s' "$step5_section_for_abort" | awk '/^step5_abort\(\) \{/{p=1} p{print} p&&/^}/{exit}')"
if printf '%s' "$step5_abort_body" | grep -q 'cv_ci_repair_abort "Step 5' \
  && printf '%s' "$step5_abort_body" | grep -q '"\${WORKTREE:-}" "\${WORKTREE_REUSED:-false}"'; then
  pass "step5_abort delegates to the shared cv_ci_repair_abort with its own WORKTREE/WORKTREE_REUSED"
else
  fail "step5_abort does not delegate to cv_ci_repair_abort with WORKTREE/WORKTREE_REUSED — a Step 5 abort after Step 3 created a worktree could leak it"
fi
step6_section_for_abort="$(awk '/^## Step 6/{p=1} /^## Step 7/{p=0} p' "$CI_REPAIR_MD")"
step6_abort_body="$(printf '%s' "$step6_section_for_abort" | awk '/^step6_abort\(\) \{/{p=1} p{print} p&&/^}/{exit}')"
if printf '%s' "$step6_abort_body" | grep -q 'cv_ci_repair_abort "Step 6' \
  && printf '%s' "$step6_abort_body" | grep -q '"\${WORKTREE:-}" "\${WORKTREE_REUSED:-false}"'; then
  pass "step6_abort delegates to the shared cv_ci_repair_abort with its own WORKTREE/WORKTREE_REUSED"
else
  fail "step6_abort does not delegate to cv_ci_repair_abort with WORKTREE/WORKTREE_REUSED — a Step 6 abort after Step 3 created a worktree could leak it"
fi

start_case "8d: Step 7 teardown and Failure/escalation both delegate to the shared helpers too (review fk-80xk9s BLOCKING-1/3)"
step7_section="$(awk '/^## Step 7/{p=1} /^## Failure/{p=0} p' "$CI_REPAIR_MD")"
if printf '%s' "$step7_section" | grep -q 'cv_ci_repair_resolve_worktree "\$REPAIR_BEAD_ID"' \
  && printf '%s' "$step7_section" | grep -q 'cv_ci_repair_remove_worktree_if_owned "Step 7"'; then
  pass "Step 7's teardown delegates to the shared resolve/remove-if-owned helpers"
else
  fail "Step 7's teardown does not delegate to the shared resolve/remove-if-owned helpers — regression risk for the reused-worktree guard"
fi
escalation_section="$(awk '/^## Failure/{p=1} /^Do not spin indefinitely/{p=0} p' "$CI_REPAIR_MD")"
if printf '%s' "$escalation_section" | grep -q 'cv_ci_repair_resolve_worktree "\$REPAIR_BEAD_ID"' \
  && printf '%s' "$escalation_section" | grep -q 'cv_ci_repair_abort "Failure/escalation"'; then
  pass "Failure/escalation delegates to the shared resolve/abort helpers"
else
  fail "Failure/escalation does not delegate to the shared resolve/abort helpers — regression risk for the reused-worktree guard"
fi

start_case "8e: the reused-worktree guard logic itself exists exactly once, in con-voyage-lib.sh, not duplicated across call sites (review fk-80xk9s BLOCKING-3)"
CV_LIB_FILE="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
if [ -f "$CV_LIB_FILE" ] && grep -q '^cv_ci_repair_remove_worktree_if_owned()' "$CV_LIB_FILE" \
  && grep -q '^cv_ci_repair_resolve_worktree()' "$CV_LIB_FILE" \
  && grep -q '^cv_ci_repair_abort()' "$CV_LIB_FILE"; then
  pass "con-voyage-lib.sh defines cv_ci_repair_resolve_worktree, cv_ci_repair_remove_worktree_if_owned, and cv_ci_repair_abort"
else
  fail "con-voyage-lib.sh is missing one or more of the shared ci-repair worktree helpers expected after the BLOCKING-3 extraction"
fi
inline_removal_hits="$(grep -c 'git worktree remove --force' "$CI_REPAIR_MD")"
if [ "$inline_removal_hits" -le 1 ]; then
  pass "main.ci-repair.md has at most one remaining inline 'git worktree remove --force' (the rest now route through the shared lib helpers)"
else
  fail "main.ci-repair.md still has ${inline_removal_hits} inline 'git worktree remove --force' call sites — the BLOCKING-3 extraction did not fully land"
fi

start_case "9: Step 4 re-anchors to the resolved worktree before any mutating command"
step4_section="$(awk '/^## Step 4/{p=1} /^## Step 7/{p=0} p' "$CI_REPAIR_MD")"
if printf '%s' "$step4_section" | grep -q 'cd "\$WORKTREE"'; then
  pass "a cd \"\$WORKTREE\" re-anchor appears between Step 4 and Step 7"
else
  fail "no cd \"\$WORKTREE\" (or equivalent re-anchor) found between Step 4 and Step 7 — a stale cwd from Step 3 could silently mutate the wrong checkout"
fi

start_case "10: ci_repair.worktree* stamp/read calls never key on the dead {convoy_id} token (review fk-hbsmk BLOCKING-1)"
# {convoy_id} is a gc-internal graph.v2 token never passed as a --var by
# either dispatch path, and this file is far above gc's inline-substitution
# size threshold, so a literal "{convoy_id}" as the bead-id argument to
# `gc bd update`/`gc bd show` is a permanent no-op that aborts every
# ci-repair run at the first stamp/read. Assert none of the four call sites
# that stamp or read the ci_repair.worktree* handoff key on {convoy_id}.
if grep -En '(gc bd (update|show)) "\{convoy_id\}"' "$CI_REPAIR_MD" | grep -q .; then
  ci_repair_worktree_convoy_hits="$(grep -n 'ci_repair\.worktree' "$CI_REPAIR_MD" | wc -l | tr -d ' ')"
  bad_hit=0
  while IFS=: read -r lineno _; do
    # Look at a small window after each dead-token call site for a
    # ci_repair.worktree* key — that's the regression this case guards.
    window="$(sed -n "${lineno},$((lineno+4))p" "$CI_REPAIR_MD")"
    if printf '%s' "$window" | grep -q 'ci_repair\.worktree'; then
      bad_hit=1
    fi
  done < <(grep -En '(gc bd (update|show)) "\{convoy_id\}"' "$CI_REPAIR_MD")
  if [ "$bad_hit" -eq 1 ]; then
    fail "a gc bd update/show call keyed on the dead {convoy_id} token touches ci_repair.worktree* metadata — this will abort every ci-repair run"
  else
    pass "no ci_repair.worktree* call sites key on the dead {convoy_id} token (unrelated pre-existing {convoy_id} uses elsewhere are out of this case's scope)"
  fi
else
  pass "no gc bd update/show call keys on the literal {convoy_id} token at all"
fi

start_case "11: ci_repair.worktree* stamp/read calls are keyed on {repair_bead} instead"
if grep -c 'gc bd update "\$REPAIR_BEAD_ID"' "$CI_REPAIR_MD" >/dev/null 2>&1 \
  && grep -q 'ci_repair\.worktree=' "$CI_REPAIR_MD" \
  && grep -q 'REPAIR_BEAD_ID="{repair_bead}"' "$CI_REPAIR_MD"; then
  pass "ci_repair.worktree* stamp/read call sites resolve the bead id from {repair_bead}"
else
  fail "ci_repair.worktree* stamp/read call sites do not appear to be keyed on {repair_bead}"
fi

start_case "12: Step 5 re-anchors to the resolved worktree on its own, independent of Step 4 (review fk-hbsmk BLOCKING-1, QA iteration 4)"
step5_section="$(awk '/^## Step 5/{p=1} /^## Step 6/{p=0} p' "$CI_REPAIR_MD")"
if printf '%s' "$step5_section" | grep -q 'cd "\$WORKTREE"' \
  && printf '%s' "$step5_section" | grep -q 'REPAIR_BEAD_ID="{repair_bead}"'; then
  pass "Step 5 re-reads ci_repair.worktree keyed on {repair_bead} and re-anchors with its own cd \"\$WORKTREE\""
else
  fail "Step 5 has no cwd re-anchor of its own — a fresh shell starting Step 5 at a stale cwd (e.g. the rig root) would run tests/lint against the wrong checkout"
fi

start_case "12b: Step 6 re-anchors to the resolved worktree on its own before commit/push (review fk-hbsmk BLOCKING-1, QA iteration 4)"
step6_section="$(awk '/^## Step 6/{p=1} /^## Step 7/{p=0} p' "$CI_REPAIR_MD")"
if printf '%s' "$step6_section" | grep -q 'cd "\$WORKTREE"' \
  && printf '%s' "$step6_section" | grep -q 'REPAIR_BEAD_ID="{repair_bead}"'; then
  pass "Step 6 re-reads ci_repair.worktree keyed on {repair_bead} and re-anchors with its own cd \"\$WORKTREE\" before git add/commit/push"
else
  fail "Step 6 has no cwd re-anchor of its own — a fresh shell starting Step 6 at a stale cwd (e.g. the rig root) would git push origin {branch} from the wrong checkout, reproducing the original fk-bjn2ba incident"
fi

start_case "13: Step 3's worktree-reuse fallback prunes stale/missing worktree registrations before recreating (review fk-80xk9s BLOCKING-2)"
step3_else_arm="$(printf '%s' "$step3_section" | awk '/^else$/{p=1} p{print} p&&/^fi$/{exit}')"
if printf '%s' "$step3_else_arm" | grep -q 'git worktree prune'; then
  pass "Step 3's else arm runs 'git worktree prune' before recreating the worktree"
else
  fail "Step 3's else arm does not run 'git worktree prune' — a worktree left in detached HEAD by a crashed rebase (Step 4b/4c's default strategy) would permanently strand every retry of the same repair bead with a 'missing but already registered worktree' error"
fi
if printf '%s' "$step3_else_arm" | grep -qE 'git worktree prune.*\n.*rm -rf "\$WORKTREE"' \
  || { pruneline="$(printf '%s' "$step3_else_arm" | grep -n 'git worktree prune' | head -1 | cut -d: -f1)"; \
       rmline="$(printf '%s' "$step3_else_arm" | grep -n 'rm -rf "\$WORKTREE"' | head -1 | cut -d: -f1)"; \
       [ -n "$pruneline" ] && [ -n "$rmline" ] && [ "$pruneline" -lt "$rmline" ]; }; then
  pass "'git worktree prune' runs before the 'rm -rf \"\$WORKTREE\"' fallback, not after"
else
  fail "'git worktree prune' does not precede 'rm -rf \"\$WORKTREE\"' — pruning after rm -rf cannot clear the stale registration before the next 'git worktree add'"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "${FAILURES} CASE(S) FAILED" >&2
  exit 1
fi
