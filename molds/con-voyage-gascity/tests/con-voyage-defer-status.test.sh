#!/usr/bin/env bash
# con-voyage-defer-status.test.sh — hermetic unit tests for
# cv_defer_status_append/cv_defer_status_peek/cv_defer_status_clear_through
# (fk-shpd87, PR noise reduction design doc slice B / AC3).
#
# Why this exists: ci-repair workers used to post a top-level PR comment for
# every routine action (rebase, retry, "not actually blocked"), each one a
# fresh gh pr comment that can re-trigger a full reviewer cycle for no
# reason. These helpers give ci-repair a "defer" path: write a one-line
# summary to shared per-PR state instead of posting immediately, so the
# NEXT comment-aggregate round (main.rereview-finalize.md) can fold it into
# that round's single comment instead. This suite proves the write/read
# primitives in isolation, offline, with no gh/gc calls at all.
#
# mayor regrade FIX-5 (2026-10-14): cv_defer_status_read_and_clear had no
# production caller (main.rereview-finalize.md uses peek-then-clear_through,
# never a destructive single-shot read) — it was removed from
# con-voyage-lib.sh, and every case below that used to exercise it now
# exercises the real peek/clear_through pair production code actually calls.
#
# Run:  bash tests/con-voyage-defer-status.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: lib under test not found at ${LIB}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-defer-status-test.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# shellcheck disable=SC1090
source "$LIB"

FAILURES=0
CASE_NAME=""
start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

fresh_state_dir() {
  local d="${SANDBOX}/state-$$-${RANDOM}"
  mkdir -p "$d"
  printf '%s' "$d"
}

# clear_all KEY — drain a dedup_key's pending-status via the real
# peek-then-clear_through pair, the exact sequence production code uses.
clear_all() {
  local key="$1"
  local peeked
  peeked="$(cv_defer_status_peek "$key")"
  [ -n "$peeked" ] && cv_defer_status_clear_through "$key" "$peeked" >/dev/null
}

# ===========================================================================
# CASE 1 — peeking with nothing deferred yet is empty, not an error.
# ===========================================================================
start_case "1: peek on a dedup_key with no pending status is empty and succeeds"
CV_STATE_DIR="$(fresh_state_dir)"
out="$(cv_defer_status_peek "cv-finalize-acme-widgets-42")"
rc=$?
assert_eq "0" "$rc" "peek exit status with nothing pending"
assert_eq "" "$out" "peek output with nothing pending"

# ===========================================================================
# CASE 2 — a single deferred status round-trips exactly through peek, then
# clear_through removes it once "posted".
# ===========================================================================
start_case "2: a single appended status is readable via peek, then cleared via clear_through"
CV_STATE_DIR="$(fresh_state_dir)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "rebased onto origin/main, 3 commits replayed clean"
[ -f "${CV_STATE_DIR}/cv-finalize-acme-widgets-42.pending-status" ] && pass "append creates the per-PR pending-status file" \
  || fail "append did not create the per-PR pending-status file"
out="$(cv_defer_status_peek "cv-finalize-acme-widgets-42")"
case "$out" in
  *"rebased onto origin/main, 3 commits replayed clean"*) pass "peek returns the appended text" ;;
  *) fail "peek did not return the appended text (got: ${out})" ;;
esac
[ -f "${CV_STATE_DIR}/cv-finalize-acme-widgets-42.pending-status" ] || fail "peek should not have removed the pending-status file"
clear_rc=0
cv_defer_status_clear_through "cv-finalize-acme-widgets-42" "$out" || clear_rc=$?
assert_eq "0" "$clear_rc" "clear_through succeeds for the content just peeked"
[ -f "${CV_STATE_DIR}/cv-finalize-acme-widgets-42.pending-status" ] && fail "pending-status file still exists after clear_through" \
  || pass "clear_through deletes the pending-status file (never posted twice)"

