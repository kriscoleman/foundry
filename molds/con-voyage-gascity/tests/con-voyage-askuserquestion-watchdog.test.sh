#!/usr/bin/env bash
# con-voyage-askuserquestion-watchdog.test.sh — hermetic, offline test for the
# city-wide interactive-prompt-stall watchdog (fk-o9ntx: item 2/DETECT of
# fk-6kvnt's proposal).
#
# BACKGROUND: a headless worker session can still call an interactive prompt
# tool (e.g. Claude Code's AskUserQuestion). Nobody watches its pane, so the
# session blocks forever (SEEN 2026-09-25: a raw --no-formula bead sat stuck
# for ~20 minutes until the mayor happened to peek it by hand). fk-6kvnt
# shipped the prevention text plus the detection primitive
# cv_text_has_interactive_prompt_stall in con-voyage-lib.sh; this script wires
# a LIVE watchdog around that primitive, scanning every active session in the
# city (not just con-voyage-dispatched ones) every cycle.
#
# HOW IT WORKS (no network, no real gc): a recording STUB `gc` is built in a
# temp dir. `gc session list --json` and `gc session peek <id> --json` are
# backed by env vars (STUB_SESSION_LIST_JSON / STUB_PEEK_OUTPUT) so a test
# case can hand back exactly the pane text it wants to exercise. The script
# under test honors GC= (default gc) so we point it at the stub, and persists
# its own dedup state under GC_CITY's .gc dir, so re-invoking run_script
# against the SAME CITY_DIR (without calling setup_case_env again) simulates
# consecutive watchdog cycles, exactly like con-voyage-review-watchdog.test.sh's
# own multi-cycle cases.
#
# Run:  bash tests/con-voyage-askuserquestion-watchdog.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-askuserquestion-watchdog.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-askq-watchdog-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv (newlines collapsed to spaces so a multi-line
# mail body still logs as one grep-able line), and answers session
# list/peek, bd list, and mail send from env vars — same idiom as
# con-voyage-review-watchdog.test.sh's stub.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city) i=$((i+2)) ;;
    --rig)  i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"

case "$sub" in
  session)
    sessub="${args[$((i+1))]:-}"
    if [ "$sessub" = "list" ]; then
      if [ "${STUB_SESSION_LIST_FAIL:-0}" = "1" ]; then
        echo "gc session list: simulated failure" >&2
        exit 1
      fi
      if [ -n "${STUB_SESSION_LIST_JSON:-}" ]; then
        printf '%s' "$STUB_SESSION_LIST_JSON"
      else
        printf '{"sessions":[]}'
      fi
      exit 0
    fi
    if [ "$sessub" = "peek" ]; then
      if [ "${STUB_PEEK_FAIL:-0}" = "1" ]; then
        echo "gc session peek: simulated failure" >&2
        exit 1
      fi
      python3 -c "
import json, os
print(json.dumps({'output': os.environ.get('STUB_PEEK_OUTPUT', ''), 'ok': True}))
"
      exit 0
    fi
    if [ "$sessub" = "nudge" ]; then
      exit 0
    fi
    exit 0
    ;;
  bd)
    bdsub="${args[$((i+1))]:-}"
    if [ "$bdsub" = "list" ]; then
      if [ -n "${STUB_BD_LIST_JSON:-}" ]; then
        printf '%s' "$STUB_BD_LIST_JSON"
      else
        printf '[]'
      fi
      exit 0
    fi
    exit 0
    ;;
  mail)
    mailsub="${args[$((i+1))]:-}"
    if [ "$mailsub" = "send" ]; then
      if [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ]; then
        echo "gc mail send: failed to deliver (simulated)" >&2
        exit 1
      fi
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# ---------------------------------------------------------------------------
# Test harness bookkeeping (same idioms as con-voyage-review-watchdog.test.sh).
# ---------------------------------------------------------------------------
FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

