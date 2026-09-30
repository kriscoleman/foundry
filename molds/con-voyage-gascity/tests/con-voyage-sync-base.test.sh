#!/usr/bin/env bash
# con-voyage-sync-base.test.sh — hermetic, offline tests for fk-hbsmk:
# cv_sync_worktree_to_base, the shared "make sure this worktree starts from
# the CURRENT origin default base" helper every con-voyage step that writes
# code calls at its START, so a worker never silently implements against a
# stale local main.
#
# EVIDENCE (operator directive, Slack #repl-city-mayor 2026-09-26 15:00): 4 of
# 7 foundry-kc con-voyage builds on 2026-09-26 started on the rig's stale
# local main (18 commits behind origin/main) on a DETACHED HEAD, because a
# first-match `find` resolution picked a stale cv-worktree-prep.sh. The mayor
# caught it by hand and had each builder rebase. This makes the sync
# structural instead of a habit.
#
# cv_sync_worktree_to_base DIR [BRANCH_NAME]:
#   1. git fetch origin (bounded by cv_with_timeout — macOS has no timeout(1)).
#   2. delegates to cv-worktree-prep.sh ensure-branch (fk-tazxl) so a detached
#      worktree gets a name before anything else happens.
#   3. delegates to cv-worktree-prep.sh resolve-base for the current default
#      base ref (origin/HEAD -> origin/main -> main), never re-deriving that
#      order itself (must never disagree with guard/built/
#      cv_resolve_base_branch about what "the base" means).
#   4. HEAD already contains the resolved base -> no-op.
#   5. Otherwise, diff HEAD against ITS merge-base with the new base: zero
#      commits of DIR's own beyond it -> recreate the branch straight from
#      the new base (`checkout -B`, never `git merge`); one or more -> replay
#      them onto the new base (`rebase --onto`, preserving DIR's own
#      commits). A conflict aborts the rebase immediately and fails closed —
#      never a half-finished rebase left behind.
#
# Prints exactly one bare word to stdout on success: noop | recreated |
# rebased (the same "pure value on stdout, diagnostics on stderr" contract
# cv_resolve_base_branch/resolve-base already use) — nothing to stdout and a
# non-zero exit on any failure.
#
# HOW IT WORKS: real local git repos under a temp sandbox (mirrors
# con-voyage-stacked-pr-base.test.sh's mk_repo/git_c pattern) — no stubs for
# git itself, since git's own fetch/rebase/merge-base behavior is exactly
# what's under test. `gc` is stubbed only so `source "$LIB"` succeeds; the
# code path under test here never calls it.
#
# Run:  bash tests/con-voyage-sync-base.test.sh   (exit 0 => all cases passed)

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

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-sync-base-test.XXXXXX")"
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
  # Persist identity into the repo's own config (not just a per-invocation `-c`
  # override): the rebase path under test creates a real replayed commit, and
  # a bare CI runner's auto-derived identity can have an empty name and abort
  # the rebase ("empty ident name ... not allowed") — see
  # con-voyage-stacked-pr-base.test.sh's mk_repo for the same precedent.
  git_c "$repo" config user.email test@example.com
  git_c "$repo" config user.name "Test"
  printf 'placeholder\n' > "$repo/README.md"
  git_c "$repo" add README.md
  git_c "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

# Fake `gc` so `source "$LIB"` succeeds; not called by cv_sync_worktree_to_base.
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

# Keep every fetch in this suite instant and bounded even if something regresses.
export CV_SYNC_FETCH_TIMEOUT_SECONDS=5

