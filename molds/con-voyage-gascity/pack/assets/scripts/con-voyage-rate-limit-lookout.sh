#!/usr/bin/env bash
# con-voyage-rate-limit-lookout.sh — the pack's claude-fleet rate-limit
# circuit breaker and proactive context-compaction handoff monitor.
#
# WHY THIS MONITOR EXISTS: con-voyage puts its most important work on claude
# (opus for the mayor, sonnet for do-work/implementation workers — see the
# README's "Model tiers" section). Two provider-side events can silently gut
# that fleet:
#
#   1. USAGE/RATE LIMITS. A Claude Code session that hits its usage limit
#      ("Claude usage limit reached. Your limit will reset at …") does not
#      crash — it just stops producing. Bead-level watchdogs see a live
#      session and a quiet bead and wait. One limited worker is a stall; a
#      shared account limit stalls the WHOLE fleet at once, so a per-lane
#      remedy is the wrong tool.
#   2. CONTEXT COMPACTION. Auto-compact landing mid-task costs the worker
#      its in-flight mental model. gc wires a PreCompact hook
#      (`gc handoff --auto`) so the compaction itself is survived, but the
#      smoothest transition is handing off BEFORE the compact lands, on the
#      worker's own terms. Claude Code advertises the approach in its status
#      line ("Context left until auto-compact: NN%"), which `gc session
#      peek` captures — so we can act early.
#
# WHAT IT DOES, per run (city-wide, all rigs at once — the order that fires
# this script is scope="city"):
#
#   - Discover every active claude-backed session (`gc session list --json`,
#     provider ∈ CV_LOOKOUT_CLAUDE_PROVIDERS) and `gc session peek` each one,
#     one at a time, until either every session is peeked or the internal
#     time budget (CV_LOOKOUT_TIME_BUDGET_SECONDS) runs out — sessions left
#     unpeeked this run are picked up next run.
#   - COMPACT RISK (breaker closed): a session advertising ≤
#     CV_LOOKOUT_COMPACT_HANDOFF_PERCENT context remaining gets a
#     `gc handoff --target` — mail-to-self + controller restart, so it
#     resumes fresh with its own handoff summary waiting. Per-session
#     cooldown (CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS) prevents kill-loops.
#   - USAGE LIMIT (any run): a session showing a limit signature OPENS the
#     circuit breaker. ESCALATION HAPPENS FIRST: breaker.state is written
#     and the mayor is mailed BEFORE any handoff is attempted, so a crash or
#     an external timeout after that point still leaves the breaker open and
#     the mayor told. A session whose pane shows Claude Code's own
#     auto-continue banner ("continuing automatically", "continuing
#     shortly") is skipped from the handoff — it will resume on its own, and
#     restarting it only loses the in-flight turn and re-primes context.
#   - AUTO-FLIP (opt-in, CV_LOOKOUT_AUTO_FLIP=true, pack default false): on
#     trip, the lookout applies an all-opencode override itself — a
#     marker-delimited managed block in city.toml overriding
#     [agent_defaults].provider and the mayor's patch provider to the
#     fallback pools, then `gc reload` — instead of only mailing
#     instructions. This exists because during a claude-wide limit the mayor
#     is ALSO on claude, so a mail-only escalation may sit unread.
#     GASCITY#5436 GUARD: on gc 1.4.2, opencode/ACP-backed sessions can be
#     silently unspawnable (the session supervisor logs "requires ACP
#     transport but the session provider cannot route ACP sessions
#     (skipping)") even though `gc config explain` correctly shows the
#     override took hold — config resolution is not proof of spawn capacity.
#     So before ever applying the override, the lookout runs a real,
#     bounded spawn-capability probe (see CV_LOOKOUT_OPENCODE_PROBE_CMD)
#     against the target fallback pool. Only a successful probe applies the
#     override and restarts sessions onto opencode; a failed probe (or one
#     still backing off) leaves the current claude providers in place,
#     escalates a distinct "flip blocked" mail to the mayor and human citing
#     gastownhall/gascity#5436, and falls back to the same
#     context-preserving, current-provider handoff sweep used when
#     CV_LOOKOUT_AUTO_FLIP is off. The same fallback applies if the override
#     was applied but `gc reload` has not yet been verified to have taken
#     effect — restarting sessions onto opencode is never safe until both
#     the spawn probe and the reload are confirmed. Once flipped and
#     verified, restarting limited sessions IS the point (they respawn on
#     opencode), so the auto-continue-banner skip above does not apply.
#     Flip-back is reset-time + live-probe gated with a minimum dwell and a
#     probe backoff, specifically so a momentary zero-claude-sessions reading
#     right after a flip can't immediately flip back and oscillate.
#   - ALL-CLEAR (not flipped): no limit signature observed for a full
#     CV_LOOKOUT_BREAKER_RESET_SECONDS window -> breaker CLOSES and the
#     mayor gets a "safe to return to claude tiers" mail.
#   - TRACKING: every run aggregates the trailing
#     CV_LOOKOUT_USAGE_WINDOW_MINUTES of .gc/usage.jsonl model facts into
#     <state-dir>/usage-snapshot.txt; the summary rides along in escalation
#     mail so the mayor switches with the fleet's actual burn in hand.
#
# DESIGN NOTES:
#   - Detection is PEEK-BASED (read-only pane capture), matching how an
#     operator would eyeball a stuck session; the script never injects keys
#     or interrupts work except through gc's own handoff path.
#   - Limit signatures are matched only inside CLAUDE-backed sessions' panes,
#     so an opencode worker editing a script that merely MENTIONS "usage
#     limit reached" (including this one) cannot trip the breaker.
#   - State is plain key=value files under CV_LOOKOUT_STATE_DIR, epoch
#     integers for timestamps, with the same malformed-field coercion
#     posture as con-voyage-lib.sh (a hand-edited or torn state file must
#     never wedge the monitor).
#   - Every step of the auto-flip sequence (state write, override apply,
#     reload+verify, mail, handoff) persists its own progress to
#     breaker.state first, so a run killed mid-flip resumes correctly next
#     time instead of repeating or skipping a step.
#   - Everything is fail-safe: a failed handoff/mail warns and continues;
#     the order controller retries non-zero exits, so only preflight
#     failures (no gc, no python3) exit non-zero.
#   - TIME BUDGET: the order itself sets an explicit exec timeout (see the
#     order file). CV_LOOKOUT_TIME_BUDGET_SECONDS is an internal budget kept
#     safely below that, so the script always has time left to escalate
#     even when a slow store makes individual `gc` calls slow — peeks and
#     handoffs are budget-checked per-iteration and simply pick up next run
#     if the budget runs out mid-scan.
#
# Environment / configuration (all optional with sane defaults):
#
#   GC                                  Path to the gc binary (default: gc)
#   GC_CITY                             City root passed to gc (default: .)
#   CV_LOOKOUT_STATE_DIR                Breaker/session state dir.
#                                       Default: $GC_CITY/.gc/con-voyage/lookout
#   CV_LOOKOUT_CLAUDE_PROVIDERS         Comma-separated gc provider names
#                                       considered claude-backed.
#                                       Default: claude,opus,sonnet
#   CV_LOOKOUT_PEEK_LINES               Pane lines captured per session.
#                                       Default: 80
#   CV_LOOKOUT_PEEK_TIMEOUT_SECONDS     Per-call bound on a single
#                                       `gc session peek`. Default: 10
#   CV_LOOKOUT_TIME_BUDGET_SECONDS      Internal wall-clock budget for the
#                                       whole run, kept below the order's own
#                                       exec timeout. Default: 90
#   CV_LOOKOUT_COMPACT_HANDOFF_PERCENT  Hand off a session when its
#                                       advertised context-remaining drops
#                                       to this percent or below. 0 disables
#                                       proactive compact handoffs.
#                                       Default: 15
#   CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS Minimum seconds between two handoffs
#                                       of the SAME session. Default: 1800
#   CV_LOOKOUT_BREAKER_RESET_SECONDS    Limit-free window before an open,
#                                       non-flipped breaker closes
#                                       (all-clear). Default: 3600
#   CV_LOOKOUT_BREAKER_REMIND_SECONDS   Minimum seconds between repeat mayor
#                                       escalations while open. Default: 1800
#   CV_LOOKOUT_ESCALATE_TARGET          Mail recipient for breaker events.
#                                       Default: mayor
#   CV_LOOKOUT_HUMAN_ESCALATE_TARGET    Second mail recipient for auto-flip
#                                       events specifically (the mayor may be
#                                       claude-limited too). Default: human
#   CV_LOOKOUT_FALLBACK_LARGE_POOL      opencode pool for opus-class
#                                       (large/critical) work in
#                                       all-opencode mode. Default: kimi-k3
#   CV_LOOKOUT_FALLBACK_MEDIUM_POOL     opencode pool for sonnet-class
#                                       (medium) work in all-opencode mode.
#                                       Default: glm-5p3-flash
#   CV_LOOKOUT_FALLBACK_SMALL_POOL      opencode pool for haiku-class
#                                       (small/rudimentary) work in
#                                       all-opencode mode. Default: minimax-m3
#   CV_LOOKOUT_USAGE_FILE               Usage JSONL sink. Default:
#                                       $GC_CITY/.gc/usage.jsonl
#   CV_LOOKOUT_USAGE_WINDOW_MINUTES     Trailing window for the usage
#                                       summary. Default: 60
#   CV_LOOKOUT_AUTO_FLIP                Opt-in: the lookout applies the
#                                       all-opencode override itself instead
#                                       of only mailing instructions. Pack
#                                       default: false. See README "Model
#                                       tiers" / the orchestration fragment.
#                                       DEPENDS ON gastownhall/gascity#5436
#                                       (open as of this writing): on gc
#                                       1.4.2 the session supervisor can
#                                       silently fail to route opencode/ACP
#                                       sessions ("requires ACP transport but
#                                       the session provider cannot route ACP
#                                       sessions (skipping)"). Every flip is
#                                       therefore gated on a live spawn probe
#                                       (CV_LOOKOUT_OPENCODE_PROBE_CMD) —
#                                       config resolving to the fallback pool
#                                       is not treated as proof it can spawn.
#   CV_LOOKOUT_CITY_TOML                city.toml path the auto-flip override
#                                       edits. Default: $GC_CITY/city.toml
#   CV_LOOKOUT_FLIP_DWELL_SECONDS       Minimum time after a flip before any
#                                       clear check runs, so a momentary
#                                       zero-claude-sessions reading right
#                                       after the flip can't immediately
#                                       flip back. Default: 900
#   CV_LOOKOUT_CLAUDE_PROBE_CMD         One-shot command used to test whether
#                                       claude is reachable again before
#                                       flipping back. Default: "claude -p ok"
#   CV_LOOKOUT_OPENCODE_PROBE_CMD       One-shot command used to prove the
#                                       opencode/ACP fallback pool can
#                                       actually spawn BEFORE flipping to it
#                                       (see the gascity#5436 note above).
#                                       Default: empty, which runs a built-in
#                                       probe that spawns a real, uniquely
#                                       aliased, --no-attach session on
#                                       CV_LOOKOUT_FALLBACK_MEDIUM_POOL (in
#                                       CV_LOOKOUT_PROBE_RIG, or the city's
#                                       first rig if unset), waits up to
#                                       CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS
#                                       for the reconciler to actually start
#                                       it, and always cleans it up. Set this
#                                       to override with a custom check (or
#                                       to stub it in tests).
#   CV_LOOKOUT_PROBE_RIG                Rig to target CV_LOOKOUT_OPENCODE_PROBE_CMD's
#                                       built-in spawn probe against. Default:
#                                       empty, meaning "the city's first rig
#                                       per `gc rig list --json`". ACP routing
#                                       capability is a gc-wide property, not
#                                       a per-rig one, so any configured rig
#                                       is representative.
#   CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS Per-call bound on a probe — shared
#                                       by the flip-back claude probe and the
#                                       pre-flip opencode spawn probe.
#                                       Default: 30
#   CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS Minimum time between two probe
#                                       attempts after a failed probe —
#                                       shared by the flip-back claude probe
#                                       and the pre-flip opencode spawn
#                                       probe. Default: 300
#
# Exit codes:
#   0 — completed (actions taken or not)
#   Non-zero — fatal setup error (gc/python3 missing)
#
# Requires: bash 4+, gc CLI, python3 (3.11+ for auto-flip's tomllib use).

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_LOOKOUT_STATE_DIR="${CV_LOOKOUT_STATE_DIR:-${GC_CITY}/.gc/con-voyage/lookout}"
CV_LOOKOUT_CLAUDE_PROVIDERS="${CV_LOOKOUT_CLAUDE_PROVIDERS:-claude,opus,sonnet}"
CV_LOOKOUT_PEEK_LINES="${CV_LOOKOUT_PEEK_LINES:-80}"
CV_LOOKOUT_PEEK_TIMEOUT_SECONDS="${CV_LOOKOUT_PEEK_TIMEOUT_SECONDS:-10}"
CV_LOOKOUT_TIME_BUDGET_SECONDS="${CV_LOOKOUT_TIME_BUDGET_SECONDS:-90}"
CV_LOOKOUT_COMPACT_HANDOFF_PERCENT="${CV_LOOKOUT_COMPACT_HANDOFF_PERCENT:-15}"
CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS="${CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS:-1800}"
CV_LOOKOUT_BREAKER_RESET_SECONDS="${CV_LOOKOUT_BREAKER_RESET_SECONDS:-3600}"
CV_LOOKOUT_BREAKER_REMIND_SECONDS="${CV_LOOKOUT_BREAKER_REMIND_SECONDS:-1800}"
CV_LOOKOUT_ESCALATE_TARGET="${CV_LOOKOUT_ESCALATE_TARGET:-mayor}"
CV_LOOKOUT_HUMAN_ESCALATE_TARGET="${CV_LOOKOUT_HUMAN_ESCALATE_TARGET:-human}"
CV_LOOKOUT_FALLBACK_LARGE_POOL="${CV_LOOKOUT_FALLBACK_LARGE_POOL:-kimi-k3}"
CV_LOOKOUT_FALLBACK_MEDIUM_POOL="${CV_LOOKOUT_FALLBACK_MEDIUM_POOL:-glm-5p3-flash}"
CV_LOOKOUT_FALLBACK_SMALL_POOL="${CV_LOOKOUT_FALLBACK_SMALL_POOL:-minimax-m3}"
CV_LOOKOUT_USAGE_FILE="${CV_LOOKOUT_USAGE_FILE:-${GC_CITY}/.gc/usage.jsonl}"
CV_LOOKOUT_USAGE_WINDOW_MINUTES="${CV_LOOKOUT_USAGE_WINDOW_MINUTES:-60}"
CV_LOOKOUT_AUTO_FLIP="${CV_LOOKOUT_AUTO_FLIP:-false}"
CV_LOOKOUT_CITY_TOML="${CV_LOOKOUT_CITY_TOML:-${GC_CITY}/city.toml}"
CV_LOOKOUT_FLIP_DWELL_SECONDS="${CV_LOOKOUT_FLIP_DWELL_SECONDS:-900}"
CV_LOOKOUT_CLAUDE_PROBE_CMD="${CV_LOOKOUT_CLAUDE_PROBE_CMD:-claude -p ok}"
CV_LOOKOUT_OPENCODE_PROBE_CMD="${CV_LOOKOUT_OPENCODE_PROBE_CMD:-}"
CV_LOOKOUT_PROBE_RIG="${CV_LOOKOUT_PROBE_RIG:-}"
CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS="${CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS:-30}"
CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS="${CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS:-300}"

