#!/usr/bin/env bash
# con-voyage-rate-limit-lookout.test.sh — hermetic, offline test for the
# pack's claude-fleet rate-limit circuit breaker + proactive
# context-compaction handoff monitor.
#
# WHY THIS MONITOR EXISTS: claude-backed workers (mayor, do-work pools,
# implementation workers) can silently stall when Claude Code hits a
# usage/rate limit ("Claude usage limit reached…"), and they lose in-flight
# context when an auto-compact lands at a bad moment. The lookout peeks every
# active claude session on a cooldown, and:
#   - context compact approaching  -> `gc handoff --target` (smooth restart
#     with handoff mail waiting),
#   - usage/rate limit observed    -> circuit breaker OPENS: handoff across
#     the claude fleet + structured escalation mail to the mayor so it can
#     switch dispatch to the all-opencode fallback pools,
#   - limits clear for a full reset window -> breaker CLOSES with an
#     all-clear mail.
#
# HOW IT WORKS (no network, no real gc): a recording STUB `gc` serves canned
# `session list --json` and per-session `session peek` output from files, and
# records every invocation (handoff/mail) to STUB_GC_LOG for assertions. The
# script's own breaker/session state lives under CV_LOOKOUT_STATE_DIR inside
# the sandbox, so multi-invocation scenarios (throttles, reset windows)
# genuinely persist state between runs.
#
# Run:  bash tests/con-voyage-rate-limit-lookout.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-rate-limit-lookout.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-lookout-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
CITY="${SANDBOX}/city"
PEEKDIR="${SANDBOX}/peeks"
SESSIONS_JSON="${SANDBOX}/sessions.json"
export STUB_GC_LOG="${SANDBOX}/gc.log"
mkdir -p "$STUBDIR" "$CITY" "$PEEKDIR"
: > "$STUB_GC_LOG"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv, serves canned session list/peek output, and
# no-ops handoff/mail (unless STUB_HANDOFF_FAIL=1).
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
    ssub="${args[$((i+1))]:-}"
    if [ "$ssub" = "list" ]; then
      cat "${STUB_SESSIONS_FILE}" 2>/dev/null || printf '{"sessions":[]}'
      exit 0
    fi
    if [ "$ssub" = "peek" ]; then
      sid="${args[$((i+2))]:-}"
      cat "${STUB_PEEK_DIR}/${sid}.txt" 2>/dev/null || printf ''
      exit 0
    fi
    ;;
  handoff)
    if [ "${STUB_HANDOFF_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
  mail)
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

assert_log_contains() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$STUB_GC_LOG"; then
    pass "$label"
  else
    fail "$label (gc log missing: $needle)"
  fi
}

assert_log_lacks() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$STUB_GC_LOG"; then
    fail "$label (gc log unexpectedly contains: $needle)"
  else
    pass "$label"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" label="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label (${file} missing or lacks: $needle)"
  fi
}

# write_sessions JSON — replace the canned `session list --json` payload.
write_sessions() { printf '%s' "$1" > "$SESSIONS_JSON"; }

# write_peek SESSION_ID — canned `session peek` text follows on stdin.
write_peek() { cat > "${PEEKDIR}/$1.txt"; }

STATE_DIR="${CITY}/.gc/con-voyage/lookout"

