#!/usr/bin/env bash
# con-voyage-anchor-staleness.test.sh — hermetic, offline tests for fk-2klp2:
# cv_anchor_too_stale, the guard con-voyage's prepare-build step uses before
# short-circuiting onto an adopted source-anchor branch (either the current
# convoy's own EXISTING_WORK_DIR, or an earlier work-bead anchor found via
# cv_find_prior_built_anchor).
#
# EVIDENCE (fk-0f1 / con-voyage root fk-vzgjt, 2026-09-30): prepare-build
# adopted a work bead's old source-anchor branch that was ~146 commits behind
# origin/main (built on release 0.5.0), with no staleness guard, so it
# short-circuited straight into the review pipeline and could only end in a
# big rebase conflict.
#
# cv_anchor_too_stale DIR [MAX_BEHIND] [BASE-REF]:
#   Prints "<behind_count> <would_conflict:0|1>" on stdout. Returns 0 (TOO
#   STALE — do not short-circuit) when EITHER:
#     - DIR is more than MAX_BEHIND commits behind the resolved base
#       (CV_STALE_ANCHOR_MAX_BEHIND env, default 50, when MAX_BEHIND is
#       omitted/non-numeric), or
#     - a non-destructive merge-tree check says merging DIR onto the base
#       would conflict.
#   Returns 1 (fine to adopt) otherwise, INCLUDING the fail-safe case where
#   no base ref can be resolved at all (an unmeasurable anchor is not proof
#   of staleness).
#
# HOW IT WORKS: real local git repos under a temp sandbox, delegating to the
# REAL cv-worktree-prep.sh behind-count/would-conflict subcommands (already
# covered directly by tests/cv-worktree-prep.test.sh) — this suite only
# proves cv_anchor_too_stale's own threshold/combination logic on top of
# them. `gc` is stubbed only so `source "$LIB"` succeeds; the code path under
# test here never calls it.
#
# Run:  bash tests/con-voyage-anchor-staleness.test.sh   (exit 0 => all passed)

set -uo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
PREP_SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-worktree-prep.sh"

for f in "$LIB" "$PREP_SCRIPT"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: required file not found at ${f}" >&2
    exit 2
  fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-anchor-staleness-test.XXXXXX")"
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
  git_c "$repo" config user.email test@example.com
  git_c "$repo" config user.name "Test"
  printf 'placeholder\n' > "$repo/README.md"
  git_c "$repo" add README.md
  git_c "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

# Fake `gc` so `source "$LIB"` succeeds; not called by cv_anchor_too_stale.
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"
# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
GC="${STUBDIR}/gc"

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

run_fn() {
  OUT="$(cv_anchor_too_stale "$@" 2>/dev/null)"
  RC=$?
}

# ===========================================================================
# CASE 1 — an anchor a handful of commits behind base, with no content
#   overlap, is well within the default threshold -> fine to adopt (exit 1).
# ===========================================================================
start_case "1: a few commits behind, no content overlap -> not stale (default threshold)"
REPO1="$(mk_repo repo1)"
WT1="${SANDBOX}/repo1-worktree"
git_c "$REPO1" worktree add -q --detach "$WT1" HEAD
printf 'anchor change\n' > "${WT1}/anchor.txt"
git_c "$WT1" add anchor.txt
git_c "$WT1" commit -q -m "feat: anchor change"
for i in 1 2 3; do
  printf 'upstream %s\n' "$i" > "${REPO1}/upstream-${i}.txt"
  git_c "$REPO1" add "upstream-${i}.txt"
  git_c "$REPO1" commit -q -m "chore: upstream ${i}"
done
run_fn "$WT1" "" main
assert_eq "1" "$RC" "cv_anchor_too_stale returns 1 (not stale) for 3 commits behind, no overlap"
assert_eq "3 0" "$OUT" "reports behind_count=3, would_conflict=0"

# ===========================================================================
# CASE 2 — the fk-0f1 shape: an anchor far beyond the threshold -> too stale
#   (exit 0), regardless of content overlap.
# ===========================================================================
start_case "2: far beyond the max-behind threshold -> too stale (exit 0)"
REPO2="$(mk_repo repo2)"
WT2="${SANDBOX}/repo2-worktree"
git_c "$REPO2" worktree add -q --detach "$WT2" HEAD
printf 'anchor change\n' > "${WT2}/anchor.txt"
git_c "$WT2" add anchor.txt
git_c "$WT2" commit -q -m "feat: anchor change"
i=1
while [ "$i" -le 5 ]; do
  printf 'upstream %s\n' "$i" > "${REPO2}/upstream-${i}.txt"
  git_c "$REPO2" add "upstream-${i}.txt"
  git_c "$REPO2" commit -q -m "chore: upstream ${i}"
  i=$((i + 1))