# A malformed override must never silently break the numeric gates below —
# same fail-safe coercion posture as con-voyage-review-watchdog.sh.
case "$CV_LOOKOUT_PEEK_LINES" in                  *[!0-9]*|'') CV_LOOKOUT_PEEK_LINES="80" ;; esac
case "$CV_LOOKOUT_PEEK_TIMEOUT_SECONDS" in        *[!0-9]*|'') CV_LOOKOUT_PEEK_TIMEOUT_SECONDS="10" ;; esac
case "$CV_LOOKOUT_TIME_BUDGET_SECONDS" in         *[!0-9]*|'') CV_LOOKOUT_TIME_BUDGET_SECONDS="90" ;; esac
case "$CV_LOOKOUT_COMPACT_HANDOFF_PERCENT" in     *[!0-9]*|'') CV_LOOKOUT_COMPACT_HANDOFF_PERCENT="15" ;; esac
case "$CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS" in    *[!0-9]*|'') CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS="1800" ;; esac
case "$CV_LOOKOUT_BREAKER_RESET_SECONDS" in       *[!0-9]*|'') CV_LOOKOUT_BREAKER_RESET_SECONDS="3600" ;; esac
case "$CV_LOOKOUT_BREAKER_REMIND_SECONDS" in      *[!0-9]*|'') CV_LOOKOUT_BREAKER_REMIND_SECONDS="1800" ;; esac
case "$CV_LOOKOUT_USAGE_WINDOW_MINUTES" in        *[!0-9]*|'') CV_LOOKOUT_USAGE_WINDOW_MINUTES="60" ;; esac
case "$CV_LOOKOUT_FLIP_DWELL_SECONDS" in          *[!0-9]*|'') CV_LOOKOUT_FLIP_DWELL_SECONDS="900" ;; esac
case "$CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS" in  *[!0-9]*|'') CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS="30" ;; esac
case "$CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS" in *[!0-9]*|'') CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS="300" ;; esac
case "$(printf '%s' "$CV_LOOKOUT_AUTO_FLIP" | tr '[:upper:]' '[:lower:]')" in
  true|1) CV_LOOKOUT_AUTO_FLIP="true" ;;
  *)      CV_LOOKOUT_AUTO_FLIP="false" ;;
