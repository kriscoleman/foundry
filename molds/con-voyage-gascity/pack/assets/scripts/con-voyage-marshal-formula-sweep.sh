#!/usr/bin/env bash
# con-voyage-marshal-formula-sweep.sh — Marshal's deterministic formula/run
# progress tier (fk-12m3 / foundry#47, fk-d0ioj2). Ports the mayor's ad hoc
# watch-run.sh (step state-change/escalation diff) + watch-anchor.sh
# (source-anchor branch/diff-size check) into a city-wide, unconditional,
# single-shot cooldown order.
#
# WHAT CHANGED FROM THE SOURCE: watch-run.sh/watch-anchor.sh each take an
# explicit `<rig> <root> [...]` argument naming ONE run a mayor session chose
# to watch, and loop forever (60s/120s sleep) for as long as that session
# stays alive. This order has no args and no loop — each invocation
# discovers every open graph.v2 workflow root itself (gc.kind=workflow,
# status open/in_progress) and runs both checks against all of them in one
# pass, the same shape con-voyage-orphan-sweep.sh uses for city-wide
# discovery.
#
# NOT PORTED: watch-run.sh's own "STUCK PROMPT" half (peeking sessions
# matching the run's template prefix). con-voyage-askuserquestion-watchdog
# (fk-o9ntx) already scans every active session city-wide for an
# interactive-prompt stall; re-checking the same condition per-run here would
# just double-report it.
#
# WHAT IT DOES, each tick, per open workflow root:
#   1. Step progress: list every bead carrying this root's gc.root_bead_id
#      (excluding "Finalize scope"/"Step spec" controller titles, same
#      exclusion watch-run.sh applied), diff status/assignee/outcome/
#      failure_class against the last tick's persisted state per step id,
#      and flag an escalation (ported mayor_is_bead_escalation) or log
#      routine progress.
#   2. Anchor health: once the root's source-anchor worktree has at least one
#      commit ahead of origin/main, fetch + check the worktree's checked-out
#      branch and diff size vs origin/main once (a DETACHED HEAD or a
#      deletion over CV_MARSHAL_ANCHOR_BIG_DELETION_LINES lines is flagged);
#      marked done afterward so a root is never re-checked once its anchor
#      has been looked at, matching watch-anchor.sh's own one-shot-per-root
#      behavior.
#   3. One digest mail per tick aggregating every flagged line across every
#      root, only when at least one line was flagged.
#
# Environment / configuration (all optional with sane defaults):
#   GC                                     Path to the gc binary (default: gc)
#   GC_CITY                                City root passed to gc (default: .)
#   CV_MARSHAL_ANCHOR_BIG_DELETION_LINES   Deletion-count flag threshold. Default: 300.
#   CV_MARSHAL_ESCALATE_TARGET             Digest mail recipient. Default: mayor.
#   CV_LENS_STORE_TIMEOUT_SECONDS          Bound on each store/mail/git call. Default: 30.
#   CV_STATE_DIR                           Override the state directory (default:
#                                          <rig_root>/.gc/con-voyage-marshal-formula-sweep).
#
# Exit codes:
#   0 — completed (flagged some, all, or none of the roots found)
#   Non-zero — fatal setup error (gc/python3 missing)
#
# Requires: bash 4+, gc CLI, git, python3.
#
# Run:  con-voyage-marshal-formula-sweep.sh

set -uo pipefail

GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_MARSHAL_ANCHOR_BIG_DELETION_LINES="${CV_MARSHAL_ANCHOR_BIG_DELETION_LINES:-300}"
CV_MARSHAL_ESCALATE_TARGET="${CV_MARSHAL_ESCALATE_TARGET:-mayor}"
CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"

case "$CV_MARSHAL_ANCHOR_BIG_DELETION_LINES" in
  *[!0-9]*|'') CV_MARSHAL_ANCHOR_BIG_DELETION_LINES="300" ;;
esac
case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
esac

if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-marshal-formula-sweep: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-marshal-formula-sweep: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

MARSHAL_ENABLED="$(cv_assistant_enabled marshal)"
if [ "$MARSHAL_ENABLED" != "true" ]; then
  echo "con-voyage-marshal-formula-sweep: disabled (marshal assistant flag is not true)"
  exit 0
fi

