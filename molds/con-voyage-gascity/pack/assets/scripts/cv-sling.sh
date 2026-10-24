#!/usr/bin/env bash
# cv-sling.sh — start con-voyages, honoring an optional per-city cap on how
# many run at once.
#
# Usage:
#   cv-sling.sh start <target> <work-bead> [gc sling args...]
#   cv-sling.sh drain          dispatch queued starts while slots are free
#   cv-sling.sh status         cap, active journeys, queue
#   cv-sling.sh limit          print the effective cap (0 = uncapped)
#
# `start` is how the facilitator launches a journey. It adds `--on con-voyage`
# itself, so `cv-sling.sh start <target> <bead> --var push=true ...` is
# `gc sling <target> <bead> --on con-voyage --var push=true ...`.
#
# THE CAP IS OFF BY DEFAULT. With no cap configured, `start` is exactly that
# gc sling: no store queries, no lock, no queue. A city opts in by committing
# a con-voyage.toml at its root:
#
#   [con_voyage]
#   max_concurrent = 1
#
# CV_MAX_CONCURRENT, when set, overrides the file (handy for a one-off). 0,
# absent, or a value that isn't a non-negative integer (warned) all mean
# uncapped. Raising or removing the cap takes effect on the next start/drain;
# no restart or re-cast is needed.
#
# With a cap of N, a journey is "active" while its graph.v2 workflow root
# (gc.kind=workflow, gc.formula_name=con-voyage) is open or in_progress, in
# the city store or any rig store. `start` slings when fewer than N are active
# and nothing is already queued; otherwise it QUEUES the start under
# CV_QUEUE_DIR (one record per work bead, FIFO) and exits 0. The
# con-voyage-queue-drain order runs `drain` on a cooldown: it slings the
# oldest queued starts while slots are free (every one of them once the cap is
# lifted) and mails the mayor about each, so the facilitator picks the journey
# up from there. A queued start whose sling fails CV_QUEUE_MAX_ATTEMPTS times
# is moved to CV_QUEUE_DIR/failed/ and the mayor is mailed.
#
# Fails closed: when the active count can't be read (a store or `gc rig list`
# query fails or times out), `start` queues instead of slinging and `drain`
# dispatches nothing that cycle. Queued argv is stored NUL-separated and
# replayed as an argv array, never through a shell.
#
# Environment (all optional):
#   GC                             gc binary (default: gc)
#   GC_CITY                        city root (default: .)
#   CV_MAX_CONCURRENT              cap override (see above)
#   CV_CONCURRENCY_CONFIG          settings file (default: $GC_CITY/con-voyage.toml)
#   CV_QUEUE_DIR                   queue location (default: $GC_CITY/.gc/cv-queue)
#   CV_QUEUE_MAX_ATTEMPTS          sling failures before set-aside (default: 3)
#   CV_QUEUE_NOTIFY_TARGET         mail recipient (default: mayor)
#   CV_SLING_STORE_TIMEOUT_SECONDS bound on each store/mail call (default: 30)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=con-voyage-lib.sh
. "${SCRIPT_DIR}/con-voyage-lib.sh"

GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_CONCURRENCY_CONFIG="${CV_CONCURRENCY_CONFIG:-${GC_CITY}/con-voyage.toml}"
CV_QUEUE_DIR="${CV_QUEUE_DIR:-${GC_CITY}/.gc/cv-queue}"
CV_QUEUE_MAX_ATTEMPTS="${CV_QUEUE_MAX_ATTEMPTS:-3}"
CV_QUEUE_NOTIFY_TARGET="${CV_QUEUE_NOTIFY_TARGET:-mayor}"
CV_SLING_STORE_TIMEOUT_SECONDS="${CV_SLING_STORE_TIMEOUT_SECONDS:-30}"
LOCK_DIR="${CV_QUEUE_DIR}/.lock"
LOCK_WAIT_SECONDS=30
LOCK_STALE_MINUTES=10