esac

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-rate-limit-lookout: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-rate-limit-lookout: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

echo "con-voyage-rate-limit-lookout: claude_providers=${CV_LOOKOUT_CLAUDE_PROVIDERS} compact<=${CV_LOOKOUT_COMPACT_HANDOFF_PERCENT}% reset=${CV_LOOKOUT_BREAKER_RESET_SECONDS}s budget=${CV_LOOKOUT_TIME_BUDGET_SECONDS}s auto_flip=${CV_LOOKOUT_AUTO_FLIP} escalate=${CV_LOOKOUT_ESCALATE_TARGET} fallback=${CV_LOOKOUT_FALLBACK_LARGE_POOL},${CV_LOOKOUT_FALLBACK_MEDIUM_POOL},${CV_LOOKOUT_FALLBACK_SMALL_POOL}"

mkdir -p "${CV_LOOKOUT_STATE_DIR}/sessions" || {
  echo "con-voyage-rate-limit-lookout: ERROR: cannot create state dir ${CV_LOOKOUT_STATE_DIR}" >&2
  exit 1
}

NOW_EPOCH="$(python3 -c 'import time; print(int(time.time()))')"
SCRIPT_START_EPOCH="$NOW_EPOCH"

# now_epoch — a cheap (no python3 startup) clock read for the frequent
# per-iteration budget checks in the peek/handoff loops below.
now_epoch() { date +%s; }

budget_exceeded() {
  [ "$(( $(now_epoch) - SCRIPT_START_EPOCH ))" -ge "$CV_LOOKOUT_TIME_BUDGET_SECONDS" ]
}

# run_with_timeout SECONDS -- CMD [ARGS...] — portable per-call bound (no
# reliance on GNU coreutils' `timeout`, which macOS doesn't ship).
run_with_timeout() {
  local secs="$1"
  shift
  [ "${1:-}" = "--" ] && shift
  python3 -c '
import subprocess, sys
timeout = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    r = subprocess.run(cmd, timeout=timeout)
    sys.exit(r.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
except Exception:
    sys.exit(1)
' "$secs" "$@"
}

# ---------------------------------------------------------------------------
# State helpers — plain key=value files, epoch integers, coerced on read.
# ---------------------------------------------------------------------------
BREAKER_FILE="${CV_LOOKOUT_STATE_DIR}/breaker.state"
CV_LOOKOUT_OVERRIDE_SIDECAR="${CV_LOOKOUT_STATE_DIR}/override-revert.json"

# state_get FILE KEY — print the value of KEY from a key=value state file.
state_get() {
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

# int_or_zero VALUE — coerce to a validated base-10 integer.
int_or_zero() {
  case "$1" in *[!0-9]*|'') printf '0' ;; *) printf '%s' "$1" ;; esac
}

BREAKER_STATE="$(state_get "$BREAKER_FILE" state)"
BREAKER_STATE="${BREAKER_STATE:-closed}"
BREAKER_OPENED_AT="$(int_or_zero "$(state_get "$BREAKER_FILE" opened_at)")"
BREAKER_LAST_LIMIT_AT="$(int_or_zero "$(state_get "$BREAKER_FILE" last_limit_seen_at)")"
BREAKER_LAST_MAIL_AT="$(int_or_zero "$(state_get "$BREAKER_FILE" last_escalated_at)")"
BREAKER_FLIPPED="$(int_or_zero "$(state_get "$BREAKER_FILE" flipped)")"
BREAKER_RELOAD_VERIFIED="$(int_or_zero "$(state_get "$BREAKER_FILE" reload_verified)")"
BREAKER_RESET_HINT_EPOCH="$(int_or_zero "$(state_get "$BREAKER_FILE" reset_hint_epoch)")"
BREAKER_LAST_PROBE_AT="$(int_or_zero "$(state_get "$BREAKER_FILE" last_probe_at)")"
BREAKER_NEXT_PROBE_AT="$(int_or_zero "$(state_get "$BREAKER_FILE" next_probe_at)")"
# spawn_probe_* — the PRE-flip opencode/ACP spawn-capability probe (gascity#5436
# guard). A deliberately separate state machine from last_probe_at/next_probe_at
# above, which gate the OPPOSITE direction (flip-BACK to claude).
SPAWN_PROBE_VERIFIED="$(int_or_zero "$(state_get "$BREAKER_FILE" spawn_probe_verified)")"
SPAWN_PROBE_LAST_AT="$(int_or_zero "$(state_get "$BREAKER_FILE" spawn_probe_last_at)")"
SPAWN_PROBE_NEXT_AT="$(int_or_zero "$(state_get "$BREAKER_FILE" spawn_probe_next_at)")"

# breaker_write — persist the CURRENT in-memory BREAKER_*/SPAWN_PROBE_* globals.
# Called with no args deliberately: the auto-flip sequence updates a few of
# these fields at a time across several steps (state open -> spawn probe ->
# override applied -> reload verified -> mailed), writing after each one so a
# killed run resumes at the right step instead of repeating or skipping it.
breaker_write() {
  printf 'state=%s\nopened_at=%s\nlast_limit_seen_at=%s\nlast_escalated_at=%s\nflipped=%s\nreload_verified=%s\nreset_hint_epoch=%s\nlast_probe_at=%s\nnext_probe_at=%s\nspawn_probe_verified=%s\nspawn_probe_last_at=%s\nspawn_probe_next_at=%s\n' \
    "$BREAKER_STATE" "$BREAKER_OPENED_AT" "$BREAKER_LAST_LIMIT_AT" "$BREAKER_LAST_MAIL_AT" \
    "$BREAKER_FLIPPED" "$BREAKER_RELOAD_VERIFIED" "$BREAKER_RESET_HINT_EPOCH" \
    "$BREAKER_LAST_PROBE_AT" "$BREAKER_NEXT_PROBE_AT" \
    "$SPAWN_PROBE_VERIFIED" "$SPAWN_PROBE_LAST_AT" "$SPAWN_PROBE_NEXT_AT" \
    > "$BREAKER_FILE" \
    || echo "con-voyage-rate-limit-lookout: WARNING: failed to write ${BREAKER_FILE}" >&2
}

# parse_reset_epoch HINT_TEXT NOW_EPOCH — best-effort "6pm" / "1pm
# (America/Detroit)" -> next occurrence as an epoch, in local time (the
# explicit zone name, when present, is not honored — this is only ever used
# to avoid probing needlessly early; a live probe is the actual safety gate,
# so an imprecise parse costs at most a few redundant probe attempts, never
# a false all-clear).
parse_reset_epoch() {
  python3 -c "
import re, sys, time
hint = sys.argv[1]
now = int(sys.argv[2])
m = re.search(r'(\d{1,2})\s*(am|pm)', hint, re.IGNORECASE)
if not m:
    print('')
    raise SystemExit(0)
hour = int(m.group(1)) % 12
if m.group(2).lower() == 'pm':
    hour += 12
t = time.localtime(now)
candidate = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, hour, 0, 0, 0, 0, -1))
if candidate <= now:
    candidate += 86400
print(int(candidate))
" "$1" "$2"
}

# run_claude_probe — one-shot, time-bounded check that claude is reachable
# again. Stubbable in tests via CV_LOOKOUT_CLAUDE_PROBE_CMD.
run_claude_probe() {
  local -a probe_cmd
  read -ra probe_cmd <<< "$CV_LOOKOUT_CLAUDE_PROBE_CMD"
  run_with_timeout "$CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS" -- "${probe_cmd[@]}" >/dev/null 2>&1
}

# spawn_probe_due — true if enough backoff time has passed since the last
# opencode spawn-capability probe attempt to try again (or none has been
# attempted yet). Mirrors the flip-back probe's own backoff gate, kept as a
# separate state machine (spawn_probe_next_at vs next_probe_at) since the two
# probes run in opposite situations and must never be conflated.
spawn_probe_due() {
  [ "$(now_epoch)" -ge "$SPAWN_PROBE_NEXT_AT" ]
}

