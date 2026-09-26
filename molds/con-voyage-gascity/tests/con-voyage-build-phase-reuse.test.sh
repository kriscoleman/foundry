#!/usr/bin/env bash
# con-voyage-build-phase-reuse.test.sh — hermetic tests for
# cv_find_prior_built_anchor (fk-ki8je: "0.8.0 build phase never reuses a
# pre-built do-work branch — only checks the sling's new convoy").
#
# REGRESSION THIS COVERS: {target}.prepare-build.md's short-circuit used to
# check ONLY the current sling's own synthetic input convoy for a work_dir —
# but every `gc sling ... --on con-voyage` creates a BRAND NEW input convoy,
# and do-work closes its OWN source anchor when it finishes, so that state
# never carries forward onto the fresh one. The short-circuit therefore never
# fired for the normal do-work -> con-voyage handoff, and a finished build
# got silently re-implemented from scratch. The fix: look at the WORK BEAD's
# other `tracks` dependents (its past source anchors, closed or open) for one
# that already has a built worktree.
#
# HOW IT WORKS: combines con-voyage-lib.test.sh's recording `gc` stub
# (STUB_BDSHOW_JSON_<id>, keyed for `bd show --json [--include-dependents]`)
# with con-voyage-stacked-pr-base.test.sh's mk_repo/git_c real-git fixture
# pattern — the function under test both queries bd (stubbed) and shells out
# to the REAL cv-worktree-prep.sh `built` check (real git, no network), so
# both need to be genuine here.
#
# Run:  bash tests/con-voyage-build-phase-reuse.test.sh   (exit 0 => all cases passed)

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

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-build-phase-reuse-test.XXXXXX")"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
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
  # Persist identity into the repo's own config (not just a per-invocation -c
  # override): cv-worktree-prep.sh's `built` check only reads refs/history,
  # but keeping this hermetic regardless of ambient git config matches the
  # sibling stacked-pr-base fixture and costs nothing.
  git_c "$repo" config user.email test@example.com
  git_c "$repo" config user.name "Test"
  printf 'placeholder\n' > "$repo/README.md"
  git_c "$repo" add README.md
  git_c "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

# mk_anchor NAME — a repo with an origin remote and origin/HEAD set, at
# exactly the base commit (not yet "built"). The caller adds further local
# commits to make it "ahead of base" (built), or leaves it as-is (not built).
mk_anchor() {
  local repo
  repo="$(mk_repo "$1")"
  local upstream="${SANDBOX}/$1-upstream.git"
  git init -q -b main --bare "$upstream"
  git_c "$repo" remote add origin "$upstream"
  git_c "$repo" push -q -u origin main
  git_c "$repo" remote set-head origin main
  printf '%s' "$repo"
}

# Ensure the REAL cv-worktree-prep.sh is what `command -v` finds, regardless
# of the cwd this suite happens to be invoked from — sidesteps the
# GC_CITY-relative `find` fallback's own cwd/version-skew traps entirely
# (see con_voyage_lib_sourced_in_agent_shell_bash_source_zsh memory point 3),
# rather than relying on being run from the mold root.
export PATH="$(dirname "$PREP_SCRIPT"):${PATH}"