done
run_fn "$WT2" "3" main
assert_eq "0" "$RC" "cv_anchor_too_stale returns 0 (too stale) once behind_count (5) exceeds max_behind (3)"
assert_eq "5 0" "$OUT" "reports behind_count=5, would_conflict=0"

# ===========================================================================
# CASE 3 — within the commit-count threshold, but the anchor and base edit
#   the exact same content -> too stale (exit 0) via the merge-conflict
#   signal, independent of the commit-count check.
# ===========================================================================
start_case "3: within threshold but would conflict -> too stale (exit 0)"
REPO3="$(mk_repo repo3)"
WT3="${SANDBOX}/repo3-worktree"
git_c "$REPO3" worktree add -q --detach "$WT3" HEAD
printf 'anchor version\n' > "${WT3}/README.md"
git_c "$WT3" add README.md
git_c "$WT3" commit -q -m "feat: anchor edits README"
printf 'base version, incompatible\n' > "${REPO3}/README.md"
git_c "$REPO3" add README.md
git_c "$REPO3" commit -q -m "chore: base edits the same README line differently"
run_fn "$WT3" "50" main
assert_eq "0" "$RC" "cv_anchor_too_stale returns 0 (too stale) on a real content conflict, even 1 commit behind"
assert_eq "1 1" "$OUT" "reports behind_count=1, would_conflict=1"

# ===========================================================================
# CASE 4 — MAX_BEHIND omitted/non-numeric falls back to
#   CV_STALE_ANCHOR_MAX_BEHIND, then to the built-in default of 50.
# ===========================================================================
start_case "4: MAX_BEHIND falls back to CV_STALE_ANCHOR_MAX_BEHIND env, then to 50"
REPO4="$(mk_repo repo4)"
WT4="${SANDBOX}/repo4-worktree"
git_c "$REPO4" worktree add -q --detach "$WT4" HEAD
printf 'anchor change\n' > "${WT4}/anchor.txt"
git_c "$WT4" add anchor.txt
git_c "$WT4" commit -q -m "feat: anchor change"
i=1
while [ "$i" -le 4 ]; do
  printf 'upstream %s\n' "$i" > "${REPO4}/upstream-${i}.txt"
  git_c "$REPO4" add "upstream-${i}.txt"
  git_c "$REPO4" commit -q -m "chore: upstream ${i}"
  i=$((i + 1))
done
CV_STALE_ANCHOR_MAX_BEHIND=2 run_fn "$WT4" "" main
assert_eq "0" "$RC" "CV_STALE_ANCHOR_MAX_BEHIND=2 makes 4-commits-behind too stale"
unset CV_STALE_ANCHOR_MAX_BEHIND
run_fn "$WT4" "" main
assert_eq "1" "$RC" "with no env override, 4 commits behind is under the built-in default (50) -> not stale"
run_fn "$WT4" "notanumber" main
assert_eq "1" "$RC" "a non-numeric MAX_BEHIND falls back to the built-in default (50), not a crash"

# ===========================================================================
# CASE 5 — FAIL-SAFE: no base ref resolves at all -> not stale (exit 1), an
#   unmeasurable anchor is not proof of staleness.
# ===========================================================================
start_case "5: fail-safe — no base ref resolves -> not stale (exit 1)"
REPO5="${SANDBOX}/repo5"
mkdir -p "$REPO5"
git_c "$REPO5" init -q -b trunk
git_c "$REPO5" config user.email test@example.com
git_c "$REPO5" config user.name "Test"
printf 'placeholder\n' > "${REPO5}/README.md"
git_c "$REPO5" add README.md
git_c "$REPO5" commit -q -m "init"
WT5="${SANDBOX}/repo5-worktree"
git_c "$REPO5" worktree add -q --detach "$WT5" HEAD
run_fn "$WT5"
assert_eq "1" "$RC" "cv_anchor_too_stale fails safe (not stale) when no base ref resolves"

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