# run_opencode_probe — gascity#5436 guard: proves the opencode/ACP fallback
# pool can actually spawn a session BEFORE the auto-flip override is applied.
# `gc config explain` showing the right provider name is NOT proof — gc 1.4.2's
# session supervisor can resolve the config correctly and still silently skip
# starting the session ("requires ACP transport but the session provider
# cannot route ACP sessions (skipping)"). Stubbable wholesale via
# CV_LOOKOUT_OPENCODE_PROBE_CMD (a one-shot command, same shape as
# CV_LOOKOUT_CLAUDE_PROBE_CMD) for tests and for operators who want a custom
# check. The built-in default actually spawns a uniquely-aliased,
# --no-attach, bounded-wait session on the medium fallback pool and always
# cleans it up — "the reconciler actually started it" is the only signal
# trusted here.
run_opencode_probe() {
  if [ -n "$CV_LOOKOUT_OPENCODE_PROBE_CMD" ]; then
    local -a probe_cmd
    read -ra probe_cmd <<< "$CV_LOOKOUT_OPENCODE_PROBE_CMD"
    run_with_timeout "$CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS" -- "${probe_cmd[@]}" >/dev/null 2>&1
    return $?
  fi

  local rig="$CV_LOOKOUT_PROBE_RIG"
  if [ -z "$rig" ]; then
    rig="$(run_with_timeout 15 -- "$GC" --city "$GC_CITY" rig list --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
rigs = data.get("rigs") if isinstance(data, dict) else data
if not isinstance(rigs, list) or not rigs:
    print("")
    raise SystemExit(0)
first = rigs[0]
name = first.get("name") if isinstance(first, dict) else first
print(name or "")
' 2>/dev/null)"
  fi
  if [ -z "$rig" ]; then
    echo "con-voyage-rate-limit-lookout: WARNING: no rig available to probe opencode spawn capability against; treating as unproven (gascity#5436)" >&2
    return 1
  fi

  local alias="cv-lookout-acp-probe-$$"
  local rc
  run_with_timeout "$CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS" -- \
    "$GC" --city "$GC_CITY" --rig "$rig" session new "$CV_LOOKOUT_FALLBACK_MEDIUM_POOL" \
    --no-attach --alias "$alias" --wait-timeout "${CV_LOOKOUT_FLIP_PROBE_TIMEOUT_SECONDS}s" \
    >/dev/null 2>&1
  rc=$?
  run_with_timeout 15 -- "$GC" --city "$GC_CITY" --rig "$rig" session close "$alias" >/dev/null 2>&1 || true
  return "$rc"
}

# reload_and_verify — apply the resolved config and confirm the mayor now
# shows the large-pool provider. Both calls are time-bounded well under the
# script's overall budget.
reload_and_verify() {
  if ! run_with_timeout 30 -- "$GC" --city "$GC_CITY" reload --timeout 20s >/dev/null 2>&1; then
    echo "con-voyage-rate-limit-lookout: WARNING: gc reload failed or timed out" >&2
    return 1
  fi
  local explain
  explain="$(run_with_timeout 15 -- "$GC" --city "$GC_CITY" config explain --agent mayor 2>/dev/null)"
  if printf '%s' "$explain" | grep -qF "$CV_LOOKOUT_FALLBACK_LARGE_POOL"; then
    return 0
  fi
  echo "con-voyage-rate-limit-lookout: WARNING: gc config explain does not show ${CV_LOOKOUT_FALLBACK_LARGE_POOL} for mayor after reload" >&2
  return 1
}

# apply_override — idempotent. Edits city.toml in place, replacing (or
# inserting) exactly [agent_defaults].provider and the mayor patch's
# .provider, each wrapped in its own uniquely-keyed marker pair so a later
# revert can find and undo precisely what was added — never anything else in
# the file. Existing content, comments, and formatting outside the marked
# lines are untouched. Backs up city.toml first; validates the result with
# tomllib before leaving it in place, restoring immediately on any failure.
apply_override() {
  python3 - "$CV_LOOKOUT_CITY_TOML" "$CV_LOOKOUT_FALLBACK_MEDIUM_POOL" "$CV_LOOKOUT_FALLBACK_LARGE_POOL" "$CV_LOOKOUT_OVERRIDE_SIDECAR" <<'PYEOF'
import json, re, sys, time

city_toml_path, medium_pool, large_pool, sidecar_path = sys.argv[1:5]
BEGIN_TAG = "# BEGIN con-voyage-lookout all-opencode (managed; removed on all-clear)"
END_TAG = "# END con-voyage-lookout all-opencode (managed; removed on all-clear)"

def begin(key):
    return f"{BEGIN_TAG} [{key}]"

def end(key):
    return f"{END_TAG} [{key}]"

try:
    with open(city_toml_path, "r") as fh:
        original_text = fh.read()
except Exception as exc:
    print(f"ERROR: cannot read {city_toml_path}: {exc}", file=sys.stderr)
    sys.exit(1)

if BEGIN_TAG in original_text:
    print("ALREADY_APPLIED")
    sys.exit(0)

lines = original_text.split("\n")

TABLE_RE = re.compile(r'^\[agent_defaults\]\s*$')
ARRAY_TABLE_RE = re.compile(r'^\[\[patches\.agent\]\]\s*$')
MAYOR_NAME_RE = re.compile(r'^\s*name\s*=\s*"mayor"\s*$')
PROVIDER_RE = re.compile(r'^(\s*provider\s*=\s*)"[^"]*"\s*$')
NEXT_TABLE_RE = re.compile(r'^\s*\[')

def find_table(header_re, name_filter=None):
    i, n = 0, len(lines)
    while i < n:
        if header_re.match(lines[i]):
            start = i
            j = i + 1
            while j < n and not NEXT_TABLE_RE.match(lines[j]):
                j += 1
            if name_filter is None or any(name_filter.match(l) for l in lines[start:j]):
                return (start, j)
            i = j
            continue
        i += 1
    return None

ad_range = find_table(TABLE_RE)
mayor_range = find_table(ARRAY_TABLE_RE, MAYOR_NAME_RE)
plan = [("agent_defaults", ad_range, medium_pool), ("mayor_patch", mayor_range, large_pool)]
# Apply from the bottom of the file up so an earlier (lower-index) range
# computed above never gets invalidated by a later edit shifting line counts.
plan.sort(key=lambda p: (p[1][0] if p[1] else -1), reverse=True)

revert = {}
for key, table_range, new_value in plan:
    if table_range is None:
        lines.append(begin(key))
        if key == "agent_defaults":
            lines.append("[agent_defaults]")
            lines.append(f'provider = "{new_value}"')
        else:
            lines.append("[[patches.agent]]")
            lines.append('name = "mayor"')
            lines.append(f'provider = "{new_value}"')
        lines.append(end(key))
        revert[key] = {"action": "append_table"}
        continue

    start, stop = table_range
    found = False
    for idx in range(start + 1, stop):
        m = PROVIDER_RE.match(lines[idx])
        if m:
            original_line = lines[idx]
            lines[idx:idx + 1] = [begin(key), f'{m.group(1)}"{new_value}"', end(key)]
            revert[key] = {"action": "replace", "original_line": original_line}
            found = True
            break
    if not found:
        lines[start + 1:start + 1] = [begin(key), f'provider = "{new_value}"', end(key)]
        revert[key] = {"action": "insert"}

new_text = "\n".join(lines)

backup_path = f"{city_toml_path}.bak.{int(time.time())}"
try:
    with open(backup_path, "w") as fh:
        fh.write(original_text)
except Exception as exc:
    print(f"ERROR: cannot write backup {backup_path}: {exc}", file=sys.stderr)
    sys.exit(1)

try:
    with open(city_toml_path, "w") as fh:
        fh.write(new_text)
except Exception as exc:
    print(f"ERROR: cannot write {city_toml_path}: {exc}", file=sys.stderr)
    sys.exit(1)

try:
    import tomllib
except ImportError:
    with open(city_toml_path, "w") as fh:
        fh.write(original_text)
    print("ERROR: python3 has no tomllib (needs 3.11+); reverted, override not applied", file=sys.stderr)
    sys.exit(1)

try:
    with open(city_toml_path, "rb") as fh:
        tomllib.load(fh)
except Exception as exc:
    with open(city_toml_path, "w") as fh:
        fh.write(original_text)
    print(f"ERROR: invalid TOML after edit, reverted in place: {exc}", file=sys.stderr)
    sys.exit(1)

revert["backup_path"] = backup_path
with open(sidecar_path, "w") as fh:
    json.dump(revert, fh)

print("APPLIED")
PYEOF
}

