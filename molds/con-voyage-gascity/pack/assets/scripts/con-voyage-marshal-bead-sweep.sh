#!/usr/bin/env bash
# con-voyage-marshal-bead-sweep.sh — Marshal's deterministic bead-liveness
# tier (fk-12m3 / foundry#47, fk-d0ioj2). Ports the mayor's ad hoc
# watch-beads.sh (status/outcome progress + escalation digest, mail-count
# tracking) into a city-wide, unconditional, single-shot cooldown order so
# the same classification runs even when no mayor session happens to be
# watching.
#
# WHAT CHANGED FROM THE SOURCE (scripts/mayor/watch-beads.sh at the city
# level): that script takes an explicit `rig:id [rig:id ...]` watch list on
# argv and loops forever with a 60s sleep, for as long as a mayor session
# keeps it alive. This order has no args and no loop — it runs once per
# invocation (the "cooldown" trigger supplies the 5m cadence) and discovers
# every eligible bead itself via `bd list`, the same shape con-voyage-
# orphan-sweep.sh (fk-yli8qd) already uses for its own city-wide discovery.
#
# ORPHAN CLASS IS CLASSIFY-ONLY: the original fk-d0ioj2 scope briefly
# required this sweep to ACT on orphaned beads (force-close them); that
# requirement was carved out to its own order, con-voyage-orphan-sweep
# (fk-yli8qd), which already force-closes beads stranded under a closed
# workflow root every 5m. This sweep only ever REPORTS one it still sees
# (a bead can be visible here for at most one tick before orphan-sweep's own
# cycle closes it) — it never calls bd close itself for this class.
#
# STUCK-READY / STRANDED-TEARDOWN are new classes this sweep's acceptance
# criteria call for that do not exist in the ported source; watch-beads.sh
# only diffs status/outcome and watch-stuck.sh only detects an interactive
# prompt on a live session, neither implements an age-based idle check. This
# script's addition: a bead is STUCK-READY when it has sat `status=open`
# (never claimed/started) for longer than CV_MARSHAL_READY_STALE_MINUTES
# under a still-open root, and STRANDED-TEARDOWN when a
# `gc.scope_role=teardown` bead has sat open longer than
# CV_MARSHAL_TEARDOWN_STALE_MINUTES. Both are heuristic liveness signals for
# a human/mayor to look at, not an automated action.
#
# WHAT IT DOES, each tick:
#   1. Gate on the marshal assistant flag (cv_assistant_enabled marshal) —
#      disabled by default, no bd/gc calls at all when off.
#   2. List every open/in_progress bead carrying gc.root_bead_id (bd list
#      --has-metadata-key gc.root_bead_id).
#   3. For each DISTINCT root id among them, look up its status ONCE this
#      tick (cached), same pattern as con-voyage-orphan-sweep.sh.
#   4. Classify each bead: orphan (root closed), stranded-teardown
#      (scope_role=teardown, stale), stuck-ready (open, stale, root still
#      open), escalation (outcome/failure_class/status, ONLY on a change
#      from the last tick's persisted state for that bead id).
#   5. Routine (no classification, or an unchanged escalation state) is
#      logged to stdout only — never mailed.
#   6. Track the mayor's unread mail count; flag a digest line when it rises
#      since the last tick.
#   7. One digest mail per tick to CV_MARSHAL_ESCALATE_TARGET (default
#      mayor), only when at least one line was flagged this tick.
#
# Environment / configuration (all optional with sane defaults):
#   GC                                Path to the gc binary (default: gc)
#   GC_CITY                           City root passed to gc (default: .)
#   CV_MARSHAL_READY_STALE_MINUTES    STUCK-READY age threshold. Default: 20.
#   CV_MARSHAL_TEARDOWN_STALE_MINUTES STRANDED-TEARDOWN age threshold. Default: 15.
#   CV_MARSHAL_ESCALATE_TARGET        Digest mail recipient. Default: mayor.
#   CV_LENS_STORE_TIMEOUT_SECONDS     Bound on each store/mail call. Default: 30.
#   CV_STATE_DIR                      Override the state directory (default:
#                                      <rig_root>/.gc/con-voyage-marshal-bead-sweep).
#
# Exit codes:
#   0 — completed (flagged some, all, or none of the candidates found)
#   Non-zero — fatal setup error (gc/python3 missing)
#
# Requires: bash 4+, gc CLI, python3.
#
# Run:  con-voyage-marshal-bead-sweep.sh

