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
# CASE 4b — fk-u8n34: cv_sync_patch_unchanged detects a CLEAN rebase (the
#   exact shape from CASE 4 above — own commit replayed onto an unrelated
#   upstream advance) as patch-UNCHANGED (exit 0). This is the fix for a
#   LOW-only review round being forced to iterate purely because
#   cv_sync_worktree_to_base rebased onto a moved origin/main with no real fix
#   commit (root fk-wofds / fk-lhjn3 iter 8, both observed live).
# ===========================================================================
start_case "4b: cv_sync_patch_unchanged reports unchanged for a clean rebase that replays the identical patch"
UPSTREAM4B="${SANDBOX}/repo4b-upstream.git"
git init -q -b main --bare "$UPSTREAM4B"
REPO4B="$(mk_repo repo4b)"
git_c "$REPO4B" remote add origin "$UPSTREAM4B"
git_c "$REPO4B" push -q -u origin main
git_c "$REPO4B" remote set-head origin main
WT4B="${SANDBOX}/repo4b-worktree"
git_c "$REPO4B" worktree add -q --detach "$WT4B" HEAD
git_c "$WT4B" checkout -q -b con-voyage/repo4b-worktree
printf 'impl\n' > "${WT4B}/impl.txt"
git_c "$WT4B" add impl.txt
git_c "$WT4B" commit -q -m "feat: implementation commit"
old_head4b="$(git_c "$WT4B" rev-parse HEAD)"
old_base4b="$(git_c "$WT4B" rev-parse main)"
# origin/main advances underneath, unrelated to impl.txt (same as CASE 4).
printf 'v2\n' >> "${REPO4B}/README.md"
git_c "$REPO4B" add README.md
git_c "$REPO4B" commit -q -m "feat: upstream advances"
git_c "$REPO4B" push -q origin main
result4b="$(cv_sync_worktree_to_base "$WT4B" 2>/dev/null)"
assert_eq "rebased" "$result4b" "fixture: CASE 4b's sync reports rebased (same shape as CASE 4)"
out4b="$(cv_sync_patch_unchanged "$WT4B" "$old_base4b" "$old_head4b" 2>&1)"
rc4b=$?
assert_eq "0" "$rc4b" "cv_sync_patch_unchanged returns 0 (unchanged) for a clean rebase with no real fix"
case "$out4b" in
  *"unchanged"*) pass "diagnostic mentions unchanged" ;;
  *) fail "expected an 'unchanged' diagnostic, got: ${out4b}" ;;
esac

# ===========================================================================
# CASE 4c — fk-u8n34: cv_sync_patch_unchanged detects a changed patch (e.g. a
#   rebase whose conflict resolution altered the diff) as CHANGED (exit 1),
#   so a real content change still forces verdict=iterate as before. Rather
#   than engineer a real rebase whose auto-merge happens to land a different
#   diff (inherently flaky to construct), this drives cv_sync_patch_unchanged
#   directly against a worktree whose post-sync HEAD carries a genuinely
#   different patch than its pre-sync HEAD — the exact distinction the
#   function exists to make, independent of how the differing HEAD got there.
# ===========================================================================
start_case "4c: cv_sync_patch_unchanged reports changed when the resulting patch actually differs"
UPSTREAM4C="${SANDBOX}/repo4c-upstream.git"
git init -q -b main --bare "$UPSTREAM4C"
REPO4C="$(mk_repo repo4c)"
git_c "$REPO4C" remote add origin "$UPSTREAM4C"
git_c "$REPO4C" push -q -u origin main
git_c "$REPO4C" remote set-head origin main
WT4C="${SANDBOX}/repo4c-worktree"
git_c "$REPO4C" worktree add -q --detach "$WT4C" HEAD
git_c "$WT4C" checkout -q -b con-voyage/repo4c-worktree
printf 'impl v1\n' > "${WT4C}/impl.txt"
git_c "$WT4C" add impl.txt
git_c "$WT4C" commit -q -m "feat: implementation commit"
old_head4c="$(git_c "$WT4C" rev-parse HEAD)"
old_base4c="$(git_c "$WT4C" rev-parse main)"
# Simulate a sync that landed a DIFFERENT patch (e.g. a resolved conflict
# changed the actual content) rather than a byte-identical replay.
printf 'v2\n' >> "${REPO4C}/README.md"
git_c "$REPO4C" add README.md
git_c "$REPO4C" commit -q -m "feat: upstream advances"
git_c "$REPO4C" push -q origin main
git_c "$WT4C" fetch -q origin
git_c "$WT4C" reset -q --hard main
printf 'impl v2 (resolved differently)\n' > "${WT4C}/impl.txt"
git_c "$WT4C" add impl.txt
git_c "$WT4C" commit -q -m "feat: implementation commit"
out4c="$(cv_sync_patch_unchanged "$WT4C" "$old_base4c" "$old_head4c" 2>&1)"
rc4c=$?
assert_eq "1" "$rc4c" "cv_sync_patch_unchanged returns 1 (changed) when the new patch actually differs"
case "$out4c" in
  *"changed"*) pass "diagnostic mentions changed" ;;
  *) fail "expected a 'changed' diagnostic, got: ${out4c}" ;;