# remove_override — the inverse of apply_override, driven entirely by the
# sidecar file apply_override wrote (crash-safe: works even if this process
# is not the one that applied the override). Idempotent no-op if there is
# nothing to revert. Touches only its own marked lines.
remove_override() {
  python3 - "$CV_LOOKOUT_CITY_TOML" "$CV_LOOKOUT_OVERRIDE_SIDECAR" <<'PYEOF'
import json, os, re, sys

city_toml_path, sidecar_path = sys.argv[1:3]
BEGIN_TAG = "# BEGIN con-voyage-lookout all-opencode (managed; removed on all-clear)"
END_TAG = "# END con-voyage-lookout all-opencode (managed; removed on all-clear)"

def begin(key):
    return f"{BEGIN_TAG} [{key}]"

def end(key):
    return f"{END_TAG} [{key}]"

try:
    with open(sidecar_path, "r") as fh:
        revert = json.load(fh)
except Exception:
    print("NOTHING_TO_REVERT")
    sys.exit(0)

try:
    with open(city_toml_path, "r") as fh:
        text = fh.read()
except Exception as exc:
    print(f"ERROR: cannot read {city_toml_path}: {exc}", file=sys.stderr)
    sys.exit(1)

if BEGIN_TAG not in text:
    print("ALREADY_CLEAN")
    try:
        os.remove(sidecar_path)
    except Exception:
        pass
    sys.exit(0)

lines = text.split("\n")

def remove_block(key, restore_line):
    b, e = begin(key), end(key)
    start = next((i for i, l in enumerate(lines) if l == b), None)
    if start is None:
        return False
    stop = next((j for j in range(start, len(lines)) if lines[j] == e), None)
    if stop is None:
        return False
    if restore_line is not None:
        lines[start:stop + 1] = [restore_line]
    else:
        del lines[start:stop + 1]
    return True

ok = True
for key in ("agent_defaults", "mayor_patch"):
    entry = revert.get(key)
    if not entry:
        continue
    action = entry.get("action")
    restore = entry.get("original_line") if action == "replace" else None
    if not remove_block(key, restore):
        print(f"WARNING: managed block for {key} not found; leaving as-is", file=sys.stderr)
        ok = False

new_text = "\n".join(lines)

try:
    import tomllib
    tomllib.loads(new_text)
except Exception as exc:
    print(f"ERROR: revert would produce invalid TOML, aborting (city.toml left untouched): {exc}", file=sys.stderr)
    sys.exit(1)

try:
    with open(city_toml_path, "w") as fh:
        fh.write(new_text)
except Exception as exc:
    print(f"ERROR: cannot write {city_toml_path}: {exc}", file=sys.stderr)
    sys.exit(1)

try:
    os.remove(sidecar_path)
except Exception:
    pass

print("REVERTED" if ok else "REVERTED_PARTIAL")
sys.exit(0 if ok else 1)
PYEOF
}