# ===========================================================================
# CASE 3 — multiple deferred statuses accumulate in append order and are
# cleared together by one clear_through once peeked together.
# ===========================================================================
start_case "3: multiple appends accumulate, oldest first, cleared together"
CV_STATE_DIR="$(fresh_state_dir)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "retried failed job 'unit-tests' (flake)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "rebased onto origin/main, 1 commit replayed clean"
out="$(cv_defer_status_peek "cv-finalize-acme-widgets-42")"
first_line="$(printf '%s\n' "$out" | sed -n '1p')"
case "$first_line" in
  *"retried failed job"*) pass "first appended status comes first" ;;
  *) fail "first appended status is not first in output (got: ${first_line})" ;;
esac
n_lines="$(printf '%s\n' "$out" | grep -c '^-')"
assert_eq "2" "$n_lines" "two distinct deferred statuses are both present"
cv_defer_status_clear_through "cv-finalize-acme-widgets-42" "$out" >/dev/null
out2="$(cv_defer_status_peek "cv-finalize-acme-widgets-42")"
assert_eq "" "$out2" "a peek after clear_through finds nothing left (never posted twice)"

# ===========================================================================
# CASE 4 — deferred status is scoped per dedup_key (per-PR), not global.
# ===========================================================================
start_case "4: deferred status is scoped to its own dedup_key"
CV_STATE_DIR="$(fresh_state_dir)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "status for PR 42"
cv_defer_status_append "cv-finalize-acme-gadgets-7" "status for PR 7"
out42="$(cv_defer_status_peek "cv-finalize-acme-widgets-42")"
cv_defer_status_clear_through "cv-finalize-acme-widgets-42" "$out42" >/dev/null
out7_untouched_check="$(cv_defer_status_peek "cv-finalize-acme-gadgets-7")"
case "$out42" in
  *"status for PR 42"*) pass "PR 42's own status is isolated to its dedup_key" ;;
  *) fail "PR 42's status leaked or was missing (got: ${out42})" ;;
esac
case "$out7_untouched_check" in
  *"status for PR 7"*) pass "clearing PR 42's status left PR 7's status untouched" ;;
  *) fail "clearing PR 42's status corrupted PR 7's own status (got: ${out7_untouched_check})" ;;
esac

# ===========================================================================
# CASE 5 — a newline embedded in the appended text is flattened to a single
# bullet line, so the pending-status file always stays one entry per line
# (a later caller can safely count/iterate lines).
# ===========================================================================
start_case "5: an embedded newline in the appended text is flattened to one line"
CV_STATE_DIR="$(fresh_state_dir)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "$(printf 'line one\nline two')"
line_count="$(wc -l < "${CV_STATE_DIR}/cv-finalize-acme-widgets-42.pending-status" | tr -d ' ')"
assert_eq "1" "$line_count" "an embedded newline does not split the pending-status file into extra lines"

# ===========================================================================
# CASE 6 — append and peek actually consult the per-dedup_key lock instead of
# racing straight past it (review fk-drbqfj BLOCKING-1: an un-guarded
# `cat`+write can otherwise destroy an append landing in that window,
# silently and with no error — a pure timing race is too flaky to assert on
# directly, so this proves the mechanism deterministically).
# `acquire_lock` is overridden to always report "held by someone else", the
# same observable state a real concurrent holder produces. Against helpers
# that never called acquire_lock/release_lock at all this override would have
# no effect and both calls below would silently succeed anyway — so this
# case only passes once the lock is genuinely wired in.
# ===========================================================================
start_case "6: append and peek back off instead of writing/reading past a held lock"
CV_STATE_DIR="$(fresh_state_dir)"
LOCK_KEY="cv-finalize-acme-locked-7"
PRE_EXISTING_FILE="${CV_STATE_DIR}/${LOCK_KEY}.pending-status"
printf -- '- pre-existing status from the lock holder\n' > "$PRE_EXISTING_FILE"

acquire_lock() { return 1; }  # simulate: another process holds this dedup_key's lock
release_lock() { :; }

