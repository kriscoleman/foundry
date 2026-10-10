#!/usr/bin/env bash
# con-voyage-marshal-agent-sweep.test.sh — hermetic test for con-voyage-
# marshal-agent-sweep.sh (fk-d0ioj2): city-wide, unconditional
# implementation/review agent liveness check (quiet session, no prompt
# visible), gated by the marshal assistant flag, distinct from
# con-voyage-askuserquestion-watchdog.
#
# Run:  bash tests/con-voyage-marshal-agent-sweep.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-marshal-agent-sweep.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}
assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (not found in output)"; fi
}
assert_not_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3 (unexpectedly found in output)"; else pass "$3"; fi
}

start_case "con-voyage-marshal-agent-sweep.sh is committed executable"
mode="$(git -C "$MOLD_DIR" ls-files -s -- "pack/assets/scripts/con-voyage-marshal-agent-sweep.sh" | awk '{print $1}')"
assert_eq "100755" "$mode" "git-tracked file mode is 100755"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-marshal-agent-sweep-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
RIG_ROOT="${SANDBOX}/rig"
mkdir -p "$STUBDIR" "$RIG_ROOT/.gc"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }

cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG:-/dev/null}"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }

args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"
case "$sub" in
  session)
    sessub="${args[$((i+1))]:-}"
    case "$sessub" in
      list)
        printf '%s' "${STUB_SESSIONS_JSON:-{\"sessions\":[]\}}"
        ;;
      peek)
        sid="${args[$((i+2))]:-}"
        var="STUB_PEEK_$(sanitize "$sid")"
        printf '%s' "${!var:-}"
        ;;
      *) exit 0 ;;
    esac
    ;;
  mail)
    mailsub="${args[$((i+1))]:-}"
    case "$mailsub" in
      send)
        [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ] && exit 1
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
GC_STUB
chmod +x "${STUBDIR}/gc"

cat > "${RIG_ROOT}/.gc/con-voyage-assistants.toml" <<'TOML'
[con_voyage.assistants]
marshal = true
TOML

run_script() {
  local log="${SANDBOX}/gc.log"
  rm -f "$log"
  local stdout_out
  stdout_out="$( (
    export PATH="${STUBDIR}:${PATH}"
    export STUB_GC_LOG="$log"
    export GC_RIG_ROOT="$RIG_ROOT"
    export CV_STATE_DIR="${SANDBOX}/state"
    export CV_MARSHAL_AGENT_STALL_MINUTES=30
    export CV_LENS_STORE_TIMEOUT_SECONDS=5
    bash "$SCRIPT"
  ) 2>&1 )"
  LAST_RC=$?
  LAST_LOG="$(cat "$log" 2>/dev/null || true)
${stdout_out}"
}

old_ts() { date -u -v-"${1}M" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${1} minutes" +%Y-%m-%dT%H:%M:%SZ; }
recent_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
start_case "disabled by default (marshal flag false): no gc calls at all"
rm -f "${RIG_ROOT}/.gc/con-voyage-assistants.toml"
rm -f "${SANDBOX}/gc.log"
out="$( (
  export PATH="${STUBDIR}:${PATH}"
  export STUB_GC_LOG="${SANDBOX}/gc.log"
  export GC_RIG_ROOT="$RIG_ROOT"
  export CV_STATE_DIR="${SANDBOX}/state-disabled"
  bash "$SCRIPT"
) 2>&1 )"
rc=$?
assert_eq "0" "$rc" "exits 0 when disabled"
assert_contains "$out" "disabled" "reports disabled in output"
assert_eq "" "$(cat "${SANDBOX}/gc.log" 2>/dev/null || true)" "no gc calls made while disabled"

cat > "${RIG_ROOT}/.gc/con-voyage-assistants.toml" <<'TOML'
[con_voyage.assistants]
marshal = true
TOML

# ---------------------------------------------------------------------------
start_case "mayor and non-implementation/review templates are excluded"
export STUB_SESSIONS_JSON='{"sessions":[
  {"id":"rc-mayor1","template":"foundry-kc/mayor","last_active":"'"$(old_ts 60)"'"},
  {"id":"rc-other1","template":"foundry-kc/gc.publisher","last_active":"'"$(old_ts 60)"'"}
]}'
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_not_contains "$LAST_LOG" "session peek" "never peeks a mayor/non-matching session"
assert_not_contains "$LAST_LOG" "mail send" "no mail sent (no eligible candidates)"
unset STUB_SESSIONS_JSON

# ---------------------------------------------------------------------------
start_case "QUIET AGENT: an implementation session quiet past threshold, no prompt visible, is flagged once"
export STUB_SESSIONS_JSON='{"sessions":[{"id":"rc-impl1","template":"foundry-kc/gc.implementation-worker","last_active":"'"$(old_ts 45)"'"}]}'
export STUB_PEEK_rc_impl1="some normal ongoing output, nothing special"
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent for the quiet agent"

start_case "QUIET AGENT: the same quiet episode is not re-flagged on the next tick"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_not_contains "$LAST_LOG" "mail send" "no repeat mail for the same unresolved quiet episode"
unset STUB_SESSIONS_JSON STUB_PEEK_rc_impl1

# ---------------------------------------------------------------------------
# fk-i1yas2 BLOCKING-2: the full recover -> re-flag cycle, not just the first
# flag and the same-episode dedup, is the entire design rationale for this
# order's per-session flag file (see header comment) — exercise all three
# ticks so a regression that leaves a stale flagged_for file after recovery
# (silently suppressing every future alert for that session) fails CI.
start_case "QUIET AGENT full cycle: flagged -> recovered -> quiet again -> flagged a second time"
rm -rf "${SANDBOX}/state"

