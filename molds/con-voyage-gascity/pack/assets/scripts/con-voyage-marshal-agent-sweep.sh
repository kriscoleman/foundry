#!/usr/bin/env bash
# con-voyage-marshal-agent-sweep.sh — Marshal's deterministic agent-liveness
# tier (fk-12m3 / foundry#47, fk-d0ioj2). Ports the "no step change in N
# minutes" stall-detection half of the mayor's ad hoc watch-stall.sh into a
# city-wide, unconditional, single-shot cooldown order.
#
# WHAT CHANGED FROM THE SOURCE: watch-stall.sh measures staleness indirectly,
# via "no step bead under this ONE con-voyage root has changed state in N
# minutes" for a root a mayor session was told to watch. This order measures
# agent liveness directly instead: every active implementation/review agent
# session's own `last_active` timestamp from `gc session list --json`,
# city-wide, no args, no per-run wiring needed. A session going quiet is
# detected the same tick regardless of whether its current bead happens to
# be mid-step (watch-stall.sh's own indirect signal would miss that case
# until the step bead itself next changes).
#
# NOT A DUPLICATE OF con-voyage-askuserquestion-watchdog (fk-o9ntx): that
# order flags a session CURRENTLY showing an interactive-prompt stall (the
# `cv_text_has_interactive_prompt_stall` glyph match on a session's rendered
# pane). This order flags the opposite and harder-to-notice case — a session
# that has gone quiet with NO prompt visible. A session that peeks as
# currently prompt-stalled is explicitly skipped here so the two orders
# never double-report the same live incident.
#
# WHAT IT DOES, each tick:
#   1. Gate on the marshal assistant flag (cv_assistant_enabled marshal).
#   2. List every active session (gc session list --json --state active),
#      excluding the mayor and any session whose template does not look like
#      an implementation or review agent (template name containing
#      "implement" or "review", case-insensitive — covers gc.implementation-
#      worker, gc.implementation-reviewer, gc.design-implementation-reviewer,
#      con-voyage.cv-*-reviewer, etc.).
#   3. For each candidate, peek its pane and skip it if it is currently
#      showing an interactive-prompt stall (askq-watchdog's job).
#   4. Otherwise compute minutes-since-last-active from the session's own
#      `last_active` field. A session quiet for at least
#      CV_MARSHAL_AGENT_STALL_MINUTES is flagged — but only once per quiet
#      episode: persisted per-session state is cleared the moment
#      `last_active` moves again, so a recovered session can be flagged
#      again on its next distinct quiet episode without needing a human to
#      clear anything by hand.
#   5. One digest mail per tick aggregating every flagged session, only when
#      at least one was flagged.
#
# Environment / configuration (all optional with sane defaults):
#   GC                                  Path to the gc binary (default: gc)
#   GC_CITY                             City root passed to gc (default: .)
#   CV_MARSHAL_AGENT_STALL_MINUTES      Quiet-session threshold. Default: 30.
#   CV_MARSHAL_ESCALATE_TARGET          Digest mail recipient. Default: mayor.
#   CV_LENS_STORE_TIMEOUT_SECONDS       Bound on each store/mail/peek call. Default: 30.
#   CV_STATE_DIR                        Override the state directory (default:
#                                       <rig_root>/.gc/con-voyage-marshal-agent-sweep).
#
# Exit codes:
#   0 — completed (flagged some, all, or none of the sessions found)
#   Non-zero — fatal setup error (gc/python3 missing)
#
# Requires: bash 4+, gc CLI, python3.
#
# Run:  con-voyage-marshal-agent-sweep.sh