CV_STATE_DIR="${CV_STATE_DIR:-$(cv_default_rig_root)/.gc/con-voyage-marshal-formula-sweep}"
mkdir -p "$CV_STATE_DIR"

mayor_is_bead_escalation() {
  local status="$1" outcome="$2" failure_class="$3"
  case "$outcome" in *fail*) return 0 ;; esac
  [ -n "$failure_class" ] && return 0
  case "$status" in
    open|in_progress|closed) return 1 ;;
    *) return 0 ;;
  esac
}

FLAGGED_LINES=""
add_flag() {
  if [ -z "$FLAGGED_LINES" ]; then
    FLAGGED_LINES="$1"
  else
    FLAGGED_LINES="${FLAGGED_LINES}"$'\n'"$1"
  fi
}

# fk-i1yas2 BLOCKING-4: a flagged step's persisted state, and a flagged
# anchor's one-shot "done" marker, are staged here and only committed once
# the digest mail below is confirmed sent — a failed send must not silently
# retire the still-unreported condition.
declare -A PENDING_STATE_WRITES=()
declare -A PENDING_ANCHOR_DONE=()

ROOTS_JSON="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" bd list --status open,in_progress --metadata-field "gc.kind=workflow" --json --limit 0 2>/dev/null)" || ROOTS_JSON=""

if [ -z "${ROOTS_JSON// /}" ]; then
  echo "con-voyage-marshal-formula-sweep: no open workflow roots this tick"
  exit 0
fi

ROOT_IDS="$(printf '%s' "$ROOTS_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for item in data:
    if isinstance(item, dict) and item.get('id'):
        print(item['id'])
" 2>/dev/null)"

if [ -z "${ROOT_IDS// /}" ]; then
  echo "con-voyage-marshal-formula-sweep: no open workflow roots this tick"
  exit 0
fi

while IFS= read -r root; do
  [ -n "${root// /}" ] || continue
  ROOT_STATE_DIR="${CV_STATE_DIR}/${root}"
  mkdir -p "$ROOT_STATE_DIR"

  # --- Step progress diff (ported from watch-run.sh) ---------------------
  STEPS_JSON="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" bd list --status open,in_progress,closed --metadata-field "gc.root_bead_id=${root}" --json --limit 0 2>/dev/null)" || STEPS_JSON=""
  if [ -n "${STEPS_JSON// /}" ]; then
    STEPS_TSV="$(printf '%s' "$STEPS_JSON" | python3 -c "
import json, sys
SEP = '\x1f'
root = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for item in data:
    if not isinstance(item, dict):
        continue
    meta = item.get('metadata') or {}
    if not isinstance(meta, dict) or meta.get('gc.root_bead_id') != root:
        continue
    title = item.get('title') or ''
    if title.startswith('Finalize scope') or title.startswith('Step spec'):
        continue
    row = [item.get('id') or '', item.get('status') or '', item.get('assignee') or '',
           str(meta.get('gc.outcome') or ''), str(meta.get('gc.failure_class') or ''), title[:50]]
    row = [str(f).replace('\n', ' ').replace('\r', ' ').replace(SEP, ' ') for f in row]
    print(SEP.join(row))
" "$root" 2>/dev/null)"

    while IFS=$'\x1f' read -r step_id status assignee outcome failure_class title; do
      [ -n "${step_id// /}" ] || continue
      who="-"; [ -n "$assignee" ] && who="@${assignee}"
      cur="${status} ${who} outcome=${outcome}${failure_class:+ fail=${failure_class}}"
      prev="$(cat "${ROOT_STATE_DIR}/${step_id}" 2>/dev/null || true)"
      if [ "$cur" != "$prev" ]; then
        if mayor_is_bead_escalation "$status" "$outcome" "$failure_class"; then
          add_flag "RUN ${root} ${step_id} [${title}]: ${prev:-<new>} -> ${cur}"
          PENDING_STATE_WRITES["${ROOT_STATE_DIR}/${step_id}"]="$cur"
        else
          printf '%s' "$cur" > "${ROOT_STATE_DIR}/${step_id}"
          echo "con-voyage-marshal-formula-sweep: ${root} ${step_id} [${title}]: ${prev:-<new>} -> ${cur}"
        fi
      fi
    done <<< "$STEPS_TSV"
  fi

  # --- Anchor health check, once per root (ported from watch-anchor.sh) ---
  [ -f "${ROOT_STATE_DIR}/.anchor_done" ] && continue

  ROOT_SHOW_JSON="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" bd show "$root" --json 2>/dev/null)" || ROOT_SHOW_JSON=""
  [ -n "${ROOT_SHOW_JSON// /}" ] || continue

  WT="$(printf '%s' "$ROOT_SHOW_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
