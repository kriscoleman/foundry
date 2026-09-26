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
#     provider ∈ CV_LOOKOUT_CLAUDE_PROVIDERS) and `gc session peek` each one.
#   - COMPACT RISK (breaker closed): a session advertising ≤
#     CV_LOOKOUT_COMPACT_HANDOFF_PERCENT context remaining gets a
#     `gc handoff --target` — mail-to-self + controller restart, so it
#     resumes fresh with its own handoff summary waiting. Per-session
#     cooldown (CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS) prevents kill-loops.
#   - USAGE LIMIT (any run): a session showing a limit signature OPENS the
#     circuit breaker: every active claude session is handed off (the fleet
#     restarts with context preserved for when limits clear) and the mayor
#     gets a structured escalation mail naming the all-opencode fallback
#     pools (CV_LOOKOUT_FALLBACK_{LARGE,MEDIUM,SMALL}_POOL, matching the
#     opus/sonnet/haiku claude tiers) so it can switch dispatch to
#     all-opencode mode. While the breaker is open the mayor is re-mailed at
#     most every CV_LOOKOUT_BREAKER_REMIND_SECONDS.
#   - ALL-CLEAR: no limit signature observed for a full
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
#   - Everything is fail-safe: a failed handoff/mail warns and continues;
#     the order controller retries non-zero exits, so only preflight
#     failures (no gc, no python3) exit non-zero.
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
#   CV_LOOKOUT_COMPACT_HANDOFF_PERCENT  Hand off a session when its
#                                       advertised context-remaining drops
#                                       to this percent or below. 0 disables
#                                       proactive compact handoffs.
#                                       Default: 15
#   CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS Minimum seconds between two handoffs
#                                       of the SAME session. Default: 1800
#   CV_LOOKOUT_BREAKER_RESET_SECONDS    Limit-free window before an open
#                                       breaker closes (all-clear). Default: 3600
#   CV_LOOKOUT_BREAKER_REMIND_SECONDS   Minimum seconds between repeat mayor
#                                       escalations while open. Default: 1800
#   CV_LOOKOUT_ESCALATE_TARGET          Mail recipient for breaker events.
#                                       Default: mayor
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
#
# Exit codes:
#   0 — completed (actions taken or not)
#   Non-zero — fatal setup error (gc/python3 missing)
#
# Requires: bash 4+, gc CLI, python3.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_LOOKOUT_STATE_DIR="${CV_LOOKOUT_STATE_DIR:-${GC_CITY}/.gc/con-voyage/lookout}"
CV_LOOKOUT_CLAUDE_PROVIDERS="${CV_LOOKOUT_CLAUDE_PROVIDERS:-claude,opus,sonnet}"
CV_LOOKOUT_PEEK_LINES="${CV_LOOKOUT_PEEK_LINES:-80}"
CV_LOOKOUT_COMPACT_HANDOFF_PERCENT="${CV_LOOKOUT_COMPACT_HANDOFF_PERCENT:-15}"
CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS="${CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS:-1800}"
CV_LOOKOUT_BREAKER_RESET_SECONDS="${CV_LOOKOUT_BREAKER_RESET_SECONDS:-3600}"
CV_LOOKOUT_BREAKER_REMIND_SECONDS="${CV_LOOKOUT_BREAKER_REMIND_SECONDS:-1800}"
CV_LOOKOUT_ESCALATE_TARGET="${CV_LOOKOUT_ESCALATE_TARGET:-mayor}"
CV_LOOKOUT_FALLBACK_LARGE_POOL="${CV_LOOKOUT_FALLBACK_LARGE_POOL:-kimi-k3}"
CV_LOOKOUT_FALLBACK_MEDIUM_POOL="${CV_LOOKOUT_FALLBACK_MEDIUM_POOL:-glm-5p3-flash}"
CV_LOOKOUT_FALLBACK_SMALL_POOL="${CV_LOOKOUT_FALLBACK_SMALL_POOL:-minimax-m3}"
CV_LOOKOUT_USAGE_FILE="${CV_LOOKOUT_USAGE_FILE:-${GC_CITY}/.gc/usage.jsonl}"
CV_LOOKOUT_USAGE_WINDOW_MINUTES="${CV_LOOKOUT_USAGE_WINDOW_MINUTES:-60}"

