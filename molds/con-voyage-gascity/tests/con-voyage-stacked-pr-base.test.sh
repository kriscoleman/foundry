#!/usr/bin/env bash
# con-voyage-stacked-pr-base.test.sh — hermetic, offline tests for the
# fk-qppb4 GitHub-stacked-PR base-branch primitive:
#
#   cv_convoy_target          — reads the `gc convoy target` value back off a
#                               convoy (stubbed gc; no real git needed).
#   cv_resolve_base_branch    — convoy target, else delegates to
#                               cv-worktree-prep.sh's own resolve-base
#                               (real git; must never disagree with guard's
#                               own default-base derivation).
#   cv_ensure_branch_based_on — moves a worktree's implementation commit(s)
#                               onto the configured base with one
#                               `git rebase --onto`, so a stacked slice's PR
#                               is opened against a branch that actually
#                               contains it. This is the con-voyage-level
#                               override called out in fk-qppb4 requirement 2:
#                               the shared do-work/build-basic formula that
#                               cuts the worktree lives outside this repo and
#                               always starts from the launcher checkout's
#                               HEAD, so this function corrects the base
#                               AFTER the implementation commit exists rather
#                               than forking that formula.
#
# Default (no `gc convoy target` set) must stay byte-identical to pre-fk-qppb4
# behavior: cv_ensure_branch_based_on's empty-base-branch case never fetches,
# never rebases, never touches the worktree.
#
# HOW IT WORKS: cv_convoy_target uses a recording `gc` stub (mirrors
# con-voyage-lib.test.sh's own stub pattern). Everything downstream of "no
# convoy target" exercises REAL local git repos under a temp sandbox (mirrors
# cv-worktree-prep.test.sh's mk_repo/git_c pattern) — no network, no stubs for
# git itself, since git's own rebase/merge-base/fetch behavior is exactly
# what's under test.
#
# Run:  bash tests/con-voyage-stacked-pr-base.test.sh   (exit 0 => all cases passed)

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

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-stacked-pr-base-test.XXXXXX")"
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
  printf 'placeholder\n' > "$repo/README.md"
  git_c "$repo" add README.md
  git_c "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

