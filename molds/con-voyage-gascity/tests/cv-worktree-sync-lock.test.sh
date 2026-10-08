#!/usr/bin/env bash
# cv-worktree-sync-lock.test.sh — hermetic, offline regression test for
# fk-dy2ygk: "shared rereview worktree races with push, lanes grade
# stale/phantom HEAD".
#
# THE BUG: con-voyage's shared source-anchor worktree ($WORKTREE /
# gc.build.source_anchor_work_dir) is mutated in place by
# cv_sync_worktree_to_base (con-voyage-lib.sh) — a `git fetch` plus a
# `checkout -B` or `rebase --onto` — with no mutual exclusion against a
# concurrent reader. Every review lane calls
# cv-review-lane-worktree.sh's `acquire`, which reads that SAME shared
# worktree's HEAD (`git rev-parse HEAD`) and forks a private lane worktree
# from it. Live evidence (2026-10-04..2026-10-06, 5 occurrences, all on the
# shared rereview-worktree mechanism): lanes graded a stale or phantom HEAD
# because `acquire` could read/fork mid-rebase, racing apply-review-findings'
# call to cv_sync_worktree_to_base on the exact same directory.
#
# THE FIX under test: both cv_sync_worktree_to_base and
# cv-review-lane-worktree.sh's `acquire` take the SAME mkdir-based advisory
# lock, keyed deterministically off the shared worktree's own path
# (`<worktree>.cvsynclock`, a sibling directory) — so every caller agrees on
# the same lock regardless of CV_STATE_DIR/city differences between
# processes. A sync in progress blocks any lane's acquire until it releases,
# and a lane's acquire cannot be observed by a concurrent sync beginning its
# fetch/rebase. No more torn HEAD reads.
#
# HOW IT WORKS: real local git repos under a temp sandbox, with the lock held
# deterministically by the test (not timing-based) to prove mutual exclusion
# without flakiness — the test acquires the lock itself, backgrounds the
# other side, asserts it is still blocked after a short bounded wait, then
# releases and asserts the backgrounded call completes correctly afterward.
#
# Run:  bash tests/cv-worktree-sync-lock.test.sh   (exit 0 => all cases passed)

set -uo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
LANE_SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-review-lane-worktree.sh"

for f in "$LIB" "$LANE_SCRIPT"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: required file not found at ${f}" >&2
    exit 2
  fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-worktree-sync-lock-test.XXXXXX")"
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
  git_c "$repo" config user.email test@example.com
  git_c "$repo" config user.name "Test"
  printf 'placeholder\n' > "$repo/README.md"
  git_c "$repo" add README.md
  git_c "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

# Fake `gc` so `source "$LIB"` succeeds; not called by the functions under test.
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

export CV_SYNC_FETCH_TIMEOUT_SECONDS=5

# ===========================================================================
# CASE 1 — a lock held externally on the shared worktree blocks
#   cv-review-lane-worktree.sh's `acquire` from reading HEAD / forking a lane
#   worktree until it is released (the exact window apply-review-findings'
#   cv_sync_worktree_to_base call needs while rebasing).
# ===========================================================================
start_case "1: acquire blocks while the shared worktree's sync lock is held, proceeds after release"
UPSTREAM1="${SANDBOX}/repo1-upstream.git"
git init -q -b main --bare "$UPSTREAM1"
REPO1="$(mk_repo repo1)"
git_c "$REPO1" remote add origin "$UPSTREAM1"
git_c "$REPO1" push -q -u origin main
SRC1="${SANDBOX}/repo1-shared-worktree"
git_c "$REPO1" worktree add -q -B con-voyage/repo1 "$SRC1" main

if ! declare -F cv_worktree_sync_lock_acquire >/dev/null 2>&1; then
  fail "cv_worktree_sync_lock_acquire is not defined in con-voyage-lib.sh — the shared lock primitive does not exist yet"