# A malformed override must never silently break the numeric gates below —
# same fail-safe coercion posture as con-voyage-review-watchdog.sh.
case "$CV_LOOKOUT_PEEK_LINES" in                  *[!0-9]*|'') CV_LOOKOUT_PEEK_LINES="80" ;; esac
case "$CV_LOOKOUT_COMPACT_HANDOFF_PERCENT" in     *[!0-9]*|'') CV_LOOKOUT_COMPACT_HANDOFF_PERCENT="15" ;; esac
case "$CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS" in    *[!0-9]*|'') CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS="1800" ;; esac
case "$CV_LOOKOUT_BREAKER_RESET_SECONDS" in       *[!0-9]*|'') CV_LOOKOUT_BREAKER_RESET_SECONDS="3600" ;; esac
case "$CV_LOOKOUT_BREAKER_REMIND_SECONDS" in      *[!0-9]*|'') CV_LOOKOUT_BREAKER_REMIND_SECONDS="1800" ;; esac
case "$CV_LOOKOUT_USAGE_WINDOW_MINUTES" in        *[!0-9]*|'') CV_LOOKOUT_USAGE_WINDOW_MINUTES="60" ;; esac

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

echo "con-voyage-rate-limit-lookout: claude_providers=${CV_LOOKOUT_CLAUDE_PROVIDERS} compact<=${CV_LOOKOUT_COMPACT_HANDOFF_PERCENT}% reset=${CV_LOOKOUT_BREAKER_RESET_SECONDS}s escalate=${CV_LOOKOUT_ESCALATE_TARGET} fallback=${CV_LOOKOUT_FALLBACK_LARGE_POOL},${CV_LOOKOUT_FALLBACK_MEDIUM_POOL},${CV_LOOKOUT_FALLBACK_SMALL_POOL}"

mkdir -p "${CV_LOOKOUT_STATE_DIR}/sessions" || {
  echo "con-voyage-rate-limit-lookout: ERROR: cannot create state dir ${CV_LOOKOUT_STATE_DIR}" >&2
  exit 1
}

NOW_EPOCH="$(python3 -c 'import time; print(int(time.time()))')"

# ---------------------------------------------------------------------------
# State helpers — plain key=value files, epoch integers, coerced on read.
# ---------------------------------------------------------------------------
BREAKER_FILE="${CV_LOOKOUT_STATE_DIR}/breaker.state"

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