# ===========================================================================
# CASE 1 — already up to date on a named branch -> no-op. Idempotent: running
#   it twice in a row is still a no-op.
# ===========================================================================
start_case "1: already current on a named branch -> no-op, idempotent"
UPSTREAM1="${SANDBOX}/repo1-upstream.git"
git init -q -b main --bare "$UPSTREAM1"
REPO1="$(mk_repo repo1)"
git_c "$REPO1" remote add origin "$UPSTREAM1"
git_c "$REPO1" push -q -u origin main
git_c "$REPO1" remote set-head origin main
before_sha1="$(git_c "$REPO1" rev-parse HEAD)"
result1="$(cv_sync_worktree_to_base "$REPO1" 2>/dev/null)"
rc1=$?
assert_eq "0" "$rc1" "exits 0 when already current"
assert_eq "noop" "$result1" "reports noop"
assert_eq "$before_sha1" "$(git_c "$REPO1" rev-parse HEAD)" "HEAD unchanged"
assert_eq "main" "$(git_c "$REPO1" symbolic-ref --short HEAD)" "stays on its named branch"
result1b="$(cv_sync_worktree_to_base "$REPO1" 2>/dev/null)"
assert_eq "noop" "$result1b" "idempotent: a second run is still a no-op"

# ===========================================================================
# CASE 2 — detached HEAD, already current -> gets a named branch attached
#   (delegates to ensure-branch), still reports noop (content unchanged).
# ===========================================================================
start_case "2: detached HEAD, already current -> named branch attached, reports noop"
UPSTREAM2="${SANDBOX}/repo2-upstream.git"
git init -q -b main --bare "$UPSTREAM2"
REPO2="$(mk_repo repo2)"
git_c "$REPO2" remote add origin "$UPSTREAM2"
git_c "$REPO2" push -q -u origin main
git_c "$REPO2" remote set-head origin main
WT2="${SANDBOX}/repo2-worktree"
git_c "$REPO2" worktree add -q --detach "$WT2" HEAD
before_sha2="$(git_c "$WT2" rev-parse HEAD)"
if git_c "$WT2" symbolic-ref -q --short HEAD >/dev/null 2>&1; then
  fail "expected the fixture worktree to start detached"
else
  pass "fixture worktree starts detached, confirming this case is meaningful"
fi
result2="$(cv_sync_worktree_to_base "$WT2" "con-voyage/repo2-worktree" 2>/dev/null)"
rc2=$?
assert_eq "0" "$rc2" "exits 0"
assert_eq "noop" "$result2" "reports noop (content unchanged)"
assert_eq "$before_sha2" "$(git_c "$WT2" rev-parse HEAD)" "HEAD's commit is unchanged"
assert_eq "con-voyage/repo2-worktree" "$(git_c "$WT2" symbolic-ref --short HEAD 2>/dev/null)" "worktree is no longer detached — named branch attached"

# ===========================================================================
# CASE 3 — fresh worktree, zero commits of its own, stale local base ->
#   recreated straight from the new origin/main tip (checkout -B), never a
#   rebase (nothing of the caller's own to replay).
# ===========================================================================
start_case "3: no local commits + stale base -> recreated from origin/main"
UPSTREAM3="${SANDBOX}/repo3-upstream.git"
git init -q -b main --bare "$UPSTREAM3"
REPO3="$(mk_repo repo3)"
git_c "$REPO3" remote add origin "$UPSTREAM3"
git_c "$REPO3" push -q -u origin main
git_c "$REPO3" remote set-head origin main
WT3="${SANDBOX}/repo3-worktree"
git_c "$REPO3" worktree add -q --detach "$WT3" HEAD
stale_sha3="$(git_c "$WT3" rev-parse HEAD)"
# origin/main advances with a new commit the worktree has never seen.
printf 'v2\n' >> "${REPO3}/README.md"
git_c "$REPO3" add README.md
git_c "$REPO3" commit -q -m "feat: upstream advances"
git_c "$REPO3" push -q origin main
new_tip3="$(git_c "$REPO3" rev-parse main)"
if [ "$stale_sha3" = "$new_tip3" ]; then
  fail "fixture setup bug: origin/main did not actually advance"
else
  pass "fixture: origin/main advanced past the worktree's stale commit"