esac

# ===========================================================================
# CASE 4d — fk-u8n34: a "recreated" sync (zero commits of DIR's own, see CASE
#   3) is trivially patch-unchanged on both sides (nothing to replay), so
#   apply-review-findings.md must not force an iteration purely because a
#   stale, commit-less worktree got reset onto the current origin/main tip.
# ===========================================================================
start_case "4d: cv_sync_patch_unchanged reports unchanged for a recreated (zero-own-commits) sync"
UPSTREAM4D="${SANDBOX}/repo4d-upstream.git"
git init -q -b main --bare "$UPSTREAM4D"
REPO4D="$(mk_repo repo4d)"
git_c "$REPO4D" remote add origin "$UPSTREAM4D"
git_c "$REPO4D" push -q -u origin main
git_c "$REPO4D" remote set-head origin main
WT4D="${SANDBOX}/repo4d-worktree"
git_c "$REPO4D" worktree add -q --detach "$WT4D" HEAD
old_head4d="$(git_c "$WT4D" rev-parse HEAD)"
old_base4d="$old_head4d"
printf 'v2\n' >> "${REPO4D}/README.md"
git_c "$REPO4D" add README.md
git_c "$REPO4D" commit -q -m "feat: upstream advances"
git_c "$REPO4D" push -q origin main
result4d="$(cv_sync_worktree_to_base "$WT4D" "con-voyage/repo4d-worktree" 2>/dev/null)"
assert_eq "recreated" "$result4d" "fixture: CASE 4d's sync reports recreated (same shape as CASE 3)"
out4d="$(cv_sync_patch_unchanged "$WT4D" "$old_base4d" "$old_head4d" 2>&1)"
rc4d=$?
assert_eq "0" "$rc4d" "cv_sync_patch_unchanged returns 0 (unchanged) for a recreated sync with no own commits either side"

# ===========================================================================
# CASE 4e — cv_sync_patch_unchanged input validation: missing args, a
#   non-existent commit, and a non-git directory all fail closed (exit 2 —
#   treat as "changed" rather than silently approving an unresolvable case).
# ===========================================================================
start_case "4e: cv_sync_patch_unchanged fails closed (exit 2) on invalid inputs"
out4e1="$(cv_sync_patch_unchanged "$WT4B" "" "$old_head4b" 2>&1)"
assert_eq "2" "$?" "returns 2 when old_base_sha is missing"
out4e2="$(cv_sync_patch_unchanged "$WT4B" "$old_base4b" "" 2>&1)"
assert_eq "2" "$?" "returns 2 when old_head is missing"
out4e3="$(cv_sync_patch_unchanged "$WT4B" "$old_base4b" "0000000000000000000000000000000000000000" 2>&1)"
assert_eq "2" "$?" "returns 2 when old_head does not resolve to a real commit"
out4e4="$(cv_sync_patch_unchanged "${SANDBOX}/does-not-exist" "$old_base4b" "$old_head4b" 2>&1)"
assert_eq "2" "$?" "returns 2 when DIR is not a git working tree"