set -uo pipefail

GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_MARSHAL_READY_STALE_MINUTES="${CV_MARSHAL_READY_STALE_MINUTES:-20}"
CV_MARSHAL_TEARDOWN_STALE_MINUTES="${CV_MARSHAL_TEARDOWN_STALE_MINUTES:-15}"
CV_MARSHAL_ESCALATE_TARGET="${CV_MARSHAL_ESCALATE_TARGET:-mayor}"
CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"

case "$CV_MARSHAL_READY_STALE_MINUTES" in
  *[!0-9]*|'') CV_MARSHAL_READY_STALE_MINUTES="20" ;;
esac
case "$CV_MARSHAL_TEARDOWN_STALE_MINUTES" in
  *[!0-9]*|'') CV_MARSHAL_TEARDOWN_STALE_MINUTES="15" ;;
esac
case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
esac

if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-marshal-bead-sweep: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-marshal-bead-sweep: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

MARSHAL_ENABLED="$(cv_assistant_enabled marshal)"
if [ "$MARSHAL_ENABLED" != "true" ]; then
  echo "con-voyage-marshal-bead-sweep: disabled (marshal assistant flag is not true)"
  exit 0
fi

CV_STATE_DIR="${CV_STATE_DIR:-$(cv_default_rig_root)/.gc/con-voyage-marshal-bead-sweep}"
mkdir -p "$CV_STATE_DIR"

# ---------------------------------------------------------------------------
# mayor_is_bead_escalation STATUS OUTCOME FAILURE_CLASS — ported verbatim
# from scripts/mayor/lib/events.sh: true if a bead's current state is a
# failure/escalation rather than routine progress.
# ---------------------------------------------------------------------------
mayor_is_bead_escalation() {
  local status="$1" outcome="$2" failure_class="$3"
  case "$outcome" in *fail*) return 0 ;; esac
  [ -n "$failure_class" ] && return 0
  case "$status" in
    open|in_progress|closed) return 1 ;;
    *) return 0 ;;
  esac
}

# minutes_since_iso8601 TIMESTAMP — whole minutes between TIMESTAMP (an
# RFC3339 string as bd emits) and now; empty TIMESTAMP or a parse failure
# prints nothing so callers treat it as "unknown age", never a stale-age
# false positive.
minutes_since_iso8601() {
  local ts="$1"
  [ -n "$ts" ] || return 0
  python3 -c "
import sys, datetime
ts = sys.argv[1]
try:
    t = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
except Exception:
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
delta = (now - t).total_seconds() / 60.0
print(int(delta))
" "$ts" 2>/dev/null
}

CANDIDATES_JSON="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" bd list --status open,in_progress --has-metadata-key gc.root_bead_id --json --limit 0 2>/dev/null)" || CANDIDATES_JSON=""

FLAGGED_LINES=""
add_flag() {
  if [ -z "$FLAGGED_LINES" ]; then
    FLAGGED_LINES="$1"
  else
    FLAGGED_LINES="${FLAGGED_LINES}"$'\n'"$1"
  fi
}

if [ -z "${CANDIDATES_JSON// /}" ]; then
  echo "con-voyage-marshal-bead-sweep: no candidates (bd list empty or failed)"
else
  # Rows: id SEP root_id SEP status SEP outcome SEP failure_class SEP
  # scope_role SEP updated_at — one per candidate bead.
  CANDIDATES_TSV="$(printf '%s' "$CANDIDATES_JSON" | python3 -c "
import json, sys
SEP = '\x1f'
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for item in data:
    if not isinstance(item, dict):
        continue
    bead_id = item.get('id') or ''
    meta = item.get('metadata') or {}
    if not isinstance(meta, dict):
        meta = {}
    root_id = meta.get('gc.root_bead_id') or ''
    if not bead_id or not root_id:
        continue
    status = item.get('status') or ''
    outcome = str(meta.get('gc.outcome') or '')
    failure_class = str(meta.get('gc.failure_class') or '')
    scope_role = str(meta.get('gc.scope_role') or '')
    updated_at = item.get('updated_at') or ''
    row = [bead_id, root_id, status, outcome, failure_class, scope_role, updated_at]
    row = [str(f).replace('\n', ' ').replace('\r', ' ').replace(SEP, ' ') for f in row]
    print(SEP.join(row))