# ---------------------------------------------------------------------------
# Recording `gc` stub (mirrors con-voyage-lib.test.sh's pattern exactly: only
# `bd show <id> --json` is exercised here, flags after the id are ignored).
# ---------------------------------------------------------------------------
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG:-/dev/null}"
args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "show" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_BDSHOW_JSON_${id//-/_}"
  printf '%s' "${!var:-}"
  exit 0
fi
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

GC_LOG="${SANDBOX}/gc.log"
: > "$GC_LOG"
export STUB_GC_LOG="$GC_LOG"
# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
GC="${STUBDIR}/gc"
# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
GC_CITY="${SANDBOX}/city"
mkdir -p "$GC_CITY"

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

# assert_log_count PATTERN EXPECTED MESSAGE (mirrors con-voyage-lib.test.sh).
assert_log_count() {
  local pattern="$1" expected="$2" msg="$3" n
  n="$(grep -E -c -- "$pattern" "$GC_LOG")"
  assert_eq "$expected" "${n:-0}" "$msg"
}

# ===========================================================================
# cv_find_prior_built_anchor
# ===========================================================================

start_case "fresh bead: the only tracking convoy is the current one -> prints nothing (build fresh)"
export STUB_BDSHOW_JSON_fk_wbfresh='{"id":"fk-wbfresh","dependents":[{"id":"fk-onlyme","dependency_type":"tracks"}]}'
assert_eq "" "$(cv_find_prior_built_anchor "fk-wbfresh" "fk-onlyme" 2>/dev/null)" "excluding the current convoy leaves no candidates"

start_case "fresh bead: work bead has zero dependents -> prints nothing"
export STUB_BDSHOW_JSON_fk_wbnone='{"id":"fk-wbnone","dependents":[]}'
assert_eq "" "$(cv_find_prior_built_anchor "fk-wbnone" "fk-currentconvoy" 2>/dev/null)" "no dependents at all -> no candidates"

start_case "closed do-work anchor with a BUILT worktree -> reused (short-circuits)"
ANCHOR1="$(mk_anchor anchor1)"
printf 'impl\n' > "${ANCHOR1}/impl.txt"
git_c "$ANCHOR1" add impl.txt
git_c "$ANCHOR1" commit -q -m "feat: implementation"
export STUB_BDSHOW_JSON_fk_wb1='{"id":"fk-wb1","dependents":[{"id":"fk-anchor1","dependency_type":"tracks"},{"id":"fk-currentconvoy","dependency_type":"tracks"}]}'
export STUB_BDSHOW_JSON_fk_anchor1="{\"id\":\"fk-anchor1\",\"status\":\"closed\",\"created_at\":\"2026-09-25T10:00:00Z\",\"metadata\":{\"work_dir\":\"${ANCHOR1}\"}}"
assert_eq "fk-anchor1 ${ANCHOR1}" "$(cv_find_prior_built_anchor "fk-wb1" "fk-currentconvoy" 2>/dev/null)" "prints the closed anchor's id and worktree path, current convoy excluded"

start_case "anchor exists but its worktree is NOT ahead of base -> not usable, prints nothing"
ANCHOR2="$(mk_anchor anchor2)"
export STUB_BDSHOW_JSON_fk_wb2='{"id":"fk-wb2","dependents":[{"id":"fk-anchor2","dependency_type":"tracks"}]}'
export STUB_BDSHOW_JSON_fk_anchor2="{\"id\":\"fk-anchor2\",\"status\":\"open\",\"created_at\":\"2026-09-25T10:00:00Z\",\"metadata\":{\"work_dir\":\"${ANCHOR2}\"}}"
assert_eq "" "$(cv_find_prior_built_anchor "fk-wb2" "fk-currentconvoy" 2>/dev/null)" "HEAD sitting exactly at base -> not built -> build fresh instead"

start_case "several qualifying candidates -> the NEWEST (by created_at) is chosen, not just the first listed"
ANCHOR_OLD="$(mk_anchor anchor-old)"
printf 'old\n' > "${ANCHOR_OLD}/old.txt"; git_c "$ANCHOR_OLD" add old.txt; git_c "$ANCHOR_OLD" commit -q -m "feat: old attempt"
ANCHOR_NEW="$(mk_anchor anchor-new)"
printf 'new\n' > "${ANCHOR_NEW}/new.txt"; git_c "$ANCHOR_NEW" add new.txt; git_c "$ANCHOR_NEW" commit -q -m "feat: newer attempt"
export STUB_BDSHOW_JSON_fk_wb3='{"id":"fk-wb3","dependents":[{"id":"fk-anchor-old","dependency_type":"tracks"},{"id":"fk-anchor-new","dependency_type":"tracks"}]}'
export STUB_BDSHOW_JSON_fk_anchor_old="{\"id\":\"fk-anchor-old\",\"created_at\":\"2026-09-20T08:00:00Z\",\"metadata\":{\"work_dir\":\"${ANCHOR_OLD}\"}}"
export STUB_BDSHOW_JSON_fk_anchor_new="{\"id\":\"fk-anchor-new\",\"created_at\":\"2026-09-25T08:00:00Z\",\"metadata\":{\"work_dir\":\"${ANCHOR_NEW}\"}}"
assert_eq "fk-anchor-new ${ANCHOR_NEW}" "$(cv_find_prior_built_anchor "fk-wb3" "fk-currentconvoy" 2>/dev/null)" "picks the newer anchor even though the older one is listed first"

start_case "candidate has a dependency_type OTHER than tracks -> excluded"
export STUB_BDSHOW_JSON_fk_wb4='{"id":"fk-wb4","dependents":[{"id":"fk-notanchor","dependency_type":"blocks"}]}'
export STUB_BDSHOW_JSON_fk_notanchor="{\"id\":\"fk-notanchor\",\"created_at\":\"2026-09-25T10:00:00Z\",\"metadata\":{\"work_dir\":\"${ANCHOR1}\"}}"
assert_eq "" "$(cv_find_prior_built_anchor "fk-wb4" "fk-currentconvoy" 2>/dev/null)" "a non-tracks dependent is never treated as a source anchor, even with a built work_dir"

start_case "candidate has no work_dir metadata at all -> excluded"
export STUB_BDSHOW_JSON_fk_wb5='{"id":"fk-wb5","dependents":[{"id":"fk-nowd","dependency_type":"tracks"}]}'
export STUB_BDSHOW_JSON_fk_nowd='{"id":"fk-nowd","created_at":"2026-09-25T10:00:00Z","metadata":{}}'
assert_eq "" "$(cv_find_prior_built_anchor "fk-wb5" "fk-currentconvoy" 2>/dev/null)" "no work_dir metadata -> nothing to reuse"

start_case "candidate's work_dir no longer exists on disk -> excluded, not an error"
export STUB_BDSHOW_JSON_fk_wb6='{"id":"fk-wb6","dependents":[{"id":"fk-gone","dependency_type":"tracks"}]}'
export STUB_BDSHOW_JSON_fk_gone='{"id":"fk-gone","created_at":"2026-09-25T10:00:00Z","metadata":{"work_dir":"/nonexistent/path/should/never/be/read"}}'
assert_eq "" "$(cv_find_prior_built_anchor "fk-wb6" "fk-currentconvoy" 2>/dev/null)" "a stale/missing worktree path is skipped, not treated as an error"

start_case "empty work bead id -> prints nothing, never calls bd show"
: > "$GC_LOG"
assert_eq "" "$(cv_find_prior_built_anchor "" "fk-currentconvoy" 2>/dev/null)" "empty work bead id short-circuits"
assert_log_count 'bd show' 0 "no bd show calls for an empty work bead id"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
