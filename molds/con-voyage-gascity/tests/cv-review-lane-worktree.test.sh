#!/usr/bin/env bash
# cv-review-lane-worktree.test.sh — hermetic, offline test for per-lane review
# worktree isolation (fk-q659).
#
# THE BUG: every con-voyage review lane for a work item shares ONE mutable
# worktree (the source anchor's recorded work_dir). A lane doing
# mutate-run-revert verification races another lane's concurrent build/test in
# the same directory, producing a false BLOCKING or false-negative finding.
#
# THE FIX under test: cv-review-lane-worktree.sh gives each lane its own
# throwaway linked git worktree, checked out at the exact commit the source
# anchor is sitting on, so lane-local mutation can never be observed by
# another lane.
#
#   acquire <source-work-dir> <lane-id>  — create-or-reuse a lane worktree,
#                                           refreshed to source's current HEAD.
#   sweep <source-work-dir>              — remove every lane worktree for that
#                                           source (post-cycle hygiene).
#
# HOW IT WORKS: real, local git repos under a temp sandbox (git init is fully
# offline) — no stubs needed, git's own worktree/checkout/clean behavior is
# exactly what is under test.
#
# Run:  bash tests/cv-review-lane-worktree.test.sh   (exit 0 => all passed)

set -uo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-review-lane-worktree.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test.XXXXXX")"
# Canonicalize: on macOS, $TMPDIR resolves under a symlink (/var ->
# /private/var). The script under test always returns realpath'd worktree
# paths (to match `git worktree list`'s own output), so path assertions below
# must compare against the same canonicalized form, not the raw mktemp path.
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

git_c() { git -C "$1" -c user.email=test@example.com -c user.name="Test" "${@:2}"; }

mk_repo() {
  local repo="${SANDBOX}/$1"
  mkdir -p "$repo"
  git_c "$repo" init -q -b main
  printf 'placeholder\n' > "$repo/README.md"
  git_c "$repo" add README.md
  git_c "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

run_script() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

OUT=""
RC=0

# ===========================================================================
# CASE 1 — acquire on a fresh source worktree creates a sibling lane worktree,
#   detached at the source's current HEAD, with matching file content.
# ===========================================================================
start_case "1: acquire creates a sibling lane worktree at source HEAD"
REPO1="$(mk_repo repo1)"
SRC1="${SANDBOX}/repo1-src"
git_c "$REPO1" worktree add -q --detach "$SRC1" HEAD
run_script acquire "$SRC1" "lane-acceptance"
assert_eq "0" "$RC" "acquire exits 0"
LANE1="$OUT"
if [ -d "$LANE1" ]; then pass "lane worktree directory exists at ${LANE1}"; else fail "lane worktree directory missing (got '${LANE1}')"; fi
case "$LANE1" in
  "${SANDBOX}/repo1-src--review-lane-acceptance") pass "lane worktree path follows the <src>--review-<lane-id> convention" ;;
  *) fail "unexpected lane worktree path: ${LANE1}" ;;
esac
if [ -f "${LANE1}/README.md" ]; then pass "lane worktree has the source's checked-out files"; else fail "lane worktree is missing README.md"; fi
src_head="$(git_c "$SRC1" rev-parse HEAD)"
lane_head="$(git_c "$LANE1" rev-parse HEAD)"
assert_eq "$src_head" "$lane_head" "lane worktree is detached at the source's HEAD commit"

# ===========================================================================
# CASE 2 — acquire is idempotent: a second call with the same source+lane-id
#   returns the SAME path and does not error.
# ===========================================================================
start_case "2: acquire is idempotent for the same source and lane-id"
run_script acquire "$SRC1" "lane-acceptance"
assert_eq "0" "$RC" "second acquire exits 0"
assert_eq "$LANE1" "$OUT" "second acquire returns the same lane worktree path"

# ===========================================================================
# CASE 3 — TRUE ISOLATION: two different lanes on the same source get two
#   DIFFERENT worktrees, and a mutation in one is never visible in the other.
#   This is the property that actually fixes fk-q659.
# ===========================================================================
start_case "3: two lanes on the same source are fully isolated from each other"
run_script acquire "$SRC1" "lane-test-evidence"
assert_eq "0" "$RC" "acquire for a second lane exits 0"
LANE2="$OUT"
if [ "$LANE1" != "$LANE2" ]; then pass "lane-acceptance and lane-test-evidence got different worktrees"; else fail "two different lane-ids collided on the same worktree path"; fi
# Simulate lane-acceptance's mutate-run-revert: transiently edit a shared file.
printf 'mutated by lane-acceptance\n' >> "${LANE1}/README.md"
if grep -q 'mutated by lane-acceptance' "${LANE2}/README.md" 2>/dev/null; then
  fail "lane-test-evidence's copy observed lane-acceptance's in-flight edit — isolation is broken"
else
  pass "lane-test-evidence's copy is unaffected by lane-acceptance's in-flight edit"
fi
if grep -q 'mutated by lane-acceptance' "${SRC1}/README.md" 2>/dev/null; then
  fail "the shared source work_dir was mutated by a lane edit — isolation is broken"
else
  pass "the shared source work_dir is untouched by the lane edit"
fi