usage() {
  cat >&2 <<'EOF'
usage: cv-sling.sh start <target> <work-bead> [gc sling args...]
       cv-sling.sh drain
       cv-sling.sh status
       cv-sling.sh limit
EOF
  exit 2
}

# ---------------------------------------------------------------------------
# Cap
# ---------------------------------------------------------------------------

# read_config_cap — print [con_voyage].max_concurrent from the settings file,
# empty when the file or key is absent, or "!<repr>" when present but not an
# integer.
read_config_cap() {
  [ -f "$CV_CONCURRENCY_CONFIG" ] || return 0
  python3 - "$CV_CONCURRENCY_CONFIG" <<'PY' 2>/dev/null
import sys
try:
    import tomllib
except ImportError:
    sys.exit(0)
try:
    with open(sys.argv[1], 'rb') as fh:
        data = tomllib.load(fh)
except Exception as exc:
    print('!unparseable (%s)' % exc)
    sys.exit(0)
val = (data.get('con_voyage') or {}).get('max_concurrent')
if val is None:
    sys.exit(0)
if isinstance(val, int) and not isinstance(val, bool):
    print(val)
else:
    print('!%r' % (val,))
PY
}

# resolve_cap — set CAP (0 = uncapped) and CAP_SOURCE (where it came from).
resolve_cap() {
  local raw
  if [ -n "${CV_MAX_CONCURRENT:-}" ]; then
    raw="$CV_MAX_CONCURRENT"; CAP_SOURCE="CV_MAX_CONCURRENT"
  else
    raw="$(read_config_cap)"; CAP_SOURCE="$CV_CONCURRENCY_CONFIG"
  fi
  CAP=0
  if [ -z "$raw" ]; then
    CAP_SOURCE="unset"
    return
  fi
  case "$raw" in
    *[!0-9]*)
      echo "cv-sling: WARNING: max_concurrent from ${CAP_SOURCE} is not a non-negative integer (got ${raw#!}); treating as uncapped" >&2
      ;;
    *) CAP=$((10#$raw)) ;;
  esac
}

# ---------------------------------------------------------------------------
# Active journeys
# ---------------------------------------------------------------------------

# filter_roots — read one `bd list --json` array on stdin; print one
# "<created_at> <id> <status>" line per open/in_progress con-voyage root.
# Exits non-zero on unparseable input.
filter_roots() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
for d in data:
    if not isinstance(d, dict):
        continue
    meta = d.get("metadata") or {}
    if meta.get("gc.kind") != "workflow" or meta.get("gc.formula_name") != "con-voyage":
        continue
    if d.get("status") not in ("open", "in_progress"):
        continue
    row = [str(d.get("created_at") or "-"), str(d.get("id") or "-"), str(d.get("status"))]
    print(" ".join(f.replace("\n", " ").replace(" ", "_") for f in row))
' 2>/dev/null
}

# query_store [--rig NAME] — print filtered root lines for one store; return
# non-zero when the query fails, times out, or returns nothing parseable.
query_store() {
  local out
  out="$(cv_with_timeout "$CV_SLING_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" "$@" \
    bd list --status open,in_progress --metadata-field gc.kind=workflow --json --limit 0 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | filter_roots
}

# active_roots — print every active con-voyage root (deduped, oldest first)
# across the city store and every non-HQ rig store. Returns non-zero when any
# store can't be read: an undercount would breach the cap.
active_roots() {
  local rigs_json rig_names rig lines more
  lines="$(query_store)" || return 1
  rigs_json="$(cv_with_timeout "$CV_SLING_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" rig list --json 2>/dev/null)" || return 1
  [ -n "$rigs_json" ] || return 1
  rig_names="$(printf '%s' "$rigs_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data.get("rigs") or []:
    if isinstance(r, dict) and not r.get("hq") and r.get("name"):
        print(r["name"])
' 2>/dev/null)" || return 1
  while IFS= read -r rig; do
    [ -n "$rig" ] || continue
    more="$(query_store --rig "$rig")" || return 1
    lines="${lines}"$'\n'"${more}"
  done <<< "$rig_names"
  printf '%s\n' "$lines" | awk 'NF && !seen[$2]++' | sort
}