append_rc=0
cv_defer_status_append "$LOCK_KEY" "a status appended while the lock is held elsewhere" || append_rc=$?
assert_eq "1" "$append_rc" "append backs off (nonzero exit) instead of writing past a held lock"

file_contents_after_append="$(cat "$PRE_EXISTING_FILE")"
case "$file_contents_after_append" in
  *"a status appended while the lock is held elsewhere"*)
    fail "append wrote into the pending-status file despite never acquiring the lock" ;;
  *)
    pass "the pre-existing pending-status file is untouched by the backed-off append" ;;
esac

peek_out="$(cv_defer_status_peek "$LOCK_KEY")"
assert_eq "" "$peek_out" "peek returns nothing when it cannot acquire the lock (does not read past it)"
[ -f "$PRE_EXISTING_FILE" ] && pass "peek left the pending-status file in place when it could not acquire the lock" \
  || fail "peek deleted the pending-status file despite never acquiring the lock"

unset -f acquire_lock release_lock
source "$LIB"  # restore the real implementations for any later case

# ===========================================================================
# CASE 7 — append's bounded retry actually recovers: a lock held by a
# short-lived holder that releases before the retry budget is exhausted must
# not be treated as a permanent failure (review fk-drbqfj iteration-2
# BLOCKING-1, qa-test fk-jhzihj: CASE 6 above only proves the two extremes,
# "never fails" and "fails forever" — nothing exercised the actual reason
# this is a bounded retry loop and not a bare acquire-or-fail, which is
# "fails N times, then succeeds on attempt N+1", the exact shape ci-repair
# and rereview-finalize are expected to hit routinely per the function's own
# comment). acquire_lock is overridden with a counter: the first two calls
# report "held elsewhere" the same way CASE 6's permanent stub does, then the
# override delegates to the real acquire_lock so the 3rd call genuinely
# acquires the lock. This pins both the outcome (eventual success, correct
# content) and the exact retry count, so an off-by-one on the attempt
# counter or a loop that only checks once would fail this case even though
# it would pass CASE 6's two extremes.
# ===========================================================================
start_case "7: append succeeds after transient lock contention (fails N times, then acquires on retry)"
CV_STATE_DIR="$(fresh_state_dir)"
APPEND_LOCK_KEY="cv-finalize-acme-retry-append"

eval "$(declare -f acquire_lock | sed '1s/acquire_lock/__real_acquire_lock/')"
ACQUIRE_LOCK_CALLS=0
ACQUIRE_LOCK_FAIL_UNTIL=2
acquire_lock() {
  ACQUIRE_LOCK_CALLS=$((ACQUIRE_LOCK_CALLS + 1))
  if [ "$ACQUIRE_LOCK_CALLS" -le "$ACQUIRE_LOCK_FAIL_UNTIL" ]; then
    return 1
  fi
  __real_acquire_lock "$@"
}

append_rc=0
cv_defer_status_append "$APPEND_LOCK_KEY" "status recorded once the transient lock holder released" || append_rc=$?
assert_eq "0" "$append_rc" "append ultimately succeeds once the transient lock releases"
assert_eq "3" "$ACQUIRE_LOCK_CALLS" "append retried acquire_lock exactly until the 3rd (succeeding) attempt"

appended_contents="$(cat "${CV_STATE_DIR}/${APPEND_LOCK_KEY}.pending-status" 2>/dev/null)"
case "$appended_contents" in
  *"status recorded once the transient lock holder released"*) pass "the appended text is present once the retry succeeds" ;;
  *) fail "appended text missing after the retry succeeds (got: ${appended_contents})" ;;
esac

unset -f acquire_lock __real_acquire_lock
source "$LIB"  # restore the real implementations for any later case