# ===========================================================================
# CASE 4 — RE-RUN MECHANICS: acquire refreshes an existing lane worktree to
#   the source's NEW commit and wipes leftover mutation state from a prior
#   review cycle (dirty/untracked files), instead of silently reusing stale
#   content.
# ===========================================================================
start_case "4: acquire refreshes a reused lane worktree to the source's current HEAD and cleans it"
printf 'left over from a previous cycle'\''s mutate-run-revert\n' > "${LANE1}/leftover.txt"
printf 'round 2 change\n' > "${SRC1}/round2.txt"
git_c "$SRC1" add round2.txt
git_c "$SRC1" commit -q -m "round 2: apply-review-findings fix"
new_src_head="$(git_c "$SRC1" rev-parse HEAD)"
run_script acquire "$SRC1" "lane-acceptance"
assert_eq "0" "$RC" "re-acquire after a new source commit exits 0"
assert_eq "$LANE1" "$OUT" "re-acquire still returns the same deterministic lane path"
refreshed_lane_head="$(git_c "$LANE1" rev-parse HEAD)"
assert_eq "$new_src_head" "$refreshed_lane_head" "re-acquired lane worktree is detached at the source's NEW HEAD"
if [ -f "${LANE1}/round2.txt" ]; then pass "re-acquired lane worktree has round 2's new file"; else fail "re-acquired lane worktree is missing round2.txt"; fi
if [ -f "${LANE1}/leftover.txt" ]; then fail "re-acquire left a prior cycle's untracked mutation on disk"; else pass "re-acquire wiped the prior cycle's leftover untracked file"; fi

# ===========================================================================
# CASE 5 — lane-id sanitization: unsafe characters never escape the
#   worktrees/ parent directory or produce a path outside the convention.
# ===========================================================================
start_case "5: acquire sanitizes an unsafe lane-id"
run_script acquire "$SRC1" "../../etc/lane"
assert_eq "0" "$RC" "acquire with an unsafe lane-id still exits 0 (sanitized, not rejected)"
case "$OUT" in
  "${SANDBOX}/repo1-src--review-"*)
    case "$OUT" in
      *".."*) fail "sanitized lane worktree path still contains '..': ${OUT}" ;;
      *"/etc/"*) fail "sanitized lane worktree path escaped into /etc: ${OUT}" ;;
      *) pass "unsafe lane-id was sanitized into a safe sibling path: ${OUT}" ;;
    esac
    ;;
  *) fail "sanitized lane worktree path is not a sibling of the source: ${OUT}" ;;
esac

# ===========================================================================
# CASE 6 — validation errors: missing lane-id, missing source dir, a relative
#   source path, and a non-git source directory are all hard errors.
# ===========================================================================
start_case "6: acquire validates its arguments"
run_script acquire "$SRC1"
if [ "$RC" -ne 0 ]; then pass "acquire fails with no lane-id"; else fail "expected non-zero exit with no lane-id"; fi
run_script acquire
if [ "$RC" -ne 0 ]; then pass "acquire fails with no arguments"; else fail "expected non-zero exit with no arguments"; fi
run_script acquire "repo1-src" "lane-x"
if [ "$RC" -ne 0 ]; then pass "acquire fails on a relative source path"; else fail "expected non-zero exit for a relative source path"; fi
NOTGIT="${SANDBOX}/not-a-repo"
mkdir -p "$NOTGIT"
run_script acquire "$NOTGIT" "lane-x"
if [ "$RC" -ne 0 ]; then pass "acquire fails on a non-git source directory"; else fail "expected non-zero exit for a non-git source directory"; fi

# ===========================================================================
# CASE 7 — sweep removes every lane worktree for a source, and only those.
# ===========================================================================
start_case "7: sweep removes this source's lane worktrees and leaves everything else"
OTHER_REPO="$(mk_repo repo-other)"
OTHER_SRC="${SANDBOX}/repo-other-src"
git_c "$OTHER_REPO" worktree add -q --detach "$OTHER_SRC" HEAD
run_script acquire "$OTHER_SRC" "lane-acceptance"
assert_eq "0" "$RC" "acquire on an unrelated source exits 0"
OTHER_LANE="$OUT"
run_script sweep "$SRC1"
assert_eq "0" "$RC" "sweep exits 0"
if [ -d "$LANE1" ]; then fail "sweep left ${LANE1} on disk"; else pass "sweep removed ${LANE1}"; fi
if [ -d "$LANE2" ]; then fail "sweep left ${LANE2} on disk"; else pass "sweep removed ${LANE2}"; fi
if [ -d "$SRC1" ]; then pass "sweep left the source work_dir itself untouched"; else fail "sweep removed the source work_dir itself — must never happen"; fi
if [ -d "$OTHER_LANE" ]; then pass "sweep left an unrelated source's lane worktree untouched"; else fail "sweep incorrectly removed an unrelated source's lane worktree"; fi
if git_c "$OTHER_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then pass "unrelated source worktree is still a valid git worktree"; else fail "unrelated source worktree was corrupted by sweep"; fi

# ===========================================================================
# CASE 8 — sweep with no matching lane worktrees is a clean no-op.
# ===========================================================================
start_case "8: sweep is a clean no-op when there is nothing to remove"
run_script sweep "$SRC1"
assert_eq "0" "$RC" "sweep exits 0 even with nothing left to sweep"

# ===========================================================================
# CASE 9 — unknown subcommand is rejected.
# ===========================================================================
start_case "9: unknown subcommand is rejected"
run_script frobnicate "$SRC1"
if [ "$RC" -ne 0 ]; then pass "unknown subcommand exits non-zero"; else fail "expected non-zero exit for an unknown subcommand"; fi

# ===========================================================================
# Summary
# ===========================================================================
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