# ===========================================================================
# CASE 5 — rebase conflict -> fails closed: a DISTINCT exit code (2), HEAD
#   restored to its pre-sync commit, no leftover rebase state, never falls
#   back to merge. fk-hcxre: a deterministic content conflict must be
#   distinguishable from a transient failure (exit 1 stays reserved for
#   fetch/ensure-branch/no-origin style failures — see case 6) so a caller
#   can treat this one as terminal instead of blindly retrying an identical
#   conflict 3 times (con-voyage root fk-vzgjt, 2026-09-30: main.build failed
#   3/3 attempts on the exact same rebase conflict before the root was left
#   stranded in_progress). The conflicted paths must also be reported on
#   stderr so a caller can record them without re-deriving them itself.
# ===========================================================================
start_case "5: conflicting rebase -> exit 2 (distinct from transient exit 1), clean tree, HEAD restored, conflicted paths reported"
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
assert_eq "2" "$rc5" "returns exit code 2 (distinct terminal signal) on a deterministic rebase conflict"
case "$err5" in
  *"conflict"*) pass "error message calls out the conflict" ;;
  *) fail "expected an explanatory conflict error message, got: ${err5}" ;;
esac
case "$err5" in
  *"SYNC_CONFLICT_PATHS="*"README.md"*) pass "reports the conflicted path(s) on stderr via a machine-readable SYNC_CONFLICT_PATHS= marker" ;;
  *) fail "expected a SYNC_CONFLICT_PATHS= marker naming README.md, got: ${err5}" ;;
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
# CASE 8 — fk-wmhr96: a caller-supplied EXPLICIT_BASE (3rd arg) declares a
#   stacked base branch that is NOT origin's default — the sync must land the
#   worktree on that branch's tip, not origin/main, even though origin/main
#   also resolves to a real commit in this repo (so the default resolution
#   order alone would never reach the declared base).
# ===========================================================================
start_case "8: explicit base arg (3rd positional) syncs onto a declared stacked base, not origin's default"
UPSTREAM8="${SANDBOX}/repo8-upstream.git"
git init -q -b main --bare "$UPSTREAM8"
REPO8="$(mk_repo repo8)"
git_c "$REPO8" remote add origin "$UPSTREAM8"
git_c "$REPO8" push -q -u origin main
git_c "$REPO8" remote set-head origin main
# A stacked base branch diverges from main with its own commit.
git_c "$REPO8" checkout -q -b stacked-base
printf 'stacked\n' > "${REPO8}/stacked.txt"
git_c "$REPO8" add stacked.txt
git_c "$REPO8" commit -q -m "feat: stacked base content"
git_c "$REPO8" push -q -u origin stacked-base
stacked_tip8="$(git_c "$REPO8" rev-parse stacked-base)"
main_tip8="$(git_c "$REPO8" rev-parse main)"
git_c "$REPO8" checkout -q main
WT8="${SANDBOX}/repo8-worktree"
git_c "$REPO8" worktree add -q --detach "$WT8" HEAD
result8="$(cv_sync_worktree_to_base "$WT8" "con-voyage/repo8-worktree" "stacked-base" 2>/dev/null)"
rc8=$?
assert_eq "0" "$rc8" "exits 0"
assert_eq "recreated" "$result8" "reports recreated"
assert_eq "$stacked_tip8" "$(git_c "$WT8" rev-parse HEAD)" "HEAD matches the declared stacked-base tip, not origin/main"
if [ "$(git_c "$WT8" rev-parse HEAD)" = "$main_tip8" ]; then
  fail "worktree landed on origin/main's tip despite an explicit stacked-base argument"
fi
assert_eq "con-voyage/repo8-worktree" "$(git_c "$WT8" symbolic-ref --short HEAD 2>/dev/null)" "worktree is on the named branch"

# ===========================================================================
# CASE 9 — an empty/unset explicit-base argument is byte-identical to the
#   pre-fk-wmhr96 two-arg call: falls through to origin/HEAD -> origin/main.
# ===========================================================================
start_case "9: an empty explicit-base argument falls through to the default resolution order"
UPSTREAM9="${SANDBOX}/repo9-upstream.git"
git init -q -b main --bare "$UPSTREAM9"
REPO9="$(mk_repo repo9)"
git_c "$REPO9" remote add origin "$UPSTREAM9"
git_c "$REPO9" push -q -u origin main
git_c "$REPO9" remote set-head origin main
main_tip9="$(git_c "$REPO9" rev-parse main)"
WT9="${SANDBOX}/repo9-worktree"
git_c "$REPO9" worktree add -q --detach "$WT9" HEAD
result9="$(cv_sync_worktree_to_base "$WT9" "con-voyage/repo9-worktree" "" 2>/dev/null)"
rc9=$?
assert_eq "0" "$rc9" "exits 0"
assert_eq "noop" "$result9" "reports noop (already current on origin/main, the default)"
assert_eq "$main_tip9" "$(git_c "$WT9" rev-parse HEAD)" "HEAD matches origin/main (default), unaffected by the new empty 3rd arg"

