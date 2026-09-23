#!/usr/bin/env bash
# con-voyage-review-watchdog.sh — review-lane liveness watchdog (fk-loo1
# FIX-F, DEFENSE-IN-DEPTH half of the review-lens liveness guard).
#
# ROOT CAUSE (see the fk-loo1 bead description for the full dogfooding
# writeup): review lens sessions are pool-managed and their only task
# delivery is a core nudge-on-route mechanism fired on bead.created/updated.
# On a slow-startup (large) repo a lens can take minutes to wake; if the pool
# restarts its still-starting run-operator in that window, the review-lane
# bead it would have claimed is left open+unassigned forever and the review
# loop can never fan in. The PRIMARY fix is an in-loop claim-verification and
# bounded re-dispatch block added to {target}.con-voyage-review-loop.md,
# which runs INSIDE the same review-loop run-operator session. This script is
# the independent, periodic safety net: it catches a stalled lane even when
# the review loop's own run-operator is the thing that died, so nobody is
# left running the inline check at all.
#
# DESIGN NOTE (why this differs from con-voyage-repair-watchdog.sh): that
# watchdog needs an external CV_STATE_DIR state file because a GitHub PR has
# no durable bd-bead representation spanning its whole repair lifecycle. A
# review-lane bead has no such gap — it IS the durable, queryable record — so
# this watchdog persists its own attempt_count/escalated bookkeeping directly
# on the lane bead's own metadata (gc.review_watchdog.*) via `bd update
# --set-metadata`, and discovers candidates with a single `bd list`
# metadata-field query instead of globbing per-PR state records. No GitHub
# calls are made anywhere in this script.
#
# ALGORITHM, per candidate review-lane bead (open or in_progress, belonging
# to an active con-voyage-review-loop scope):
#   - Already escalated (gc.review_watchdog.escalated=1) -> skip entirely.
#   - open + unassigned (never claimed):
#     - no gc.routed_to metadata -> WARNING, skip (nothing safe to target).
#     - the routed pool has NO live session at all -> re-route immediately
#       via `gc sling <routed_to> <lane> --nudge` (unambiguous "pool is
#       drained" signal; no staleness gate, mirrors con-voyage-repair-
#       watchdog.sh's own "confirmed-dead is unambiguous on its own" case).
#     - the routed pool has a live session but the bead has sat unclaimed
#       past CV_LENS_STALL_SECONDS -> touch (persist attempt bookkeeping,
#       which bumps updated_at and re-fires nudge-on-route) + directly nudge
#       that live session.
#     - otherwise (pool alive, still within the grace window) -> no action.
#   - in_progress + assignee known (claimed):
#     - the assignee's own session is no longer alive -> WARNING, skip. This
#       watchdog never re-routes a bead out from under its assignee on a
#       guess; that stays the inline review-loop check's job with fuller
#       context.
#     - assignee alive but updated_at stalled past CV_LENS_STALL_SECONDS ->
#       re-notify the SAME assignee session directly (no re-route, no new
#       bead — mirrors con-voyage-repair-watchdog.sh's own "stalled but
#       alive" reuse path).
#     - otherwise -> no action.
#   - After CV_LENS_MAX_ATTEMPTS consecutive re-dispatches with still no
#     progress -> escalate via `gc mail send CV_LENS_ESCALATE_TARGET` and
#     stop re-dispatching that lane until a human (or a fresh review cycle)
#     clears it.
#
# Environment / configuration (all optional with sane defaults):
#
#   GC                     Path to the gc binary (default: gc)
#   GC_CITY                City root passed to gc (default: current directory)
#   CV_LENS_STALL_SECONDS  Seconds a review-lane bead may show no progress
#                          (unclaimed past this age, or claimed with
#                          updated_at unchanged) before this watchdog acts.
#                          Default: 600 (10 minutes).
#   CV_LENS_MAX_ATTEMPTS   Consecutive watchdog re-dispatches allowed for the
#                          SAME lane before escalating instead. Default: 3.
#   CV_LENS_ESCALATE_TARGET  Mail recipient when a lane exhausts
#                          CV_LENS_MAX_ATTEMPTS. Default: the reserved
#                          `human` alias.
#
# Exit codes:
#   0 — completed (some, all, or none of the candidate lanes needed action)
#   Non-zero — fatal setup error (gc/python3 missing)
#
# The order controller treats any non-zero exit as a transient failure and
# retries on the next cooldown interval.
#
# Requires: bash 4+, gc CLI, python3.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_LENS_STALL_SECONDS="${CV_LENS_STALL_SECONDS:-600}"
CV_LENS_MAX_ATTEMPTS="${CV_LENS_MAX_ATTEMPTS:-3}"
CV_LENS_ESCALATE_TARGET="${CV_LENS_ESCALATE_TARGET:-human}"