breaker_write() {
  # breaker_write STATE OPENED_AT LAST_LIMIT_AT LAST_MAIL_AT
  printf 'state=%s\nopened_at=%s\nlast_limit_seen_at=%s\nlast_escalated_at=%s\n' \
    "$1" "$2" "$3" "$4" > "$BREAKER_FILE" \
    || echo "con-voyage-rate-limit-lookout: WARNING: failed to write ${BREAKER_FILE}" >&2
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
  # A city with zero claude sessions cannot be rate-limited; if the breaker
  # was left open (e.g. sessions closed before the window elapsed), close it
  # out rather than stranding the fleet in fallback mode.
  if [ "$BREAKER_STATE" = "open" ]; then
    echo "con-voyage-rate-limit-lookout: CLEAR — breaker open but no claude sessions remain; closing"
    breaker_write closed "$BREAKER_OPENED_AT" 0 "$NOW_EPOCH"
    "$GC" --city "$GC_CITY" mail send "$CV_LOOKOUT_ESCALATE_TARGET" \
      -s "con-voyage rate-limit lookout: breaker closed (no claude sessions remain)" \
      -m "The usage-limit circuit breaker is CLOSED. No active claude-backed sessions remain, so no limit pressure is possible. Safe to resume normal claude-tier dispatch." \
      >/dev/null 2>&1 \
      || echo "con-voyage-rate-limit-lookout: WARNING: all-clear mail to ${CV_LOOKOUT_ESCALATE_TARGET} failed" >&2
  fi
  exit 0
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
#   limited     — a usage/rate-limit signature is showing
#   reset_hint  — the advertised reset time, when Claude Code prints one
#   compact_pct — advertised context remaining before auto-compact (-1 = n/a)
# ---------------------------------------------------------------------------
classify_peek() {
  # classify_peek PEEK_TEXT_FILE -> SEP-joined "limited SEP reset_hint SEP compact_pct"
  python3 -c "
import re, sys
SEP = '\x1f'
try:
    text = open(sys.argv[1], 'r', errors='replace').read()
except Exception:
    text = ''
limited_patterns = [
    r'usage limit reached',
    r'limit will reset',
    r'rate limit reached',
    r'hit your\b.{0,40}\blimit',
    r'api error:\s*429',
    r'\boverloaded\b',
]
limited = any(re.search(p, text, re.IGNORECASE) for p in limited_patterns)
reset_hint = ''
m = re.search(r'limit will reset\s*(?:at|around)?\s*([^\n.]{1,40})', text, re.IGNORECASE)
if m:
    reset_hint = m.group(1).strip()
compact_pct = -1
m = re.search(r'auto-compact[^0-9]{0,20}(\d{1,3})\s*%', text, re.IGNORECASE)
if m:
    compact_pct = int(m.group(1))
elif re.search(r'context low', text, re.IGNORECASE):
    compact_pct = 0
print(SEP.join(['1' if limited else '0', reset_hint, str(compact_pct)]))
" "$1"
}

# handoff_session SESSION_ID REASON — throttled gc handoff --target.
handoff_session() {
  local sid="$1" reason="$2"
  local sfile="${CV_LOOKOUT_STATE_DIR}/sessions/${sid}.state"
  local last
  last="$(int_or_zero "$(state_get "$sfile" last_handoff_at)")"
  if [ "$((NOW_EPOCH - last))" -lt "$CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS" ]; then
    echo "con-voyage-rate-limit-lookout: SKIP ${sid} — handed off $((NOW_EPOCH - last))s ago (cooldown ${CV_LOOKOUT_HANDOFF_COOLDOWN_SECONDS}s)"
    return 0
  fi
  if "$GC" --city "$GC_CITY" handoff --target "$sid" "con-voyage-rate-limit-lookout: ${reason}" 2>&1; then
    printf 'last_handoff_at=%s\n' "$NOW_EPOCH" > "$sfile" 2>/dev/null || true
    echo "con-voyage-rate-limit-lookout: HANDOFF ${sid} — ${reason}"
  else
    echo "con-voyage-rate-limit-lookout: WARNING: handoff failed for ${sid} (${reason}); will retry next cycle" >&2
  fi
}

# ---------------------------------------------------------------------------
# Pass 1: classify every session.
# ---------------------------------------------------------------------------
LIMITED_ROWS=""     # lines: id SEP template SEP reset_hint
COMPACT_ROWS=""     # lines: id SEP template SEP pct
ALL_ROWS=""

while IFS=$'\x1f' read -r sid template provider; do
  [ -n "$sid" ] || continue
  ALL_ROWS="${ALL_ROWS}${sid}"$'\x1f'"${template}"$'\n'

  peek_text="$("$GC" --city "$GC_CITY" session peek "$sid" --lines "$CV_LOOKOUT_PEEK_LINES" 2>/dev/null)"
  peek_file="${CV_LOOKOUT_STATE_DIR}/sessions/${sid}.peek"
  printf '%s' "$peek_text" > "$peek_file" 2>/dev/null || continue

  classification="$(classify_peek "$peek_file")"
  limited="$(printf '%s' "$classification" | cut -d$'\x1f' -f1)"
  reset_hint="$(printf '%s' "$classification" | cut -d$'\x1f' -f2)"
  compact_pct="$(printf '%s' "$classification" | cut -d$'\x1f' -f3)"
  case "$compact_pct" in *[!0-9-]*|'') compact_pct="-1" ;; esac

  if [ "$limited" = "1" ]; then
    echo "con-voyage-rate-limit-lookout: LIMITED ${sid} (${template})${reset_hint:+ — ${reset_hint}}"
    LIMITED_ROWS="${LIMITED_ROWS}${sid}"$'\x1f'"${template}"$'\x1f'"${reset_hint}"$'\n'
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
  limited_count="$(printf '%s' "$LIMITED_ROWS" | grep -c . || true)"
  limited_list="$(printf '%s' "$LIMITED_ROWS" | awk -F'\x1f' '{printf "%s(%s)%s ", $1, $2, ($3 != "" ? " reset:" $3 : "")}')"

  if [ "$BREAKER_STATE" != "open" ]; then
    echo "con-voyage-rate-limit-lookout: TRIP — ${limited_count} claude session(s) limited: ${limited_list}"
  else
    echo "con-voyage-rate-limit-lookout: breaker already open — ${limited_count} session(s) still limited"
  fi

  # Fleet-wide handoff: every active claude session restarts with its
  # context preserved, ready to resume (or be re-routed) when limits clear.
  # Per-session cooldown still applies so a fresh handoff is never killed
  # mid-restart.
  printf '%s' "$ALL_ROWS" | while IFS=$'\x1f' read -r hsid _; do
    [ -n "$hsid" ] || continue
    handoff_session "$hsid" "claude usage limit observed fleet-wide — all-opencode fallback engaged"
  done

  # Escalate to the mayor on trip, then at most every REMIND seconds.
  if [ "$BREAKER_STATE" != "open" ] || [ "$((NOW_EPOCH - BREAKER_LAST_MAIL_AT))" -ge "$CV_LOOKOUT_BREAKER_REMIND_SECONDS" ]; then
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
     ${CV_LOOKOUT_FALLBACK_LARGE_POOL} until the breaker closes.