else
  cv_worktree_sync_lock_acquire "$SRC1" || fail "test setup: could not acquire the lock on ${SRC1}"

  OUT1_FILE="${SANDBOX}/acquire1.out"
  RC1_FILE="${SANDBOX}/acquire1.rc"
  (
    bash "$LANE_SCRIPT" acquire "$SRC1" lane1 > "$OUT1_FILE" 2>&1
    echo $? > "$RC1_FILE"
  ) &
  bg_pid=$!

  sleep 2
  if kill -0 "$bg_pid" 2>/dev/null; then
    pass "acquire is still blocked 2s in, while the sync lock is held"
  else
    fail "acquire returned while the sync lock was still held — no mutual exclusion"
  fi

  cv_worktree_sync_lock_release "$SRC1"
  wait "$bg_pid" 2>/dev/null
  lane_rc1="$(cat "$RC1_FILE" 2>/dev/null || echo "?")"
  lane_wt1="$(cat "$OUT1_FILE" 2>/dev/null || echo "")"
  assert_eq "0" "$lane_rc1" "acquire succeeds once the lock is released"
  if [ -n "$lane_wt1" ] && [ -d "$lane_wt1" ]; then
    pass "acquire produced a real lane worktree directory after the lock cleared"
  else
    fail "acquire did not produce a usable lane worktree path (got '${lane_wt1}')"
  fi
  assert_eq "$(git_c "$SRC1" rev-parse HEAD)" "$(git -C "${lane_wt1:-/nonexistent}" rev-parse HEAD 2>/dev/null || echo "?")" \
    "lane worktree is pinned to the shared worktree's HEAD, read only after the lock cleared"
fi

# ===========================================================================
# CASE 2 — the reverse direction: a lock held externally on the shared
#   worktree blocks cv_sync_worktree_to_base itself from starting its
#   fetch/rebase until the lock is released.
# ===========================================================================
start_case "2: cv_sync_worktree_to_base blocks while the sync lock is externally held, proceeds after release"
UPSTREAM2="${SANDBOX}/repo2-upstream.git"
git init -q -b main --bare "$UPSTREAM2"
REPO2="$(mk_repo repo2)"
git_c "$REPO2" remote add origin "$UPSTREAM2"
git_c "$REPO2" push -q -u origin main
git_c "$REPO2" remote set-head origin main
WT2="${SANDBOX}/repo2-worktree"
git_c "$REPO2" worktree add -q -B con-voyage/repo2 "$WT2" main
# origin/main advances so the sync call below has real work to do (recreated).
printf 'v2\n' >> "${REPO2}/README.md"
git_c "$REPO2" add README.md
git_c "$REPO2" commit -q -m "feat: upstream advances"
git_c "$REPO2" push -q origin main
new_tip2="$(git_c "$REPO2" rev-parse main)"

if ! declare -F cv_worktree_sync_lock_acquire >/dev/null 2>&1; then
  fail "cv_worktree_sync_lock_acquire is not defined in con-voyage-lib.sh — the shared lock primitive does not exist yet"
else
  cv_worktree_sync_lock_acquire "$WT2" || fail "test setup: could not acquire the lock on ${WT2}"

  OUT2_FILE="${SANDBOX}/sync2.out"
  RC2_FILE="${SANDBOX}/sync2.rc"
  (
    cv_sync_worktree_to_base "$WT2" "con-voyage/repo2" > "$OUT2_FILE" 2>/dev/null
    echo $? > "$RC2_FILE"
  ) &
  bg_pid2=$!

  sleep 2
  if kill -0 "$bg_pid2" 2>/dev/null; then
    pass "cv_sync_worktree_to_base is still blocked 2s in, while the lock is externally held"
  else
    fail "cv_sync_worktree_to_base returned while the lock was still held — no mutual exclusion"
  fi

  cv_worktree_sync_lock_release "$WT2"
  wait "$bg_pid2" 2>/dev/null
  sync_rc2="$(cat "$RC2_FILE" 2>/dev/null || echo "?")"
  sync_out2="$(cat "$OUT2_FILE" 2>/dev/null || echo "")"
  assert_eq "0" "$sync_rc2" "cv_sync_worktree_to_base succeeds once the lock is released"
  assert_eq "recreated" "$sync_out2" "cv_sync_worktree_to_base still reports the correct result after waiting"
  assert_eq "$new_tip2" "$(git_c "$WT2" rev-parse HEAD)" "HEAD now matches the new origin/main tip"