# ---------------------------------------------------------------------------
# Recording `gc` stub — only `convoy status <id> --json` is needed here.
# Mirrors con-voyage-lib.test.sh's stub pattern (STUB_BDSHOW_JSON_<id>) but
# keyed for convoy status instead.
# ---------------------------------------------------------------------------
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
if [ "${args[$i]:-}" = "convoy" ] && [ "${args[$((i+1))]:-}" = "status" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_CONVOY_STATUS_JSON_${id//-/_}"
  printf '%s' "${!var:-}"
  exit 0
fi
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"
# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
GC="${STUBDIR}/gc"

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

# ===========================================================================
# cv_convoy_target
# ===========================================================================
start_case "cv_convoy_target: convoy with a target field set -> returns it"
export STUB_CONVOY_STATUS_JSON_cv_1='{"convoy":{"id":"cv-1","fields":{"target":"polecat/mold/slice1"}}}'
assert_eq "polecat/mold/slice1" "$(cv_convoy_target "cv-1")" "returns the stored target verbatim"

start_case "cv_convoy_target: convoy with an empty fields object -> empty"
export STUB_CONVOY_STATUS_JSON_cv_2='{"convoy":{"id":"cv-2","fields":{}}}'
assert_eq "" "$(cv_convoy_target "cv-2")" "no target key -> empty output"

start_case "cv_convoy_target: unresolvable convoy id -> empty (fail-safe, not an error)"
assert_eq "" "$(cv_convoy_target "cv-unknown")" "no stub configured -> gc prints nothing -> empty"

start_case "cv_convoy_target: empty input -> empty"
assert_eq "" "$(cv_convoy_target "")" "empty input echoes empty (caller's problem, never invents an id)"

# ===========================================================================
# cv_resolve_base_branch
# ===========================================================================
start_case "cv_resolve_base_branch: convoy target set -> short-circuits, never reads the worktree dir"
export STUB_CONVOY_STATUS_JSON_cv_3='{"convoy":{"id":"cv-3","fields":{"target":"polecat/mold/slice1"}}}'
assert_eq "polecat/mold/slice1" "$(cv_resolve_base_branch "cv-3" "/nonexistent/path/should/never/be/read")" "returns the convoy target directly"

start_case "cv_resolve_base_branch: no convoy target -> delegates to cv-worktree-prep.sh resolve-base"
REPO1="$(mk_repo repo1)"
UPSTREAM1="${SANDBOX}/repo1-upstream.git"
git init -q -b main --bare "$UPSTREAM1"
git_c "$REPO1" remote add origin "$UPSTREAM1"
git_c "$REPO1" push -q -u origin main
git_c "$REPO1" remote set-head origin main
assert_eq "origin/main" "$(bash "$PREP_SCRIPT" resolve-base "$REPO1")" "sanity: cv-worktree-prep.sh's own resolve-base is unchanged (a remote-tracking ref, correct for guard's diff base)"
assert_eq "main" "$(cv_resolve_base_branch "cv-unknown" "$REPO1")" "fk-qppb4 B1: strips the origin/ prefix so the result is a bare branch name gh pr create --base accepts"

if command -v zsh >/dev/null 2>&1; then
  zsh_out="$(GC="$GC" zsh -c 'source "'"$LIB"'" && cv_resolve_base_branch "cv-unknown" "'"$REPO1"'"' 2>/dev/null)"
  assert_eq "main" "$zsh_out" "fk-qppb4 B2: sourced under zsh (BASH_SOURCE[0] is empty there), still delegates instead of silently falling back to a hardcoded main"
else
  echo "  SKIP: zsh not available in this environment — fk-qppb4 B2 zsh-parity check not run"
fi

start_case "cv_resolve_base_branch: no convoy target, no remote at all -> the empty-tree fail-safe degrades further to the literal 'main'"
REPO2="${SANDBOX}/repo2"
mkdir -p "$REPO2"
git_c "$REPO2" init -q -b trunk
printf 'x\n' > "${REPO2}/f.txt"
git_c "$REPO2" add f.txt
git_c "$REPO2" commit -q -m "init"
assert_eq "main" "$(cv_resolve_base_branch "cv-unknown" "$REPO2")" "an empty-tree hash is not a usable branch name, so this falls back further than guard does"

# ===========================================================================
# cv_ensure_branch_based_on
# ===========================================================================
start_case "cv_ensure_branch_based_on: empty base_branch -> no-op, HEAD untouched, no fetch attempted"
REPO3="$(mk_repo repo3)"
before_sha="$(git_c "$REPO3" rev-parse HEAD)"
cv_ensure_branch_based_on "$REPO3" ""
rc=$?
assert_eq "0" "$rc" "returns 0 for an empty base_branch"
assert_eq "$before_sha" "$(git_c "$REPO3" rev-parse HEAD)" "HEAD is unchanged (no remote configured, so any fetch attempt would have failed loudly)"

start_case "cv_ensure_branch_based_on: worktree already based on the target -> no rebase needed"
UPSTREAM4="${SANDBOX}/repo4-upstream.git"
git init -q -b main --bare "$UPSTREAM4"
REPO4="$(mk_repo repo4)"
git_c "$REPO4" remote add origin "$UPSTREAM4"
git_c "$REPO4" push -q -u origin main
git_c "$REPO4" checkout -q -b work
printf 'impl\n' > "${REPO4}/impl.txt"
git_c "$REPO4" add impl.txt
git_c "$REPO4" commit -q -m "feat: implementation commit"
before_sha4="$(git_c "$REPO4" rev-parse HEAD)"
cv_ensure_branch_based_on "$REPO4" "main"
rc=$?
assert_eq "0" "$rc" "returns 0 when already based on the target"
assert_eq "$before_sha4" "$(git_c "$REPO4" rev-parse HEAD)" "HEAD is unchanged — no rebase performed"

start_case "cv_ensure_branch_based_on: stacked slice -> rebases the implementation commit onto the real base"
UPSTREAM5="${SANDBOX}/repo5-upstream.git"
git init -q -b main --bare "$UPSTREAM5"
REPO5="$(mk_repo repo5)"
git_c "$REPO5" remote add origin "$UPSTREAM5"
git_c "$REPO5" push -q -u origin main
git_c "$REPO5" remote set-head origin main
# slice1: an already-open stacked PR branch, one commit ahead of main.
git_c "$REPO5" checkout -q -b slice1
printf 'slice1\n' > "${REPO5}/slice1.txt"
git_c "$REPO5" add slice1.txt
git_c "$REPO5" commit -q -m "feat: slice1"
git_c "$REPO5" push -q -u origin slice1
# Simulate prepare-worktree cutting slice2's worktree from main (the
# always-main default core do-work knows about) instead of slice1.
git_c "$REPO5" checkout -q main
git_c "$REPO5" checkout -q -b slice2-work
printf 'slice2\n' > "${REPO5}/slice2.txt"
git_c "$REPO5" add slice2.txt
git_c "$REPO5" commit -q -m "feat: slice2 implementation"
cv_ensure_branch_based_on "$REPO5" "slice1"
rc=$?
assert_eq "0" "$rc" "rebase onto slice1 succeeds (no conflict)"
if git_c "$REPO5" merge-base --is-ancestor origin/slice1 HEAD 2>/dev/null; then
  pass "slice1's tip is now a real ancestor of HEAD (properly stacked)"
else
  fail "expected origin/slice1 to be an ancestor of HEAD after the rebase"
fi
assert_eq "slice1" "$(cat "${REPO5}/slice1.txt")" "slice1's own change is present after rebase"
assert_eq "slice2" "$(cat "${REPO5}/slice2.txt")" "slice2's implementation change survived the rebase"

start_case "cv_ensure_branch_based_on: base branch does not resolve to any commit -> fails loud"
REPO6="$(mk_repo repo6)"
before_sha6="$(git_c "$REPO6" rev-parse HEAD)"
err6="$(cv_ensure_branch_based_on "$REPO6" "no-such-branch-anywhere" 2>&1)"
rc=$?
assert_eq "1" "$rc" "returns non-zero when the base branch cannot be resolved"
case "$err6" in
  *"does not resolve"*) pass "error message explains the base branch could not be resolved" ;;
  *) fail "expected an explanatory error message, got: ${err6}" ;;