# count_active — set ACTIVE (count) and ACTIVE_LINES; return non-zero when
# the count is unknown.
count_active() {
  ACTIVE_LINES="$(active_roots)" || return 1
  ACTIVE="$(printf '%s' "$ACTIVE_LINES" | grep -c . || true)"
}

# ---------------------------------------------------------------------------
# Queue
# ---------------------------------------------------------------------------

lock_acquire() {
  mkdir -p "$CV_QUEUE_DIR" || return 1
  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null
      continue
    fi
    [ "$waited" -ge "$LOCK_WAIT_SECONDS" ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
}

queued_records() {
  find "$CV_QUEUE_DIR" -maxdepth 1 -name '*.sling' 2>/dev/null | sort
}

# read_record FILE — load a record's argv into REC_ARGS.
read_record() {
  REC_ARGS=()
  local a
  while IFS= read -r -d '' a; do REC_ARGS+=("$a"); done < "$1"
}

# find_queued BEAD — print the record queuing BEAD, if any.
find_queued() {
  local rec
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    read_record "$rec"
    [ "${REC_ARGS[1]:-}" = "$1" ] && { printf '%s' "$rec"; return 0; }
  done < <(queued_records)
  return 1
}

enqueue() {
  local seq_file="${CV_QUEUE_DIR}/.seq" seq rec
  seq="$(cat "$seq_file" 2>/dev/null)"
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  seq=$((10#$seq + 1))
  printf '%d\n' "$seq" > "$seq_file"
  rec="$(printf '%s/%010d.sling' "$CV_QUEUE_DIR" "$seq")"
  printf '%s\0' "$@" > "${rec}.tmp" && mv -f "${rec}.tmp" "$rec"
}

notify() {
  cv_with_timeout "$CV_SLING_STORE_TIMEOUT_SECONDS" "$GC" mail send "$CV_QUEUE_NOTIFY_TARGET" \
    -s "$1" -m "$2" >/dev/null 2>&1 \
    || echo "cv-sling: WARNING: could not mail ${CV_QUEUE_NOTIFY_TARGET}: $1" >&2
}

sling() {
  local target="$1" bead="$2"; shift 2
  "$GC" sling "$target" "$bead" --on con-voyage "$@" < /dev/null
}

# drain_locked SLOTS — sling queued starts oldest-first; SLOTS < 0 means
# uncapped. Caller holds the lock.
drain_locked() {
  local slots="$1" rec attempts_file attempts bead
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    [ "$slots" -eq 0 ] && break
    read_record "$rec"
    bead="${REC_ARGS[1]:-}"
    if sling "${REC_ARGS[@]}"; then
      rm -f "$rec" "${rec%.sling}.attempts"
      echo "cv-sling: dequeued and started con-voyage for ${bead}"
      notify "con-voyage started from queue: ${bead}" \
        "The concurrency queue freed a slot and slung ${bead} (gc sling ${REC_ARGS[*]:0:2} --on con-voyage). Pick the journey up as usual."
      [ "$slots" -gt 0 ] && slots=$((slots - 1))
    else
      attempts_file="${rec%.sling}.attempts"
      attempts="$(cat "$attempts_file" 2>/dev/null)"
      case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
      attempts=$((attempts + 1))
      if [ "$attempts" -ge "$CV_QUEUE_MAX_ATTEMPTS" ]; then
        mkdir -p "${CV_QUEUE_DIR}/failed"
        mv -f "$rec" "${CV_QUEUE_DIR}/failed/" && rm -f "$attempts_file"
        echo "cv-sling: WARNING: sling for ${bead} failed ${attempts} times; moved to ${CV_QUEUE_DIR}/failed/" >&2
        notify "con-voyage queue: start for ${bead} set aside" \
          "Slinging the queued con-voyage for ${bead} failed ${attempts} times. The record is in ${CV_QUEUE_DIR}/failed/. Fix the cause, then start it again with cv-sling.sh start."
      else
        printf '%d\n' "$attempts" > "$attempts_file"
        echo "cv-sling: WARNING: sling for ${bead} failed (attempt ${attempts}/${CV_QUEUE_MAX_ATTEMPTS}); kept queued" >&2
      fi
    fi
  done < <(queued_records)
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_start() {
  [ $# -ge 2 ] && [ -n "$1" ] && [ -n "$2" ] || usage
  local a
  for a in "${@:3}"; do
    case "$a" in --on|--on=*) echo "cv-sling: --on is not allowed; cv-sling always slings --on con-voyage" >&2; usage ;; esac
  done
  resolve_cap
  local cap="$CAP"
  if [ "$cap" -eq 0 ]; then
    sling "$@"
    return
  fi

  local bead="$2"
  lock_acquire || { echo "cv-sling: queue is busy (lock held); retry shortly" >&2; return 1; }
  if find_queued "$bead" >/dev/null; then
    echo "cv-sling: ${bead} is already queued; nothing to do"
    return 0
  fi
  local reason
  if ! count_active; then
    reason="could not count active con-voyages (store query failed); failing closed"
  elif [ -n "$(queued_records)" ]; then
    reason="active ${ACTIVE}/${cap}, and earlier starts are queued ahead of it"
  elif [ "$ACTIVE" -ge "$cap" ]; then
    reason="active ${ACTIVE}/${cap}"
  else
    echo "cv-sling: starting con-voyage for ${bead} (active ${ACTIVE}/${cap})"
    sling "$@"
    return
  fi
  enqueue "$@" || { echo "cv-sling: could not write the queue record under ${CV_QUEUE_DIR}" >&2; return 1; }
  echo "cv-sling: QUEUED con-voyage for ${bead}: ${reason}. con-voyage-queue-drain starts it when a slot frees."
  # Earlier starts may be waiting on a slot that is already free.
  if [ -n "${ACTIVE:-}" ] && [ "$ACTIVE" -lt "$cap" ]; then
    drain_locked $((cap - ACTIVE))
  fi
  return 0
}

cmd_drain() {
  [ -n "$(queued_records)" ] || return 0
  lock_acquire || { echo "cv-sling: queue is busy (lock held); skipping this cycle"; return 0; }
  resolve_cap
  local cap="$CAP"
  if [ "$cap" -eq 0 ]; then
    drain_locked -1
    return 0
  fi
  if ! count_active; then
    echo "cv-sling: WARNING: could not count active con-voyages; dispatching nothing this cycle" >&2
    return 0
  fi
  if [ "$ACTIVE" -ge "$cap" ]; then
    echo "cv-sling: at cap (active ${ACTIVE}/${cap}); $(queued_records | grep -c .) start(s) still queued"
    return 0
  fi
  drain_locked $((cap - ACTIVE))
}

cmd_status() {
  local cap rec n=0
  resolve_cap
  cap="$CAP"
  if [ "$cap" -eq 0 ]; then
    echo "max_concurrent: uncapped (source: ${CAP_SOURCE})"
  else
    echo "max_concurrent: ${cap} (source: ${CAP_SOURCE})"
  fi
  if count_active; then
    echo "active: ${ACTIVE}"
    [ -n "$ACTIVE_LINES" ] && printf '%s\n' "$ACTIVE_LINES" | awk '{print "  " $2 "  " $3 "  created " $1}'
  else
    echo "active: unknown (store query failed)"
  fi
  echo "queued: $(queued_records | grep -c .)"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    n=$((n + 1))
    read_record "$rec"
    echo "  ${n}. ${REC_ARGS[1]:-?} -> ${REC_ARGS[0]:-?}"
  done < <(queued_records)
  echo "failed: $(find "${CV_QUEUE_DIR}/failed" -maxdepth 1 -name '*.sling' 2>/dev/null | grep -c .)"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  start) cmd_start "$@" ;;
  drain) cmd_drain ;;
  status) cmd_status ;;
  limit) resolve_cap; echo "$CAP" ;;
  *) usage ;;
esac