fi
result3="$(cv_sync_worktree_to_base "$WT3" "con-voyage/repo3-worktree" 2>/dev/null)"
rc3=$?
assert_eq "0" "$rc3" "exits 0"
assert_eq "recreated" "$result3" "reports recreated"
assert_eq "$new_tip3" "$(git_c "$WT3" rev-parse HEAD)" "HEAD now matches the new origin/main tip"
assert_eq "con-voyage/repo3-worktree" "$(git_c "$WT3" symbolic-ref --short HEAD 2>/dev/null)" "worktree is on the named branch"

# ===========================================================================
# CASE 4 — worktree with REAL local commits, behind origin/main -> rebased
#   onto the new tip, own commit(s) preserved.
# ===========================================================================
start_case "4: worktree behind origin/main WITH local commits -> rebased, commits preserved"
UPSTREAM4="${SANDBOX}/repo4-upstream.git"
git init -q -b main --bare "$UPSTREAM4"
REPO4="$(mk_repo repo4)"
git_c "$REPO4" remote add origin "$UPSTREAM4"
git_c "$REPO4" push -q -u origin main
git_c "$REPO4" remote set-head origin main
WT4="${SANDBOX}/repo4-worktree"
git_c "$REPO4" worktree add -q --detach "$WT4" HEAD
git_c "$WT4" checkout -q -b con-voyage/repo4-worktree
printf 'impl\n' > "${WT4}/impl.txt"
git_c "$WT4" add impl.txt
git_c "$WT4" commit -q -m "feat: implementation commit"
own_commit_msg4="$(git_c "$WT4" log -1 --format=%s)"
# origin/main advances underneath, unrelated to impl.txt.
printf 'v2\n' >> "${REPO4}/README.md"
git_c "$REPO4" add README.md
git_c "$REPO4" commit -q -m "feat: upstream advances"
git_c "$REPO4" push -q origin main
new_tip4="$(git_c "$REPO4" rev-parse main)"
result4="$(cv_sync_worktree_to_base "$WT4" 2>/dev/null)"
rc4=$?
assert_eq "0" "$rc4" "exits 0"
assert_eq "rebased" "$result4" "reports rebased"
if git_c "$WT4" merge-base --is-ancestor "$new_tip4" HEAD 2>/dev/null; then
  pass "the new origin/main tip is now an ancestor of HEAD"
else
  fail "expected the new origin/main tip to be an ancestor of HEAD after rebase"
fi
assert_eq "impl" "$(cat "${WT4}/impl.txt")" "the worktree's own implementation change survived the rebase"
assert_eq "$own_commit_msg4" "$(git_c "$WT4" log -1 --format=%s)" "own commit message preserved (replayed, not squashed)"
assert_eq "con-voyage/repo4-worktree" "$(git_c "$WT4" symbolic-ref --short HEAD 2>/dev/null)" "stays on its own named branch"

# ===========================================================================
# CASE 5 — rebase conflict -> fails closed: non-zero exit, HEAD restored to
#   its pre-sync commit, no leftover rebase state, never falls back to merge.
# ===========================================================================
start_case "5: conflicting rebase -> non-zero exit, clean tree, HEAD restored"
UPSTREAM5="${SANDBOX}/repo5-upstream.git"
git init -q -b main --bare "$UPSTREAM5"
REPO5="$(mk_repo repo5)"
git_c "$REPO5" remote add origin "$UPSTREAM5"
git_c "$REPO5" push -q -u origin main
git_c "$REPO5" remote set-head origin main
WT5="${SANDBOX}/repo5-worktree"
git_c "$REPO5" worktree add -q --detach "$WT5" HEAD
git_c "$WT5" checkout -q -b con-voyage/repo5-worktree
printf 'worktree line\n' > "${WT5}/README.md"
git_c "$WT5" add README.md
git_c "$WT5" commit -q -m "feat: worktree touches README"
before_sha5="$(git_c "$WT5" rev-parse HEAD)"
# origin/main advances with a CONFLICTING change to the same line.
printf 'upstream line\n' > "${REPO5}/README.md"
git_c "$REPO5" add README.md
git_c "$REPO5" commit -q -m "feat: upstream also touches README (conflicts)"
git_c "$REPO5" push -q origin main
err5="$(cv_sync_worktree_to_base "$WT5" 2>&1 >/dev/null)"
rc5=$?
assert_eq "1" "$rc5" "returns non-zero on a rebase conflict"
case "$err5" in
  *"conflict"*) pass "error message calls out the conflict" ;;
  *) fail "expected an explanatory conflict error message, got: ${err5}" ;;