# send_flip_mail open|clear — mails BOTH the mayor and the human. The mayor
# may itself be claude-limited when this fires, which is exactly why the
# human copy exists.
send_flip_mail() {
  local kind="$1" subject body mayor_ok=0
  if [ "$kind" = "blocked" ]; then
    subject="con-voyage rate-limit lookout: claude limit circuit breaker OPEN — all-opencode auto-flip BLOCKED (target can't spawn)"
    body="The con-voyage rate-limit lookout observed claude usage/rate limits. CV_LOOKOUT_AUTO_FLIP=true, but a live spawn-capability probe against the opencode fallback pool FAILED, so the lookout did NOT flip. Current claude providers are being kept.

Limited sessions: ${limited_list:-unknown}

Why: gc 1.4.2 has an open bug (gastownhall/gascity#5436) where the session
supervisor can silently fail to route opencode/ACP-backed sessions
('requires ACP transport but the session provider cannot route ACP sessions
(skipping)') even when config resolves the provider correctly. Flipping
config without proof the target can actually spawn would leave the fleet —
mayor included — with zero spawnable sessions, which is worse than staying
on claude and waiting out the limit. So the lookout proves spawn capability
with a real probe before ever touching city.toml, and skipped the flip here
because that probe failed.

Manual fallback (same as CV_LOOKOUT_AUTO_FLIP=false mode) if you want to
re-sling work by hand once you've independently confirmed a pool can spawn:
  gc sling <rig>/${CV_LOOKOUT_FALLBACK_LARGE_POOL} <bead> --nudge   # opus-class
  gc sling <rig>/${CV_LOOKOUT_FALLBACK_MEDIUM_POOL} <bead> --nudge  # sonnet-class
  gc sling <rig>/${CV_LOOKOUT_FALLBACK_SMALL_POOL} <bead> --nudge   # haiku-class

The lookout will keep retrying the spawn probe on a backoff (next attempt in
${CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS}s) and will flip automatically the
moment it succeeds. Affected sessions are being handed off on their CURRENT
provider instead (context preserved), same as CV_LOOKOUT_AUTO_FLIP=false.

Claude usage (trailing ${CV_LOOKOUT_USAGE_WINDOW_MINUTES}m): ${USAGE_SUMMARY:-no model facts recorded}"
  elif [ "$kind" = "open" ]; then
    subject="con-voyage rate-limit lookout: city flipped to all-opencode (auto-flip)"
    body="The con-voyage rate-limit lookout observed claude usage/rate limits and AUTOMATICALLY flipped the city to all-opencode mode (CV_LOOKOUT_AUTO_FLIP=true).

Limited sessions: ${limited_list:-unknown}

What changed (managed block in city.toml, then gc reload):
  - [agent_defaults].provider -> ${CV_LOOKOUT_FALLBACK_MEDIUM_POOL}
  - mayor patch .provider     -> ${CV_LOOKOUT_FALLBACK_LARGE_POOL}

Why: during a claude-wide limit the mayor is on claude too, so a mail-only
escalation could sit unread. The lookout applies the switch itself instead.

To undo by hand before the automatic all-clear: remove the two blocks
delimited by '# BEGIN con-voyage-lookout all-opencode ... [agent_defaults]'
/ '[mayor_patch]' (and their matching END lines) in city.toml, then run:
gc reload

The lookout flips back on its own once the parsed reset time has passed and
a live probe confirms claude is reachable again (minimum dwell ${CV_LOOKOUT_FLIP_DWELL_SECONDS}s, then probes on a backoff).

Claude usage (trailing ${CV_LOOKOUT_USAGE_WINDOW_MINUTES}m): ${USAGE_SUMMARY:-no model facts recorded}"
  else
    subject="con-voyage rate-limit lookout: city flipped back from all-opencode (auto-flip all-clear)"
    body="The con-voyage rate-limit lookout probed claude successfully after the parsed reset time and reverted the all-opencode override in city.toml (gc reload applied). Normal claude-tier dispatch (opus/sonnet) resumes for new work.

Claude usage (trailing ${CV_LOOKOUT_USAGE_WINDOW_MINUTES}m): ${USAGE_SUMMARY:-no model facts recorded}"
  fi
  if "$GC" --city "$GC_CITY" mail send "$CV_LOOKOUT_ESCALATE_TARGET" -s "$subject" -m "$body" 2>&1; then
    mayor_ok=1
  else
    echo "con-voyage-rate-limit-lookout: WARNING: flip mail to ${CV_LOOKOUT_ESCALATE_TARGET} failed" >&2
  fi
  if ! "$GC" --city "$GC_CITY" mail send "$CV_LOOKOUT_HUMAN_ESCALATE_TARGET" -s "$subject" -m "$body" 2>&1; then
    echo "con-voyage-rate-limit-lookout: WARNING: flip mail to ${CV_LOOKOUT_HUMAN_ESCALATE_TARGET} failed" >&2
  fi
  [ "$mayor_ok" = "1" ]
}

# ---------------------------------------------------------------------------
# Discovery: every active claude-backed session in the city.
# ---------------------------------------------------------------------------
SESSIONS_JSON="$("$GC" --city "$GC_CITY" session list --json 2>/dev/null)"
[ -n "$SESSIONS_JSON" ] || SESSIONS_JSON='{"sessions":[]}'

SESSIONS_TSV="$(printf '%s' "$SESSIONS_JSON" | CV_LOOKOUT_CLAUDE_PROVIDERS="$CV_LOOKOUT_CLAUDE_PROVIDERS" python3 -c "
import json, os, sys
SEP = '\x1f'
claude = {p.strip() for p in os.environ.get('CV_LOOKOUT_CLAUDE_PROVIDERS','').split(',') if p.strip()}
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    raise SystemExit(0)
for s in sessions:
    if not isinstance(s, dict):
        continue
    if s.get('closed'):
        continue
    if s.get('state') != 'active':
        continue
    provider = str(s.get('provider') or '')
    if provider not in claude:
        continue
    print(SEP.join([str(s.get('id') or ''), str(s.get('template') or ''), provider]))
" 2>/dev/null)"

if [ -z "$SESSIONS_TSV" ]; then
  echo "con-voyage-rate-limit-lookout: no active claude-backed sessions found"
fi

# ---------------------------------------------------------------------------
# Usage tracking: aggregate the trailing window of model facts from the
# city's usage sink. Best-effort — a missing/unparseable file yields an
# empty summary, never a failure. Written to a snapshot every run and
# embedded in escalation mail.
# ---------------------------------------------------------------------------
USAGE_SUMMARY="$(CV_LOOKOUT_USAGE_FILE="$CV_LOOKOUT_USAGE_FILE" python3 -c "
import json, os, sys
path = os.environ.get('CV_LOOKOUT_USAGE_FILE','')
window_ms = int('${CV_LOOKOUT_USAGE_WINDOW_MINUTES}') * 60 * 1000
now_ms = int('${NOW_EPOCH}') * 1000
totals = {}
try:
    fh = open(path, 'r')
except Exception:
    raise SystemExit(0)
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            fact = json.loads(line)
        except Exception:
            continue
        if not isinstance(fact, dict) or fact.get('kind') != 'model':
            continue
        try:
            at = int(fact.get('at') or 0)
        except Exception:
            continue
        if at < now_ms - window_ms:
            continue
        model = str(fact.get('model') or 'unknown')
        t = totals.setdefault(model, [0, 0, 0, 0])
        for i, k in enumerate(('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_creation_tokens')):
            try:
                t[i] += int(fact.get(k) or 0)
            except Exception:
                pass
parts = [
    f'{m} tokens: in={v[0]} out={v[1]} cache_read={v[2]} cache_write={v[3]}'
    for m, v in sorted(totals.items())
]
print('; '.join(parts))
" 2>/dev/null)"
if [ -n "$USAGE_SUMMARY" ]; then
  printf '# con-voyage-rate-limit-lookout usage snapshot (trailing %sm, epoch %s)\n%s\n' \
    "$CV_LOOKOUT_USAGE_WINDOW_MINUTES" "$NOW_EPOCH" "$USAGE_SUMMARY" \
    > "${CV_LOOKOUT_STATE_DIR}/usage-snapshot.txt" 2>/dev/null || true
  echo "con-voyage-rate-limit-lookout: usage ${CV_LOOKOUT_USAGE_WINDOW_MINUTES}m: ${USAGE_SUMMARY}"
fi

# ---------------------------------------------------------------------------
# Peek + classify each session. Classification is done in python3 over the
# captured pane text:
#   limited      — a usage/rate-limit signature is showing
#   reset_hint   — the advertised reset time, when Claude Code prints one
#   compact_pct  — advertised context remaining before auto-compact (-1 = n/a)
#   auto_resume  — Claude Code's own "continuing automatically/shortly"
#                  banner is showing (it will resume without help)
# ---------------------------------------------------------------------------
classify_peek() {
  # classify_peek PEEK_TEXT_FILE -> SEP-joined "limited SEP reset_hint SEP compact_pct SEP auto_resume"
  python3 -c "
import re, sys
SEP = '\x1f'
try:
    text = open(sys.argv[1], 'r', errors='replace').read()
except Exception:
    text = ''

# fk-xtbtcw: a claude pane's scrollback routinely QUOTES limit language that
# never came from Claude Code itself — a lookout mail body, a skill
# excerpt, a Slack thread pasted into the pane. A whole-scrollback substring
# search false-opens the breaker on that quoted text. Claude Code's own
# usage/rate-limit banner is emitted live, at the current tail of the pane,
# prefixed with its own '✗' glyph — so anchor detection to recent, glyph-
# prefixed lines instead of searching the entire captured buffer. A bare
# 'overloaded' (Claude Code's transient 529 retry banner, which auto-
# recovers) is intentionally NOT a limited signal on its own.
BANNER_LINES = 12
tail_text = '\n'.join(text.splitlines()[-BANNER_LINES:])
BANNER_GLYPH = '✗'
limited_patterns = [
    r'^\s*' + BANNER_GLYPH + r'.*usage limit reached',
    r'^\s*' + BANNER_GLYPH + r'.*rate limit reached',
    r'^\s*' + BANNER_GLYPH + r'.*limit will reset',
    r'^\s*' + BANNER_GLYPH + r'.*hit your\b.{0,40}\blimit',
    r'^\s*' + BANNER_GLYPH + r'.*api error:\s*429',
]
limited = any(re.search(p, tail_text, re.IGNORECASE | re.MULTILINE) for p in limited_patterns)
reset_hint = ''
m = re.search(r'(?:limit will reset|resets)\s*(?:at|around)?\s*([^\n.]{1,40})', tail_text, re.IGNORECASE)
if m:
    reset_hint = m.group(1).strip()
compact_pct = -1
m = re.search(r'auto-compact[^0-9]{0,20}(\d{1,3})\s*%', text, re.IGNORECASE)
if m:
    compact_pct = int(m.group(1))
elif re.search(r'context low', text, re.IGNORECASE):
    compact_pct = 0
auto_resume = bool(re.search(r'continuing automatically|continuing shortly', tail_text, re.IGNORECASE))
print(SEP.join(['1' if limited else '0', reset_hint, str(compact_pct), '1' if auto_resume else '0']))
" "$1"
}

# handoff_session SESSION_ID REASON — throttled gc handoff --target.
handoff_session() {
  local sid="$1" reason="$2"
  local sfile="${CV_LOOKOUT_STATE_DIR}/sessions/${sid}.state"
  local last
  last="$(int_or_zero "$(state_get "$sfile" last_handoff_at)")"
  if [ "$(( $(now_epoch) - last ))" -lt "$CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS" ]; then
    echo "con-voyage-rate-limit-lookout: SKIP ${sid} — handed off $(( $(now_epoch) - last ))s ago (cooldown ${CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS}s)"
    return 0
  fi
  if "$GC" --city "$GC_CITY" handoff --target "$sid" "con-voyage-rate-limit-lookout: ${reason}" 2>&1; then
    printf 'last_handoff_at=%s\n' "$(now_epoch)" > "$sfile" 2>/dev/null || true
    echo "con-voyage-rate-limit-lookout: HANDOFF ${sid} — ${reason}"
  else
    echo "con-voyage-rate-limit-lookout: WARNING: handoff failed for ${sid} (${reason}); will retry next cycle" >&2
  fi
}

# selective_handoff_sweep REASON — hand off every non-auto-resuming session,
# skipping ones showing Claude Code's own auto-continue banner (they resume
# on their own; restarting only loses the in-flight turn). Used whenever
# claude-tier dispatch is being KEPT — CV_LOOKOUT_AUTO_FLIP is off, or it's on
# but the flip hasn't (yet, or safely) taken effect this run — so sessions
# respawn on the CURRENT provider, never assumed to land on opencode.
selective_handoff_sweep() {
  local reason="$1"
  printf '%s' "$ALL_ROWS" | while IFS=$'\x1f' read -r hsid _; do
    [ -n "$hsid" ] || continue
    if [ "$(session_auto_resume "$hsid")" = "1" ]; then
      echo "con-voyage-rate-limit-lookout: SKIP ${hsid} — showing Claude Code's auto-continue banner, will resume on its own"
      continue
    fi
    if budget_exceeded; then
      echo "con-voyage-rate-limit-lookout: time budget reached; remaining handoff(s) deferred to next run"
      break
    fi
    handoff_session "$hsid" "$reason"
  done
}

# mass_handoff_sweep REASON — hand off EVERY session, including ones showing
# the auto-continue banner. Only safe to call once the all-opencode override
# has been applied AND verified live (gc reload confirmed) — restarting a
# session IS the point once that's true, since it will respawn on opencode.
mass_handoff_sweep() {
  local reason="$1"
  printf '%s' "$ALL_ROWS" | while IFS=$'\x1f' read -r hsid _; do
    [ -n "$hsid" ] || continue
    if budget_exceeded; then
      echo "con-voyage-rate-limit-lookout: time budget reached; remaining handoff(s) deferred to next run"
      break
    fi
    handoff_session "$hsid" "$reason"
  done
}

# session_auto_resume SID -> "1" if SID was classified as limited AND
# showing the auto-continue banner this run, else "0". Pure-bash lookup
# (matches the rest of the script's IFS=$'\x1f' idiom) — deliberately not
# awk: `awk -F'\x1f'` depends on awk interpreting a hex escape in -F, which
# BSD awk (macOS's /usr/bin/awk) does not do, silently breaking field
# splitting (see the TRIP-line formatting fix below for the bug this caused).
session_auto_resume() {
  local target="$1" lsid _t _r lauto
  while IFS=$'\x1f' read -r lsid _t _r lauto; do
    [ "$lsid" = "$target" ] || continue
    if [ "$lauto" = "1" ]; then
      printf '1'
    else
      printf '0'
    fi
    return
  done <<< "$LIMITED_ROWS"
  printf '0'
}

# ---------------------------------------------------------------------------
# Pass 1: classify sessions, budget-bounded. A session left unpeeked this
# run (budget exhausted) is simply picked up next run.
# ---------------------------------------------------------------------------
LIMITED_ROWS=""     # lines: id SEP template SEP reset_hint SEP auto_resume
COMPACT_ROWS=""     # lines: id SEP template SEP pct
ALL_ROWS=""

while IFS=$'\x1f' read -r sid template provider; do
  [ -n "$sid" ] || continue
  ALL_ROWS="${ALL_ROWS}${sid}"$'\x1f'"${template}"$'\n'

  if budget_exceeded; then
    echo "con-voyage-rate-limit-lookout: time budget (${CV_LOOKOUT_TIME_BUDGET_SECONDS}s) reached during peek scan; remaining session(s) deferred to next run"
    break
  fi

  peek_text="$(run_with_timeout "$CV_LOOKOUT_PEEK_TIMEOUT_SECONDS" -- "$GC" --city "$GC_CITY" session peek "$sid" --lines "$CV_LOOKOUT_PEEK_LINES" 2>/dev/null)"
  peek_file="${CV_LOOKOUT_STATE_DIR}/sessions/${sid}.peek"
  printf '%s' "$peek_text" > "$peek_file" 2>/dev/null || continue

  classification="$(classify_peek "$peek_file")"
  limited="$(printf '%s' "$classification" | cut -d$'\x1f' -f1)"
  reset_hint="$(printf '%s' "$classification" | cut -d$'\x1f' -f2)"
  compact_pct="$(printf '%s' "$classification" | cut -d$'\x1f' -f3)"
  auto_resume="$(printf '%s' "$classification" | cut -d$'\x1f' -f4)"
  case "$compact_pct" in *[!0-9-]*|'') compact_pct="-1" ;; esac
  case "$auto_resume" in 1) : ;; *) auto_resume="0" ;; esac

  if [ "$limited" = "1" ]; then
    echo "con-voyage-rate-limit-lookout: LIMITED ${sid} (${template})${reset_hint:+ — ${reset_hint}}${auto_resume:+ }${auto_resume:+[auto-resume=${auto_resume}]}"
    LIMITED_ROWS="${LIMITED_ROWS}${sid}"$'\x1f'"${template}"$'\x1f'"${reset_hint}"$'\x1f'"${auto_resume}"$'\n'
  elif [ "$compact_pct" -ge 0 ] && [ "$compact_pct" -le "$CV_LOOKOUT_COMPACT_HANDOFF_PERCENT" ]; then
    COMPACT_ROWS="${COMPACT_ROWS}${sid}"$'\x1f'"${template}"$'\x1f'"${compact_pct}"$'\n'
  else
    echo "con-voyage-rate-limit-lookout: OK ${sid} (${template}, provider=${provider})"
  fi