print((d.get('metadata') or {}).get('gc.build.source_anchor_work_dir') or '')
" 2>/dev/null)"
  [ -n "$WT" ] && [ -d "$WT" ] || continue

  # fk-d0ioj2 review fk-9oigyg LOW-4 (regraded BLOCKING, low-batch regrade
  # 2026-10-10): this fetch's exit code used to be discarded outright. A
  # transient fetch failure right when a root's anchor first drifts would
  # compute AHEAD off stale local refs; if that happened to read as "0
  # ahead," the root got marked `.anchor_done` — a one-shot, never-rechecked
  # marker per this check's own design — and this root's anchor would never
  # be looked at again. Skip this tick's AHEAD computation on a failed fetch
  # instead, leaving `.anchor_done` unset so the next sweep retries against
  # fresh refs.
  if ! cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" git -C "$WT" fetch origin --quiet >/dev/null 2>&1; then
    echo "con-voyage-marshal-formula-sweep: ANCHOR ${root} fetch failed, retrying next sweep" >&2
    continue
  fi

  AHEAD="$(git -C "$WT" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  case "$AHEAD" in *[!0-9]*|'') AHEAD=0 ;; esac
  [ "$AHEAD" -gt 0 ] || continue

  BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  STAT="$(git -C "$WT" diff --shortstat origin/main...HEAD 2>/dev/null | sed 's/^ *//')"
  DEL="$(printf '%s' "$STAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')"
  DEL="${DEL:-0}"

  FLAG=""
  [ "$BRANCH" = "HEAD" ] && FLAG="DETACHED HEAD "
  [ "$DEL" -gt "$CV_MARSHAL_ANCHOR_BIG_DELETION_LINES" ] && FLAG="${FLAG}BIG-DELETION "

  if [ -n "$FLAG" ]; then
    add_flag "ANCHOR ${root} ${FLAG}branch=${BRANCH} ahead=${AHEAD} (${STAT}) wt=$(basename "$WT")"
    PENDING_ANCHOR_DONE["${ROOT_STATE_DIR}/.anchor_done"]=1
  else
    echo "con-voyage-marshal-formula-sweep: ANCHOR ${root} clean branch=${BRANCH} ahead=${AHEAD} (${STAT})"
    touch "${ROOT_STATE_DIR}/.anchor_done"
  fi
done <<< "$ROOT_IDS"

if [ -z "$FLAGGED_LINES" ]; then
  echo "con-voyage-marshal-formula-sweep: no flagged conditions this tick"
  exit 0
fi

FLAGGED_COUNT="$(printf '%s\n' "$FLAGGED_LINES" | grep -c .)"
mail_out="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
  "$GC" --city "$GC_CITY" mail send "$CV_MARSHAL_ESCALATE_TARGET" \
    -s "MARSHAL FORMULA SWEEP: ${FLAGGED_COUNT} flagged condition(s)" \
    -m "con-voyage-marshal-formula-sweep flagged ${FLAGGED_COUNT} condition(s) this tick:

${FLAGGED_LINES}" \
    2>&1)"
mail_rc=$?
if [ "$mail_rc" -eq 0 ]; then
  for pending_key in "${!PENDING_STATE_WRITES[@]}"; do
    printf '%s' "${PENDING_STATE_WRITES[$pending_key]}" > "$pending_key"
  done
  for pending_anchor in "${!PENDING_ANCHOR_DONE[@]}"; do
    touch "$pending_anchor"
  done
else
  echo "con-voyage-marshal-formula-sweep: WARNING: digest mail to ${CV_MARSHAL_ESCALATE_TARGET} failed: ${mail_out}" >&2
  echo "con-voyage-marshal-formula-sweep: WARNING: not advancing persisted state for ${#PENDING_STATE_WRITES[@]} step(s) and ${#PENDING_ANCHOR_DONE[@]} anchor check(s) — will re-flag next tick" >&2
fi

exit 0
