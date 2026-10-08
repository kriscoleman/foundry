#!/usr/bin/env bash
# con-voyage-orphan-sweep.sh — close open beads stranded under an already-
# CLOSED graph.v2 workflow root (fk-yli8qd; mitigates engine re-mint tracked
# on fk-ruuy6).
#
# THE GAP THIS CLOSES: the gascity engine keeps minting review-loop
# iterations (ralph/scope bodies, then review lanes) AFTER a workflow root
# closes, and even after its ralph is closed. Root cause is engine-side
# (internal/dispatch/ralph.go processRalphCheck, no root re-check before the
# mint). On 2026-10-04 this burned ~15 reviewer slots on dead roots
# fk-i2ogbp (up to iteration 5) and fk-iexopm (scope body fk-guif47
# re-minted after the WHOLE tree was closed). Live journeys starved
# meanwhile, with host load ~80. Each lane self-closes as
# orphaned_root_race, but only after claiming a slot and mailing the mayor.
# This is a pack-side MITIGATION until the engine is fixed.
#
# WHAT IT DOES, each tick:
#   1. List every open/in_progress/blocked bead carrying a gc.root_bead_id
#      (bd list --has-metadata-key gc.root_bead_id).
#   2. For each DISTINCT root id among them, look up its status ONCE this
#      tick (cached). Beads under an OPEN root are left completely alone —
#      the root itself is never touched either.
#   3. For every candidate whose root is CLOSED: stamp
#      gc.work_outcome=abandoned + gc.outcome=skipped, then `bd close
#      --force` with a reason naming the closed root (and its own close
#      reason, when known).
#   4. Descendants close LEAF-FIRST: plain lane/step beads, then
#      gc.kind=scope-check, then gc.kind=scope, then gc.kind=ralph, then
#      gc.kind=workflow-finalize — ordering is global across all closed
#      roots in this tick, which still guarantees every root's own leaves
#      close before its own controllers. A kind this script doesn't
#      recognize ranks last (fail-closed as a controller, not as a leaf).
#   5. Bounded: at most CV_ORPHAN_SWEEP_MAX_CLOSES closes per tick (default
#      50); any remainder is picked up on a later tick since it is still
#      open and its root is still closed (idempotent — a bead this script
#      already closed no longer matches the open-status list query).
#   6. Mails CV_ORPHAN_SWEEP_ESCALATE_TARGET (default mayor) ONE digest
#      line per tick, and only when something actually closed
#      ("ORPHAN SWEEP: closed <n> under roots <ids>"). A quiet tick sends
#      no mail.
#
# WHAT IT NEVER DOES: touch a bead whose root is open or unresolvable, touch
# the root bead itself (con-voyage-finalize.sh / cv_close_workflow_root own
# that), or exceed its per-tick close cap.
#
# Environment / configuration (all optional with sane defaults):
#   GC                           Path to the gc binary (default: gc)
#   GC_CITY                      City root passed to gc (default: .)
#   CV_ORPHAN_SWEEP_ENABLED      Set to false/0 to disable the sweep
#                                entirely (no bd calls at all). Default: true.
#   CV_ORPHAN_SWEEP_MAX_CLOSES   Per-tick close cap. Default: 50.
#   CV_ORPHAN_SWEEP_ESCALATE_TARGET  Digest mail recipient. Default: mayor.
#   CV_LENS_STORE_TIMEOUT_SECONDS  Bound on the digest mail call. Default: 30.
#
# Exit codes:
#   0 — completed (closed some, all, or none of the candidates found)
#   Non-zero — fatal setup error (gc/python3 missing)
#
# Requires: bash 4+, gc CLI, python3.
#
# Run:  con-voyage-orphan-sweep.sh

set -uo pipefail

GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_ORPHAN_SWEEP_ENABLED="${CV_ORPHAN_SWEEP_ENABLED:-true}"
CV_ORPHAN_SWEEP_MAX_CLOSES="${CV_ORPHAN_SWEEP_MAX_CLOSES:-50}"
CV_ORPHAN_SWEEP_ESCALATE_TARGET="${CV_ORPHAN_SWEEP_ESCALATE_TARGET:-mayor}"
CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"

case "$CV_ORPHAN_SWEEP_MAX_CLOSES" in
  *[!0-9]*|'') CV_ORPHAN_SWEEP_MAX_CLOSES="50" ;;
esac
case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
esac

case "${CV_ORPHAN_SWEEP_ENABLED,,}" in
  false|0|no|off)
    echo "con-voyage-orphan-sweep: disabled (CV_ORPHAN_SWEEP_ENABLED=${CV_ORPHAN_SWEEP_ENABLED})"
    exit 0
    ;;
esac

if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-orphan-sweep: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-orphan-sweep: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

# Sourced for bead_status/cv_with_timeout only (functions only, no side
# effects at source time). Resolved relative to THIS script's own location
# (fk-q2pon convention — the live pack's copy sits next to its own copy of
# con-voyage-lib.sh).
# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

