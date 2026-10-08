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
#   - usage/rate limit observed    -> circuit breaker OPENS: breaker.state is
#     written and the mayor is mailed FIRST (before any handoff), a session
#     showing Claude Code's own auto-continue banner is left alone (it will
#     resume on its own), and — opt-in, CV_LOOKOUT_AUTO_FLIP=true — the
#     lookout applies an all-opencode override to city.toml itself and
#     reloads, because during a claude-wide limit the mayor may be unable to
#     act on a mail-only escalation,
#   - limits clear -> breaker CLOSES (reset-window based when not flipped;
#     reset-time + live-probe + dwell based when flipped, specifically so a
#     momentary zero-claude-sessions reading right after a flip can't
#     immediately flip back and oscillate).
#
# HOW IT WORKS (no network, no real gc, no real claude): a recording STUB
# `gc` serves canned `session list --json`, per-session `session peek`,
# `config explain --agent mayor`, and `reload` output/exit codes from files,
# and records every invocation to STUB_GC_LOG for assertions. A stub `claude`
# probe script similarly serves a controllable exit code. The script's own
# breaker/session state and any city.toml it edits live under the sandbox, so
# multi-invocation scenarios (throttles, reset windows, crash-resume) genuinely
# persist state between runs.
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
# The `gc` stub. Records argv, serves canned session list/peek/config/reload
# output, and no-ops handoff/mail (unless a STUB_*_FAIL flag is set).
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

if [ "${STUB_PEEK_DELAY_SECONDS:-0}" != "0" ]; then
  args_str=" $* "
  case "$args_str" in *" peek "*) sleep "${STUB_PEEK_DELAY_SECONDS}" ;; esac
fi
if [ "${STUB_HANDOFF_DELAY_SECONDS:-0}" != "0" ]; then
  args_str=" $* "
  case "$args_str" in *" handoff "*) sleep "${STUB_HANDOFF_DELAY_SECONDS}" ;; esac
fi

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
  rig)
    rsub="${args[$((i+1))]:-}"
    if [ "$rsub" = "list" ]; then
      if [ "${STUB_NO_RIGS:-0}" = "1" ]; then
        printf '{"rigs":[]}'
      else
        printf '{"rigs":[{"name":"%s"}]}' "${STUB_RIG_NAME:-example-rig}"
      fi
      exit 0
    fi
    ;;
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
    if [ "$ssub" = "new" ]; then
      if [ "${STUB_SESSION_NEW_FAIL:-0}" = "1" ]; then
        exit 1
      fi
      exit 0
    fi
    if [ "$ssub" = "close" ]; then
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
    if [ "${STUB_MAIL_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
  reload)
    if [ "${STUB_RELOAD_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
  config)
    csub="${args[$((i+1))]:-}"
    if [ "$csub" = "explain" ]; then
      if [ "${STUB_EXPLAIN_STALE:-0}" = "1" ]; then
        printf 'provider = "sonnet"\n'
      else
        printf 'provider = "%s"\n' "${STUB_EXPECT_LARGE_POOL:-kimi-k3}"
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
# The `claude` probe stub — a one-shot, controllable "is claude reachable".
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/claude-probe" <<'PROBE_STUB'
#!/usr/bin/env bash
printf 'probed\n' >> "${STUB_PROBE_LOG:-/dev/null}"
if [ "${STUB_PROBE_FAIL:-0}" = "1" ]; then
  exit 1
fi
exit 0
PROBE_STUB
chmod +x "${STUBDIR}/claude-probe"

# ---------------------------------------------------------------------------
# The `opencode-probe` stub — a one-shot, controllable "can the opencode
# fallback pool actually spawn a session" pre-flip guard (gascity#5436).
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/opencode-probe" <<'OPENCODE_PROBE_STUB'
#!/usr/bin/env bash
printf 'probed\n' >> "${STUB_OPENCODE_PROBE_LOG:-/dev/null}"
if [ "${STUB_OPENCODE_PROBE_FAIL:-0}" = "1" ]; then
  exit 1
fi
exit 0
OPENCODE_PROBE_STUB
chmod +x "${STUBDIR}/opencode-probe"

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

assert_file_lacks() {
  local file="$1" needle="$2" label="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then
    fail "$label (${file} unexpectedly contains: $needle)"
  else
    pass "$label"
  fi
}

# assert_log_order NEEDLE_A NEEDLE_B LABEL — first line matching A occurs
# strictly before the first line matching B in STUB_GC_LOG.
assert_log_order() {
  local a="$1" b="$2" label="$3" line_a line_b
  line_a="$(grep -nF -- "$a" "$STUB_GC_LOG" | head -1 | cut -d: -f1)"
  line_b="$(grep -nF -- "$b" "$STUB_GC_LOG" | head -1 | cut -d: -f1)"
  if [ -z "$line_a" ] || [ -z "$line_b" ]; then
    fail "$label (could not find both '$a' and '$b' in gc log)"
  elif [ "$line_a" -lt "$line_b" ]; then
    pass "$label"
  else
    fail "$label (found '$a' at line $line_a, '$b' at line $line_b — wrong order)"
  fi
}