# ===========================================================================
# CASE 10 — review fk-wmhr96 BLOCKING-3: an explicit_base that resolves to
#   NEITHER origin/<explicit_base> NOR the bare name (typo, or a branch never
#   pushed to origin) must not silently fall through to the default base with
#   no signal — it must emit a surfaced warning on stderr, and still fail
#   SAFE by falling back to the default base rather than hanging or erroring.
# ===========================================================================
start_case "10: an unresolvable explicit base warns on stderr instead of silently falling through"
UPSTREAM10="${SANDBOX}/repo10-upstream.git"
git init -q -b main --bare "$UPSTREAM10"
REPO10="$(mk_repo repo10)"
git_c "$REPO10" remote add origin "$UPSTREAM10"
git_c "$REPO10" push -q -u origin main
git_c "$REPO10" remote set-head origin main
main_tip10="$(git_c "$REPO10" rev-parse main)"
WT10="${SANDBOX}/repo10-worktree"
git_c "$REPO10" worktree add -q --detach "$WT10" HEAD
STDERR10="${SANDBOX}/case10-stderr.txt"
result10="$(cv_sync_worktree_to_base "$WT10" "con-voyage/repo10-worktree" "nonexistent-declared-base" 2>"$STDERR10")"
rc10=$?
assert_eq "0" "$rc10" "exits 0 (fails safe, not closed)"
assert_eq "noop" "$result10" "falls back to the default base (already current on origin/main)"
assert_eq "$main_tip10" "$(git_c "$WT10" rev-parse HEAD)" "HEAD matches origin/main (default fallback), not left unresolved"
if grep -qi "nonexistent-declared-base" "$STDERR10"; then
  pass "emits a surfaced warning naming the unresolvable declared base"
else
  fail "expected a warning on stderr naming the unresolvable explicit base (got: $(cat "$STDERR10"))"
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

# ===========================================================================
# fk-hcxre: build.md must treat a deterministic sync conflict (exit 2) as
# terminal — close this step AND the con-voyage root, mail the mayor once,
# and stop, rather than `exit 1`-ing into another graph.v2 retry attempt on
# the identical conflict (con-voyage root fk-vzgjt: 3/3 identical attempts,
# root left stranded in_progress).
# ===========================================================================
start_case "build.md: a sync-conflict (exit 2) is terminal — closes the step and the root, mails once, never re-exits 1"
assert_md_contains "$BUILD_MD" 'SYNC_RC" -eq 2' "build.md branches specifically on the distinct sync-conflict exit code (2)"
assert_md_contains "$BUILD_MD" "gc.outcome=fail" "build.md records gc.outcome=fail on a sync conflict"
assert_md_contains "$BUILD_MD" "gc.failure_class=sync_conflict" "build.md records a distinct gc.failure_class=sync_conflict"
assert_md_contains "$BUILD_MD" "SYNC_CONFLICT_PATHS=" "build.md parses the conflicted paths reported by cv_sync_worktree_to_base"
assert_md_contains "$BUILD_MD" "cv_bead_close \"\$ROOT_ID\" abandoned" "build.md closes the con-voyage ROOT bead as abandoned on a sync conflict, so it never sits stranded in_progress"
assert_md_contains "$BUILD_MD" "gc.build.sync_conflict_mail_sent" "build.md dedups the mayor mail via a root-bead metadata flag (mirrors cv-synthesis-low-mail.sh's code_review.low_mail_sent pattern)"