# A malformed override must never silently break the staleness/escalation
# checks that gate this watchdog's core behavior — same fail-safe posture as
# every other malformed-field guard in this pack (see con-voyage-repair-
# watchdog.sh's identical coercion of CV_STALL_SECONDS/CV_MAX_ATTEMPTS).
case "$CV_LENS_STALL_SECONDS" in
  *[!0-9]*|'') CV_LENS_STALL_SECONDS="600" ;;
esac
case "$CV_LENS_MAX_ATTEMPTS" in
  *[!0-9]*|'') CV_LENS_MAX_ATTEMPTS="3" ;;
esac

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-review-watchdog: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-review-watchdog: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

echo "con-voyage-review-watchdog: stall=${CV_LENS_STALL_SECONDS}s max_attempts=${CV_LENS_MAX_ATTEMPTS} escalate_target=${CV_LENS_ESCALATE_TARGET}"

# ---------------------------------------------------------------------------
# Shared session-liveness helpers (session_id_for_ident,
# first_alive_session_id_for_route) — see con-voyage-lib.sh for the
# authoritative doc comments. Shared with con-voyage-repair-watchdog.sh's
# sibling implementor_alive/bead_status helpers.
# ---------------------------------------------------------------------------
# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

# is_stale UPDATED_AT THRESHOLD_SECONDS — exit 0 if UPDATED_AT is more than
# THRESHOLD_SECONDS in the past. A missing/unparseable UPDATED_AT fails SAFE
# (never stale) — matches con-voyage-repair-watchdog.sh's identical helper.
is_stale() {
  local updated_at="$1" threshold="$2"
  [ -n "${updated_at// /}" ] || return 1
  python3 -c "
import sys
from datetime import datetime, timezone

updated_at = sys.argv[1]
try:
    threshold_s = float(sys.argv[2])
except Exception:
    sys.exit(1)
try:
    ts = updated_at.strip()
    if ts.endswith('Z'):
        ts = ts[:-1] + '+00:00'
    parsed = datetime.fromisoformat(ts)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    age = (datetime.now(timezone.utc) - parsed).total_seconds()
except Exception:
    sys.exit(1)
sys.exit(0 if age > threshold_s else 1)
" "$updated_at" "$threshold"
}

# ---------------------------------------------------------------------------
# Discovery: every open/in_progress review-lane bead across the city, in one
# query. A lane bead is a graph.v2 template child of an active
# con-voyage-review-loop scope: gc.ralph_step_id ends with
# ".con-voyage-review-loop", gc.scope_role=member, and its title carries the
# "Con-voyage: " floor/roster-lane prefix (this excludes sibling scope
# members that are not lanes at all, e.g. "Apply con-voyage review findings"
# and "Synthesize con-voyage review"). -n 0 disables the default 50-row cap —
# a missed stalled lane defeats the entire point of this watchdog.
# ---------------------------------------------------------------------------
LANES_JSON="$("$GC" --city "$GC_CITY" bd list --status open,in_progress --has-metadata-key gc.ralph_step_id -n 0 --json 2>/dev/null)"
[ -n "$LANES_JSON" ] || LANES_JSON="[]"