fi

# ===========================================================================
# CASE 3 — review fk-hbsmk BLOCKING-1: a release carrying a STALE token (one
#   whose lock has since been reclaimed by a different holder) must not
#   delete that different holder's live lock.
# ===========================================================================
start_case "3: release with a mismatched owner token does not delete a live lock held by someone else"
REPO3_DIR="${SANDBOX}/repo3-plain"
mkdir -p "$REPO3_DIR"
git_c "$REPO3_DIR" init -q -b main
printf 'x\n' > "${REPO3_DIR}/f"
git_c "$REPO3_DIR" add f
git_c "$REPO3_DIR" commit -q -m init

stale_token="$(cv_worktree_sync_lock_acquire "$REPO3_DIR")"
if [ -z "$stale_token" ]; then
  fail "test setup: cv_worktree_sync_lock_acquire did not print an ownership token"
else
  # Simulate a reclaim: release WITHOUT the stale token (legacy/forced path),
  # then a second holder acquires fresh — this is the new live lock.
  cv_worktree_sync_lock_release "$REPO3_DIR"
  live_token="$(cv_worktree_sync_lock_acquire "$REPO3_DIR")"
  if [ -z "$live_token" ]; then
    fail "test setup: second acquire did not print an ownership token"
  else
    cv_worktree_sync_lock_release "$REPO3_DIR" "$stale_token"
    if [ -d "$(cv_worktree_sync_lock_dir "$REPO3_DIR")" ]; then
      pass "release with a stale/mismatched token left the live lock in place"
    else
      fail "release with a stale/mismatched token deleted a different holder's live lock"
    fi
    cv_worktree_sync_lock_release "$REPO3_DIR" "$live_token"
    if [ -d "$(cv_worktree_sync_lock_dir "$REPO3_DIR")" ]; then
      fail "release with the correct current token failed to delete the lock"
    else
      pass "release with the correct current token deletes the lock"
    fi
  fi
fi

# ===========================================================================
# CASE 4 — review fk-hbsmk BLOCKING-2: a lock past the stale-mtime threshold
#   is reclaimed ONLY when its recorded holder pid is actually dead. A
#   long-running-but-alive holder (mtime stale, pid alive) must NOT be
#   reclaimed out from under it.
# ===========================================================================
start_case "4: stale-mtime reclaim requires a dead holder pid, not just an old mtime"
REPO4_DIR="${SANDBOX}/repo4-plain"
mkdir -p "$REPO4_DIR"
git_c "$REPO4_DIR" init -q -b main
printf 'x\n' > "${REPO4_DIR}/f"
git_c "$REPO4_DIR" add f
git_c "$REPO4_DIR" commit -q -m init

LOCKDIR4="$(cv_worktree_sync_lock_dir "$REPO4_DIR")"

# 4a: mtime stale, holder pid alive (this test process itself) -> must block.
mkdir "$LOCKDIR4"
printf '%s\n' "$$" > "${LOCKDIR4}/pid"
printf '%s\n' "alive-holder-token" > "${LOCKDIR4}/owner"
touch -t "$(date -v-3700S +%Y%m%d%H%M.%S 2>/dev/null || date -d '-3700 seconds' +%Y%m%d%H%M.%S)" "$LOCKDIR4" 2>/dev/null
OUT4A_FILE="${SANDBOX}/acquire4a.out"
RC4A_FILE="${SANDBOX}/acquire4a.rc"
(
  CV_WORKTREE_SYNC_LOCK_STALE_SECONDS=1 cv_worktree_sync_lock_acquire "$REPO4_DIR" 3 > "$OUT4A_FILE" 2>/dev/null
  echo $? > "$RC4A_FILE"
) &
bg4a_pid=$!
sleep 1
if kill -0 "$bg4a_pid" 2>/dev/null; then
  pass "an old-mtime lock with a LIVE holder pid is not reclaimed"
else
  fail "an old-mtime lock with a LIVE holder pid was reclaimed anyway (liveness check missing)"
fi
rm -rf "$LOCKDIR4" 2>/dev/null
wait "$bg4a_pid" 2>/dev/null