esac
assert_eq "$before_sha6" "$(git_c "$REPO6" rev-parse HEAD)" "HEAD is unchanged when the base cannot be resolved"

start_case "cv_ensure_branch_based_on: rebase conflict -> fails loud and leaves the worktree clean (rebase aborted)"
UPSTREAM7="${SANDBOX}/repo7-upstream.git"
git init -q -b main --bare "$UPSTREAM7"
REPO7="$(mk_repo repo7)"
git_c "$REPO7" remote add origin "$UPSTREAM7"
git_c "$REPO7" push -q -u origin main
git_c "$REPO7" remote set-head origin main
# slice1 changes README.md's first line.
git_c "$REPO7" checkout -q -b slice1
printf 'slice1 line\n' > "${REPO7}/README.md"
git_c "$REPO7" add README.md
git_c "$REPO7" commit -q -m "feat: slice1 touches README"
git_c "$REPO7" push -q -u origin slice1
# slice2-work (cut from main) ALSO changes README.md's first line, differently.
git_c "$REPO7" checkout -q main
git_c "$REPO7" checkout -q -b slice2-work
printf 'slice2 conflicting line\n' > "${REPO7}/README.md"
git_c "$REPO7" add README.md
git_c "$REPO7" commit -q -m "feat: slice2 also touches README (conflicts with slice1)"
before_sha7="$(git_c "$REPO7" rev-parse HEAD)"
err7="$(cv_ensure_branch_based_on "$REPO7" "slice1" 2>&1)"
rc=$?
assert_eq "1" "$rc" "returns non-zero on a rebase conflict"
case "$err7" in
  *"conflict"*) pass "error message calls out the conflict" ;;
  *) fail "expected an explanatory conflict error message, got: ${err7}" ;;