done <<< "$SESSIONS_TSV"

# ---------------------------------------------------------------------------
# Pass 2: act. Breaker logic first (limits dominate), then compact handoffs.
# ---------------------------------------------------------------------------
if [ -n "$LIMITED_ROWS" ]; then
  trip=0
  [ "$BREAKER_STATE" != "open" ] && trip=1

  # Portable TRIP-list formatting — see session_auto_resume's comment above
  # for why this is a plain bash loop and not awk -F'\x1f'.
  limited_count=0
  limited_list=""
  first_reset_hint=""
  while IFS=$'\x1f' read -r lsid ltemplate lreset _la; do
    [ -n "$lsid" ] || continue
    limited_count=$((limited_count + 1))
    entry="${lsid}(${ltemplate})"
    [ -n "$lreset" ] && entry="${entry} reset:${lreset}"
    limited_list="${limited_list}${entry} "
    if [ -z "$first_reset_hint" ] && [ -n "$lreset" ]; then
      first_reset_hint="$lreset"
    fi
  done <<< "$LIMITED_ROWS"

  if [ "$trip" -eq 1 ]; then
    echo "con-voyage-rate-limit-lookout: TRIP — ${limited_count} claude session(s) limited: ${limited_list}"
  else
    echo "con-voyage-rate-limit-lookout: breaker already open — ${limited_count} session(s) still limited"
  fi

  now="$(now_epoch)"
  BREAKER_STATE="open"
  [ "$trip" -eq 1 ] && BREAKER_OPENED_AT="$now"
  BREAKER_LAST_LIMIT_AT="$now"
  if [ -n "$first_reset_hint" ]; then
    parsed="$(parse_reset_epoch "$first_reset_hint" "$now")"
    # fk-xtbtcw: a hint that parses to the past (or now) is a mis-parse, not
    # a real reset time -- ignore it rather than storing it on the breaker.
    if [ -n "$parsed" ] && [ "$parsed" -gt "$now" ]; then
      BREAKER_RESET_HINT_EPOCH="$parsed"
    fi
  fi

  # ESCALATE FIRST: breaker.state open is on disk before anything slow
  # (override apply, reload, mail, or handoff) is attempted. A crash or an
  # external timeout past this point still leaves the breaker open.
  breaker_write

  should_mail=0
  [ "$trip" -eq 1 ] && should_mail=1
  [ "$(( now - BREAKER_LAST_MAIL_AT ))" -ge "$CV_LOOKOUT_BREAKER_REMIND_SECONDS" ] && should_mail=1

  if [ "$CV_LOOKOUT_AUTO_FLIP" = "true" ]; then
    if [ "$BREAKER_FLIPPED" != "1" ]; then
      if spawn_probe_due; then
        echo "con-voyage-rate-limit-lookout: probing ${CV_LOOKOUT_FALLBACK_MEDIUM_POOL} (opencode/ACP) for spawn capability before flipping (gascity#5436 guard)"
        SPAWN_PROBE_LAST_AT="$now"
        if run_opencode_probe; then
          echo "con-voyage-rate-limit-lookout: spawn probe succeeded; applying all-opencode override (mechanism: managed city.toml block — see README/PR for why)"
          SPAWN_PROBE_VERIFIED="1"
          if apply_override; then
            BREAKER_FLIPPED="1"
            breaker_write
            echo "con-voyage-rate-limit-lookout: override applied; reloading city config"
            if reload_and_verify; then
              BREAKER_RELOAD_VERIFIED="1"
            else
              BREAKER_RELOAD_VERIFIED="0"
              echo "con-voyage-rate-limit-lookout: WARNING: reload not verified; will retry next run" >&2
            fi
          else
            echo "con-voyage-rate-limit-lookout: WARNING: override apply failed; staying unflipped, will retry next run" >&2
          fi
        else
          echo "con-voyage-rate-limit-lookout: WARNING: spawn probe failed — ${CV_LOOKOUT_FALLBACK_MEDIUM_POOL} (opencode/ACP) cannot spawn right now (gastownhall/gascity#5436); NOT flipping, keeping current claude providers" >&2
          SPAWN_PROBE_VERIFIED="0"
          SPAWN_PROBE_NEXT_AT=$(( now + CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS ))
        fi
        breaker_write
        should_mail=1
      else
        echo "con-voyage-rate-limit-lookout: spawn probe backoff active — next attempt in $(( SPAWN_PROBE_NEXT_AT - now ))s; NOT flipping yet"
      fi
    elif [ "$BREAKER_RELOAD_VERIFIED" != "1" ]; then
      echo "con-voyage-rate-limit-lookout: retrying reload verification for an already-applied override"
      if reload_and_verify; then
        BREAKER_RELOAD_VERIFIED="1"
        breaker_write
      fi
    fi

    if [ "$should_mail" -eq 1 ]; then
      if [ "$BREAKER_FLIPPED" = "1" ]; then
        if send_flip_mail "open"; then
          BREAKER_LAST_MAIL_AT="$now"
        fi
      else
        if send_flip_mail "blocked"; then
          BREAKER_LAST_MAIL_AT="$now"
        fi
      fi
      breaker_write
    fi

    # Restarting sessions onto opencode is only safe once the override is
    # BOTH applied and verified live (gc reload confirmed) — never assume a
    # flip that hasn't cleared both gates actually took effect. Otherwise,
    # fall back to the same context-preserving sweep on the CURRENT provider
    # used when auto-flip is off (covers: blocked-by-probe, and
    # applied-but-not-yet-verified).
    if [ "$BREAKER_FLIPPED" = "1" ] && [ "$BREAKER_RELOAD_VERIFIED" = "1" ]; then
      mass_handoff_sweep "claude usage limit observed fleet-wide — all-opencode fallback engaged, respawning on opencode"
    else
      selective_handoff_sweep "claude usage limit observed fleet-wide — all-opencode fallback blocked or not yet verified (gascity#5436 guard), preserving context on current provider"
    fi

  else
    if [ "$should_mail" -eq 1 ]; then
      mail_body="The con-voyage rate-limit lookout observed claude usage/rate limits. The circuit breaker is OPEN — switch dispatch to all-opencode mode.