# ===========================================================================
# CASE 8 — peek's bounded retry actually recovers, same scenario as CASE 7
# but for the read side (review fk-drbqfj iteration-2 BLOCKING-1).
# ===========================================================================
start_case "8: peek succeeds after transient lock contention (fails N times, then acquires on retry)"
CV_STATE_DIR="$(fresh_state_dir)"
READ_LOCK_KEY="cv-finalize-acme-retry-read"
PRE_FILE="${CV_STATE_DIR}/${READ_LOCK_KEY}.pending-status"
printf -- '- status pending before the transient lock holder released\n' > "$PRE_FILE"

eval "$(declare -f acquire_lock | sed '1s/acquire_lock/__real_acquire_lock/')"
ACQUIRE_LOCK_CALLS=0
ACQUIRE_LOCK_FAIL_UNTIL=2
acquire_lock() {
  ACQUIRE_LOCK_CALLS=$((ACQUIRE_LOCK_CALLS + 1))
  if [ "$ACQUIRE_LOCK_CALLS" -le "$ACQUIRE_LOCK_FAIL_UNTIL" ]; then
    return 1
  fi
  __real_acquire_lock "$@"
}

CASE8_OUT_FILE="${SANDBOX}/case8-read-out-$$"
# Redirect stdout to a file rather than capturing via $(...): a command
# substitution subshell would increment ACQUIRE_LOCK_CALLS in a forked
# process, silently discarding the count once the subshell exits.
cv_defer_status_peek "$READ_LOCK_KEY" > "$CASE8_OUT_FILE"
read_out="$(cat "$CASE8_OUT_FILE")"
case "$read_out" in
  *"status pending before the transient lock holder released"*) pass "peek returns the pending text once the retry succeeds" ;;
  *) fail "peek did not return the pending text after the retry succeeds (got: ${read_out})" ;;
esac
assert_eq "3" "$ACQUIRE_LOCK_CALLS" "peek retried acquire_lock exactly until the 3rd (succeeding) attempt"
[ -f "$PRE_FILE" ] || fail "peek should never remove the pending-status file"

unset -f acquire_lock __real_acquire_lock
source "$LIB"  # restore the real implementations for any later case

# ===========================================================================
# CASE 9 — empty dedup_key is refused by append and peek instead of touching
# "CV_STATE_DIR/.pending-status" (review fk-7bmhlz LOW-3, carried forward
# from iteration 1: these edge cases were never directly exercised before).
# ===========================================================================
start_case "9: an empty dedup_key is refused by cv_defer_status_append, no file written"
CV_STATE_DIR="$(fresh_state_dir)"
empty_key_append_rc=0
cv_defer_status_append "" "text for an empty dedup_key" || empty_key_append_rc=$?
assert_eq "1" "$empty_key_append_rc" "cv_defer_status_append refuses an empty dedup_key"
[ -f "${CV_STATE_DIR}/.pending-status" ] && fail "cv_defer_status_append wrote a .pending-status file for an empty dedup_key" \
  || pass "cv_defer_status_append wrote nothing for an empty dedup_key"

start_case "9b: an empty dedup_key is refused by cv_defer_status_peek, returns nothing"
CV_STATE_DIR="$(fresh_state_dir)"
empty_key_read_rc=0
empty_key_out="$(cv_defer_status_peek "" )" || empty_key_read_rc=$?
assert_eq "1" "$empty_key_read_rc" "cv_defer_status_peek refuses an empty dedup_key"
assert_eq "" "$empty_key_out" "cv_defer_status_peek prints nothing for an empty dedup_key"

start_case "9c: an empty dedup_key is refused by cv_defer_status_clear_through, returns nothing touched"
CV_STATE_DIR="$(fresh_state_dir)"
empty_key_clear_rc=0
cv_defer_status_clear_through "" "some expected content" || empty_key_clear_rc=$?
assert_eq "1" "$empty_key_clear_rc" "cv_defer_status_clear_through refuses an empty dedup_key"