log_count() {
  local logfile="$1" pattern="$2"
  [ -f "$logfile" ] || { echo 0; return; }
  local n
  n="$(grep -E -c -- "$pattern" "$logfile")"
  printf '%s' "${n:-0}"
}

assert_log_count() {
  local n; n="$(log_count "$1" "$2")"
  assert_eq "$3" "$n" "$4"
}

# session_json ID NAME TEMPLATE SESSION_NAME RIG — one `gc session list` entry.
session_json() {
  python3 -c "
import json, sys
sid, name, template, session_name, rig = sys.argv[1:6]
print(json.dumps({
    'id': sid, 'name': name, 'template': template,
    'session_name': session_name, 'rig': rig, 'state': 'active',
}))
" "$1" "$2" "$3" "$4" "$5"
}

# write_sessions SESSION_JSON... — wrap session_json objects into the
# {"sessions": [...]} envelope `gc session list --json` returns.
write_sessions() {
  python3 -c "
import json, sys
print(json.dumps({'sessions': [json.loads(x) for x in sys.argv[1:]]}))
" "$@"
}

CITY_DIR=""
GC_LOG=""
OUT=""
RC=0

setup_case_env() {
  CITY_DIR="${SANDBOX}/city-${1}"
  GC_LOG="${SANDBOX}/gc-${1}.log"
  mkdir -p "$CITY_DIR"
  : > "$GC_LOG"
}

# askq_state_path SESSION_ID — on-disk dedup state file path for a session,
# mirroring the script's own default CV_ASKQ_STATE_DIR layout (this suite
# never overrides CV_ASKQ_STATE_DIR, so it always resolves under GC_CITY).
askq_state_path() {
  printf '%s/.gc/cv-askuserquestion-watchdog/%s.state' "$CITY_DIR" "$1"
}

# run_script — invoke the script under test with the stub wired in.
run_script() {
  OUT="$(
    env \
      GC="${STUBDIR}/gc" \
      GC_CITY="$CITY_DIR" \
      STUB_GC_LOG="$GC_LOG" \
      "$@" \
      bash "$SCRIPT" 2>&1
  )"
  RC=$?
}

DEFAULT_ENV=(CV_ASKQ_MAIL_TARGET="mayor" CV_ASKQ_PEEK_LINES="50" CV_ASKQ_STORE_TIMEOUT_SECONDS="5")

# Two distinct realistic AskUserQuestion pane captures (footer phrases split
# across the two literal substrings cv_text_has_interactive_prompt_stall
# actually matches on) plus one normal, non-stuck frame.
STUCK_TEXT_A=$'Pick an approach?\n1. Rewrite\n2. Patch\n\n  ↑/↓ to navigate · Enter to select · Esc to close'
STUCK_TEXT_B=$'Deploy now?\n1. Yes\n2. No\n\n  ↑/↓ to navigate · Enter to select · Esc to close'
NORMAL_TEXT=$'Running tests...\nAll good.\n'

# ===========================================================================
# CASE 1 — No active sessions at all: clean no-op, no peek/mail calls.
# ===========================================================================
start_case "1: no active sessions is a clean no-op"
setup_case_env "1"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0 with no candidate sessions"
assert_log_count "$GC_LOG" 'session peek|mail send' 0 "no peek or mail calls when nothing was found"

# ===========================================================================
# CASE 2 — The mayor's own session is excluded entirely, even when its pane
#   shows the stall footer (the mayor legitimately uses interactive prompts
#   with a human at the terminal — see fk-6kvnt).
# ===========================================================================
start_case "2: the mayor's own session is never a candidate"
setup_case_env "2"
run_script "${DEFAULT_ENV[@]}" \
  STUB_SESSION_LIST_JSON="$(write_sessions "$(session_json rc-inv mayor mayor mayor '')")" \
  STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session peek rc-inv' 0 "the mayor's session is filtered out before any peek is attempted"