# write_sessions JSON — replace the canned `session list --json` payload.
write_sessions() { printf '%s' "$1" > "$SESSIONS_JSON"; }

# write_peek SESSION_ID — canned `session peek` text follows on stdin.
write_peek() { cat > "${PEEKDIR}/$1.txt"; }

STATE_DIR="${CITY}/.gc/con-voyage/lookout"
CITY_TOML="${CITY}/city.toml"

# write_city_toml — a minimal but realistic city.toml fixture, matching the
# shape the override editor has to handle: an existing [agent_defaults] with
# a provider line, and an existing [[patches.agent]] name="mayor" block with
# its own provider line, plus unrelated content before/after that must
# survive untouched.
write_city_toml() {
  cat > "$CITY_TOML" <<'EOF'
# city.toml — test fixture
[[rigs]]
name = "example-rig"
default_branch = "main"

[[patches.agent]]
dir = ""
name = "mayor"
# some operator comment that must survive
provider = "claude"
append_fragments = ["con-voyage-orchestration"]

[agent_defaults]
provider = "sonnet"
append_fragments = ["city-standards"]

[daemon]
session_circuit_breaker = true
EOF
}

# reset_world — clear gc log, peeks, sessions, city.toml, and ALL lookout
# state.
reset_world() {
  : > "$STUB_GC_LOG"
  rm -f "${PEEKDIR}"/*.txt 2>/dev/null || true
  rm -rf "$STATE_DIR"
  rm -f "$CITY_TOML" "${CITY_TOML}".bak.* 2>/dev/null || true
  write_sessions '{"sessions":[]}'
  unset STUB_HANDOFF_FAIL STUB_MAIL_FAIL STUB_RELOAD_FAIL STUB_PROBE_FAIL STUB_EXPLAIN_STALE
  unset STUB_PEEK_DELAY_SECONDS STUB_HANDOFF_DELAY_SECONDS
  unset STUB_OPENCODE_PROBE_FAIL STUB_NO_RIGS STUB_RIG_NAME STUB_SESSION_NEW_FAIL
}

# run_lookout [EXTRA_ENV ...] — invoke the script under test. Defaults to a
# working opencode spawn-capability probe stub so pre-existing scenarios that
# expect a flip to succeed don't need to know about the gascity#5436 guard;
# tests of the guard itself override STUB_OPENCODE_PROBE_FAIL (or clear
# CV_LOOKOUT_OPENCODE_PROBE_CMD to exercise the built-in probe).
run_lookout() {
  env \
    GC="${STUBDIR}/gc" \
    GC_CITY="$CITY" \
    STUB_GC_LOG="$STUB_GC_LOG" \
    STUB_SESSIONS_FILE="$SESSIONS_JSON" \
    STUB_PEEK_DIR="$PEEKDIR" \
    CV_LOOKOUT_CLAUDE_PROBE_CMD="${STUBDIR}/claude-probe" \
    CV_LOOKOUT_OPENCODE_PROBE_CMD="${STUBDIR}/opencode-probe" \
    CV_LOOKOUT_CITY_TOML="$CITY_TOML" \
    ${STUB_HANDOFF_FAIL:+STUB_HANDOFF_FAIL="$STUB_HANDOFF_FAIL"} \
    ${STUB_MAIL_FAIL:+STUB_MAIL_FAIL="$STUB_MAIL_FAIL"} \
    ${STUB_RELOAD_FAIL:+STUB_RELOAD_FAIL="$STUB_RELOAD_FAIL"} \
    ${STUB_PROBE_FAIL:+STUB_PROBE_FAIL="$STUB_PROBE_FAIL"} \
    ${STUB_PROBE_LOG:+STUB_PROBE_LOG="$STUB_PROBE_LOG"} \
    ${STUB_OPENCODE_PROBE_FAIL:+STUB_OPENCODE_PROBE_FAIL="$STUB_OPENCODE_PROBE_FAIL"} \
    ${STUB_OPENCODE_PROBE_LOG:+STUB_OPENCODE_PROBE_LOG="$STUB_OPENCODE_PROBE_LOG"} \
    ${STUB_NO_RIGS:+STUB_NO_RIGS="$STUB_NO_RIGS"} \
    ${STUB_RIG_NAME:+STUB_RIG_NAME="$STUB_RIG_NAME"} \
    ${STUB_SESSION_NEW_FAIL:+STUB_SESSION_NEW_FAIL="$STUB_SESSION_NEW_FAIL"} \
    ${STUB_EXPLAIN_STALE:+STUB_EXPLAIN_STALE="$STUB_EXPLAIN_STALE"} \
    ${STUB_PEEK_DELAY_SECONDS:+STUB_PEEK_DELAY_SECONDS="$STUB_PEEK_DELAY_SECONDS"} \
    ${STUB_HANDOFF_DELAY_SECONDS:+STUB_HANDOFF_DELAY_SECONDS="$STUB_HANDOFF_DELAY_SECONDS"} \
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
assert_log_order "mail send mayor" "handoff --target rc-wrk1" "item 1: escalation mailed before any handoff"

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
printf 'state=open\nopened_at=1000\nlast_limit_seen_at=1000\nlast_escalated_at=1000\nflipped=0\nreload_verified=0\nreset_hint_epoch=0\nlast_probe_at=0\nnext_probe_at=0\n' > "${STATE_DIR}/breaker.state"
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
start_case "fk-xtbtcw: pane merely QUOTING a limit phrase does not false-open the breaker"
# ===========================================================================
# Regression for con-voyage-rate-limit-lookout opening the breaker on a
# session whose pane scrollback just quotes limit language (a lookout mail
# body, a skill excerpt) rather than showing Claude Code's own banner.
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
con-voyage rate-limit lookout: claude limit circuit breaker OPEN
The lookout observed a "rate limit reached" condition earlier today; see the
runbook section on what to do when a usage limit reached banner appears, and
note the fix for limit will reset parsing in fk-xtbtcw.
⏺ Back to normal work, applying review findings
EOF
write_peek rc-inv <<'EOF'
⏺ Coordinating as usual
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff --target rc-wrk1" "quoted limit text does not trigger a handoff"
assert_log_lacks "mail send mayor" "quoted limit text does not open the breaker / mail the mayor"
assert_file_contains "${STATE_DIR}/breaker.state" "state=closed" "breaker stays closed on quoted-only text"
assert_file_contains "${STATE_DIR}/breaker.state" "reset_hint_epoch=0" "no reset hint stored from quoted-only text"

# ===========================================================================
start_case "fk-xtbtcw: Claude Code's real banner still trips the breaker even with quoted text earlier in the pane"
# ===========================================================================
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
con-voyage rate-limit lookout: an earlier mail mentioned "rate limit reached"
in its subject line, purely for context, and is not itself a live banner.
⏺ Working on the fix…
✗ Claude usage limit reached. Your limit will reset at 6pm
EOF
write_peek rc-inv <<'EOF'
⏺ Coordinating
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_contains "mail send mayor" "real banner at the tail still escalates (no regression)"
assert_log_contains "handoff --target rc-wrk1" "real banner at the tail still hands off the limited session"
assert_file_contains "${STATE_DIR}/breaker.state" "state=open" "breaker opens on a real banner at the tail"

# ===========================================================================
start_case "fk-xtbtcw: transient 'API Error: 529 ... overloaded' retry does not open the breaker on its own"
# ===========================================================================
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
⏺ Applying review findings
API Error: 529 {"type":"overloaded_error","message":"Overloaded"} · Retrying…
⏺ Retry succeeded, continuing
EOF
write_peek rc-inv <<'EOF'
⏺ Coordinating
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff --target rc-wrk1" "529 overloaded retry alone does not trigger a handoff"
assert_log_lacks "mail send mayor" "529 overloaded retry alone does not open the breaker"
assert_file_contains "${STATE_DIR}/breaker.state" "state=closed" "breaker stays closed on a transient 529 retry"

# ===========================================================================
start_case "fk-xtbtcw: real banner scrolled past the tail window by subsequent output is still detected"
# ===========================================================================
# Review fk-xtbtcw BLOCKING-1: a hardcoded 12-line tail window let a real
# banner scroll out of view before the lookout's next scheduled peek if the
# session kept printing afterward (retry chatter, continued tool output).
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 6pm
noise1
noise2
noise3
noise4
noise5
noise6
noise7
noise8
noise9
noise10
noise11
noise12
EOF
write_peek rc-inv <<'EOF'
⏺ Coordinating
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "state=open" "breaker still opens once banner scrolls past the old 12-line tail window"

# ===========================================================================
start_case "fk-xtbtcw: real banner wrapped across two pane lines by terminal width is still detected"
# ===========================================================================
# Review fk-xtbtcw BLOCKING-2: tmux wraps long lines at the pane's column
# width, so the real banner's glyph and limit phrase can land on two
# physical lines. The old same-line-only match missed this.
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
⏺ Working on the fix…
✗ Claude usage limit
reached. Your limit will reset at 6pm
EOF
write_peek rc-inv <<'EOF'
⏺ Coordinating
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "state=open" "wrapped real banner still opens the breaker"

# ===========================================================================
start_case "fk-vaw6jx: unrelated glyph-prefixed bullets do not adopt incidental limit text a couple lines later"
# ===========================================================================
# Review fk-vaw6jx BLOCKING-1: the BLOCKING-2 wrap fix above joined ANY
# glyph-anchored line with the next BANNER_JOIN_LINES lines before searching
# for the limit phrase, with no check that the two actually belong to the
# same banner. This pack's own CI output uses the same glyph as a plain
# pass/fail bullet, so three ordinary test-failure bullets followed a couple
# lines later by an incidental "rate limit reached" mention (a runbook note,
# a quoted mail excerpt) got swept into the same join window and false-opened
# the breaker — exactly what the fk-xtbtcw fix above exists to prevent, just
# via a different glyph occurrence.
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ test_foo failed
✗ test_bar failed
✗ test_baz failed
Build summary: 3 failed, 10 passed
See the runbook note: a rate limit reached banner may appear during retries.
EOF
write_peek rc-inv <<'EOF'
⏺ Coordinating
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff --target rc-wrk1" "unrelated glyph bullets + incidental limit text do not trigger a handoff"
assert_log_lacks "mail send mayor" "unrelated glyph bullets + incidental limit text do not open the breaker"
assert_file_contains "${STATE_DIR}/breaker.state" "state=closed" "breaker stays closed when the limit phrase only appears via an unrelated glyph line's join window"

# ===========================================================================
start_case "fk-xtbtcw: a glyph line's own incidental tail plus an unrelated next line straddling the limit phrase does not false-open the breaker"
# ===========================================================================
# Review fk-xtbtcw BLOCKING-1 (iteration 3, qa-test lane): the iteration-2
# fix only required the matched phrase to START inside the glyph line's own
# text (m.start() < len(line)), not that the WHOLE phrase lives there. A
# glyph line whose own trailing text happens to begin a limit-phrase regex,
# followed by an unrelated next line that happens to complete it, still
# satisfies m.start() < len(line) even though this is not a real wrapped
# banner.
reset_world
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Flaky test retried; we briefly hit the rate
limit reached note is just in the log, nothing to see here, false alarm
EOF
write_peek rc-inv <<'EOF'
⏺ Coordinating
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff --target rc-wrk1" "straddled incidental limit phrase does not trigger a handoff"
assert_log_lacks "mail send mayor" "straddled incidental limit phrase does not open the breaker"
assert_file_contains "${STATE_DIR}/breaker.state" "state=closed" "breaker stays closed when the limit phrase only completes via an unrelated next line"

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
out="$(run_lookout CV_LOOKOUT_COMPACT_HANDOFF_PERCENT=abc CV_LOOKOUT_BREAKER_RESET_SECONDS= CV_LOOKOUT_PEEK_LINES=-4 CV_LOOKOUT_TIME_BUDGET_SECONDS=bogus CV_LOOKOUT_FLIP_DWELL_SECONDS=nope CV_LOOKOUT_BANNER_TAIL_LINES=bogus CV_LOOKOUT_BANNER_JOIN_LINES=-1 2>&1)"; rc=$?
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

# ===========================================================================
start_case "item 3 (default, no auto-flip): auto-continue banner session skipped, compaction-low session still handed off"
# ===========================================================================
reset_world
write_sessions '{"sessions":[
  {"id":"rc-autoresume","template":"knuckles/gc.implementation-worker","provider":"sonnet","state":"active","closed":false},
  {"id":"rc-compactlow","template":"knuckles/gc.implementation-worker","provider":"sonnet","state":"active","closed":false}
]}'
write_peek rc-autoresume <<'EOF'
✗ Claude usage limit reached · continuing automatically at 1pm (America/Detroit)
EOF
write_peek rc-compactlow <<'EOF'
⏺ Applying findings
Context left until auto-compact: 5%
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
if printf '%s' "$out" | grep -qF "SKIP rc-autoresume"; then
  pass "auto-resuming session is logged as skipped (script's own stdout, not a gc call)"
else
  fail "auto-resuming session is logged as skipped (stdout missing: SKIP rc-autoresume)"
fi
assert_log_lacks "handoff --target rc-autoresume" "auto-resuming session is NOT handed off"
assert_log_contains "handoff --target rc-compactlow" "non-auto-resuming session in the fleet sweep is still handed off"
assert_log_contains "mail send mayor" "mayor is still escalated even though the limited session was skipped"

# ===========================================================================
start_case "item 4: TRIP line formats multiple limited sessions correctly (no field smear)"
# ===========================================================================
reset_world
write_sessions '{"sessions":[
  {"id":"rc-aaa","template":"foundry-kc/gc.run-operator","provider":"sonnet","state":"active","closed":false},
  {"id":"rc-bbb","template":"rc-5d0cqebd.dog","provider":"sonnet","state":"active","closed":false}
]}'
write_peek rc-aaa <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 6pm
EOF
write_peek rc-bbb <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 6pm
EOF
out="$(run_lookout 2>&1)"
if printf '%s' "$out" | grep -qF "rc-aaa(foundry-kc/gc.run-operator)"; then
  pass "TRIP line: first session correctly parenthesized (sid/template not smeared together)"
else
  fail "TRIP line malformed for rc-aaa; got: $(printf '%s' "$out" | grep TRIP)"
fi
if printf '%s' "$out" | grep -qF "rc-bbb(rc-5d0cqebd.dog)"; then
  pass "TRIP line: second session correctly parenthesized"
else
  fail "TRIP line malformed for rc-bbb; got: $(printf '%s' "$out" | grep TRIP)"
fi

# ===========================================================================
start_case "item 2: time budget — 40 slow sessions still escalate within budget, not all peeked"
# ===========================================================================
reset_world
sessions_json='{"sessions":['
for n in $(seq 1 40); do
  sid="rc-slow${n}"
  [ "$n" -gt 1 ] && sessions_json="${sessions_json},"
  sessions_json="${sessions_json}{\"id\":\"${sid}\",\"template\":\"knuckles/w${n}\",\"provider\":\"sonnet\",\"state\":\"active\",\"closed\":false}"
  if [ "$n" -eq 1 ]; then
    write_peek "$sid" <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 6pm
EOF
  else
    write_peek "$sid" <<'EOF'
⏺ working
EOF
  fi
done
sessions_json="${sessions_json}]}"
write_sessions "$sessions_json"
start_ts=$(date +%s)
out="$(run_lookout STUB_PEEK_DELAY_SECONDS=3 CV_LOOKOUT_TIME_BUDGET_SECONDS=5 CV_LOOKOUT_PEEK_TIMEOUT_SECONDS=10 2>&1)"; rc=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
[ "$rc" -eq 0 ] && pass "exit 0 under budget pressure" || fail "exit code $rc (output: $out)"
if [ "$elapsed" -lt 30 ]; then
  pass "run finished well under the 40x3s=120s naive-serial time ($elapsed s elapsed)"
else
  fail "run took ${elapsed}s — budget did not bound the peek scan"
fi
assert_file_contains "${STATE_DIR}/breaker.state" "state=open" "breaker opened within budget despite slow peeks"
assert_log_contains "mail send mayor" "escalation mailed within budget despite slow peeks"
if printf '%s' "$out" | grep -qF "time budget"; then
  pass "budget-exceeded message logged (not all sessions were peeked)"
else
  fail "expected a time-budget log message"
fi

# ===========================================================================
start_case "AUTO_FLIP=true: trip applies override, reloads, mails, THEN hands off — in that order"
# ===========================================================================
reset_world
write_city_toml
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 11pm
EOF
write_peek rc-inv <<'EOF'
⏺ coordinating
EOF
STUB_OPENCODE_PROBE_LOG="${SANDBOX}/opencode-probe-open.log"
: > "$STUB_OPENCODE_PROBE_LOG"
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
[ -s "$STUB_OPENCODE_PROBE_LOG" ] && pass "spawn-capability probe was invoked before flipping (gascity#5436 guard)" || fail "spawn probe was never invoked"
assert_file_contains "${STATE_DIR}/breaker.state" "spawn_probe_verified=1" "spawn probe recorded verified"
assert_file_contains "${STATE_DIR}/breaker.state" "state=open" "breaker open"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=1" "breaker flipped=1"
assert_file_contains "$CITY_TOML" "glm-5p3-flash" "city.toml agent_defaults overridden to medium pool"
assert_file_contains "$CITY_TOML" "kimi-k3" "city.toml mayor patch overridden to large pool"
assert_file_contains "$CITY_TOML" "# some operator comment that must survive" "unrelated city.toml content survives untouched"
assert_log_contains "reload" "gc reload invoked"
assert_log_contains "config explain --agent mayor" "gc config explain invoked to verify the reload"
assert_log_contains "mail send mayor" "mayor mailed about the flip"
assert_log_contains "mail send human" "human mailed about the flip (mayor may itself be claude-limited)"
assert_log_contains "handoff --target rc-wrk1" "limited session handed off after flip (respawns on opencode)"
assert_log_order "reload" "mail send mayor" "override reload happens before the flip mail"
assert_log_order "mail send mayor" "handoff --target rc-wrk1" "flip mail happens before any handoff"
assert_log_order "config explain" "handoff --target rc-wrk1" "reload verification happens before any handoff"

# ===========================================================================
start_case "AUTO_FLIP=true: auto-resuming session IS handed off once flipped (restarting is the point)"
# ===========================================================================
# State persists from the previous case; that trip already flipped. Confirm
# a session showing the auto-continue banner is NOT skipped in this mode.
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached · continuing automatically at 11pm (America/Detroit)
EOF
: > "$STUB_GC_LOG"
# Bypass the per-session handoff cooldown: the previous case already handed
# rc-wrk1 off moments ago, and this case is specifically testing the
# auto-resume-banner logic, not cooldown interaction.
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS=0 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_contains "handoff --target rc-wrk1" "auto-resuming session still handed off when flipped (must respawn on opencode)"

# ===========================================================================
start_case "AUTO_FLIP=true: reload not verified -> next run retries reload without re-applying the override"
# ===========================================================================
reset_world
write_city_toml
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 11pm
EOF
write_peek rc-inv <<'EOF'
⏺ coordinating
EOF
STUB_EXPLAIN_STALE=1
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
unset STUB_EXPLAIN_STALE
[ "$rc" -eq 0 ] && pass "first (crashy) run exit 0" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=1" "override applied on first run despite unverified reload"
assert_file_contains "${STATE_DIR}/breaker.state" "reload_verified=0" "reload_verified recorded 0 (state survives a killed/failed run)"
marker_count_before="$(grep -c 'BEGIN con-voyage-lookout' "$CITY_TOML")"
: > "$STUB_GC_LOG"
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "resume run exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "APPLIED" "resume run does not re-apply the override (idempotent apply was not re-invoked)"
assert_log_contains "config explain --agent mayor" "resume run retries the reload verification"
assert_file_contains "${STATE_DIR}/breaker.state" "reload_verified=1" "reload_verified now 1 after the retry succeeds"
marker_count_after="$(grep -c 'BEGIN con-voyage-lookout' "$CITY_TOML")"
[ "$marker_count_before" = "$marker_count_after" ] && pass "managed-block count unchanged across the retry (no duplicate blocks)" || fail "managed-block count changed: ${marker_count_before} -> ${marker_count_after}"

# ===========================================================================
start_case "AUTO_FLIP=true: zero claude sessions right after a flip does NOT flip back (no oscillation)"
# ===========================================================================
reset_world
write_city_toml
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 11pm
EOF
write_peek rc-inv <<'EOF'
⏺ coordinating
EOF
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=1" "sanity: flipped after the trip"
# All claude sessions have now "respawned on opencode" — the fleet is empty
# from the lookout's (claude-provider-filtered) point of view.
write_sessions '{"sessions":[]}'
: > "$STUB_GC_LOG"
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 with zero claude sessions" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "state=open" "breaker STAYS open with zero claude sessions post-flip"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=1" "breaker STAYS flipped with zero claude sessions post-flip"
assert_log_lacks "REVERTED" "override not reverted just because no claude sessions remain"

# ===========================================================================
start_case "AUTO_FLIP=true: flip-back requires BOTH the parsed reset time to have passed AND a successful probe"
# ===========================================================================
reset_world
write_city_toml
mkdir -p "$STATE_DIR"
# Seed a flipped breaker whose dwell window has long since passed but whose
# parsed reset time is still in the future — direct state seeding, same
# technique the pre-existing reset-window test above uses.
future_reset=$(( $(date +%s) + 3600 ))
printf 'state=open\nopened_at=1\nlast_limit_seen_at=1\nlast_escalated_at=1\nflipped=1\nreload_verified=1\nreset_hint_epoch=%s\nlast_probe_at=0\nnext_probe_at=0\n' "$future_reset" > "${STATE_DIR}/breaker.state"
# apply_override's sidecar must exist for remove_override to have something
# to revert — build it the same way a real flip would have.
run_lookout CV_LOOKOUT_AUTO_FLIP=true >/dev/null 2>&1 || true
# The run above may have re-tripped; force back to the seeded "waiting on
# reset time" state for a clean probe test.
printf 'state=open\nopened_at=1\nlast_limit_seen_at=1\nlast_escalated_at=1\nflipped=1\nreload_verified=1\nreset_hint_epoch=%s\nlast_probe_at=0\nnext_probe_at=0\n' "$future_reset" > "${STATE_DIR}/breaker.state"
write_sessions '{"sessions":[]}'
: > "$STUB_GC_LOG"
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 while waiting on reset time" || fail "exit code $rc (output: $out)"
assert_log_lacks "claude-probe" "no probe attempted before the parsed reset time"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=1" "still flipped (reset time not reached)"

# Now move the reset time into the past: the probe should run and, on
# success, flip back.
past_reset=$(( $(date +%s) - 60 ))
printf 'state=open\nopened_at=1\nlast_limit_seen_at=1\nlast_escalated_at=1\nflipped=1\nreload_verified=1\nreset_hint_epoch=%s\nlast_probe_at=0\nnext_probe_at=0\n' "$past_reset" > "${STATE_DIR}/breaker.state"
: > "$STUB_GC_LOG"
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 after reset time with a successful probe" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "state=closed" "breaker closed after successful probe past reset time"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=0" "breaker unflipped after successful probe"
assert_file_lacks "$CITY_TOML" "BEGIN con-voyage-lookout" "managed block removed from city.toml on flip-back"
assert_file_contains "$CITY_TOML" "# some operator comment that must survive" "unrelated city.toml content still survives after revert"
assert_log_contains "mail send mayor" "all-clear mailed to the mayor on flip-back"
assert_log_contains "mail send human" "all-clear mailed to the human on flip-back"

# ===========================================================================
start_case "AUTO_FLIP=true: a failed probe stays flipped and backs off before re-probing"
# ===========================================================================
reset_world
write_city_toml
# Apply a REAL flip first (must actually run apply_override so city.toml
# genuinely has the managed block and the sidecar exists), then force the
# clock fields so this run's clear-check reaches the probe stage.
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 11pm
EOF
write_peek rc-inv <<'EOF'
⏺ coordinating
EOF
run_lookout CV_LOOKOUT_AUTO_FLIP=true >/dev/null 2>&1 || true
assert_file_contains "$CITY_TOML" "BEGIN con-voyage-lookout" "sanity: the setup run really applied the override"
past_reset=$(( $(date +%s) - 60 ))
printf 'state=open\nopened_at=1\nlast_limit_seen_at=1\nlast_escalated_at=1\nflipped=1\nreload_verified=1\nreset_hint_epoch=%s\nlast_probe_at=0\nnext_probe_at=0\n' "$past_reset" > "${STATE_DIR}/breaker.state"
write_sessions '{"sessions":[]}'
: > "$STUB_GC_LOG"
STUB_PROBE_FAIL=1
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS=600 2>&1)"; rc=$?
unset STUB_PROBE_FAIL
[ "$rc" -eq 0 ] && pass "exit 0 after a failed probe" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=1" "still flipped after a failed probe"
assert_file_contains "$CITY_TOML" "BEGIN con-voyage-lookout" "managed block still present after a failed probe"
assert_log_lacks "REVERTED" "no revert attempted after a failed probe"
next_probe="$(grep -E '^next_probe_at=' "${STATE_DIR}/breaker.state" | cut -d= -f2)"
now="$(date +%s)"
if [ "$next_probe" -gt "$now" ]; then
  pass "next probe scheduled in the future (backoff applied)"
else
  fail "expected next_probe_at in the future, got ${next_probe} (now=${now})"
fi
# A second run before the backoff elapses must not probe again.
: > "$STUB_GC_LOG"
STUB_PROBE_LOG="${SANDBOX}/probe.log"
: > "$STUB_PROBE_LOG"
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
if [ -s "$STUB_PROBE_LOG" ]; then
  fail "probe ran again before the backoff window elapsed"
else
  pass "no re-probe before the backoff window elapses"
fi

# ===========================================================================
start_case "AUTO_FLIP=true: failed spawn probe BLOCKS the flip (gascity#5436 guard) — claude kept, BLOCKED mail, selective handoff"
# ===========================================================================
reset_world
write_city_toml
write_sessions '{"sessions":[
  {"id":"rc-wrk1","template":"knuckles/gc.implementation-worker","provider":"sonnet","state":"active","closed":false},
  {"id":"rc-autoresume","template":"knuckles/gc.implementation-worker","provider":"sonnet","state":"active","closed":false},
  {"id":"rc-inv","template":"mayor","provider":"opus","state":"active","closed":false}
]}'
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 11pm
EOF
write_peek rc-autoresume <<'EOF'
✗ Claude usage limit reached · continuing automatically at 11pm (America/Detroit)
EOF
write_peek rc-inv <<'EOF'
⏺ coordinating
EOF
STUB_OPENCODE_PROBE_FAIL=1
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
unset STUB_OPENCODE_PROBE_FAIL
[ "$rc" -eq 0 ] && pass "exit 0 despite a blocked flip" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=0" "breaker stays unflipped when the spawn probe fails"
assert_file_contains "${STATE_DIR}/breaker.state" "spawn_probe_verified=0" "spawn_probe_verified recorded 0"
assert_file_lacks "$CITY_TOML" "BEGIN con-voyage-lookout" "city.toml override never applied when the probe fails"
assert_file_contains "$CITY_TOML" 'provider = "claude"' "mayor patch still on claude (never touched)"
assert_log_lacks "reload" "no gc reload attempted when the probe fails"
assert_log_lacks "config explain" "no reload verification attempted when the probe fails"
assert_log_contains "mail send mayor" "mayor mailed about the blocked flip"
assert_log_contains "mail send human" "human mailed about the blocked flip"
assert_log_contains "BLOCKED" "escalation names the blocked auto-flip explicitly"
assert_log_contains "gascity#5436" "escalation cites the gascity#5436 dependency"
assert_log_contains "handoff --target rc-wrk1" "limited session still handed off on its CURRENT provider"
assert_log_lacks "handoff --target rc-autoresume" "auto-resuming session still skipped when blocked (selective sweep, not mass)"

# ===========================================================================
start_case "AUTO_FLIP=true: a failed spawn probe backs off, then flips once it later succeeds"
# ===========================================================================
reset_world
write_city_toml
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 11pm
EOF
write_peek rc-inv <<'EOF'
⏺ coordinating
EOF
STUB_OPENCODE_PROBE_FAIL=1
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS=600 2>&1)"; rc=$?
unset STUB_OPENCODE_PROBE_FAIL
[ "$rc" -eq 0 ] && pass "exit 0 after a failed spawn probe" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=0" "still unflipped after a failed spawn probe"
next_spawn_probe="$(grep -E '^spawn_probe_next_at=' "${STATE_DIR}/breaker.state" | cut -d= -f2)"
now="$(date +%s)"
if [ "$next_spawn_probe" -gt "$now" ]; then
  pass "next spawn probe scheduled in the future (backoff applied)"
else
  fail "expected spawn_probe_next_at in the future, got ${next_spawn_probe} (now=${now})"
fi

# A second run before the backoff elapses must not re-probe.
: > "$STUB_GC_LOG"
STUB_OPENCODE_PROBE_LOG="${SANDBOX}/opencode-probe-backoff.log"
: > "$STUB_OPENCODE_PROBE_LOG"
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true 2>&1)"; rc=$?
if [ -s "$STUB_OPENCODE_PROBE_LOG" ]; then
  fail "spawn probe ran again before the backoff window elapsed"
else
  pass "no spawn re-probe before the backoff window elapses"
fi
if printf '%s' "$out" | grep -qF "spawn probe backoff active"; then
  pass "backoff message logged"
else
  fail "expected a spawn-probe backoff log message"
fi

# Force the backoff to have elapsed: the next attempt should probe again and,
# since the stub now succeeds (STUB_OPENCODE_PROBE_FAIL unset), flip normally.
sed -i.bak -E 's/^spawn_probe_next_at=.*/spawn_probe_next_at=1/' "${STATE_DIR}/breaker.state" && rm -f "${STATE_DIR}/breaker.state.bak"
: > "$STUB_GC_LOG"
# rc-wrk1 was already handed off (on its current provider) by the earlier
# blocked runs' selective sweep; bypass the per-session cooldown so this
# assertion is about the mass-sweep-once-flipped behavior, not cooldown timing.
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS=0 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 once the spawn probe succeeds after backoff" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=1" "flip proceeds once the spawn probe later succeeds"
assert_log_contains "mail send mayor" "mayor mailed about the (now successful) flip"
assert_log_contains "handoff --target rc-wrk1" "limited session handed off once flipped"

# ===========================================================================
start_case "AUTO_FLIP=true: built-in spawn probe (no CV_LOOKOUT_OPENCODE_PROBE_CMD override) discovers a rig and spawns/closes a real probe session"
# ===========================================================================
reset_world
write_city_toml
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 11pm
EOF
write_peek rc-inv <<'EOF'
⏺ coordinating
EOF
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true CV_LOOKOUT_OPENCODE_PROBE_CMD= 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 using the built-in probe" || fail "exit code $rc (output: $out)"
assert_log_contains "rig list --json" "built-in probe discovers a rig"
assert_log_contains "session new glm-5p3-flash" "built-in probe spawns a session on the medium fallback pool"
assert_log_contains "--no-attach" "built-in probe spawns without attaching"
assert_log_contains "session close" "built-in probe cleans up its probe session"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=1" "flip proceeds once the built-in probe confirms spawn capability"

# ===========================================================================
start_case "AUTO_FLIP=true: built-in spawn probe treats 'no rig available' as unproven -> flip blocked"
# ===========================================================================
reset_world
write_city_toml
write_sessions "$TWO_CLAUDE_SESSIONS"
write_peek rc-wrk1 <<'EOF'
✗ Claude usage limit reached. Your limit will reset at 11pm
EOF
write_peek rc-inv <<'EOF'
⏺ coordinating
EOF
STUB_NO_RIGS=1
out="$(run_lookout CV_LOOKOUT_AUTO_FLIP=true CV_LOOKOUT_OPENCODE_PROBE_CMD= 2>&1)"; rc=$?
unset STUB_NO_RIGS
[ "$rc" -eq 0 ] && pass "exit 0 with no rig available" || fail "exit code $rc (output: $out)"
assert_file_contains "${STATE_DIR}/breaker.state" "flipped=0" "flip blocked when no rig is available to probe against"
if printf '%s' "$out" | grep -qF "no rig available to probe"; then
  pass "warns that no rig was available to probe spawn capability"
else
  fail "expected a 'no rig available' warning"
fi
assert_log_lacks "session new" "no probe session attempted when no rig is discoverable"

# ===========================================================================
start_case "AUTO_FLIP=false (default): original non-flipping behavior is unchanged, incl. auto-resume skip"
# ===========================================================================
reset_world
write_sessions '{"sessions":[
  {"id":"rc-autoresume2","template":"knuckles/gc.implementation-worker","provider":"sonnet","state":"active","closed":false}
]}'
write_peek rc-autoresume2 <<'EOF'
✗ Claude usage limit reached · continuing shortly
EOF
out="$(run_lookout 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit code $rc (output: $out)"
assert_log_lacks "handoff --target rc-autoresume2" "AUTO_FLIP off: auto-resuming session still skipped (unchanged behavior)"
assert_log_lacks "reload" "AUTO_FLIP off: no reload attempted"
assert_log_lacks "config explain" "AUTO_FLIP off: no config explain attempted"
[ ! -f "$CITY_TOML" ] && pass "AUTO_FLIP off: city.toml never created/touched" || fail "AUTO_FLIP off: city.toml unexpectedly exists"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