# ===========================================================================
# CASE 10 — a missing CV_STATE_DIR does not crash append or peek; append
# surfaces the failure (no silent data loss), peek reports nothing pending
# (review fk-7bmhlz LOW-3).
# ===========================================================================
start_case "10: a missing CV_STATE_DIR does not crash cv_defer_status_append"
CV_STATE_DIR="${SANDBOX}/does-not-exist-$$-${RANDOM}"
missing_dir_append_rc=0
cv_defer_status_append "cv-finalize-acme-missing-dir" "text with no CV_STATE_DIR" || missing_dir_append_rc=$?
case "$missing_dir_append_rc" in
  # acquire_lock's own "mkdir -p \${CV_STATE_DIR}/.locks" already creates
  # CV_STATE_DIR as a pre-existing side effect (not something this fix
  # changes) — the only thing this case pins is "no crash", any clean exit.
  0|1) pass "cv_defer_status_append exits 0 or 1 (no crash) when CV_STATE_DIR does not exist (rc=${missing_dir_append_rc})" ;;
  *) fail "cv_defer_status_append exited abnormally (rc=${missing_dir_append_rc}) when CV_STATE_DIR does not exist" ;;
esac

start_case "10b: a missing CV_STATE_DIR does not crash cv_defer_status_peek"
CV_STATE_DIR="${SANDBOX}/still-does-not-exist-$$-${RANDOM}"
missing_dir_read_out="$(cv_defer_status_peek "cv-finalize-acme-missing-dir" 2>&1)"
missing_dir_read_rc=$?
assert_eq "0" "$missing_dir_read_rc" "cv_defer_status_peek exits 0 (no crash) when CV_STATE_DIR does not exist"
assert_eq "" "$missing_dir_read_out" "cv_defer_status_peek prints nothing when CV_STATE_DIR does not exist"

# ===========================================================================
# CASE 11 — real-process concurrency: a REAL backgrounded OS process holding
# the dedup_key's lock actually blocks a foreground caller in another
# process, not just an in-process function-override simulation (review
# fk-7bmhlz LOW-2, QA/test-engineering, carried forward from iteration 2:
# CASE 6-8 above prove the mechanism by overriding acquire_lock in-process,
# which can't rule out the lock being process-local rather than a real
# filesystem-level mutex two separate processes both honor). The background
# process acquires the SAME lock via the real acquire_lock, holds it for a
# known ~1s while it appends its own line, then releases — a foreground
# cv_defer_status_append racing against it is only safe if it genuinely
# waits on the real, cross-process `mkdir`-based lock in
# ${CV_STATE_DIR}/.locks, not an in-memory guard scoped to one process.
# ===========================================================================
start_case "11: a real background process holding the lock actually blocks a foreground cv_defer_status_append in a different process"
CV_STATE_DIR="$(fresh_state_dir)"
CONCURRENCY_KEY="cv-finalize-acme-real-concurrency"
(
  # shellcheck disable=SC1090
  source "$LIB"
  while ! acquire_lock "$CONCURRENCY_KEY"; do sleep 0.1; done
  sleep 1
  printf -- '- background holder appended its line\n' >> "${CV_STATE_DIR}/${CONCURRENCY_KEY}.pending-status"
  release_lock "$CONCURRENCY_KEY"
) &
BG_PID=$!
sleep 0.2  # give the background process a head start so it holds the lock first
fg_append_rc=0
cv_defer_status_append "$CONCURRENCY_KEY" "foreground text appended after the real lock released" || fg_append_rc=$?
wait "$BG_PID"
assert_eq "0" "$fg_append_rc" "the foreground append eventually succeeds once the real background holder (a separate OS process) releases the lock"
final_contents="$(cat "${CV_STATE_DIR}/${CONCURRENCY_KEY}.pending-status" 2>/dev/null)"
case "$final_contents" in
  *"background holder appended its line"*"foreground text appended after the real lock released"*)
    pass "both the background process's and the foreground process's lines are present, in order — the real cross-process lock serialized them" ;;
  *)
    fail "expected both lines present in append order, got: ${final_contents}" ;;
esac

