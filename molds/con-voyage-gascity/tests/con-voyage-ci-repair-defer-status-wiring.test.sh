#!/usr/bin/env bash
# con-voyage-ci-repair-defer-status-wiring.test.sh — content-check proof that
# ci-repair's routine conflict-resolution summary defers into the next
# aggregated review comment instead of posting its own top-level PR comment
# (fk-shpd87: PR noise reduction design doc, slice B, AC3+AC4).
#
# HOW IT WORKS: {target}.ci-repair.md and main.rereview-finalize.md are LLM
# prompts, not scripts, so there is nothing to execute or stub (same approach
# as con-voyage-ci-repair-lifecycle.test.sh / con-voyage-ci-repair-guard.test.sh).
# We grep/sed the real, shipped prompt files for the required wiring:
#   - AC3: the 4b (merge_conflict) resolution summary defers via
#     cv_defer_status_append instead of a fresh PR comment.
#   - AC4: the 4d branch-protection escalation still posts a PR comment and
#     mails the mayor immediately, unchanged.
#   - the next aggregated comment (main.rereview-finalize.md) reads and
#     clears the SAME dedup_key convention ci-repair derives on its own
#     (cv-finalize-<owner>-<repo>-<pr>), before building that round's
#     manifest, so the deferred status is never posted twice.
#
# Run:  bash tests/con-voyage-ci-repair-defer-status-wiring.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
CI_REPAIR_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage-ci-repair/main.ci-repair.md"
REREVIEW_FINALIZE_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.rereview-finalize.md"
CV_LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

for f in "$CI_REPAIR_MD" "$REREVIEW_FINALIZE_MD" "$CV_LIB"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: file under test not found at ${f}" >&2
    exit 2
  fi
done

FAILURES=0
CASE_NAME=""
start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# ===========================================================================
# CASE 1 — con-voyage-lib.sh actually defines the two helpers this suite
# (and main.ci-repair.md / main.rereview-finalize.md) assume exist.
# ===========================================================================
start_case "1: con-voyage-lib.sh defines cv_defer_status_append and cv_defer_status_read_and_clear"
if grep -qE '^cv_defer_status_append\(\)' "$CV_LIB"; then
  pass "cv_defer_status_append is defined"
else
  fail "cv_defer_status_append is not defined in con-voyage-lib.sh"
fi
if grep -qE '^cv_defer_status_read_and_clear\(\)' "$CV_LIB"; then
  pass "cv_defer_status_read_and_clear is defined"
else
  fail "cv_defer_status_read_and_clear is not defined in con-voyage-lib.sh"
fi

# ===========================================================================
# CASE 2 — AC3: the 4b merge_conflict section defers via
# cv_defer_status_append and no longer instructs posting a fresh PR comment
# for the routine resolution summary.
# ===========================================================================
start_case "2: 4b (merge_conflict) resolution summary defers instead of commenting"
sec4b="$(sed -n '/^### 4b\. `merge_conflict`/,/^### 4c\./p' "$CI_REPAIR_MD")"
if [ -z "$sec4b" ]; then
  fail "could not isolate the '### 4b. \`merge_conflict\`' section"
else
  n_defer_calls="$(printf '%s\n' "$sec4b" | grep -c 'cv_defer_status_append')"
  if [ "$n_defer_calls" -ge 1 ]; then
    pass "4b section calls cv_defer_status_append (${n_defer_calls} call site(s))"
  else
    fail "4b section never calls cv_defer_status_append"
  fi
  if printf '%s\n' "$sec4b" | grep -qE 'as BOTH a machine-bannered PR[[:space:]]*$|BOTH a machine-bannered PR\s*$'; then
    fail "4b section still instructs posting a fresh machine-bannered PR comment for the routine resolution summary"
  else
    pass "4b section no longer instructs a fresh top-level PR comment for the routine resolution summary"
  fi
fi

# ===========================================================================
# CASE 3 — AC4: the 4d branch-protection escalation is UNCHANGED — it still
# posts immediately via cv-pr-comment.sh and mails the mayor. This is the
# one ci-repair path this slice must NOT touch.
# ===========================================================================
start_case "3: 4d branch-protection escalation still posts immediately and mails the mayor (unchanged)"
sec4d="$(sed -n '/^### 4d\. `blocked`/,/^## Step 5/p' "$CI_REPAIR_MD")"
if [ -z "$sec4d" ]; then
  fail "could not isolate the '### 4d. \`blocked\`' section"
else
  if printf '%s\n' "$sec4d" | grep -q 'Post one' && printf '%s\n' "$sec4d" | grep -q 'machine-bannered PR comment'; then
    pass "4d still instructs posting one machine-bannered PR comment for the branch-protection block"
  else
    fail "4d no longer instructs an immediate PR comment for the branch-protection block (AC4 regression)"
  fi
  if printf '%s\n' "$sec4d" | grep -q 'gc mail send {escalation_target}'; then
    pass "4d still escalates to {escalation_target} by mail"
  else
    fail "4d no longer mails {escalation_target} on the branch-protection block"
  fi
  if printf '%s\n' "$sec4d" | grep -q 'cv_defer_status_append'; then
    fail "4d (human-actionable) must not defer via cv_defer_status_append — it should post immediately"
  else
    pass "4d does not defer its human-actionable status (correctly posts immediately instead)"
  fi
fi

# ===========================================================================
# CASE 4 — the deferred status is keyed with the SAME dedup_key convention
# the .finalize record uses (cv-finalize-<owner>-<repo>-<pr>), derived
# locally from {repo}/{pr} since con-voyage-ci-repair has no
# gc.var.finalize_key of its own.
# ===========================================================================
start_case "4: ci-repair derives the cv-finalize-<owner>-<repo>-<pr> dedup_key locally"
if grep -qE 'CV_DEDUP_KEY="cv-finalize-\$\{CV_OWNER\}-\$\{CV_REPONAME\}-\{pr\}"' "$CI_REPAIR_MD"; then
  pass "ci-repair derives cv-finalize-<owner>-<repo>-<pr> from {repo}/{pr} directly"
else
  fail "ci-repair does not derive the cv-finalize-<owner>-<repo>-<pr> dedup_key as expected"
fi

# ===========================================================================
# CASE 5 — main.rereview-finalize.md reads and clears the deferred status
# using the SAME finalize-record dedup_key ($FINALIZE_KEY) BEFORE building
# the round's manifest, so a deferred status is folded into this round's
# comment, not lost or posted twice.
# ===========================================================================
start_case "5: rereview-finalize reads+clears deferred status by \$FINALIZE_KEY before posting"
if grep -q 'cv_defer_status_read_and_clear "\$FINALIZE_KEY"' "$REREVIEW_FINALIZE_MD"; then
  pass "rereview-finalize calls cv_defer_status_read_and_clear \"\$FINALIZE_KEY\""
else
  fail "rereview-finalize does not call cv_defer_status_read_and_clear \"\$FINALIZE_KEY\""
fi
read_line="$(grep -n 'cv_defer_status_read_and_clear' "$REREVIEW_FINALIZE_MD" | head -1 | cut -d: -f1)"
post_line="$(grep -n 'comment-aggregate "\$PR_NUMBER"' "$REREVIEW_FINALIZE_MD" | head -1 | cut -d: -f1)"
if [ -n "$read_line" ] && [ -n "$post_line" ] && [ "$read_line" -lt "$post_line" ]; then
  pass "deferred status is read+cleared before the aggregated comment is posted (line ${read_line} < ${post_line})"
else
  fail "deferred status read/clear does not precede the aggregated comment post (read_line=${read_line:-?}, post_line=${post_line:-?})"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
