#!/usr/bin/env bash
# con-voyage-defer-status.test.sh — hermetic unit tests for
# cv_defer_status_append/cv_defer_status_read_and_clear (fk-shpd87, PR noise
# reduction design doc slice B / AC3).
#
# Why this exists: ci-repair workers used to post a top-level PR comment for
# every routine action (rebase, retry, "not actually blocked"), each one a
# fresh gh pr comment that can re-trigger a full reviewer cycle for no
# reason. These two helpers give ci-repair a "defer" path: write a one-line
# summary to shared per-PR state instead of posting immediately, so the
# NEXT comment-aggregate round (main.rereview-finalize.md) can fold it into
# that round's single comment instead. This suite proves the write/read
# primitives in isolation, offline, with no gh/gc calls at all.
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

# ===========================================================================
# CASE 1 — reading with nothing deferred yet is empty, not an error.
# ===========================================================================
start_case "1: read_and_clear on a dedup_key with no pending status is empty and succeeds"
CV_STATE_DIR="$(fresh_state_dir)"
out="$(cv_defer_status_read_and_clear "cv-finalize-acme-widgets-42")"
rc=$?
assert_eq "0" "$rc" "read_and_clear exit status with nothing pending"
assert_eq "" "$out" "read_and_clear output with nothing pending"

# ===========================================================================
# CASE 2 — a single deferred status round-trips exactly.
# ===========================================================================
start_case "2: a single appended status is readable, then cleared"
CV_STATE_DIR="$(fresh_state_dir)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "rebased onto origin/main, 3 commits replayed clean"
[ -f "${CV_STATE_DIR}/cv-finalize-acme-widgets-42.pending-status" ] && pass "append creates the per-PR pending-status file" \
  || fail "append did not create the per-PR pending-status file"
out="$(cv_defer_status_read_and_clear "cv-finalize-acme-widgets-42")"
case "$out" in
  *"rebased onto origin/main, 3 commits replayed clean"*) pass "read_and_clear returns the appended text" ;;
  *) fail "read_and_clear did not return the appended text (got: ${out})" ;;
esac
[ -f "${CV_STATE_DIR}/cv-finalize-acme-widgets-42.pending-status" ] && fail "pending-status file still exists after read_and_clear" \
  || pass "read_and_clear deletes the pending-status file (never posted twice)"

# ===========================================================================
# CASE 3 — multiple deferred statuses accumulate in append order and are
# cleared together by one read_and_clear.
# ===========================================================================
start_case "3: multiple appends accumulate, oldest first, cleared together"
CV_STATE_DIR="$(fresh_state_dir)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "retried failed job 'unit-tests' (flake)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "rebased onto origin/main, 1 commit replayed clean"
out="$(cv_defer_status_read_and_clear "cv-finalize-acme-widgets-42")"
first_line="$(printf '%s\n' "$out" | sed -n '1p')"
case "$first_line" in
  *"retried failed job"*) pass "first appended status comes first" ;;
  *) fail "first appended status is not first in output (got: ${first_line})" ;;
esac
n_lines="$(printf '%s\n' "$out" | grep -c '^-')"
assert_eq "2" "$n_lines" "two distinct deferred statuses are both present"
out2="$(cv_defer_status_read_and_clear "cv-finalize-acme-widgets-42")"
assert_eq "" "$out2" "a second read_and_clear after the first finds nothing left (never posted twice)"

# ===========================================================================
# CASE 4 — deferred status is scoped per dedup_key (per-PR), not global.
# ===========================================================================
start_case "4: deferred status is scoped to its own dedup_key"
CV_STATE_DIR="$(fresh_state_dir)"
cv_defer_status_append "cv-finalize-acme-widgets-42" "status for PR 42"
cv_defer_status_append "cv-finalize-acme-gadgets-7" "status for PR 7"
out42="$(cv_defer_status_read_and_clear "cv-finalize-acme-widgets-42")"
out7_untouched_check="$(cv_defer_status_read_and_clear "cv-finalize-acme-gadgets-7")"
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
# CASE 6 — both helpers actually consult the per-dedup_key lock instead of
# racing straight past it (review fk-drbqfj BLOCKING-1: the un-guarded
# `cat`+`rm` in read_and_clear can otherwise destroy an append landing in
# that window, silently and with no error — a pure timing race is too flaky
# to assert on directly, so this proves the mechanism deterministically).
# `acquire_lock` is overridden to always report "held by someone else", the
# same observable state a real concurrent holder produces. Against the
# pre-fix helpers (which never called acquire_lock/release_lock at all) this
# override has no effect and both calls below would silently succeed anyway
# — so this case only passes once the lock is genuinely wired in.
# ===========================================================================
start_case "6: both helpers back off instead of writing past a held lock"
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

read_out="$(cv_defer_status_read_and_clear "$LOCK_KEY")"
assert_eq "" "$read_out" "read_and_clear returns nothing when it cannot acquire the lock (does not read past it)"
[ -f "$PRE_EXISTING_FILE" ] && pass "read_and_clear left the pending-status file in place when it could not acquire the lock" \
  || fail "read_and_clear deleted the pending-status file despite never acquiring the lock"

unset -f acquire_lock release_lock
source "$LIB"  # restore the real implementations for any later case

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