# ---------------------------------------------------------------------------
# Discover candidates: every open/in_progress/blocked bead carrying a
# gc.root_bead_id. A `bd list` failure or empty result degrades to a no-op
# quiet tick, never a crash. Bounded by cv_with_timeout like this script's
# other two store calls (pinned lookup, digest mail) — a slow store must
# degrade this tick to "no candidates", not hang the whole order (fk-9iqxnx
# review LOW-8, re-graded BLOCKING).
# ---------------------------------------------------------------------------
CANDIDATES_JSON="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" bd list --status open,in_progress,blocked --has-metadata-key gc.root_bead_id --json --limit 0 2>/dev/null)" || CANDIDATES_JSON=""

if [ -z "${CANDIDATES_JSON// /}" ]; then
  echo "con-voyage-orphan-sweep: no candidates (bd list empty or failed)"
  exit 0
fi

# CANDIDATES_TSV rows: id<SEP>root_id<SEP>kind — one per candidate bead.
# Beads with no gc.root_bead_id (should already be excluded by
# --has-metadata-key, but tolerate a looser `bd list` implementation) are
# dropped here too.
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
    kind = meta.get('gc.kind') or ''
    if not bead_id or not root_id:
        continue
    row = [str(f).replace('\n', ' ').replace('\r', ' ').replace(SEP, ' ') for f in (bead_id, root_id, kind)]
    print(SEP.join(row))
" 2>/dev/null)"

if [ -z "${CANDIDATES_TSV// /}" ]; then
  echo "con-voyage-orphan-sweep: no eligible candidates (all missing gc.root_bead_id)"
  exit 0
fi

# rank_for_kind KIND — leaf beads (no gc.kind) rank 0 and close first;
# controllers close in the order the workflow tears down: scope-check ->
# scope -> ralph -> workflow-finalize. A non-empty kind this script doesn't
# recognize ranks LAST (fail-closed as a controller) rather than as a leaf,
# so a future engine-introduced kind this script hasn't been taught about
# doesn't get closed ahead of controllers that may depend on it (review
# fk-gypn9m BLOCKING-2 fold-in of iteration-1 LOW-3).
rank_for_kind() {
  case "$1" in
    "") printf '0' ;;
    scope-check) printf '1' ;;
    scope) printf '2' ;;
    ralph) printf '3' ;;
    workflow-finalize) printf '4' ;;
    *) printf '5' ;;
  esac
}

declare -A ROOT_STATUS=()
declare -A ROOT_REASON=()
declare -A ROOT_CLOSED_COUNT=()

PENDING=""

while IFS=$'\x1f' read -r bead_id root_id kind; do
  [ -n "${bead_id// /}" ] || continue
  [ -n "${root_id// /}" ] || continue

  if [ -z "${ROOT_STATUS[$root_id]+x}" ]; then
    local_status="" local_reason=""
    IFS=$'\x1f' read -r local_status local_reason <<< "$(bead_status "$root_id" close_reason)"
    ROOT_STATUS[$root_id]="$local_status"
    ROOT_REASON[$root_id]="$local_reason"
  fi

  [ "${ROOT_STATUS[$root_id]}" = "closed" ] || continue

  rank="$(rank_for_kind "$kind")"
  PENDING="${PENDING}${rank}$(printf '\x1f')${bead_id}$(printf '\x1f')${root_id}"$'\n'
done <<< "$CANDIDATES_TSV"

if [ -z "${PENDING// /}" ]; then
  echo "con-voyage-orphan-sweep: no candidates under a closed root this tick"
  exit 0
fi

# Stable sort by rank only — ties (same rank, different roots/ids) keep
# their original relative order, so leaf-first holds per-root regardless of
# interleaving across roots.
SORTED_PENDING="$(printf '%s' "$PENDING" | sort -t"$(printf '\x1f')" -k1,1n -s)"

# Pinned candidates (review fk-gypn9m BLOCKING-1/BLOCKING-3): a PINNED
# candidate is a deliberate human hold (e.g. an operator pinning a sample
# orphan for inspection) — force-closing it anyway would destroy exactly the
# evidence that hold was meant to preserve. Ordinary dependency/gate-blocked
# state (`bd blocked`) is NOT a human-hold signal: it is the normal state of
# every workflow controller (scope-check depends on its lanes, scope on
# scope-check, the ralph on scope, workflow-finalize on the ralph), and the
# leaf-first rank ordering above already closes those dependencies before
# their controllers — no separate skip is needed for it. Fetch the pinned
# set ONCE per tick (not once per candidate) and look candidates up
# in-process, mirroring the ROOT_STATUS cache above; wrap the one-time fetch
# in cv_with_timeout so a slow store degrades this tick to "treat everything
# as pinned, skip it all" (fail-safe) instead of hanging the whole order.
declare -A PINNED_SET=()
PINNED_FETCH_FAILED=0
PINNED_JSON="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" bd list --pinned --json 2>/dev/null)"
PINNED_FETCH_RC=$?
if [ "$PINNED_FETCH_RC" -ne 0 ] || [ -z "${PINNED_JSON// /}" ]; then
  PINNED_FETCH_FAILED=1
  echo "con-voyage-orphan-sweep: WARNING: bd list --pinned lookup failed; treating every candidate as pinned this tick" >&2