run_script "${DEFAULT_ENV[@]}" \
  STUB_SESSION_LIST_JSON="$(write_sessions "$(session_json rc-inv mayor mayor mayor '')")" \
  STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_log_count "$GC_LOG" 'mail send' 0 "still no mail after a second cycle — the mayor is never a candidate no matter how many cycles run"

# ===========================================================================
# CASE 3 — A non-mayor session's first stuck sighting: no mail yet (a single
#   peek is the LAST RENDERED FRAME and can be stale/self-resolving).
# ===========================================================================
start_case "3: a stuck frame seen once does not alert"
setup_case_env "3"
SESSIONS_3="$(write_sessions "$(session_json rc-3 'foundry-kc/gc.implementation-worker-3' 'foundry-kc/gc.implementation-worker' 'gc__implementation-worker-rc-3' 'foundry-kc')")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_3" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session peek rc-3' 1 "the candidate session was peeked"
assert_log_count "$GC_LOG" 'mail send' 0 "one sighting alone never mails"

# ===========================================================================
# CASE 4 — The SAME stuck frame on a second consecutive cycle mails exactly
#   once, and the mail names the session, its template, the unblock command,
#   and a resolved bead id.
# ===========================================================================
start_case "4: the same stuck frame on a second consecutive cycle mails once"
setup_case_env "4"
SESSIONS_4="$(write_sessions "$(session_json rc-4 'foundry-kc/gc.implementation-worker-4' 'foundry-kc/gc.implementation-worker' 'gc__implementation-worker-rc-4' 'foundry-kc')")"
BD_4='[{"id":"fk-example4"}]'
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_4" STUB_PEEK_OUTPUT="$STUCK_TEXT_A" STUB_BD_LIST_JSON="$BD_4"
assert_log_count "$GC_LOG" 'mail send' 0 "first sighting still does not mail"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_4" STUB_PEEK_OUTPUT="$STUCK_TEXT_A" STUB_BD_LIST_JSON="$BD_4"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "the second consecutive sighting of the same stuck frame mails exactly once"
assert_log_count "$GC_LOG" 'mail send.*rc-4' 1 "the mail body/subject names the stuck session id"
assert_log_count "$GC_LOG" 'template foundry-kc/gc.implementation-worker' 1 "the mail names the session's template"
assert_log_count "$GC_LOG" 'fk-example4' 1 "the mail includes the resolved bead id"
assert_log_count "$GC_LOG" 'session nudge rc-4 .option-number. --delivery immediate' 1 "the mail includes the literal unblock command"

# ===========================================================================
# CASE 5 — The same stuck frame on a THIRD cycle (already alerted) never
#   sends a duplicate mail.
# ===========================================================================
start_case "5: an already-alerted stuck frame never duplicates the mail"
setup_case_env "5"
SESSIONS_5="$(write_sessions "$(session_json rc-5 'foundry-kc/gc.implementation-worker-5' 'foundry-kc/gc.implementation-worker' 'gc__implementation-worker-rc-5' 'foundry-kc')")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_5" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_5" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_log_count "$GC_LOG" 'mail send' 1 "exactly one mail after cycle 2"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_5" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 1 "still exactly one mail after a third identical cycle — no duplicate"

# ===========================================================================
# CASE 6 — A normal (non-stuck) frame never mails, and clears prior tracked
#   state: a stall that later recurs needs two FRESH consecutive sightings
#   again rather than counting the pre-recovery sighting.
# ===========================================================================
start_case "6: a normal frame never mails and resets prior tracked state"
setup_case_env "6"
SESSIONS_6="$(write_sessions "$(session_json rc-6 'foundry-kc/gc.implementation-worker-6' 'foundry-kc/gc.implementation-worker' 'gc__implementation-worker-rc-6' 'foundry-kc')")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_6" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_6" STUB_PEEK_OUTPUT="$NORMAL_TEXT"
assert_eq "0" "$RC" "script exits 0 on a normal frame"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail while the frame is normal"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_6" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_log_count "$GC_LOG" 'mail send' 0 "recurrence after recovery is treated as a fresh first sighting, not an immediate re-alert"