sync_conflict_line_build="$(md_line_of "$BUILD_MD" 'SYNC_RC" -eq 2')"
if [ -n "$sync_conflict_line_build" ] && [ -n "$shortcircuit_line_build" ] && [ "$sync_conflict_line_build" -lt "$shortcircuit_line_build" ]; then
  pass "the sync-conflict terminal branch (line ${sync_conflict_line_build}) runs before the short-circuit decision (line ${shortcircuit_line_build}), so it can never be skipped"
else
  fail "expected the sync-conflict terminal branch to precede the short-circuit decision"
fi

# Negative control: the OLD unconditional "sync failed -> exit 1" one-liner
# (which retried a deterministic conflict identically to a transient one)
# must be gone from the main sync call itself — it must only appear inside
# the transient-failure branch (SYNC_RC -ne 0), not as a blanket `||` on the
# cv_sync_worktree_to_base call.
if grep -qF 'cv_sync_worktree_to_base "$WORKTREE" "con-voyage/${CONVOY_ID}")" \' "$BUILD_MD"; then
  fail "build.md must not treat every cv_sync_worktree_to_base failure identically via a blanket ||-exit-1 (fk-hcxre: a conflict must branch separately)"
else
  pass "no blanket ||-exit-1 regressed back onto the cv_sync_worktree_to_base call"
fi

# ===========================================================================
# review fk-hcxre BLOCKING-1/2 (root fk-fqaft): the terminal `SYNC_RC -eq 2`
# block above was only ever checked with static `assert_md_contains` greps,
# never actually run — so neither the unbounded/swallowed `gc mail send` nor
# the unverified `cv_bead_close` could be caught by "ALL CASES PASSED". Pull
# the real block out of the markdown source (never a hand-copied duplicate,
# so it can't drift from what a worker actually executes) and run it for
# real, against a stubbed `gc`/`bd` that can simulate a hang, a failure, and
# a root that refuses to close.
# ===========================================================================
extract_bash_block() {
  local file="$1" needle="$2"
  python3 -c "
import re, sys
text = open(sys.argv[1]).read()
needle = sys.argv[2]
for block in re.findall(r'\`\`\`bash\n(.*?)\n\`\`\`', text, re.S):
    if needle in block:
        print(block)
        break
" "$file" "$needle"
}

TERMINAL_BLOCK="$(extract_bash_block "$BUILD_MD" 'SYNC_RC" -eq 2')"
if [ -z "$TERMINAL_BLOCK" ]; then
  fail "could not extract the SYNC_RC-eq-2 terminal block out of ${BUILD_MD} — cannot exercise it"
else
  TERM_WT="$(mk_repo "terminal-block-wt")"

  # A second stub bindir layered in FRONT of the shared $STUBDIR: overrides
  # gc/bd per scenario while still falling through to the shared stub for
  # anything cv_sync_worktree_to_base itself would need (not exercised here).
  TERM_STUBDIR="${SANDBOX}/terminal-stubbin"
  mkdir -p "$TERM_STUBDIR" "${SANDBOX}/terminal-state"

  cat > "${TERM_STUBDIR}/bd" <<'BD_STUB'
#!/usr/bin/env bash
# The block's own direct `bd update`/`bd close` calls on $CLAIMED_BEAD_ID —
# not under test here, always a harmless no-op.
exit 0
BD_STUB
  chmod +x "${TERM_STUBDIR}/bd"

  # gc is a Python script (not bash) so it can parse --json output cleanly
  # and keep call-counting state without fighting word-splitting.
  cat > "${TERM_STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env python3
import json, os, sys, time

state_dir = os.environ["TERM_STATE_DIR"]
mail_mode = os.environ.get("STUB_MAIL_MODE", "ok")
root_always_open = os.environ.get("STUB_ROOT_ALWAYS_OPEN", "false") == "true"

def bump(name):
    path = os.path.join(state_dir, name)
    n = 0
    if os.path.exists(path):
        n = int(open(path).read().strip() or "0")
    n += 1
    open(path, "w").write(str(n))
    return n

args = sys.argv[1:]

if args[:2] == ["mail", "send"]:
    n = bump("mail_calls")
    if mail_mode == "timeout":
        time.sleep(5)
        sys.exit(0)
    if mail_mode == "fail":
        sys.stderr.write("stub gc: mail send failed\n")
        sys.exit(1)
    print(json.dumps({"message": {"id": "stub-mail-%d" % n}}))
    sys.exit(0)