esac
assert_eq "$before_sha5" "$(git_c "$WT5" rev-parse HEAD)" "HEAD is restored to its pre-sync commit (rebase --abort ran)"
# WT5 is a LINKED worktree (`git worktree add`), so `${WT5}/.git` is a plain
# FILE (a `gitdir:` pointer), never a directory — `${WT5}/.git/rebase-merge`
# can therefore never resolve to a directory on any machine regardless of
# whether rebase state was actually left behind, making the old guessed-path
# check tautological (dropping the `rebase --abort` call entirely would still
# PASS). Resolve the worktree's real git-dir indirection instead (review
# fk-hbsmk B3, con-voyage synthesis root fk-gg5d6).
WT5_REBASE_MERGE="$(git_c "$WT5" rev-parse --git-path rebase-merge)"
WT5_REBASE_APPLY="$(git_c "$WT5" rev-parse --git-path rebase-apply)"
if [ -d "$WT5_REBASE_MERGE" ] || [ -d "$WT5_REBASE_APPLY" ]; then
  fail "expected no in-progress rebase state left behind (resolved via 'git rev-parse --git-path', not a guessed .git subpath)"
else
  pass "no in-progress rebase state left behind (resolved via the worktree's real git-dir indirection)"
fi
status_out5="$(git_c "$WT5" status --porcelain)"
assert_eq "" "$status_out5" "worktree is clean after the aborted rebase"

# ===========================================================================
# CASE 6 — no origin remote configured at all -> fetch cannot succeed -> this
#   fails closed rather than silently skip the sync (the whole point of this
#   helper is to never let a step proceed on an unconfirmed base).
# ===========================================================================
start_case "6: no origin remote at all -> fails closed rather than silently proceeding"
REPO6="$(mk_repo repo6)"
before_sha6="$(git_c "$REPO6" rev-parse HEAD)"
err6="$(cv_sync_worktree_to_base "$REPO6" 2>&1 >/dev/null)"
rc6=$?
assert_eq "1" "$rc6" "returns non-zero when there is no origin to sync against"
assert_eq "$before_sha6" "$(git_c "$REPO6" rev-parse HEAD)" "HEAD is untouched"

# ===========================================================================
# CASE 7 — review fk-hbsmk B2 (con-voyage synthesis root fk-gg5d6):
#   cv-worktree-prep.sh resolution must be deterministic via a caller-
#   supplied CV_PACK_ROOT, not solely dependent on the fragile `command -v ||
#   find $GC_CITY -maxdepth 6` fallback — the exact stale-copy-resolution
#   mechanism this whole helper exists to eliminate for base resolution
#   itself. GC_CITY is pointed at a sandbox with nothing findable in it, so
#   the ONLY way this can succeed is via CV_PACK_ROOT.
# ===========================================================================
start_case "7: CV_PACK_ROOT resolves cv-worktree-prep.sh deterministically, independent of the find fallback"
UPSTREAM7="${SANDBOX}/repo7-upstream.git"
git init -q -b main --bare "$UPSTREAM7"
REPO7="$(mk_repo repo7)"
git_c "$REPO7" remote add origin "$UPSTREAM7"
git_c "$REPO7" push -q -u origin main
git_c "$REPO7" remote set-head origin main
EMPTY_CITY7="${SANDBOX}/empty-city-7"
mkdir -p "$EMPTY_CITY7"
ERR7="${SANDBOX}/case7-err.log"
GC_CITY_SAVE7="${GC_CITY:-}"
GC_CITY="$EMPTY_CITY7"
result7="$(CV_PACK_ROOT="${MOLD_DIR}/pack" cv_sync_worktree_to_base "$REPO7" 2>"$ERR7")"
rc7=$?
GC_CITY="$GC_CITY_SAVE7"
assert_eq "0" "$rc7" "exits 0 — CV_PACK_ROOT alone is enough, GC_CITY has nothing findable"
assert_eq "noop" "$result7" "reports noop (already current)"
if [ -s "$ERR7" ] && grep -qi 'cv-worktree-prep.sh not found' "$ERR7"; then
  fail "expected CV_PACK_ROOT to resolve cv-worktree-prep.sh without needing the find fallback, got: $(cat "$ERR7")"