LANES_TSV="$(printf '%s' "$LANES_JSON" | python3 -c "
import json, sys
# Unit separator, not a tab: bash classifies tab as IFS whitespace and
# collapses consecutive delimiters, silently merging away an empty field
# (e.g. a blank assignee). 0x1f is never IFS whitespace, so empty fields
# round-trip correctly. Same convention as bead_status/pr_finalize_state in
# con-voyage-lib.sh.
SEP = '\x1f'
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(data, list):
    raise SystemExit(0)
for d in data:
    if not isinstance(d, dict):
        continue
    meta = d.get('metadata') or {}
    ralph = str(meta.get('gc.ralph_step_id') or '')
    if not ralph.endswith('.con-voyage-review-loop'):
        continue
    if meta.get('gc.scope_role') != 'member':
        continue
    title = d.get('title') or ''
    if not title.startswith('Con-voyage: '):
        continue
    row = [
        d.get('id') or '',
        d.get('status') or '',
        d.get('assignee') or '',
        d.get('updated_at') or '',
        meta.get('gc.routed_to') or '',
        str(meta.get('gc.review_watchdog.attempt_count') or '0'),
        str(meta.get('gc.review_watchdog.escalated') or '0'),
    ]
    print(SEP.join(row))
" 2>/dev/null)"

if [ -z "$LANES_TSV" ]; then
  echo "con-voyage-review-watchdog: no active review lanes found"
  exit 0
fi