if args[:2] == ["bd", "show"]:
    closed_marker = os.path.join(state_dir, "root_closed")
    status = "closed" if (not root_always_open and os.path.exists(closed_marker)) else "in_progress"
    print(json.dumps({"id": args[2] if len(args) > 2 else "", "status": status, "metadata": {}}))
    sys.exit(0)

if args[:2] == ["bd", "update"]:
    sys.exit(0)

if args[:2] == ["bd", "close"]:
    bump("bd_close_calls")
    if not root_always_open:
        open(os.path.join(state_dir, "root_closed"), "w").write("1")
    sys.exit(0)

sys.exit(0)
GC_STUB
  chmod +x "${TERM_STUBDIR}/gc"

  run_terminal_block() {
    # PATH: TERM_STUBDIR first (mail-timeout/root-status control), then
    # STUBDIR (real cv-worktree-prep.sh's own PATH assumptions), then the
    # real PATH (git, python3, mktemp, sed).
    env -i \
      PATH="${TERM_STUBDIR}:${STUBDIR}:${PATH}" \
      HOME="${HOME:-}" \
      TERM_STATE_DIR="${SANDBOX}/terminal-state" \
      STUB_MAIL_MODE="$1" \
      STUB_ROOT_ALWAYS_OPEN="$2" \
      CV_LENS_STORE_TIMEOUT_SECONDS=1 \
      SYNC_RC=2 \
      SYNC_ERR_TEXT="" \
      WORKTREE="$TERM_WT" \
      CONVOY_ID="fk-termconvoy" \
      ROOT_ID="fk-termroot" \
      CLAIMED_BEAD_ID="fk-termclaim" \
      CV_LIB="$LIB" \
      GC_CITY="." \
      bash -c "cd '$TERM_WT' && $TERMINAL_BLOCK"
  }

  reset_terminal_state() { rm -f "${SANDBOX}/terminal-state"/*; }

  start_case "build.md terminal block: gc mail send timing out is never swallowed"
  reset_terminal_state
  TERM_STDERR="$(run_terminal_block timeout false 2>&1 1>/dev/null)"
  TERM_RC=$?
  assert_eq "1" "$TERM_RC" "the block exits non-zero when the sync-conflict mail times out (never silently continues to close the root)"
  case "$TERM_STDERR" in
    *"timed out"*) pass "stderr reports the mail timeout" ;;
    *) fail "expected stderr to report the mail timeout, got: ${TERM_STDERR}" ;;
  esac
  if [ -f "${SANDBOX}/terminal-state/bd_close_calls" ]; then
    fail "root close must not run after an unconfirmed/timed-out mayor mail — cv_bead_close was still invoked"
  else
    pass "cv_bead_close never ran after the mail timed out"
  fi

  start_case "build.md terminal block: a failing gc mail send is never swallowed"
  reset_terminal_state
  TERM_STDERR="$(run_terminal_block fail false 2>&1 1>/dev/null)"
  TERM_RC=$?
  assert_eq "1" "$TERM_RC" "the block exits non-zero when the sync-conflict mail send fails"
  case "$TERM_STDERR" in
    *"mayor NOT notified"*) pass "stderr makes the un-notified mayor explicit" ;;
    *) fail "expected stderr to call out the mayor was not notified, got: ${TERM_STDERR}" ;;
  esac

  start_case "build.md terminal block: a root that never closes gets a retry, then an escalation mail — not a silent exit 0"
  reset_terminal_state
  TERM_STDERR="$(run_terminal_block ok true 2>&1 1>/dev/null)"
  TERM_RC=$?
  assert_eq "0" "$TERM_RC" "the block still exits 0 once it has escalated (this is a terminal path, not a retryable one)"
  assert_eq "2" "$(cat "${SANDBOX}/terminal-state/bd_close_calls" 2>/dev/null || echo 0)" "cv_bead_close was retried exactly once after the first attempt left the root open"
  assert_eq "2" "$(cat "${SANDBOX}/terminal-state/mail_calls" 2>/dev/null || echo 0)" "a second, distinct mail (the root-failed-to-close escalation) was sent in addition to the original sync-conflict mail"
  case "$TERM_STDERR" in
    *"escalated to mayor"*) pass "stderr records the escalation" ;;
    *) fail "expected stderr to record the root-close escalation, got: ${TERM_STDERR}" ;;
  esac

  start_case "build.md terminal block: happy path — root closes on the first attempt, no retry, no escalation"
  reset_terminal_state
  TERM_STDERR="$(run_terminal_block ok false 2>&1 1>/dev/null)"
  TERM_RC=$?
  assert_eq "0" "$TERM_RC" "the block exits 0 when the mail sends and the root closes cleanly"
  assert_eq "1" "$(cat "${SANDBOX}/terminal-state/bd_close_calls" 2>/dev/null || echo 0)" "cv_bead_close ran exactly once — no wasted retry on the happy path"
  assert_eq "1" "$(cat "${SANDBOX}/terminal-state/mail_calls" 2>/dev/null || echo 0)" "only the original sync-conflict mail was sent — no escalation on the happy path"
  case "$TERM_STDERR" in
    *"escalated to mayor"*) fail "the happy path must never escalate, got: ${TERM_STDERR}" ;;
    *) pass "no escalation on the happy path" ;;
  esac
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
  *"sync"*"recreated"*|*"recreated"*"sync"*) pass "apply-review-findings.md's prose accounts for a recreated/rebased sync result" ;;
  *) fail "expected apply-review-findings.md to call out a recreated/rebased sync result" ;;
esac

# ===========================================================================
# fk-u8n34: apply-review-findings.md must distinguish a rebase/recreate that
# actually changed patch content (still forces iterate) from a clean
# rebase-onto-a-moved-base that replayed the IDENTICAL patch (eligible for
# verdict=done, same as a genuine no-op pass) — see cv_sync_patch_unchanged
# above. A blanket "any sync result = iterate" rule is exactly what forced a
# LOW-only review round (0 BLOCKING, LOW-only mail already sent) to re-run
# every lane purely because origin/main moved under it (root fk-wofds /
# fk-lhjn3 iteration 8).
# ===========================================================================
start_case "apply-review-findings.md: distinguishes a patch-unchanged rebase/recreate from a real content change (fk-u8n34)"
assert_md_contains "$APPLY_MD" 'cv_sync_patch_unchanged "$WORKTREE" "$PRE_SYNC_BASE_SHA" "$PRE_SYNC_HEAD"' \
  "apply-review-findings.md calls cv_sync_patch_unchanged after syncing, with the pre-sync base/head it captured itself"
assert_md_contains "$APPLY_MD" 'SYNC_PATCH_UNCHANGED' \
  "apply-review-findings.md threads SYNC_PATCH_UNCHANGED through its own prose"
assert_md_contains "$APPLY_MD" 'eligible for verdict=done when there are also no BLOCKING' \
  "apply-review-findings.md documents the patch-unchanged branch as eligible for verdict=done"
assert_md_contains "$APPLY_MD" 'including a rebase-only pass where `$SYNC_PATCH_UNCHANGED=true`' \
  "apply-review-findings.md tells the closing step not to record a fix_commit for a patch-unchanged rebase"
patch_check_line_apply="$(md_line_of "$APPLY_MD" 'cv_sync_patch_unchanged "$WORKTREE"')"
verdict_true_line_apply="$(md_line_of "$APPLY_MD" 'but `$SYNC_PATCH_UNCHANGED` is')"
if [ -n "$patch_check_line_apply" ] && [ -n "$verdict_true_line_apply" ] && [ "$patch_check_line_apply" -lt "$verdict_true_line_apply" ]; then
  pass "the patch-unchanged check (line ${patch_check_line_apply}) precedes the prose branching on it (line ${verdict_true_line_apply})"
else
  fail "expected the patch-unchanged check to precede the prose that branches on it"
fi

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

# ===========================================================================
# review fk-wmhr96 BLOCKING-1/2: every code-writing step's sync call must
# thread a declared stacked base (`cv_convoy_target`) through as the explicit
# 3rd arg to cv_sync_worktree_to_base. A sync call left on the bare 2-arg (or
# 1-arg) form silently un-stacks the branch the moment origin/main advances
# past the declared base mid-journey — a no-op right up until it isn't, which
# is exactly how this slipped past review once already (BLOCKING-1/2 above).
# ===========================================================================
start_case "build.md: threads cv_convoy_target as the explicit 3rd arg to cv_sync_worktree_to_base"
assert_md_contains "$BUILD_MD" 'cv_convoy_target "$CONVOY_ID"' "build.md resolves CONVOY_TARGET via cv_convoy_target"
assert_md_contains "$BUILD_MD" 'cv_sync_worktree_to_base "$WORKTREE" "$WORK_BRANCH_NAME" "$CONVOY_TARGET"' "build.md passes \$CONVOY_TARGET as the explicit 3rd arg"

start_case "apply-review-findings.md: threads cv_convoy_target as the explicit 3rd arg to cv_sync_worktree_to_base (fk-wmhr96 BLOCKING-1)"
assert_md_contains "$APPLY_MD" 'cv_convoy_target "$CONVOY_ID"' "apply-review-findings.md resolves CONVOY_TARGET via cv_convoy_target"
assert_md_contains "$APPLY_MD" 'cv_sync_worktree_to_base "$WORKTREE" "$WORK_BRANCH_NAME" "$CONVOY_TARGET"' "apply-review-findings.md passes \$CONVOY_TARGET as the explicit 3rd arg"

start_case "ci-repair.md: threads cv_convoy_target as the explicit 3rd arg to cv_sync_worktree_to_base (fk-wmhr96 BLOCKING-2)"
assert_md_contains "$CI_REPAIR_MD" 'cv_convoy_target "{convoy_id}"' "ci-repair.md resolves CONVOY_TARGET via cv_convoy_target"
assert_md_contains "$CI_REPAIR_MD" 'cv_sync_worktree_to_base "$(pwd)" "" "$CONVOY_TARGET"' "ci-repair.md passes \$CONVOY_TARGET as the explicit 3rd arg"

# ===========================================================================
# review fk-hbsmk BLOCKING-1: both implementor-routed steps (build.md and
# apply-review-findings.md) stamp a dedicated gc.build.implementor_session
# key on the workflow root from THEIR OWN claimed step bead's gc.session_name
# — never leaving publish.md to read the root's mutable, last-writer-wins
# gc.session_name (re-stamped by every session_affinity=require step that
# touches the root, including review lanes, the synthesizer, and publish
# itself).
# ===========================================================================
start_case "build.md: stamps gc.build.implementor_session on the workflow root from its own claimed bead's gc.session_name"
assert_md_contains "$BUILD_MD" 'gc.build.implementor_session=' "build.md sets gc.build.implementor_session on \$ROOT_ID"
assert_md_contains "$BUILD_MD" 'gc bd show "$GC_BEAD_ID" --json' "reads its OWN claimed step bead, not the workflow root"
stamp_line_build="$(md_line_of "$BUILD_MD" 'gc.build.implementor_session=')"
cd_line_build="$(md_line_of "$BUILD_MD" 'cd "$WORKTREE"')"
if [ -n "$cd_line_build" ] && [ -n "$stamp_line_build" ] && [ "$cd_line_build" -lt "$stamp_line_build" ]; then
  pass "the implementor-session stamp (line ${stamp_line_build}) runs after \$WORKTREE is resolved (line ${cd_line_build})"
else
  fail "expected the implementor-session stamp to run after \$WORKTREE is resolved"
fi

start_case "apply-review-findings.md: stamps gc.build.implementor_session on the workflow root from its own claimed bead's gc.session_name"
assert_md_contains "$APPLY_MD" 'gc.build.implementor_session=' "apply-review-findings.md sets gc.build.implementor_session on \$ROOT_ID"
assert_md_contains "$APPLY_MD" 'gc bd show "$GC_BEAD_ID" --json' "reads its OWN claimed step bead, not the workflow root"
stamp_line_apply="$(md_line_of "$APPLY_MD" 'gc.build.implementor_session=')"
if [ -n "$stamp_line_apply" ] && [ -n "$sync_line_apply" ] && [ "$stamp_line_apply" -lt "$sync_line_apply" ]; then
  pass "the implementor-session stamp (line ${stamp_line_apply}) runs before the base sync (line ${sync_line_apply}), so it re-stamps every iteration this step runs"
else
  fail "expected the implementor-session stamp to precede the base sync"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