else
  pass "cv-worktree-prep.sh was resolved via CV_PACK_ROOT, not the (here, unusable) find fallback"
fi

# ===========================================================================
# Structural checks — the helper must actually be wired into every
# code-writing step's START, not just exist unused in the lib.
# ===========================================================================
BUILD_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.build.md"
APPLY_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.apply-review-findings.md"
CI_REPAIR_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage-ci-repair/main.ci-repair.md"
PREPARE_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.prepare-build.md"
for f in "$BUILD_MD" "$APPLY_MD" "$CI_REPAIR_MD" "$PREPARE_MD"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: workflow file under test not found at ${f}" >&2
    exit 2
  fi
done

assert_md_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label (not found verbatim in ${file})"
  fi
}

md_line_of() {
  local file="$1" needle="$2"
  grep -nF -- "$needle" "$file" | head -1 | cut -d: -f1
}

start_case "build.md: calls cv_sync_worktree_to_base before the short-circuit decision"
assert_md_contains "$BUILD_MD" 'cv_sync_worktree_to_base "$WORKTREE"' "build.md calls cv_sync_worktree_to_base on \$WORKTREE"
sync_line_build="$(md_line_of "$BUILD_MD" 'cv_sync_worktree_to_base "$WORKTREE"')"
shortcircuit_line_build="$(md_line_of "$BUILD_MD" '## Short-circuit')"
if [ -n "$sync_line_build" ] && [ -n "$shortcircuit_line_build" ] && [ "$sync_line_build" -lt "$shortcircuit_line_build" ]; then
  pass "sync call (line ${sync_line_build}) precedes the short-circuit decision (line ${shortcircuit_line_build})"
else
  fail "expected the sync call to precede the short-circuit decision"
fi

start_case "build.md: CV_LIB bootstrap prefers GC_RIG_ROOT over the worktree's own (possibly stale) mold copy (fk-n7qn1)"
# Same class of bug as apply-review-findings.md below, and fatal here too
# (this call sits before the short-circuit decision, so it aborts the whole
# build step): a worktree whose checked-out branch predates
# cv_sync_worktree_to_base's introduction has no copy of the function in its
# own mold cast, so resolving CV_LIB solely from the worktree's own
# `git rev-parse --show-toplevel` can never self-heal. GC_RIG_ROOT must be
# tried first.
assert_md_contains "$BUILD_MD" 'CV_TOPLEVEL="${GC_RIG_ROOT:-}"' "build.md's sync bootstrap starts from GC_RIG_ROOT, not the worktree's own git toplevel"
rig_root_line_build="$(md_line_of "$BUILD_MD" 'CV_TOPLEVEL="${GC_RIG_ROOT:-}"')"
worktree_toplevel_line_build="$(md_line_of "$BUILD_MD" '  CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"')"
if [ -n "$rig_root_line_build" ] && [ -n "$worktree_toplevel_line_build" ] && [ "$rig_root_line_build" -lt "$worktree_toplevel_line_build" ]; then
  pass "GC_RIG_ROOT is tried (line ${rig_root_line_build}) before falling back to the worktree's own toplevel (line ${worktree_toplevel_line_build})"
else
  fail "expected GC_RIG_ROOT resolution to precede the worktree-toplevel fallback (a worktree whose own mold predates cv_sync_worktree_to_base must not be the only source tried)"
fi