# ===========================================================================
# CASE 7 — Dedup key is (session, question), not session alone: after being
#   alerted on question A, the SAME session stalling on a DIFFERENT question
#   B must go through its own two-sighting gate before it alerts too.
# ===========================================================================
start_case "7: a different stuck question on the same session alerts independently"
setup_case_env "7"
SESSIONS_7="$(write_sessions "$(session_json rc-7 'foundry-kc/gc.implementation-worker-7' 'foundry-kc/gc.implementation-worker' 'gc__implementation-worker-rc-7' 'foundry-kc')")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_7" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_7" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_log_count "$GC_LOG" 'mail send' 1 "question A alerts once after its second sighting"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_7" STUB_PEEK_OUTPUT="$STUCK_TEXT_B"
assert_log_count "$GC_LOG" 'mail send' 1 "question B's first sighting alone does not add a second mail"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_7" STUB_PEEK_OUTPUT="$STUCK_TEXT_B"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 2 "question B's second consecutive sighting sends its own, independent mail"
assert_log_count "$GC_LOG" '.none known.' 2 "with no bd fixture configured, both alerts' bead field falls back to a safe placeholder rather than failing"

# ===========================================================================
# CASE 8 — A failed/timed-out `gc session list` must never be treated as a
#   genuinely idle city: the watchdog logs a WARNING and exits non-zero (so
#   the order controller retries next cooldown, per this script's own
#   documented exit-code contract) instead of silently completing as if
#   zero sessions were found.
# ===========================================================================
start_case "8: a failed session list is a WARNING + non-zero exit, not a false all-clear"
setup_case_env "8"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_FAIL=1
assert_eq "1" "$RC" "script exits non-zero so the order controller retries next cycle"
assert_log_count "$GC_LOG" 'session peek|mail send' 0 "no downstream peek/mail calls are attempted when discovery itself failed"
if printf '%s' "$OUT" | grep -q 'WARNING: session list unavailable'; then
  pass "logs a WARNING distinguishing this from a genuinely idle city"
else
  fail "expected a WARNING that session list itself failed"
fi
if printf '%s' "$OUT" | grep -q 'no active sessions found'; then
  fail "must not print the same message a genuinely idle city would print"
else
  pass "does not print the idle-city message on a real discovery failure"
fi

# ===========================================================================
# CASE 9 — A failed/timed-out `gc session peek` for one session must not be
#   classified "not stuck": the watchdog logs a WARNING and leaves that
#   session's tracked state untouched, so a real stall whose peek keeps
#   failing is never cleared and rendered invisible. Once peek recovers,
#   the preserved first sighting still counts toward the two-consecutive-
#   sightings gate.
# ===========================================================================
start_case "9: a failed peek logs a WARNING and does not clear tracked state"
setup_case_env "9"
SESSIONS_9="$(write_sessions "$(session_json rc-9 'foundry-kc/gc.implementation-worker-9' 'foundry-kc/gc.implementation-worker' 'gc__implementation-worker-rc-9' 'foundry-kc')")"
STATE_9="$(askq_state_path rc-9)"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_9" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
if [ -f "$STATE_9" ]; then pass "first sighting recorded tracked state"; else fail "expected tracked state to exist after the first sighting"; fi
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_9" STUB_PEEK_FAIL=1
assert_eq "0" "$RC" "script exits 0 overall (one session's peek failure is not fatal to the whole cycle)"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail fires off a failed peek"
if printf '%s' "$OUT" | grep -q 'WARNING: session peek rc-9 unavailable'; then
  pass "logs a WARNING naming the session whose peek failed"
else
  fail "expected a WARNING for the failed peek"
fi
if [ -f "$STATE_9" ]; then
  pass "tracked state from the first sighting is preserved (not cleared) when the next peek merely fails"
else
  fail "the failed peek incorrectly cleared this session's tracked state"
fi
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_9" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 1 "the preserved first sighting plus this real second sighting of the same frame still alerts once, despite the failed peek in between"