" 2>/dev/null)"

  declare -A ROOT_STATUS=()

  while IFS=$'\x1f' read -r bead_id root_id status outcome failure_class scope_role updated_at; do
    [ -n "${bead_id// /}" ] || continue
    [ -n "${root_id// /}" ] || continue

    if [ -z "${ROOT_STATUS[$root_id]+x}" ]; then
      local_status=""
      IFS=$'\x1f' read -r local_status _ <<< "$(bead_status "$root_id" id)"
      ROOT_STATUS[$root_id]="$local_status"
    fi
    root_status="${ROOT_STATUS[$root_id]}"

    classification=""
    if [ "$root_status" = "closed" ]; then
      classification="ORPHAN"
    elif [ "$scope_role" = "teardown" ] && [ "$status" = "open" ]; then
      age="$(minutes_since_iso8601 "$updated_at")"
      if [ -n "$age" ] && [ "$age" -ge "$CV_MARSHAL_TEARDOWN_STALE_MINUTES" ]; then
        classification="STRANDED-TEARDOWN(${age}m)"
      fi
    elif [ "$status" = "open" ] && [ "$root_status" != "closed" ]; then
      age="$(minutes_since_iso8601 "$updated_at")"
      if [ -n "$age" ] && [ "$age" -ge "$CV_MARSHAL_READY_STALE_MINUTES" ]; then
        classification="STUCK-READY(${age}m)"
      fi
    fi

    cur="${status} root=${root_id} outcome=${outcome}${failure_class:+ fail=${failure_class}}${classification:+ class=${classification}}"
    prev="$(cat "${CV_STATE_DIR}/${bead_id}" 2>/dev/null || true)"
    if [ "$cur" != "$prev" ]; then
      printf '%s' "$cur" > "${CV_STATE_DIR}/${bead_id}"
      if [ -n "$classification" ]; then
        add_flag "${classification}: ${bead_id} (root ${root_id}) ${status} outcome=${outcome}${failure_class:+ fail=${failure_class}}"
      elif mayor_is_bead_escalation "$status" "$outcome" "$failure_class"; then
        add_flag "ESCALATION: ${bead_id} (root ${root_id}): ${prev:-<new>} -> ${cur}"
      else
        echo "con-voyage-marshal-bead-sweep: ${bead_id}: ${prev:-<new>} -> ${cur}"
      fi
    fi
  done <<< "$CANDIDATES_TSV"
fi

# Mayor mail count, ported from watch-beads.sh.
UNREAD="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" mail count 2>/dev/null | grep -oE '[0-9]+ unread' | grep -oE '[0-9]+' || true)"
if [ -n "$UNREAD" ]; then
  PREV_UNREAD="$(cat "${CV_STATE_DIR}/_mail" 2>/dev/null || echo 0)"
  case "$PREV_UNREAD" in *[!0-9]*|'') PREV_UNREAD=0 ;; esac
  if [ "$UNREAD" -gt "$PREV_UNREAD" ]; then
    add_flag "mayor mail: ${UNREAD} unread"
  fi
  printf '%s' "$UNREAD" > "${CV_STATE_DIR}/_mail"
fi

if [ -z "$FLAGGED_LINES" ]; then
  echo "con-voyage-marshal-bead-sweep: no flagged conditions this tick"
  exit 0
fi

FLAGGED_COUNT="$(printf '%s\n' "$FLAGGED_LINES" | grep -c .)"
mail_out="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
  "$GC" --city "$GC_CITY" mail send "$CV_MARSHAL_ESCALATE_TARGET" \
    -s "MARSHAL BEAD SWEEP: ${FLAGGED_COUNT} flagged condition(s)" \
    -m "con-voyage-marshal-bead-sweep flagged ${FLAGGED_COUNT} condition(s) this tick:

${FLAGGED_LINES}" \
    2>&1)"
mail_rc=$?
if [ "$mail_rc" -ne 0 ]; then
  echo "con-voyage-marshal-bead-sweep: WARNING: digest mail to ${CV_MARSHAL_ESCALATE_TARGET} failed: ${mail_out}" >&2
fi

exit 0