start_case "apply-review-findings.md: calls cv_sync_worktree_to_base at the start and treats a change as iterate"
# review fk-hbsmk B1 (con-voyage synthesis root fk-gg5d6): the previous
# looser check here (bare function-name substring) could not tell
# `cv_sync_worktree_to_base "$(pwd)"` (syncs the shared rig-root launcher
# checkout — wrong) apart from `cv_sync_worktree_to_base "$WORKTREE"` (syncs
# the actual target worktree — right), so it stayed green through the bug.
# Require the same exact-argument pattern build.md's own check already does,
# plus an explicit negative-control that the old buggy call shape is gone.
assert_md_contains "$APPLY_MD" 'cv_sync_worktree_to_base "$WORKTREE"' "apply-review-findings.md calls cv_sync_worktree_to_base on \$WORKTREE, not ambient \$(pwd)"
if grep -qF 'cv_sync_worktree_to_base "$(pwd)"' "$APPLY_MD"; then
  fail "apply-review-findings.md must never sync via ambient \$(pwd) — that syncs the shared rig-root launcher checkout, not the target worktree (fk-hbsmk B1)"
else
  pass "no ambient-\$(pwd) sync call regressed back in"
fi
assert_md_contains "$APPLY_MD" 'code_review.verdict=iterate' "apply-review-findings.md still documents the iterate verdict"
sync_line_apply="$(md_line_of "$APPLY_MD" 'cv_sync_worktree_to_base')"
verdict_section_line_apply="$(md_line_of "$APPLY_MD" '### Setting code_review.verdict')"
if [ -n "$sync_line_apply" ] && [ -n "$verdict_section_line_apply" ] && [ "$sync_line_apply" -lt "$verdict_section_line_apply" ]; then
  pass "sync call (line ${sync_line_apply}) precedes the verdict-setting section (line ${verdict_section_line_apply})"
else
  fail "expected the sync call to precede the verdict-setting section"
fi
case "$(cat "$APPLY_MD")" in
  *"sync"*"recreated"*|*"recreated"*"sync"*) pass "apply-review-findings.md's prose accounts for a recreated/rebased sync result forcing iterate" ;;
  *) fail "expected apply-review-findings.md to call out that a sync-induced change (recreated/rebased) also forces verdict=iterate" ;;
esac

start_case "prepare-build.md: syncs a freshly-created worktree to origin's current base before handing it off (fk-grepg)"
# fk-grepg: `git worktree add "$WORKTREE" --detach HEAD` bases a brand new
# worktree on whatever the SHARED rig-root checkout's HEAD happens to be at
# that instant, not on origin's current default branch. If a concurrent
# workflow has left the rig root on its own feature branch, every fresh
# worktree created here silently inherits that branch's commits (confirmed
# live: worktrees/fk-qzq0p and worktrees/fk-5r71y both inherited
# fk-atuxk's already-merged commit 8052f36 this way). The fresh-bead branch
# must call cv_sync_worktree_to_base on $WORKTREE right after creating it, the
# same structural fix build.md/apply-review-findings.md/ci-repair.md already
# apply at their own start (fk-hbsmk) — cv_sync_worktree_to_base's own
# CASE 3 above already proves this recreates a stale/contaminated fresh
# worktree from the real origin/main tip, so this is a wiring check only, not
# a re-test of that behavior.
assert_md_contains "$PREPARE_MD" 'cv_sync_worktree_to_base "$WORKTREE"' "prepare-build.md calls cv_sync_worktree_to_base on \$WORKTREE"
if grep -qF 'cv_sync_worktree_to_base "$(pwd)"' "$PREPARE_MD"; then
  fail "prepare-build.md must never sync via ambient \$(pwd) — that syncs the shared rig-root launcher checkout, not the freshly created worktree (fk-hbsmk B1 class)"
else
  pass "no ambient-\$(pwd) sync call regressed back in"