esac
assert_eq "$before_sha7" "$(git_c "$REPO7" rev-parse HEAD)" "HEAD is restored to its pre-rebase commit (rebase --abort ran)"
if [ -d "${REPO7}/.git/rebase-merge" ] || [ -d "${REPO7}/.git/rebase-apply" ]; then
  fail "expected no in-progress rebase state left behind"
else
  pass "no in-progress rebase state left behind — worktree is usable again"
fi

# ===========================================================================
# {target}.setup-con-voyage-review.md — structural check (mirrors
# con-voyage-publish.test.sh's assert_contains/line_of pattern for verifying
# embedded bash in a workflow .md file) that the setup step actually wires
# cv_resolve_base_branch and cv_ensure_branch_based_on in, in the right order,
# before gathering review context.
# ===========================================================================
SETUP_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/{target}.setup-con-voyage-review.md"
if [ ! -f "$SETUP_MD" ]; then
  echo "FATAL: workflow file under test not found at ${SETUP_MD}" >&2
  exit 2
fi

assert_md_contains() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$SETUP_MD"; then
    pass "$label"
  else
    fail "$label (not found verbatim in ${SETUP_MD})"
  fi
}

md_line_of() {
  grep -nF -- "$1" "$SETUP_MD" | head -1 | cut -d: -f1
}

start_case "setup-con-voyage-review.md: resolves BASE_BRANCH and corrects the worktree before gathering review context"
assert_md_contains 'BASE_BRANCH="$(source "$CV_LIB" && cv_resolve_base_branch "$CONVOY_ID" "$(pwd)")"' "resolves BASE_BRANCH via the shared cv_resolve_base_branch()"
assert_md_contains 'CONVOY_TARGET="$(source "$CV_LIB" && cv_convoy_target "$CONVOY_ID")"' "resolves CONVOY_TARGET via the shared cv_convoy_target()"
assert_md_contains 'source "$CV_LIB" && cv_ensure_branch_based_on "$(pwd)" "$CONVOY_TARGET"' "calls cv_ensure_branch_based_on with CONVOY_TARGET, not the always-resolved BASE_BRANCH, so an unconfigured journey stays a byte-identical no-op (fk-qppb4 L3)"
assert_md_contains 'gc.failure_class=base_branch_conflict' "a failed rebase closes the step with a distinct, actionable failure_class"

resolve_line="$(md_line_of 'BASE_BRANCH="$(source "$CV_LIB" && cv_resolve_base_branch "$CONVOY_ID" "$(pwd)")"')"
rebase_line="$(md_line_of 'source "$CV_LIB" && cv_ensure_branch_based_on "$(pwd)" "$CONVOY_TARGET"')"
gather_line="$(md_line_of 'Gather the requirements artifact')"

if [ -n "$resolve_line" ] && [ -n "$rebase_line" ] && [ "$resolve_line" -lt "$rebase_line" ]; then
  pass "BASE_BRANCH resolution (line ${resolve_line}) precedes the rebase call (line ${rebase_line})"
else
  fail "expected BASE_BRANCH resolution to precede the rebase call"
fi

if [ -n "$rebase_line" ] && [ -n "$gather_line" ] && [ "$rebase_line" -lt "$gather_line" ]; then
  pass "the rebase call (line ${rebase_line}) precedes gathering review context (line ${gather_line})"
else
  fail "expected the rebase correction to happen before review context is gathered"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