else
  while IFS= read -r pinned_id; do
    [ -n "$pinned_id" ] && PINNED_SET["$pinned_id"]=1
  done < <(printf '%s' "$PINNED_JSON" | python3 -c "
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
" 2>/dev/null)
fi

is_pinned_candidate() {
  local id="$1"
  [ "$PINNED_FETCH_FAILED" = "1" ] && return 0
  [ -n "${PINNED_SET[$id]+x}" ]
}

CLOSED_TOTAL=0
SKIPPED_PINNED_TOTAL=0

while IFS=$'\x1f' read -r _rank bead_id root_id; do
  [ -n "${bead_id// /}" ] || continue
  if [ "$CLOSED_TOTAL" -ge "$CV_ORPHAN_SWEEP_MAX_CLOSES" ]; then
    echo "con-voyage-orphan-sweep: reached CV_ORPHAN_SWEEP_MAX_CLOSES (${CV_ORPHAN_SWEEP_MAX_CLOSES}) this tick; remaining candidates will be picked up next tick"
    break
  fi

  if is_pinned_candidate "$bead_id"; then
    echo "con-voyage-orphan-sweep: SKIP (pinned/blocked) ${bead_id} (root ${root_id}); leaving open for human review"
    SKIPPED_PINNED_TOTAL=$((SKIPPED_PINNED_TOTAL + 1))
    continue
  fi

  root_reason="${ROOT_REASON[$root_id]:-}"
  close_reason="orphan-sweep: root ${root_id} closed"
  if [ -n "${root_reason// /}" ]; then
    close_reason="${close_reason} (${root_reason})"
  fi

  if ! "$GC" --city "$GC_CITY" bd update "$bead_id" \
      --set-metadata 'gc.outcome=skipped' \
      --set-metadata 'gc.work_outcome=abandoned' >/dev/null 2>&1; then
    echo "con-voyage-orphan-sweep: WARNING: could not stamp metadata on ${bead_id} (root ${root_id}); attempting close anyway" >&2
  fi

  if "$GC" --city "$GC_CITY" bd close "$bead_id" --reason "$close_reason" --force >/dev/null 2>&1; then
    CLOSED_TOTAL=$((CLOSED_TOTAL + 1))
    ROOT_CLOSED_COUNT[$root_id]=$(( ${ROOT_CLOSED_COUNT[$root_id]:-0} + 1 ))
  else
    echo "con-voyage-orphan-sweep: WARNING: bd close --force failed for ${bead_id} (root ${root_id}); will retry next tick" >&2
  fi
done <<< "$SORTED_PENDING"

if [ "$CLOSED_TOTAL" -eq 0 ]; then
  if [ "$SKIPPED_PINNED_TOTAL" -gt 0 ]; then
    echo "con-voyage-orphan-sweep: no candidates closed this tick (${SKIPPED_PINNED_TOTAL} skipped: pinned/gated)"
  else
    echo "con-voyage-orphan-sweep: no candidates actually closed this tick (all bd close attempts failed, or none found under a closed root)"
  fi
  exit 0
fi

ROOT_IDS_LIST=""
for root_id in "${!ROOT_CLOSED_COUNT[@]}"; do
  echo "con-voyage-orphan-sweep: root ${root_id}: closed ${ROOT_CLOSED_COUNT[$root_id]} descendant(s)"
  if [ -z "$ROOT_IDS_LIST" ]; then
    ROOT_IDS_LIST="$root_id"
  else
    ROOT_IDS_LIST="${ROOT_IDS_LIST}, ${root_id}"
  fi
done

skipped_suffix=""
skipped_sentence=""
if [ "$SKIPPED_PINNED_TOTAL" -gt 0 ]; then
  skipped_suffix=" (${SKIPPED_PINNED_TOTAL} skipped: pinned/gated)"
  skipped_sentence=" ${SKIPPED_PINNED_TOTAL} other candidate(s) under these roots were pinned or gate-blocked and left open for human review instead of being force-closed."
fi

mail_out="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
  "$GC" --city "$GC_CITY" mail send "$CV_ORPHAN_SWEEP_ESCALATE_TARGET" \
    -s "ORPHAN SWEEP: closed ${CLOSED_TOTAL} under roots ${ROOT_IDS_LIST}${skipped_suffix}" \
    -m "con-voyage-orphan-sweep closed ${CLOSED_TOTAL} stranded descendant bead(s) under already-closed workflow root(s): ${ROOT_IDS_LIST}. Each was left open by the engine re-minting work after its root closed (fk-ruuy6).${skipped_sentence}" \
    2>&1)"
mail_rc=$?
if [ "$mail_rc" -ne 0 ]; then
  echo "con-voyage-orphan-sweep: WARNING: digest mail to ${CV_ORPHAN_SWEEP_ESCALATE_TARGET} failed: ${mail_out}" >&2
fi

exit 0