# reset_world — clear gc log, peeks, sessions, and ALL lookout state.
reset_world() {
  : > "$STUB_GC_LOG"
  rm -f "${PEEKDIR}"/*.txt 2>/dev/null || true
  rm -rf "$STATE_DIR"
  write_sessions '{"sessions":[]}'
  unset STUB_HANDOFF_FAIL
}

# run_lookout [EXTRA_ENV ...] — invoke the script under test.
run_lookout() {
  env \
    GC="${STUBDIR}/gc" \
    GC_CITY="$CITY" \
    STUB_GC_LOG="$STUB_GC_LOG" \
    STUB_SESSIONS_FILE="$SESSIONS_JSON" \
    STUB_PEEK_DIR="$PEEKDIR" \
    ${STUB_HANDOFF_FAIL:+STUB_HANDOFF_FAIL="$STUB_HANDOFF_FAIL"} \
    "$@" \
    bash "$SCRIPT"
}

TWO_CLAUDE_SESSIONS='{"sessions":[
  {"id":"rc-wrk1","template":"knuckles/gc.implementation-worker","provider":"sonnet","state":"active","closed":false},
  {"id":"rc-inv","template":"mayor","provider":"opus","state":"active","closed":false}
]}'

# ===========================================================================
start_case "no sessions at all -> clean no-op exit"
# ===========================================================================
reset_world
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff" "no handoff issued"
assert_log_lacks "mail" "no mail sent"

# ===========================================================================
start_case "healthy claude sessions -> no handoff, no mail, breaker stays closed"
# ===========================================================================
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
⏺ Reading src/main.go…
  ⎿  ✓ tests pass
EOF
write_peek rc-inv <<'EOF'
⏺ Dispatching review lanes for bead kn-1234
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff" "no handoff issued for healthy sessions"
assert_log_lacks "mail send" "no escalation mail for healthy sessions"
assert_file_contains "${STATE_DIR}/breaker.state" "state=closed" "breaker state recorded closed"

# ===========================================================================
start_case "context-compact risk -> proactive handoff; cooldown suppresses immediate repeat"
# ===========================================================================
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
⏺ Applying review findings (4/9)
Context left until auto-compact: 9%
EOF
write_peek rc-inv <<'EOF'
⏺ Waiting on lens results
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "first run exit 0" || fail "first run exit $rc (output: $out)"
assert_log_contains "handoff --target rc-wrk1" "compact-risk session handed off"
assert_log_lacks "handoff --target rc-inv" "healthy mayor not handed off"
assert_log_lacks "mail send" "compact handoff does not spam the mayor"
: > "$STUB_GC_LOG"
out="$(run_lookout 2>&1)"; rc=$?
assert_log_lacks "handoff" "second run within cooldown does not re-handoff"

# ===========================================================================
start_case "usage limit observed -> breaker OPENS: mayor escalation + fleet handoff"
# ===========================================================================
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
⏺ Working on the fix…
✗ Claude usage limit reached. Your limit will reset at 6pm
EOF
write_peek rc-inv <<'EOF'
⏺ Coordinating
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 (order retries are for fatal errors only)" || fail "exit code $rc (output: $out)"
assert_log_contains "mail send mayor" "escalation mailed to the mayor"
assert_log_contains "all-opencode" "escalation names the all-opencode fallback mode"
assert_log_contains "kimi-k3" "escalation names the large (opus-class) fallback pool"
assert_log_contains "glm-5p3-flash" "escalation names the medium (sonnet-class) fallback pool"
assert_log_contains "minimax-m3" "escalation names the small (haiku-class) fallback pool"
assert_log_contains "handoff --target rc-wrk1" "limited session handed off"
assert_log_contains "handoff --target rc-inv" "breaker flip hands off across claude workers (mayor too)"
assert_file_contains "${STATE_DIR}/breaker.state" "state=open" "breaker state recorded open"

# ===========================================================================
start_case "breaker open + still limited -> no duplicate escalation inside remind window"
# ===========================================================================
# State persists from the previous case (same sandbox): rerun with the limit
# still showing and assert no second mail is sent.
: > "$STUB_GC_LOG"
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "mail send mayor" "no duplicate mayor mail inside remind window"

# ===========================================================================
start_case "breaker open + limits cleared past reset window -> all-clear + breaker CLOSES"
# ===========================================================================
write_peek rc-wrk1 <<'EOF'
⏺ Back to work after reset
EOF
# Age the breaker's last_limit_seen_at beyond the reset window by rewriting
# state directly (documented key=value format).
printf 'state=open\nopened_at=1000\nlast_limit_seen_at=1000\nlast_escalated_at=1000\n' > "${STATE_DIR}/breaker.state"
: > "$STUB_GC_LOG"
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_contains "mail send mayor" "all-clear mailed to the mayor"
assert_file_contains "${STATE_DIR}/breaker.state" "state=closed" "breaker closed after clear window"

# ===========================================================================
start_case "opencode-backed sessions are ignored even when peek text mentions limits"
# ===========================================================================
reset_world
write_sessions '{"sessions":[
  {"id":"rc-oc1","template":"knuckles/cv-review-intensive","provider":"cv-review-intensive","state":"active","closed":false},
  {"id":"rc-oc2","template":"knuckles/minimax-m3","provider":"minimax-m3","state":"active","closed":false}
]}'
write_peek rc-oc1 <<'EOF'
⏺ Reviewing the diff — note the code handles a usage limit reached branch here
EOF
write_peek rc-oc2 <<'EOF'
⏺ Summarizing findings
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff" "no handoff for opencode sessions"
assert_log_lacks "mail send" "no escalation for opencode sessions"

# ===========================================================================
start_case "closed sessions are skipped"
# ===========================================================================
reset_world
write_sessions '{"sessions":[
  {"id":"rc-dead","template":"knuckles/gc.implementation-worker","provider":"sonnet","state":"closed","closed":true}
]}'
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff" "closed sessions never handed off"

# ===========================================================================
start_case "malformed numeric env knobs coerce to defaults instead of breaking"
# ===========================================================================
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
Context left until auto-compact: 9%
EOF
write_peek rc-inv <<'EOF'
⏺ ok
EOF
out="$(run_lookout CV_LOOKOUT_COMPACT_HANDOFF_PERCENT=abc CV_LOOKOUT_BREAKER_RESET_SECONDS= CV_LOOKOUT_PEEK_LINES=-4 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 with garbage env" || fail "exit code $rc (output: $out)"
assert_log_contains "handoff --target rc-wrk1" "compact handoff still works with coerced defaults"

# ===========================================================================
start_case "usage.jsonl window summary rides along in the escalation mail"
# ===========================================================================
reset_world
mkdir -p "${CITY}/.gc"
now_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
cat > "${CITY}/.gc/usage.jsonl" <<EOF
{"run_id":"rc-wrk1","session_id":"rc-wrk1","worker":"bd__x","kind":"model","model":"claude-sonnet-5","provider":"claude","input_tokens":10,"output_tokens":20,"cache_read_tokens":30,"cache_creation_tokens":40,"at":${now_ms}}
{"run_id":"rc-inv","session_id":"rc-inv","worker":"mayor","kind":"model","model":"claude-opus-4-8","provider":"claude","input_tokens":1,"output_tokens":2,"cache_read_tokens":3,"cache_creation_tokens":4,"at":${now_ms}}
EOF
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 6pm
EOF
write_peek rc-inv <<'EOF'
⏺ ok
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_contains "mail send mayor" "escalation mailed"
# The mail body is a single argv entry; token totals must appear in the log line.
assert_log_contains "tokens" "escalation includes a usage summary"

# ===========================================================================
start_case "handoff failure trips warn-and-continue (fail-safe, still escalates)"
# ===========================================================================
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 6pm
EOF
write_peek rc-inv <<'EOF'
⏺ ok
EOF
STUB_HANDOFF_FAIL=1
out="$(run_lookout 2>&1)"; rc=$?
unset STUB_HANDOFF_FAIL
[ "$rc" -eq 0 ] && pass "exit 0 despite handoff failures" || fail "exit code $rc (output: $out)"
assert_log_contains "mail send mayor" "mayor still escalated when a handoff fails"

# ===========================================================================
start_case "fatal preflight: gc missing -> non-zero"
# ===========================================================================
out="$(GC="${SANDBOX}/no-such-gc" GC_CITY="$CITY" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "non-zero exit when gc is missing" || fail "expected non-zero, got 0"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