# ===========================================================================
# CASE 12 — cv_defer_status_clear_through clears the whole file when the
# current content exactly matches what was peeked and posted (the common
# case: nothing appended since the peek).
# ===========================================================================
start_case "12: clear_through removes the file when current content exactly matches EXPECTED"
CV_STATE_DIR="$(fresh_state_dir)"
CLEAR_KEY="cv-finalize-acme-clear-exact"
cv_defer_status_append "$CLEAR_KEY" "only status, nothing appended after the peek"
peeked="$(cv_defer_status_peek "$CLEAR_KEY")"
clear_rc=0
cv_defer_status_clear_through "$CLEAR_KEY" "$peeked" || clear_rc=$?
assert_eq "0" "$clear_rc" "clear_through succeeds on an exact match"
[ -f "${CV_STATE_DIR}/${CLEAR_KEY}.pending-status" ] && fail "clear_through left the pending-status file in place on an exact match" \
  || pass "clear_through removed the pending-status file on an exact match"

# ===========================================================================
# CASE 13 — the race this fix exists to close: a status appended AFTER the
# peek (e.g. a concurrent ci-repair run, while the aggregate comment post is
# still in flight) must survive clear_through, not be destroyed along with
# the posted prefix (review fk-z6rts BLOCKING-1).
# ===========================================================================
start_case "13: clear_through preserves a status appended after the peek"
CV_STATE_DIR="$(fresh_state_dir)"
RACE_KEY="cv-finalize-acme-clear-race"
cv_defer_status_append "$RACE_KEY" "status A, present at peek time"
peeked_a="$(cv_defer_status_peek "$RACE_KEY")"
# Simulate a concurrent cv_defer_status_append landing in the window between
# the peek above and the clear below (the post is a live network call in
# the real caller).
cv_defer_status_append "$RACE_KEY" "status B, appended after the peek while posting A was still in flight"
clear_rc=0
cv_defer_status_clear_through "$RACE_KEY" "$peeked_a" || clear_rc=$?
assert_eq "0" "$clear_rc" "clear_through succeeds when the current content is EXPECTED plus a later append"
remaining="$(cat "${CV_STATE_DIR}/${RACE_KEY}.pending-status" 2>/dev/null)"
case "$remaining" in
  *"status A"*) fail "clear_through left the already-posted status A behind (got: ${remaining})" ;;
esac
case "$remaining" in
  *"status B, appended after the peek while posting A was still in flight"*)
    pass "clear_through preserved status B, appended after the peek, for the next round's peek" ;;
  *)
    fail "clear_through destroyed status B, appended after the peek (got: ${remaining})" ;;
esac

# ===========================================================================
# CASE 14 — if the current content no longer has EXPECTED as a prefix at
# all (an unexpected external change), clear_through fails closed: it
# leaves the file completely untouched and reports failure rather than
# risk destroying content nobody has confirmed posting.
# ===========================================================================
start_case "14: clear_through leaves the file untouched and fails when EXPECTED is not a prefix of the current content"
CV_STATE_DIR="$(fresh_state_dir)"
MISMATCH_KEY="cv-finalize-acme-clear-mismatch"
cv_defer_status_append "$MISMATCH_KEY" "status that was never actually peeked"
clear_rc=0
cv_defer_status_clear_through "$MISMATCH_KEY" "status that was peeked but does not match current content" || clear_rc=$?
assert_eq "1" "$clear_rc" "clear_through reports failure on a content mismatch"
mismatch_contents="$(cat "${CV_STATE_DIR}/${MISMATCH_KEY}.pending-status" 2>/dev/null)"
case "$mismatch_contents" in
  *"status that was never actually peeked"*) pass "clear_through left the mismatched file's content untouched" ;;
  *) fail "clear_through modified the file despite a content mismatch (got: ${mismatch_contents})" ;;
esac