Limited sessions: ${limited_list:-unknown}

Fallback pools (claude equivalency):
  - opus-class   (large / critical / intensive) -> ${CV_LOOKOUT_FALLBACK_LARGE_POOL}
  - sonnet-class (medium / standard workers)    -> ${CV_LOOKOUT_FALLBACK_MEDIUM_POOL}
  - haiku-class  (small / rudimentary)          -> ${CV_LOOKOUT_FALLBACK_SMALL_POOL}

What to do (see the con-voyage-orchestration fragment, 'All-opencode fallback mode'):
  1. Re-sling in-flight claude beads to the fallback pools:
     gc sling <rig>/${CV_LOOKOUT_FALLBACK_LARGE_POOL} <bead> --nudge   # opus-class
     gc sling <rig>/${CV_LOOKOUT_FALLBACK_MEDIUM_POOL} <bead> --nudge  # sonnet-class
     gc sling <rig>/${CV_LOOKOUT_FALLBACK_SMALL_POOL} <bead> --nudge   # haiku-class
  2. Prefer fallback-pool targets for all NEW work until the all-clear.
  3. For a durable switch, point city.toml [agent_defaults].provider at
     ${CV_LOOKOUT_FALLBACK_MEDIUM_POOL} and the mayor patch at
     ${CV_LOOKOUT_FALLBACK_LARGE_POOL} until the breaker closes. (A city can
     also opt into CV_LOOKOUT_AUTO_FLIP=true so the lookout does this step
     itself, gated on a live spawn-capability probe — see README 'Model
     tiers'.)

Before bulk re-slinging: confirm the fallback pool can actually spawn a
session first. gc 1.4.2 has an open bug (gastownhall/gascity#5436) where the
session supervisor can silently fail to route opencode/ACP-backed sessions
even when config looks correct — a quiet 'requires ACP transport but the
session provider cannot route ACP sessions (skipping)' in supervisor.log,
not a loud error. Re-slinging onto a pool that can't spawn just idles work
instead of running it.

Claude usage (trailing ${CV_LOOKOUT_USAGE_WINDOW_MINUTES}m): ${USAGE_SUMMARY:-no model facts recorded}

The breaker auto-closes after ${CV_LOOKOUT_BREAKER_RESET_SECONDS}s with no limit signature; you will get an all-clear mail here."
      if "$GC" --city "$GC_CITY" mail send "$CV_LOOKOUT_ESCALATE_TARGET" \
        -s "con-voyage rate-limit lookout: claude limit circuit breaker OPEN — switch to all-opencode mode" \
        -m "$mail_body" \
        2>&1; then
        echo "con-voyage-rate-limit-lookout: escalated to ${CV_LOOKOUT_ESCALATE_TARGET}"
        BREAKER_LAST_MAIL_AT="$now"
      else
        echo "con-voyage-rate-limit-lookout: WARNING: escalation mail to ${CV_LOOKOUT_ESCALATE_TARGET} failed; will retry next cycle" >&2
      fi
      breaker_write
    fi

    # item 3: skip sessions that will auto-resume on their own; restarting
    # them only loses the in-flight turn and re-primes context.
    selective_handoff_sweep "claude usage limit observed fleet-wide"
  fi

elif [ "$BREAKER_STATE" = "open" ]; then
  now="$(now_epoch)"
  if [ "$CV_LOOKOUT_AUTO_FLIP" = "true" ] && [ "$BREAKER_FLIPPED" = "1" ]; then
    # Reset-time + live-probe gated clear, with a minimum dwell and a probe
    # backoff — NOT "no claude sessions remain," which would immediately
    # flip back right after a flip drains the claude-backed session list and
    # oscillate.
    dwell_left=$(( BREAKER_OPENED_AT + CV_LOOKOUT_FLIP_DWELL_SECONDS - now ))
    if [ "$dwell_left" -gt 0 ]; then
      echo "con-voyage-rate-limit-lookout: flipped — dwell window ${dwell_left}s remaining before any clear check"
    elif [ "$BREAKER_RESET_HINT_EPOCH" -gt 0 ] && [ "$now" -lt "$BREAKER_RESET_HINT_EPOCH" ]; then
      echo "con-voyage-rate-limit-lookout: flipped — waiting for parsed reset time ($(( BREAKER_RESET_HINT_EPOCH - now ))s remaining)"
    elif [ "$now" -lt "$BREAKER_NEXT_PROBE_AT" ]; then
      echo "con-voyage-rate-limit-lookout: flipped — next clear probe in $(( BREAKER_NEXT_PROBE_AT - now ))s (backoff)"
    else
      echo "con-voyage-rate-limit-lookout: flipped — probing claude to check for all-clear"
      BREAKER_LAST_PROBE_AT="$now"
      if run_claude_probe; then
        echo "con-voyage-rate-limit-lookout: probe succeeded — reverting all-opencode override"
        if remove_override; then
          BREAKER_STATE="closed"
          BREAKER_FLIPPED="0"
          BREAKER_RELOAD_VERIFIED="0"
          BREAKER_LAST_LIMIT_AT="0"
          BREAKER_RESET_HINT_EPOCH="0"
          BREAKER_NEXT_PROBE_AT="0"
          breaker_write
          send_flip_mail "clear"
        else
          echo "con-voyage-rate-limit-lookout: WARNING: override revert failed; staying flipped, will retry" >&2
          BREAKER_NEXT_PROBE_AT=$(( now + CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS ))
          breaker_write
        fi
      else
        echo "con-voyage-rate-limit-lookout: probe failed — still limited, staying flipped"
        BREAKER_NEXT_PROBE_AT=$(( now + CV_LOOKOUT_FLIP_REPROBE_BACKOFF_SECONDS ))
        breaker_write
      fi
    fi
  else
    # Not flipped (auto-flip off, or on but never successfully applied —
    # nothing to revert): original reset-window clear is safe as-is.
    if [ "$(( now - BREAKER_LAST_LIMIT_AT ))" -ge "$CV_LOOKOUT_BREAKER_RESET_SECONDS" ]; then
      echo "con-voyage-rate-limit-lookout: CLEAR — no limit signature for ${CV_LOOKOUT_BREAKER_RESET_SECONDS}s; breaker closed"
      BREAKER_STATE="closed"
      BREAKER_LAST_LIMIT_AT="0"
      breaker_write
      if "$GC" --city "$GC_CITY" mail send "$CV_LOOKOUT_ESCALATE_TARGET" \
        -s "con-voyage rate-limit lookout: breaker closed — claude tiers clear" \
        -m "No claude usage/rate-limit signature has been observed for ${CV_LOOKOUT_BREAKER_RESET_SECONDS}s. The circuit breaker is CLOSED — safe to resume normal claude-tier dispatch (opus/sonnet) for new work.

Claude usage (trailing ${CV_LOOKOUT_USAGE_WINDOW_MINUTES}m): ${USAGE_SUMMARY:-no model facts recorded}" \
        2>&1; then
        echo "con-voyage-rate-limit-lookout: all-clear mailed to ${CV_LOOKOUT_ESCALATE_TARGET}"
      else
        echo "con-voyage-rate-limit-lookout: WARNING: all-clear mail to ${CV_LOOKOUT_ESCALATE_TARGET} failed" >&2
      fi
    else
      echo "con-voyage-rate-limit-lookout: breaker open — clean this run, $(( BREAKER_LAST_LIMIT_AT + CV_LOOKOUT_BREAKER_RESET_SECONDS - now ))s left in reset window"
    fi
  fi
fi

# Proactive compact handoffs — only while the breaker is closed. When the
# breaker is open the fleet has already been handed off (or, unflipped,
# selectively handed off) this run; piling on more restarts is churn.
if [ "$BREAKER_STATE" != "open" ] && [ -z "$LIMITED_ROWS" ] && [ "$CV_LOOKOUT_COMPACT_HANDOFF_PERCENT" -gt 0 ] && [ -n "$COMPACT_ROWS" ]; then
  printf '%s' "$COMPACT_ROWS" | while IFS=$'\x1f' read -r csid _ cpct; do
    [ -n "$csid" ] || continue
    if budget_exceeded; then
      echo "con-voyage-rate-limit-lookout: time budget reached; remaining compact handoff(s) deferred to next run"
      break
    fi
    handoff_session "$csid" "context at ${cpct}% — proactive handoff ahead of auto-compact"
  done
fi

# A clean run still stamps the breaker file so operators (and tests) can tell
# "lookout ran and the breaker is closed" apart from "lookout never ran".
if [ "$BREAKER_STATE" != "open" ] && [ -z "$LIMITED_ROWS" ]; then
  breaker_write
fi

exit 0