# ---------------------------------------------------------------------------
# bash 4+ preflight.
#
# This pack requires bash 4+ (mapfile, associative arrays, ${var^^}) — see
# con-voyage-lib.sh's header. macOS ships bash 3.2 as /bin/bash, and
# `#!/usr/bin/env bash` resolves to it whenever /bin precedes a newer bash on
# PATH — which is the default even AFTER `brew install bash`, because
# /opt/homebrew/bin is typically appended, not prepended.
#
# Without this guard the failure is both silent and actively misleading:
#   * `mapfile` reports "command not found" and leaves its target array UNSET,
#     so the next reference dies on `unbound variable` under `set -u` — the
#     order just fails every tick and `gc doctor` says only "N order(s)
#     failing repeatedly (advisory)".
#   * `declare -A map` is rejected, but the following `map[key]=value` still
#     "succeeds" as ARITHMETIC indexing on a normal array, so every key
#     collapses onto index 0. That path produces confidently WRONG results
#     rather than stopping.
#
# So: re-exec under a capable bash when one is installed, else fail fast with
# an actionable message instead of either failure mode above.
# ---------------------------------------------------------------------------
if [ -z "${CV_BASH_REEXEC:-}" ] && [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  for _cv_bash in /opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash /usr/bin/bash; do
    [ -x "$_cv_bash" ] || continue
    _cv_major="$("$_cv_bash" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
    case "$_cv_major" in ''|*[!0-9]*) continue ;; esac
    [ "$_cv_major" -ge 4 ] || continue
    CV_BASH_REEXEC=1 exec "$_cv_bash" "$0" "$@"
  done
  echo "${0##*/}: con-voyage requires bash 4+, but this is bash ${BASH_VERSION:-unknown}." >&2
  echo "${0##*/}: macOS ships bash 3.2 as /bin/bash. Install a newer bash:" >&2
  echo "${0##*/}:   brew install bash" >&2
  exit 78
fi

set -uo pipefail

GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_MARSHAL_AGENT_STALL_MINUTES="${CV_MARSHAL_AGENT_STALL_MINUTES:-30}"
CV_MARSHAL_ESCALATE_TARGET="${CV_MARSHAL_ESCALATE_TARGET:-mayor}"
CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"

case "$CV_MARSHAL_AGENT_STALL_MINUTES" in
  *[!0-9]*|'') CV_MARSHAL_AGENT_STALL_MINUTES="30" ;;
esac
case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
esac

if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-marshal-agent-sweep: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-marshal-agent-sweep: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

MARSHAL_ENABLED="$(cv_assistant_enabled marshal)"
if [ "$MARSHAL_ENABLED" != "true" ]; then
  echo "con-voyage-marshal-agent-sweep: disabled (marshal assistant flag is not true)"
  exit 0
fi

CV_STATE_DIR="${CV_STATE_DIR:-$(cv_default_rig_root)/.gc/con-voyage-marshal-agent-sweep}"
mkdir -p "$CV_STATE_DIR"

# fk-9oigyg review LOW-2: bounded, best-effort cleanup of per-session flag
# files whose session has long since disappeared. Never load-bearing.
CV_MARSHAL_STATE_TTL_DAYS="${CV_MARSHAL_STATE_TTL_DAYS:-30}"
cv_marshal_prune_state_dir "$CV_STATE_DIR" "$CV_MARSHAL_STATE_TTL_DAYS"

FLAGGED_LINES=""
add_flag() {
  if [ -z "$FLAGGED_LINES" ]; then
    FLAGGED_LINES="$1"
  else
    FLAGGED_LINES="${FLAGGED_LINES}"$'\n'"$1"
  fi
}

# fk-i1yas2 BLOCKING-4: a session's flagged-episode marker is staged here and
# only committed once the digest mail below is confirmed sent, so a failed
# send doesn't silently retire the still-unreported quiet episode.
declare -A PENDING_FLAG_WRITES=()

SESSIONS_JSON="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" session list --json --state active 2>/dev/null)" || SESSIONS_JSON=""

if [ -z "${SESSIONS_JSON// /}" ]; then
  echo "con-voyage-marshal-agent-sweep: no active sessions this tick"
  exit 0
fi