export STUB_SESSIONS_JSON='{"sessions":[{"id":"rc-cycle1","template":"foundry-kc/gc.implementation-worker","last_active":"'"$(old_ts 45)"'"}]}'
export STUB_PEEK_rc_cycle1="working normally"
run_script
assert_eq "0" "$LAST_RC" "tick 1 exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "tick 1: first quiet episode is flagged"

export STUB_SESSIONS_JSON='{"sessions":[{"id":"rc-cycle1","template":"foundry-kc/gc.implementation-worker","last_active":"'"$(recent_ts)"'"}]}'
run_script
assert_eq "0" "$LAST_RC" "tick 2 exits 0"
assert_not_contains "$LAST_LOG" "mail send" "tick 2: recovery (recent last_active) clears the flag, sends no mail"

export STUB_SESSIONS_JSON='{"sessions":[{"id":"rc-cycle1","template":"foundry-kc/gc.implementation-worker","last_active":"'"$(old_ts 50)"'"}]}'
run_script
assert_eq "0" "$LAST_RC" "tick 3 exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "tick 3: a second, distinct quiet episode is flagged again after recovery"
unset STUB_SESSIONS_JSON STUB_PEEK_rc_cycle1

# ---------------------------------------------------------------------------
# fk-i1yas2 BLOCKING-4: a failed digest-mail send must not retire the flag
# file for the quiet episode it was reporting, or the next tick sees
# last_active unchanged and silently drops the signal forever.
start_case "a failed digest mail does not retire the quiet-agent flag"
rm -rf "${SANDBOX}/state"
export STUB_SESSIONS_JSON='{"sessions":[{"id":"rc-failmail1","template":"foundry-kc/gc.implementation-worker","last_active":"'"$(old_ts 45)"'"}]}'
export STUB_PEEK_rc_failmail1="working normally"
export STUB_MAIL_SEND_FAIL=1
run_script
assert_eq "0" "$LAST_RC" "tick 1 (mail fails) still exits 0"
unset STUB_MAIL_SEND_FAIL

run_script
assert_contains "$LAST_LOG" "mail send mayor" "tick 2: the still-unreported quiet episode is re-flagged after the earlier mail failure"
unset STUB_SESSIONS_JSON STUB_PEEK_rc_failmail1

# ---------------------------------------------------------------------------
start_case "a recently-active review session is not flagged"
export STUB_SESSIONS_JSON='{"sessions":[{"id":"rc-rev1","template":"vandoor/con-voyage.cv-security-reviewer","last_active":"'"$(recent_ts)"'"}]}'
export STUB_PEEK_rc_rev1="working normally"
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_not_contains "$LAST_LOG" "mail send" "no mail sent for a recently-active session"
unset STUB_SESSIONS_JSON STUB_PEEK_rc_rev1

# ---------------------------------------------------------------------------
start_case "a prompt-stalled session is excluded (askq-watchdog's job, not ours)"
export STUB_SESSIONS_JSON='{"sessions":[{"id":"rc-impl2","template":"foundry-kc/gc.implementation-worker","last_active":"'"$(old_ts 45)"'"}]}'
export STUB_PEEK_rc_impl2=$'1. Option A\n2. Option B\n↑/↓ to navigate · Enter to select · Esc to close'
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "prompt-stalled" "the prompt-stalled session is recognized and skipped"
assert_not_contains "$LAST_LOG" "mail send" "no quiet-agent mail sent for a prompt-stalled session"
unset STUB_SESSIONS_JSON STUB_PEEK_rc_impl2

# ---------------------------------------------------------------------------
# fk-9oigyg review LOW-1: a session id containing a path separator must never
# let the per-session flag file resolve outside CV_STATE_DIR.
start_case "LOW-1: a session id containing a path separator never escapes CV_STATE_DIR"
export STUB_SESSIONS_JSON='{"sessions":[{"id":"rc-evil/../../escape","template":"foundry-kc/gc.implementation-worker","last_active":"'"$(old_ts 45)"'"}]}'
export STUB_PEEK_rc_evil_______escape="working normally"
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent for the malicious-id quiet episode"
[ -e "${SANDBOX}/escape" ] \
  && fail "a flag file escaped CV_STATE_DIR via the path-separator session id" \
  || pass "no file was written outside CV_STATE_DIR"
state_file_count="$(find "${SANDBOX}/state" -type f | grep -c .)"
assert_eq "1" "$state_file_count" "exactly one sanitized flag file was written, inside CV_STATE_DIR"
unset STUB_SESSIONS_JSON STUB_PEEK_rc_evil_______escape

# ---------------------------------------------------------------------------
# fk-9oigyg review LOW-2: a bounded, age-based prune keeps CV_STATE_DIR from
# growing unbounded as sessions disappear.
start_case "LOW-2: an ancient flag file is pruned from CV_STATE_DIR on the next tick"
rm -rf "${SANDBOX}/state"
mkdir -p "${SANDBOX}/state"
touch -t 202001010000 "${SANDBOX}/state/rc-long-gone.flagged_for"
export STUB_SESSIONS_JSON='{"sessions":[]}'
run_script
assert_eq "0" "$LAST_RC" "exits 0"
[ -f "${SANDBOX}/state/rc-long-gone.flagged_for" ] \
  && fail "an ancient flag file for a long-gone session was not pruned" \
  || pass "the ancient flag file was pruned"
unset STUB_SESSIONS_JSON

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