# ===========================================================================
# CASE 10 — Mail-delivery-failure retry path: a mail send failure on the
#   second consecutive sighting must NOT mark this (session, frame) alerted
#   — otherwise a transient mail outage would permanently suppress the
#   alert for a stall nobody was ever actually told about. Mirrors
#   con-voyage-repair-watchdog.test.sh CASE 13's shape.
# ===========================================================================
start_case "10: a failed alert mail is retried next cycle (no false alerted=1)"
setup_case_env "10"
SESSIONS_10="$(write_sessions "$(session_json rc-10 'foundry-kc/gc.implementation-worker-10' 'foundry-kc/gc.implementation-worker' 'gc__implementation-worker-rc-10' 'foundry-kc')")"
STATE_10="$(askq_state_path rc-10)"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_10" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_10" STUB_PEEK_OUTPUT="$STUCK_TEXT_A" STUB_MAIL_SEND_FAIL=1
assert_eq "0" "$RC" "script exits 0 (a failed alert mail is non-fatal to the whole run)"
assert_log_count "$GC_LOG" 'mail send' 1 "the alert mail was attempted on the second sighting"
assert_eq "0" "$(grep -o 'alerted=.*' "$STATE_10" 2>/dev/null | cut -d= -f2)" "alerted stays 0 when the alert mail itself failed to send"
if printf '%s' "$OUT" | grep -q 'WARNING'; then
  pass "logs a WARNING for the failed alert mail"
else
  fail "expected a WARNING for the failed alert mail"
fi
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON="$SESSIONS_10" STUB_PEEK_OUTPUT="$STUCK_TEXT_A"
assert_eq "0" "$RC" "script exits 0 on the retry cycle"
assert_log_count "$GC_LOG" 'mail send' 2 "the retry cycle attempts the alert mail again (now succeeding)"
assert_eq "1" "$(grep -o 'alerted=.*' "$STATE_10" 2>/dev/null | cut -d= -f2)" "alerted flips to 1 once the retried mail actually succeeds"

# ===========================================================================
# CASE 11 — Robustness: a malformed CV_ASKQ_PEEK_LINES override must never
#   crash the script or silently disable the peek-lines bound — coerced to
#   its documented default (50), same fail-safe posture as every other
#   malformed-field guard in this pack (con-voyage-repair-watchdog.sh's
#   CV_STALL_SECONDS/CV_MAX_ATTEMPTS, covered by
#   con-voyage-review-watchdog.test.sh CASE 14).
# ===========================================================================
start_case "11: a non-numeric CV_ASKQ_PEEK_LINES is coerced to its default, not fatal"
setup_case_env "11"
run_script CV_ASKQ_MAIL_TARGET="mayor" CV_ASKQ_PEEK_LINES="not-a-number" CV_ASKQ_STORE_TIMEOUT_SECONDS="5" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0 (a malformed CV_ASKQ_PEEK_LINES does not crash the run)"
if printf '%s' "$OUT" | grep -q 'peek_lines=50'; then
  pass "the startup banner shows the coerced default (50) took effect downstream"
else
  fail "expected the startup banner to show peek_lines=50 after coercion"
fi

# ===========================================================================
# CASE 12 — Same guard, empty-string form of the override (the case
#   statement's other branch: `*[!0-9]*|''`).
# ===========================================================================
start_case "12: an empty CV_ASKQ_PEEK_LINES is also coerced to its default"
setup_case_env "12"
run_script CV_ASKQ_MAIL_TARGET="mayor" CV_ASKQ_PEEK_LINES="" CV_ASKQ_STORE_TIMEOUT_SECONDS="5" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0 (an empty CV_ASKQ_PEEK_LINES does not crash the run)"
if printf '%s' "$OUT" | grep -q 'peek_lines=50'; then
  pass "an empty override also coerces to the default (50)"
else
  fail "expected an empty CV_ASKQ_PEEK_LINES to coerce to peek_lines=50"
fi

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