Claude usage (trailing ${CV_LOOKOUT_USAGE_WINDOW_MINUTES}m): ${USAGE_SUMMARY:-no model facts recorded}

The breaker auto-closes after ${CV_LOOKOUT_BREAKER_RESET_SECONDS}s with no limit signature; you will get an all-clear mail here."
    if "$GC" --city "$GC_CITY" mail send "$CV_LOOKOUT_ESCALATE_TARGET" \
      -s "con-voyage rate-limit lookout: claude limit circuit breaker OPEN — switch to all-opencode mode" \
      -m "$mail_body" \
      2>&1; then
      echo "con-voyage-rate-limit-lookout: escalated to ${CV_LOOKOUT_ESCALATE_TARGET}"
      breaker_write open "${BREAKER_OPENED_AT:-$NOW_EPOCH}" "$NOW_EPOCH" "$NOW_EPOCH"
    else
      echo "con-voyage-rate-limit-lookout: WARNING: escalation mail to ${CV_LOOKOUT_ESCALATE_TARGET} failed; will retry next cycle" >&2
      # Keep the observed limit timestamp even when the mail fails, so the
      # reset window still measures from the last SEEN limit.
      breaker_write open "${BREAKER_OPENED_AT:-$NOW_EPOCH}" "$NOW_EPOCH" "$BREAKER_LAST_MAIL_AT"
    fi
  else
    breaker_write open "$BREAKER_OPENED_AT" "$NOW_EPOCH" "$BREAKER_LAST_MAIL_AT"
  fi

elif [ "$BREAKER_STATE" = "open" ]; then
  # No limit showing this run. Close only after a full reset window clean.
  if [ "$((NOW_EPOCH - BREAKER_LAST_LIMIT_AT))" -ge "$CV_LOOKOUT_BREAKER_RESET_SECONDS" ]; then
    echo "con-voyage-rate-limit-lookout: CLEAR — no limit signature for ${CV_LOOKOUT_BREAKER_RESET_SECONDS}s; breaker closed"
    breaker_write closed "$BREAKER_OPENED_AT" 0 "$NOW_EPOCH"
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
    echo "con-voyage-rate-limit-lookout: breaker open — clean this run, $((BREAKER_LAST_LIMIT_AT + CV_LOOKOUT_BREAKER_RESET_SECONDS - NOW_EPOCH))s left in reset window"
  fi
fi

# Proactive compact handoffs — only while the breaker is closed. When the
# breaker is open the fleet has already been handed off wholesale; piling on
# more restarts is churn.
if [ "$BREAKER_STATE" != "open" ] && [ -z "$LIMITED_ROWS" ] && [ "$CV_LOOKOUT_COMPACT_HANDOFF_PERCENT" -gt 0 ] && [ -n "$COMPACT_ROWS" ]; then
  printf '%s' "$COMPACT_ROWS" | while IFS=$'\x1f' read -r csid _ cpct; do
    [ -n "$csid" ] || continue
    handoff_session "$csid" "context at ${cpct}% — proactive handoff ahead of auto-compact"
  done
fi

# A clean run still stamps the breaker file so operators (and tests) can tell
# "lookout ran and the breaker is closed" apart from "lookout never ran".
if [ "$BREAKER_STATE" != "open" ] && [ -z "$LIMITED_ROWS" ]; then
  breaker_write closed "$BREAKER_OPENED_AT" "$BREAKER_LAST_LIMIT_AT" "$BREAKER_LAST_MAIL_AT"
fi

exit 0
