#!/usr/bin/env bash
# con-voyage-publish.test.sh — hermetic, offline structural test for
# {target}.publish.md's CV_STATE_DIR default-resolution block (fk-mr07 B4).
#
# This 17-line inline block is the actual REQ-002 fix site (publish writes
# the .finalize record the con-voyage-finalize monitor later reads), but
# before this test it had zero coverage: no .test.sh executed or grepped it,
# and it isn't covered by this pack's drift-detection suite
# (agents-contract.test.sh has no match for CV_STATE_DIR/cv_default_state_dir).
# The `bash -n` proof-command sweep only covers standalone .sh files, so this
# block was never syntax- or logic-checked by anything, automated or
# otherwise.
#
# Mirrors the existing pattern for structurally verifying embedded bash in a
# workflow .md file (con-voyage-review-watchdog.test.sh CASE 16, which greps
# {target}.con-voyage-review-loop.md for key fragments) rather than
# extracting and executing the fenced block — no other test in this suite
# does the latter for a markdown-embedded block, and the resolution logic
# itself (cv_default_state_dir) already has direct unit coverage in
# con-voyage-lib.test.sh.
#
# Run:  bash tests/con-voyage-publish.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PUBLISH_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/{target}.publish.md"

if [ ! -f "$PUBLISH_MD" ]; then
  echo "FATAL: workflow file under test not found at ${PUBLISH_MD}" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$PUBLISH_MD"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (not found verbatim in ${PUBLISH_MD})" >&2
    FAILURES=$((FAILURES+1))
  fi
}

assert_not_contains() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$PUBLISH_MD"; then
    echo "  FAIL: $label (found verbatim in ${PUBLISH_MD}, expected it gone)" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: $label"
  fi
}

line_of() {
  grep -nF -- "$1" "$PUBLISH_MD" | head -1 | cut -d: -f1
}

# ===========================================================================
# CASE 1 — The block reuses con-voyage-lib.sh's cv_default_state_dir()
#   instead of hand-copying its GC_RIG_ROOT / .beads-walkup / GC_CITY
#   resolution algorithm inline (fk-mr07 B2). Each assertion targets a
#   distinct part of the real call chain, not just the symbol's name, so a
#   future edit that silently drops the sourcing or the guard still fails
#   even though "cv_default_state_dir" remains present as a comment.
# ===========================================================================
start_case "1: CV_STATE_DIR resolution calls the shared cv_default_state_dir(), not a duplicate"
assert_contains 'if [ -z "${CV_STATE_DIR:-}" ]; then' "resolution only runs when the caller has not already set CV_STATE_DIR"
assert_contains 'CV_LIB="$(command -v con-voyage-lib.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"' "locates con-voyage-lib.sh via the same command-v/find idiom as this file's CV_VERIFY/CV_GUARD/CV_BIN"
assert_contains 'CV_STATE_DIR="$(source "$CV_LIB" && cv_default_state_dir)"' "sources the lib and calls cv_default_state_dir() for the resolved value"

# ===========================================================================
# CASE 2 — The GC_CITY last-resort fallback survives the B2 dedup (an
#   environment where con-voyage-lib.sh cannot be located degrades to the
#   prior city-root behavior instead of failing closed).
# ===========================================================================
start_case "2: GC_CITY fallback is preserved when the lib cannot be located"
assert_contains '[ -n "${CV_STATE_DIR:-}" ] || CV_STATE_DIR="${GC_CITY:-.}/.gc/cv-pr-watch"' "falls back to GC_CITY when CV_LIB is empty or the source+call produced nothing"

# ===========================================================================
# CASE 3 — Ordering: CV_STATE_DIR must be fully resolved before it is used
#   to create the directory or write the finalize record.
# ===========================================================================
start_case "3: resolution happens before CV_STATE_DIR is used"
guard_line="$(line_of 'if [ -z "${CV_STATE_DIR:-}" ]; then')"
mkdir_line="$(line_of 'mkdir -p "$CV_STATE_DIR"')"
write_line="$(line_of '} > "${CV_STATE_DIR}/${finalize_key}.finalize"')"

