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
      if [ -n "${STUB_SESSION_LIST_JSON:-}" ]; then
        printf '%s' "$STUB_SESSION_LIST_JSON"
      else
        printf '{"sessions":[]}'
      fi
      exit 0
    fi
    if [ "$sessub" = "peek" ]; then
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