while IFS=$'\x1f' read -r lane_id status assignee updated_at routed_to attempt_count escalated; do
  [ -n "$lane_id" ] || continue

  # SECURITY / robustness: attempt_count/escalated came from bead metadata
  # this process does not exclusively own. Both are used in bash arithmetic
  # below, so coerce to a validated base-10 integer HERE before that happens
  # — same posture as con-voyage-lib.sh's ST_ATTEMPT_COUNT/ST_ESCALATED
  # coercion in con-voyage-repair-watchdog.sh.
  case "$attempt_count" in *[!0-9]*|'') attempt_count="0" ;; esac
  case "$escalated" in *[!0-9]*|'') escalated="0" ;; esac

  if [ "$escalated" = "1" ]; then
    echo "con-voyage-review-watchdog: SKIP ${lane_id} — already escalated; not re-dispatching"
    continue
  fi

  needs_action=0
  use_reroute=0
  action_desc=""
  target_session_id=""

  if [ "$status" = "open" ] && [ -z "${assignee// /}" ]; then
    if [ -z "${routed_to// /}" ]; then
      echo "con-voyage-review-watchdog: WARNING: ${lane_id} is open+unassigned but has no gc.routed_to metadata; cannot safely re-dispatch" >&2
      continue
    fi
    route_session_id="$(first_alive_session_id_for_route "$routed_to")"
    if [ -z "$route_session_id" ]; then
      needs_action=1
      use_reroute=1
      action_desc="DEAD (no live session for route ${routed_to})"
    elif is_stale "$updated_at" "$CV_LENS_STALL_SECONDS"; then
      needs_action=1
      use_reroute=0
      target_session_id="$route_session_id"
      action_desc="STALLED (never claimed, pool alive)"
    fi
  elif [ "$status" = "in_progress" ] && [ -n "${assignee// /}" ]; then
    if is_stale "$updated_at" "$CV_LENS_STALL_SECONDS"; then
      assignee_session_id="$(session_id_for_ident "$assignee")"
      if [ -z "$assignee_session_id" ]; then
        echo "con-voyage-review-watchdog: WARNING: ${lane_id} is claimed by ${assignee} but no live session matches that identity; leaving it for a human/fresh cycle rather than guessing" >&2
        continue
      fi
      needs_action=1
      use_reroute=0
      target_session_id="$assignee_session_id"
      action_desc="STALLED (claimed, no progress)"
    fi
  fi

  if [ "$needs_action" -eq 0 ]; then
    echo "con-voyage-review-watchdog: OK ${lane_id} — no action (status=${status} assignee=${assignee} updated_at=${updated_at})"
    continue
  fi

  # Escalation check BEFORE acting: CV_LENS_MAX_ATTEMPTS re-dispatches have
  # already been made against this SAME lane and it is STILL stalled/dead —
  # escalate instead of trying again.
  if [ "$attempt_count" -ge "$CV_LENS_MAX_ATTEMPTS" ] 2>/dev/null; then
    echo "con-voyage-review-watchdog: ESCALATE ${lane_id} — ${attempt_count} failed attempt(s), notifying ${CV_LENS_ESCALATE_TARGET} and stopping re-dispatch"
    if "$GC" --city "$GC_CITY" mail send "$CV_LENS_ESCALATE_TARGET" \
      -s "con-voyage review watchdog: giving up on ${lane_id}" \
      -m "Review lane ${lane_id} (routed_to=${routed_to}) has made no progress after ${attempt_count} watchdog re-dispatch attempt(s). This watchdog is stopping automatic re-dispatch for this lane — please take a look." \
      2>&1; then
      # $lane_id is an EXISTING, already-rig-prefixed review-lane bead — the
      # same fk-7v3r bug class as con-voyage-lib.sh's helpers and
      # con-voyage-pr-watch.sh's in-flight update: `--city` alone (no
      # `--rig`) routes an already-rig-prefixed id to the CITY store instead
      # of its owning rig's, so `bd update` silently "Issue not found"s
      # every cycle (fk-mr07). Rely on cwd auto-detection instead, matching
      # this file's own bead_status/close_if_open calls (via con-voyage-lib.sh)
      # and every other already-fixed bd call in this pack.
      "$GC" bd update "$lane_id" --set-metadata "gc.review_watchdog.escalated=1" >/dev/null 2>&1 \
        || echo "con-voyage-review-watchdog: WARNING: failed to persist the escalated flag for ${lane_id}" >&2
    else
      echo "con-voyage-review-watchdog: WARNING: escalation mail to ${CV_LENS_ESCALATE_TARGET} failed for ${lane_id}; will retry next cycle" >&2
    fi
    continue
  fi

  new_attempt_count=$((attempt_count + 1))

  if [ "$use_reroute" -eq 1 ]; then
    echo "con-voyage-review-watchdog: ${action_desc} ${lane_id} — re-routing to ${routed_to} (attempt ${new_attempt_count}/${CV_LENS_MAX_ATTEMPTS})"
    if "$GC" --city "$GC_CITY" sling "$routed_to" "$lane_id" --nudge 2>&1; then
      "$GC" bd update "$lane_id" \
        --set-metadata "gc.review_watchdog.attempt_count=${new_attempt_count}" \
        --set-metadata "gc.review_watchdog.escalated=0" >/dev/null 2>&1 \
        || echo "con-voyage-review-watchdog: WARNING: failed to persist attempt_count for ${lane_id}" >&2
    else
      echo "con-voyage-review-watchdog: WARNING: re-route sling failed for ${lane_id}; will retry next cycle" >&2
    fi
  else
    echo "con-voyage-review-watchdog: ${action_desc} ${lane_id} — nudging session ${target_session_id} (attempt ${new_attempt_count}/${CV_LENS_MAX_ATTEMPTS})"
    if "$GC" --city "$GC_CITY" session nudge "$target_session_id" \
      "Review lane ${lane_id} has shown no progress in over ${CV_LENS_STALL_SECONDS}s. Watchdog re-dispatch attempt ${new_attempt_count}/${CV_LENS_MAX_ATTEMPTS}." \
      2>&1; then
      "$GC" bd update "$lane_id" \
        --set-metadata "gc.review_watchdog.attempt_count=${new_attempt_count}" \
        --set-metadata "gc.review_watchdog.escalated=0" >/dev/null 2>&1 \
        || echo "con-voyage-review-watchdog: WARNING: failed to persist attempt_count for ${lane_id}" >&2
    else
      echo "con-voyage-review-watchdog: WARNING: session nudge failed for ${lane_id}; will retry next cycle" >&2
    fi
  fi
done <<< "$LANES_TSV"

exit 0