# 4b: mtime stale, holder pid genuinely dead -> reclaimed.
mkdir "$LOCKDIR4"
dead_pid=$(( $$ + 1 ))
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
printf '%s\n' "$dead_pid" > "${LOCKDIR4}/pid"
printf '%s\n' "dead-holder-token" > "${LOCKDIR4}/owner"
touch -t "$(date -v-3700S +%Y%m%d%H%M.%S 2>/dev/null || date -d '-3700 seconds' +%Y%m%d%H%M.%S)" "$LOCKDIR4" 2>/dev/null
new_token4b="$(CV_WORKTREE_SYNC_LOCK_STALE_SECONDS=1 cv_worktree_sync_lock_acquire "$REPO4_DIR" 5)"
if [ -n "$new_token4b" ] && [ "$new_token4b" != "dead-holder-token" ]; then
  pass "an old-mtime lock with a DEAD holder pid is reclaimed with a fresh token"
else
  fail "an old-mtime lock with a dead holder pid was not reclaimed (got token '${new_token4b}')"
fi
cv_worktree_sync_lock_release "$REPO4_DIR" "$new_token4b"

# ===========================================================================
# CASE 5 — review fk-hbsmk BLOCKING-3: two concurrent lane `acquire` calls
#   against the SAME source with DIFFERENT lane ids must not serialize
#   against each other — only against an active sync.
# ===========================================================================
start_case "5: two concurrent lane acquires on the same source do not serialize against each other"
UPSTREAM5="${SANDBOX}/repo5-upstream.git"
git init -q -b main --bare "$UPSTREAM5"
REPO5="$(mk_repo repo5)"
git_c "$REPO5" remote add origin "$UPSTREAM5"
git_c "$REPO5" push -q -u origin main
SRC5="${SANDBOX}/repo5-shared-worktree"
git_c "$REPO5" worktree add -q -B con-voyage/repo5 "$SRC5" main

# A slow `git worktree add` substitute: wrap git so the FIRST lane's worktree
# add blocks until a sentinel file appears, proving (if the second lane
# finishes first) that the two forks ran concurrently rather than queued.
SLOWDIR="${SANDBOX}/slowbin5"
mkdir -p "$SLOWDIR"
REAL_GIT="$(command -v git)"
SENTINEL5="${SANDBOX}/lane1-add-started"
cat > "${SLOWDIR}/git" <<SLOWGIT
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "worktree" ] && [ "\$4" = "add" ] && [[ "\$5" == *"--review-lane1" ]]; then
  touch "${SENTINEL5}"
  sleep 2
fi
exec "${REAL_GIT}" "\$@"
SLOWGIT
chmod +x "${SLOWDIR}/git"

OUT5A_FILE="${SANDBOX}/acquire5a.out"
(
  PATH="${SLOWDIR}:${PATH}" bash "$LANE_SCRIPT" acquire "$SRC5" lane1 > "$OUT5A_FILE" 2>&1
) &
lane1_bg=$!

waited5=0
while [ ! -f "$SENTINEL5" ] && [ "$waited5" -lt 10 ]; do sleep 0.2; waited5=$((waited5 + 1)); done
if [ ! -f "$SENTINEL5" ]; then
  fail "test setup: lane1's worktree add never started"
else
  OUT5B_FILE="${SANDBOX}/acquire5b.out"
  RC5B_FILE="${SANDBOX}/acquire5b.rc"
  start5b=$(date +%s)
  bash "$LANE_SCRIPT" acquire "$SRC5" lane2 > "$OUT5B_FILE" 2>&1
  echo $? > "$RC5B_FILE"
  elapsed5b=$(( $(date +%s) - start5b ))
  rc5b="$(cat "$RC5B_FILE" 2>/dev/null || echo "?")"
  assert_eq "0" "$rc5b" "lane2's acquire succeeds while lane1's worktree add is still in flight"
  if [ "$elapsed5b" -lt 2 ]; then
    pass "lane2's acquire completed in ${elapsed5b}s without waiting on lane1's worktree add (not serialized)"
  else
    fail "lane2's acquire took ${elapsed5b}s — appears serialized behind lane1's worktree add"
  fi
fi
wait "$lane1_bg" 2>/dev/null

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