if [ -n "$guard_line" ] && [ -n "$mkdir_line" ] && [ "$guard_line" -lt "$mkdir_line" ]; then
  pass_or_fail=0
else
  pass_or_fail=1
fi
if [ "$pass_or_fail" -eq 0 ]; then
  echo "  PASS: resolution guard (line ${guard_line}) precedes mkdir -p \$CV_STATE_DIR (line ${mkdir_line})"
else
  echo "  FAIL: expected the resolution guard to precede mkdir -p \$CV_STATE_DIR" >&2
  FAILURES=$((FAILURES+1))
fi

if [ -n "$mkdir_line" ] && [ -n "$write_line" ] && [ "$mkdir_line" -lt "$write_line" ]; then
  echo "  PASS: mkdir -p \$CV_STATE_DIR (line ${mkdir_line}) precedes the .finalize write (line ${write_line})"
else
  echo "  FAIL: expected mkdir -p \$CV_STATE_DIR to precede the .finalize write" >&2
  FAILURES=$((FAILURES+1))
fi

# ===========================================================================
# CASE 4 — fk-qppb4 (GitHub stacked PRs): BASE_BRANCH is resolved via the
#   shared cv_resolve_base_branch() helper, not a hand-filled placeholder
#   that silently always meant "main".
# ===========================================================================
start_case "4: BASE_BRANCH is resolved via the shared cv_resolve_base_branch(), not a placeholder"
assert_contains 'BASE_BRANCH="$(source "$CV_LIB" && cv_resolve_base_branch "$CONVOY_ID" "$(pwd)")"' "resolves BASE_BRANCH by sourcing con-voyage-lib.sh and calling cv_resolve_base_branch"
assert_contains 'CONVOY_ID="{convoy_id}"' "resolves the journey's convoy id from the graph.v2 template var"
assert_not_contains '<base-branch>' "no hand-filled <base-branch> placeholder remains anywhere in this file"

# ===========================================================================
# CASE 5 — the resolved $BASE_BRANCH, not a hardcoded main or placeholder,
#   reaches both the hygiene guard's base-ref arg and the PR-create --base.
# ===========================================================================
start_case "5: the resolved \$BASE_BRANCH reaches the hygiene guard's base-ref argument"
assert_contains '"$CV_GUARD" guard "$(pwd)" "origin/${BASE_BRANCH}"' "guard is called with origin/\${BASE_BRANCH}, not a hardcoded origin/main"

start_case "6: the resolved \$BASE_BRANCH reaches the PR-create --base flag"
assert_contains '--base "$BASE_BRANCH" --head <work-branch>' "cv-pr-comment.sh create receives --base \"\$BASE_BRANCH\""

# ===========================================================================
# CASE 7 — ordering: BASE_BRANCH must be resolved before either the guard
#   call or the PR-create call consumes it.
# ===========================================================================
start_case "7: BASE_BRANCH resolution precedes both of its consumers"
resolve_line="$(line_of 'BASE_BRANCH="$(source "$CV_LIB" && cv_resolve_base_branch "$CONVOY_ID" "$(pwd)")"')"
guard_use_line="$(line_of '"$CV_GUARD" guard "$(pwd)" "origin/${BASE_BRANCH}"')"
pr_create_line="$(line_of '--base "$BASE_BRANCH" --head <work-branch>')"

if [ -n "$resolve_line" ] && [ -n "$guard_use_line" ] && [ "$resolve_line" -lt "$guard_use_line" ]; then
  echo "  PASS: BASE_BRANCH resolution (line ${resolve_line}) precedes the guard call (line ${guard_use_line})"
else
  echo "  FAIL: expected BASE_BRANCH resolution to precede the guard call" >&2
  FAILURES=$((FAILURES+1))
fi

if [ -n "$resolve_line" ] && [ -n "$pr_create_line" ] && [ "$resolve_line" -lt "$pr_create_line" ]; then
  echo "  PASS: BASE_BRANCH resolution (line ${resolve_line}) precedes the PR-create call (line ${pr_create_line})"
else
  echo "  FAIL: expected BASE_BRANCH resolution to precede the PR-create call" >&2
  FAILURES=$((FAILURES+1))
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