CANDIDATES_TSV="$(printf '%s' "$SESSIONS_JSON" | python3 -c "
import json, sys
SEP = '\x1f'
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    sessions = []
for item in sessions:
    if not isinstance(item, dict):
        continue
    sid = item.get('id') or ''
    template = (item.get('template') or '').lower()
    if not sid or not template:
        continue
    if 'mayor' in template:
        continue
    if 'implement' not in template and 'review' not in template:
        continue
    last_active = item.get('last_active') or ''
    row = [sid, item.get('template') or '', last_active]
    row = [str(f).replace('\n', ' ').replace('\r', ' ').replace(SEP, ' ') for f in row]
    print(SEP.join(row))
" 2>/dev/null)"

if [ -z "${CANDIDATES_TSV// /}" ]; then
  echo "con-voyage-marshal-agent-sweep: no implementation/review agent sessions this tick"
  exit 0
fi

while IFS=$'\x1f' read -r sid template last_active; do
  [ -n "${sid// /}" ] || continue

  PEEK="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" session peek "$sid" 2>/dev/null)" || PEEK=""
  if cv_text_has_interactive_prompt_stall "$PEEK"; then
    echo "con-voyage-marshal-agent-sweep: ${sid} (${template}) is prompt-stalled — leaving to askuserquestion-watchdog"
    continue
  fi

  quiet_minutes="$(cv_minutes_since_iso8601 "$last_active")"
  [ -n "$quiet_minutes" ] || continue

  # fk-9oigyg review LOW-1: sanitize before using the session id as a path
  # component, so a session id containing a path separator can never resolve
  # a flag-file read/write outside CV_STATE_DIR.
  sid_safe="$(cv_path_safe_component "$sid")"
  flagged_for_file="${CV_STATE_DIR}/${sid_safe}.flagged_for"
  if [ "$quiet_minutes" -lt "$CV_MARSHAL_AGENT_STALL_MINUTES" ]; then
    # Recently active: clear any flag tied to a now-stale last_active so a
    # LATER, distinct quiet episode (session goes quiet again after this)
    # can be flagged again without needing a human to clear anything.
    rm -f "$flagged_for_file"
    echo "con-voyage-marshal-agent-sweep: ${sid} (${template}) active, last_active=${last_active}"
    continue
  fi

  # Quiet past threshold: flag once PER DISTINCT last_active value (i.e. once
  # per quiet episode), not once per tick and not deferred to a second tick —
  # an already-stale session must be caught the first time this sweep ever
  # sees it, not one more CV_MARSHAL_AGENT_STALL_MINUTES later.
  prev_flagged_for="$(cat "$flagged_for_file" 2>/dev/null || true)"
  if [ "$last_active" != "$prev_flagged_for" ]; then
    add_flag "QUIET AGENT: ${sid} (${template}) no activity in ${quiet_minutes}m (last_active=${last_active})"
    PENDING_FLAG_WRITES["$flagged_for_file"]="$last_active"
  fi
done <<< "$CANDIDATES_TSV"

if [ -z "$FLAGGED_LINES" ]; then
  echo "con-voyage-marshal-agent-sweep: no flagged conditions this tick"
  exit 0
fi

FLAGGED_COUNT="$(printf '%s\n' "$FLAGGED_LINES" | grep -c .)"
if cv_marshal_send_digest "$CV_LENS_STORE_TIMEOUT_SECONDS" "$CV_MARSHAL_ESCALATE_TARGET" \
    "MARSHAL AGENT SWEEP: ${FLAGGED_COUNT} quiet agent(s)" \
    "con-voyage-marshal-agent-sweep flagged ${FLAGGED_COUNT} quiet agent session(s) this tick (no activity, no interactive prompt visible):

${FLAGGED_LINES}" \
    "con-voyage-marshal-agent-sweep" "${#PENDING_FLAG_WRITES[@]} flagged entr(y/ies)"; then
  for pending_file in "${!PENDING_FLAG_WRITES[@]}"; do
    printf '%s' "${PENDING_FLAG_WRITES[$pending_file]}" > "$pending_file"
  done
fi

exit 0