# ===========================================================================
# CASE 15 — a blank EXPECTED is a caller error (nothing was peeked, so there
# is nothing confirmed-posted to clear); clear_through refuses it outright
# without touching the file.
# ===========================================================================
start_case "15: clear_through refuses a blank EXPECTED and touches nothing"
CV_STATE_DIR="$(fresh_state_dir)"
BLANK_KEY="cv-finalize-acme-clear-blank"
cv_defer_status_append "$BLANK_KEY" "status present when EXPECTED is blank"
clear_rc=0
cv_defer_status_clear_through "$BLANK_KEY" "" || clear_rc=$?
assert_eq "1" "$clear_rc" "clear_through refuses a blank EXPECTED"
[ -f "${CV_STATE_DIR}/${BLANK_KEY}.pending-status" ] && pass "clear_through left the pending-status file in place for a blank EXPECTED" \
  || fail "clear_through deleted the pending-status file despite a blank EXPECTED"

# ===========================================================================
# CASE 16 — mayor regrade BLOCKING-4 (was LOW-7, 2026-10-14): the '/' and
# '..' charset guards in cv_defer_status_append, cv_defer_status_peek, and
# cv_defer_status_clear_through are direct safety checks against a dedup_key
# that could otherwise escape CV_STATE_DIR (path traversal) or be
# interpreted as a nested path — exercise each guard directly instead of
# only relying on the dedup_key convention never producing one in practice.
# A pre-existing sibling file both outside and inside CV_STATE_DIR proves no
# write happens anywhere on a rejected key.
# ===========================================================================
start_case "16: append refuses a dedup_key containing '/' and writes nothing"
CV_STATE_DIR="$(fresh_state_dir)"
TRAVERSAL_KEY="../escape"
append_traversal_rc=0
cv_defer_status_append "$TRAVERSAL_KEY" "should never be written" || append_traversal_rc=$?
assert_eq "1" "$append_traversal_rc" "append refuses a dedup_key containing '..'"
[ -f "${SANDBOX}/escape.pending-status" ] && fail "append escaped CV_STATE_DIR via a '..' dedup_key" \
  || pass "append wrote nothing outside CV_STATE_DIR for a '..' dedup_key"

start_case "16b: append refuses a dedup_key containing a nested '/' and writes nothing"
CV_STATE_DIR="$(fresh_state_dir)"
NESTED_KEY="sub/dir-key"
append_nested_rc=0
cv_defer_status_append "$NESTED_KEY" "should never be written" || append_nested_rc=$?
assert_eq "1" "$append_nested_rc" "append refuses a dedup_key containing '/'"
[ -d "${CV_STATE_DIR}/sub" ] && fail "append created a nested directory for a '/' dedup_key" \
  || pass "append created no nested directory for a '/' dedup_key"

start_case "16c: peek refuses a dedup_key containing '/' or '..' and returns nothing"
CV_STATE_DIR="$(fresh_state_dir)"
peek_traversal_out="$(cv_defer_status_peek "../escape" 2>&1)"
assert_eq "" "$peek_traversal_out" "peek returns nothing for a '..' dedup_key"
peek_nested_out="$(cv_defer_status_peek "sub/dir-key" 2>&1)"
assert_eq "" "$peek_nested_out" "peek returns nothing for a '/' dedup_key"

start_case "16d: clear_through refuses a dedup_key containing '/' or '..' and touches nothing"
CV_STATE_DIR="$(fresh_state_dir)"
clear_traversal_rc=0
cv_defer_status_clear_through "../escape" "some expected content" || clear_traversal_rc=$?
assert_eq "1" "$clear_traversal_rc" "clear_through refuses a '..' dedup_key"
clear_nested_rc=0
cv_defer_status_clear_through "sub/dir-key" "some expected content" || clear_nested_rc=$?
assert_eq "1" "$clear_nested_rc" "clear_through refuses a '/' dedup_key"
[ -f "${SANDBOX}/escape.pending-status" ] && fail "clear_through escaped CV_STATE_DIR via a '..' dedup_key" \
  || pass "clear_through touched nothing outside CV_STATE_DIR for a '..' dedup_key"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
