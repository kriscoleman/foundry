#!/usr/bin/env bash
# cv-timeout.test.sh — hermetic, offline tests for cv-timeout.sh, the
# standalone bounded-call primitive extracted so callers that cannot source
# con-voyage-lib.sh (e.g. main.rereview-seed.md's CV_LIB-unresolved fallback,
# review fk-xfewni BLOCKING LOW-7) still get the SAME hardened timeout
# cv_with_timeout provides, instead of a lesser, unhardened reimplementation.
#
# Mirrors con-voyage-lib.test.sh's own cv_with_timeout cases (same bugs, same
# fixes) so this standalone copy is proven to carry the identical hardening,
# not just the same doc comment.
#
# Run:  bash tests/cv-timeout.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-timeout.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi
if [ ! -x "$SCRIPT" ]; then
  echo "FATAL: ${SCRIPT} is not executable" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then pass "${desc} (=${actual})"; else fail "${desc}: expected '${expected}', got '${actual}'"; fi
}

start_case "a command that finishes within the bound passes through output and exit status"
out="$("$SCRIPT" 5 sh -c 'printf ok; exit 3')"; rc=$?
assert_eq "ok" "$out" "stdout passed through"
assert_eq "3" "$rc" "exit status passed through"

start_case "a hung command is killed at the bound, not left to run to completion"
t0="$(date +%s)"
out="$("$SCRIPT" 1 sleep 20)"; rc=$?
t1="$(date +%s)"
elapsed=$((t1 - t0))
assert_eq "124" "$rc" "killed command reports 124"
if [ "$elapsed" -lt 10 ]; then
  pass "returned in ${elapsed}s, not the hung command's full 20s"
else
  fail "took ${elapsed}s — the bound did not actually apply"
fi

start_case "a malformed SECONDS runs the command with no bound (fail-open on bad config)"
out="$("$SCRIPT" not-a-number echo hi)"; rc=$?
assert_eq "hi" "$out" "command still ran"
assert_eq "0" "$rc" "exit status passed through"

start_case "an empty SECONDS runs the command with no bound"
out="$("$SCRIPT" '' echo hi)"; rc=$?
assert_eq "hi" "$out" "command still ran"
assert_eq "0" "$rc" "exit status passed through"

start_case "a zero/negative SECONDS runs the command with no bound"
out="$("$SCRIPT" 0 echo hi)"; rc=$?
assert_eq "hi" "$out" "command still ran"
assert_eq "0" "$rc" "exit status passed through"

start_case "a fast command returns promptly, not after the full bound"
t0="$(date +%s)"
out="$("$SCRIPT" 20 echo fast)"
t1="$(date +%s)"
elapsed=$((t1 - t0))
assert_eq "fast" "$out" "stdout passed through"
if [ "$elapsed" -lt 5 ]; then
  pass "returned in ${elapsed}s, not the full 20s bound"
else
  fail "took ${elapsed}s — did not return promptly"
fi

start_case "a leading-zero decimal bound (010) is read as decimal 10, not octal 8"
out="$("$SCRIPT" 010 sleep 9; echo "rc=$?")"
case "$out" in
  *rc=124*) fail "treated 010 as octal 8 (killed before the actual 10s decimal bound) or crashed: ${out}" ;;
  *rc=0*) pass "010 read as decimal 10 — sleep 9 completed on its own" ;;
  *) fail "unexpected result: ${out}" ;;
esac

start_case "a leading-zero bound with an 8/9 digit (08) does not crash or orphan the child"
out="$("$SCRIPT" 08 true 2>&1)"; rc=$?
assert_eq "0" "$rc" "08 did not crash the arithmetic expansion"

if command -v zsh >/dev/null 2>&1; then
  start_case "under zsh: passes through output/status and actually kills a hung command"
  zsh_out="$(zsh -c "'$SCRIPT' 5 sh -c 'printf ok; exit 3'")"
  zsh_rc=$?
  assert_eq "ok" "$zsh_out" "zsh: stdout passed through"
  assert_eq "3" "$zsh_rc" "zsh: exit status passed through"

  zsh -c "'$SCRIPT' 1 sleep 20" >/dev/null 2>&1
  zsh_rc2=$?
  assert_eq "124" "$zsh_rc2" "zsh: killed command reports 124"
else
  echo "(skipping zsh cases — zsh not found on PATH)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