fi
worktree_add_line_prepare="$(md_line_of "$PREPARE_MD" 'git worktree add "$WORKTREE" --detach HEAD')"
sync_line_prepare="$(md_line_of "$PREPARE_MD" 'cv_sync_worktree_to_base "$WORKTREE"')"
# fk-ki8je's earlier PRIOR_ANCHOR_DIR reuse branch has its own, EARLIER
# occurrence of this exact work_dir line — grab the LAST occurrence, which is
# the fresh-bead branch's, the one this sync call must actually precede.
work_dir_line_prepare="$(grep -nF -- 'gc bd update "$CONVOY_ID" --set-metadata "work_dir=${WORKTREE}"' "$PREPARE_MD" | tail -1 | cut -d: -f1)"
if [ -n "$worktree_add_line_prepare" ] && [ -n "$sync_line_prepare" ] && [ "$worktree_add_line_prepare" -lt "$sync_line_prepare" ]; then
  pass "sync call (line ${sync_line_prepare}) comes after worktree creation (line ${worktree_add_line_prepare})"
else
  fail "expected the sync call to come after 'git worktree add \"\$WORKTREE\" --detach HEAD'"
fi
if [ -n "$sync_line_prepare" ] && [ -n "$work_dir_line_prepare" ] && [ "$sync_line_prepare" -lt "$work_dir_line_prepare" ]; then
  pass "sync call (line ${sync_line_prepare}) precedes persisting work_dir on the convoy (line ${work_dir_line_prepare})"
else
  fail "expected the sync call to precede persisting work_dir, so a contaminated worktree is never handed off as resolved"
fi

start_case "apply-review-findings.md: CV_LIB bootstrap prefers GC_RIG_ROOT over the worktree's own (possibly stale) mold copy (fk-n7qn1)"
# fk-n7qn1: if the worktree's own branch predates cv_sync_worktree_to_base's
# introduction into con-voyage-lib.sh, its own molds/con-voyage-gascity copy
# lacks the function entirely, so resolving CV_LIB solely from the
# worktree's own `git -C "$WORKTREE" rev-parse --show-toplevel` can never
# self-heal — the very call meant to sync the worktree needs a copy of the
# function the worktree does not have. GC_RIG_ROOT (every gc-spawned session
# already carries it) always points at the rig root, which recast+go-live
# keeps current, so it must be tried first.
assert_md_contains "$APPLY_MD" 'CV_TOPLEVEL="${GC_RIG_ROOT:-}"' "apply-review-findings.md's sync bootstrap starts from GC_RIG_ROOT, not the worktree's own git toplevel"
rig_root_line_apply="$(md_line_of "$APPLY_MD" 'CV_TOPLEVEL="${GC_RIG_ROOT:-}"')"
worktree_toplevel_line_apply="$(md_line_of "$APPLY_MD" 'git -C "$WORKTREE" rev-parse --show-toplevel')"
if [ -n "$rig_root_line_apply" ] && [ -n "$worktree_toplevel_line_apply" ] && [ "$rig_root_line_apply" -lt "$worktree_toplevel_line_apply" ]; then
  pass "GC_RIG_ROOT is tried (line ${rig_root_line_apply}) before falling back to the worktree's own toplevel (line ${worktree_toplevel_line_apply})"
else
  fail "expected GC_RIG_ROOT resolution to precede the worktree-toplevel fallback (a worktree whose own mold predates cv_sync_worktree_to_base must not be the only source tried)"
fi

start_case "ci-repair.md: syncs the shared workspace before checking out the PR branch"
assert_md_contains "$CI_REPAIR_MD" 'cv_sync_worktree_to_base' "ci-repair.md calls cv_sync_worktree_to_base"
sync_line_repair="$(md_line_of "$CI_REPAIR_MD" 'cv_sync_worktree_to_base')"
checkout_line_repair="$(md_line_of "$CI_REPAIR_MD" 'git checkout {branch}')"
if [ -n "$sync_line_repair" ] && [ -n "$checkout_line_repair" ] && [ "$sync_line_repair" -lt "$checkout_line_repair" ]; then
  pass "sync call (line ${sync_line_repair}) precedes checking out {branch} (line ${checkout_line_repair})"
else
  fail "expected the sync call to precede the PR-branch checkout"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
