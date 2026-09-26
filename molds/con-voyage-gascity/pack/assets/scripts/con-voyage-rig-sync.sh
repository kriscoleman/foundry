#!/usr/bin/env bash
# con-voyage-rig-sync.sh — keep each rig's local default branch fast-forwarded
# to origin (fk-hewd2; operator directive, Slack #repl-city-mayor,
# 2026-09-26: "We need our rigs to try and be synced with main consistently."
# foundry-kc's local main had sat 18 commits behind origin/main, feeding
# stale-base con-voyage builds).
#
# WHAT IT DOES, per registered rig (via `gc rig list --json`, skipping the
# HQ city root and any rig with no configured default_branch):
#   1. `git fetch origin` (bounded by cv_with_timeout — the only network call
#      this script makes).
#   2. Fast-forward the rig ROOT's local default branch to origin
#      (`git merge --ff-only`) ONLY when the root is already checked out on
#      that branch AND its tracked tree is clean. A single `merge --ff-only`
#      handles both "behind" (advances) and "already current" (no-op,
#      trivially succeeds) identically — no separate ahead/behind check
#      needed.
#   3. Never switches branches, stashes, resets, or rebases — a rig that
#      isn't already on its default branch, or isn't clean, is left exactly
#      as found and just reported.
#
# WHAT IT NEVER DOES: touch rigs/*/worktrees/ (con-voyage's own build/review
# worktrees — this script only ever runs git against the rig ROOT path `gc
# rig list` reports), or touch the HQ city root (no rig path of its own,
# managed by hand).
#
# REPORTING: a rig that can't be fast-forwarded (dirty, diverged, on another
# branch, or a failed fetch) is logged every cycle but mailed to
# CV_RIG_SYNC_ESCALATE_TARGET (default: mayor) only on a STATE CHANGE — a
# per-rig ".state" file under CV_STATE_DIR remembers the last reported state
# so a persisting problem doesn't re-mail every cycle, and recovering to "ok"
# resets the baseline so a later regression mails again. Two overlapping runs
# of this script (a cooldown firing again before the prior one finished) are
# serialized per-rig by a portable mkdir-based lock — the same primitive
# fk-11yuv added to con-voyage-repair-watchdog.sh (not yet lifted into
# con-voyage-lib.sh as a shared helper — fk-8b5fl — so it is duplicated here
# rather than half-shared).
#
# Environment / configuration (all optional with sane defaults):
#
#   GC                 Path to the gc binary (default: gc)
#   GC_CITY            City root passed to gc (default: current directory)
#   CV_STATE_DIR       Directory holding one "<rig-name>.state" record per
#                      monitored rig (default: "${GC_CITY:-.}/.gc/cv-rig-sync"
#                      — city-scoped, since this order fans out across every
#                      registered rig from a single city-level invocation,
#                      unlike con-voyage-pr-watch.sh/con-voyage-repair-
#                      watchdog.sh's own single-rig-scoped CV_STATE_DIR).
#   CV_RIG_SYNC_ESCALATE_TARGET  Mail recipient for a rig that can't be
#                      fast-forwarded. Default: "mayor" (the operator
#                      directive that created this order was specifically to
#                      mail the mayor; override for a city with no such
#                      alias).
#   CV_RIG_SYNC_FETCH_TIMEOUT_SECONDS  Wall-clock bound for `git fetch origin`
#                      (macOS has no `timeout(1)` — see cv_with_timeout in
#                      con-voyage-lib.sh). Default: 60.
#   CV_LOCK_STALE_SECONDS  Seconds after which a held per-rig lock is presumed
#                      abandoned (crashed holder) and stolen rather than left
#                      to wedge that rig's monitoring forever. Default: 300.
#
# Exit codes:
#   0 — completed (some, all, or none of the registered rigs needed action)
#   Non-zero — fatal setup error (gc/git/python3 missing)
#
# The order controller treats any non-zero exit as a transient failure and
# retries on the next cooldown interval.
#
# Requires: bash 4+, gc CLI, git, python3.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"

# Sourced for cv_with_timeout only (functions only, no side effects at source
# time — see the file's own header). Resolved relative to THIS script's own
# location, never a `find $GC_CITY` search (fk-q2pon: deterministic lib/script
# resolution — the live pack's copy of this script sits right next to its own
# copy of con-voyage-lib.sh, so BASH_SOURCE always resolves the matching one).
# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

CV_STATE_DIR="${CV_STATE_DIR:-${GC_CITY:-.}/.gc/cv-rig-sync}"
CV_RIG_SYNC_ESCALATE_TARGET="${CV_RIG_SYNC_ESCALATE_TARGET:-mayor}"
CV_RIG_SYNC_FETCH_TIMEOUT_SECONDS="${CV_RIG_SYNC_FETCH_TIMEOUT_SECONDS:-60}"
CV_LOCK_STALE_SECONDS="${CV_LOCK_STALE_SECONDS:-300}"

# Malformed numeric overrides fail safe to the documented default, same
# posture as every other tunable in this pack (con-voyage-repair-watchdog.sh).
case "$CV_RIG_SYNC_FETCH_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_RIG_SYNC_FETCH_TIMEOUT_SECONDS="60" ;;
esac
case "$CV_LOCK_STALE_SECONDS" in
  *[!0-9]*|'') CV_LOCK_STALE_SECONDS="300" ;;
esac

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-rig-sync: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "con-voyage-rig-sync: ERROR: git not found." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-rig-sync: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

mkdir -p "$CV_STATE_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# Per-rig mutual exclusion (mirrors con-voyage-repair-watchdog.sh's fk-11yuv
# Fix 2b lock exactly — see this file's header for why it is a local copy,
# not yet a shared con-voyage-lib.sh helper). `mkdir` is atomic on every POSIX
# filesystem this pack runs on, so it doubles as a lock primitive without
# depending on `flock` (not reliably available on macOS).
# ---------------------------------------------------------------------------
CV_LOCK_DIR="${CV_STATE_DIR}/.locks"

# acquire_lock RIG_NAME — exit 0 (lock held) or 1 (held by someone else and
# not stale). A stale lock (older than CV_LOCK_STALE_SECONDS — a crashed or
# hung holder) is stolen rather than left to wedge that rig's record forever.
acquire_lock() {
  local rig_name="$1"
  local lockdir="${CV_LOCK_DIR}/${rig_name}.lock"
  mkdir -p "$CV_LOCK_DIR" 2>/dev/null
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\n' "$$" > "${lockdir}/pid" 2>/dev/null || true
    return 0
  fi
  # Held already (or a crashed holder's leftover). Steal attempts are
  # serialized behind a second, fixed-path mkdir mutex so only one contender
  # ever judges staleness and acts on it — see con-voyage-repair-watchdog.sh's
  # acquire_lock for the full rationale (this is the same algorithm).
  local steal_mutex="${lockdir}.stealing"
  if ! mkdir "$steal_mutex" 2>/dev/null; then
    return 1
  fi
  if python3 -c "
import os, sys, time
try:
    age = time.time() - os.stat(sys.argv[1]).st_mtime
except Exception:
    sys.exit(1)
sys.exit(0 if age > float(sys.argv[2]) else 1)
" "$lockdir" "$CV_LOCK_STALE_SECONDS" 2>/dev/null; then
    rm -rf "$lockdir" 2>/dev/null
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "${lockdir}/pid" 2>/dev/null || true
      echo "con-voyage-rig-sync: NOTICE: stole stale lock for ${rig_name} (>${CV_LOCK_STALE_SECONDS}s; prior holder presumed dead)" >&2
      rm -rf "$steal_mutex" 2>/dev/null
      return 0
    fi
  fi
  rm -rf "$steal_mutex" 2>/dev/null
  return 1
}

# release_lock RIG_NAME — always safe to call even if the lock was never
# acquired.
release_lock() {
  local rig_name="$1"
  rm -rf "${CV_LOCK_DIR}/${rig_name}.lock" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Per-rig state (dedicated minimal schema — a rig's sync status has nothing
# in common with con-voyage-pr-watch.sh/con-voyage-repair-watchdog.sh's
# per-PR state, so it gets its own file format rather than overloading
# theirs). One "<rig-name>.state" file, two fields.
# ---------------------------------------------------------------------------

# rig_sync_state_read RIG_NAME — sets RS_LAST_STATE (default "unknown").
rig_sync_state_read() {
  local rig_name="$1"
  local f="${CV_STATE_DIR}/${rig_name}.state"
  RS_LAST_STATE="unknown"
  if [ -f "$f" ]; then
    local k v
    while IFS='=' read -r k v || [ -n "$k" ]; do
      case "$k" in
        last_state) [ -n "$v" ] && RS_LAST_STATE="$v" ;;
      esac
    done < "$f"
  fi
}

# rig_sync_state_write RIG_NAME STATE
rig_sync_state_write() {
  local rig_name="$1" state="$2"
  local f="${CV_STATE_DIR}/${rig_name}.state"
  {
    printf 'last_state=%s\n' "$state"
    printf 'updated_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  } > "$f"
}

# ---------------------------------------------------------------------------
# report_rig_state RIG_NAME STATE DETAIL DEFAULT_BRANCH — log every cycle;
# mail CV_RIG_SYNC_ESCALATE_TARGET only when STATE differs from the last
# reported state for this rig (dedup "at most once per state change" — a
# persisting problem is logged but not re-mailed; recovering to "ok" resets
# the baseline so a later regression mails again).
# ---------------------------------------------------------------------------
report_rig_state() {
  local rig_name="$1" state="$2" detail="$3" default_branch="$4"

  rig_sync_state_read "$rig_name"
  local prior="$RS_LAST_STATE"

  if [ "$state" = "ok" ]; then
    echo "con-voyage-rig-sync: OK ${rig_name} — ${detail}"
    [ "$prior" != "$state" ] && rig_sync_state_write "$rig_name" "$state"
    return
  fi

  echo "con-voyage-rig-sync: WARNING: ${rig_name} (${state}) — ${detail}" >&2

  if [ "$prior" = "$state" ]; then
    echo "con-voyage-rig-sync: SKIP mail for ${rig_name} — already reported '${state}' this state-change"
    return
  fi

  if "$GC" --city "$GC_CITY" mail send "$CV_RIG_SYNC_ESCALATE_TARGET" \
    -s "con-voyage-rig-sync: ${rig_name} needs attention (${state})" \
    -m "Rig '${rig_name}' could not be fast-forwarded to origin/${default_branch}: ${detail}. It has been left untouched — no branch switch, stash, reset, or rebase was attempted." \
    2>&1; then
    rig_sync_state_write "$rig_name" "$state"
  else
    echo "con-voyage-rig-sync: WARNING: mail to ${CV_RIG_SYNC_ESCALATE_TARGET} failed for ${rig_name}; will retry next cycle" >&2
  fi
}

# ---------------------------------------------------------------------------
# process_rig RIG_NAME RIG_PATH DEFAULT_BRANCH — classify and, when safe,
# fast-forward exactly one rig. Called with that rig's lock already held.
# ---------------------------------------------------------------------------
process_rig() {
  local rig_name="$1" rig_path="$2" default_branch="$3"

  if [ ! -d "$rig_path" ]; then
    echo "con-voyage-rig-sync: WARNING: rig '${rig_name}' path '${rig_path}' does not exist; skipping" >&2
    return
  fi

  local fetch_out
  if ! fetch_out="$(cv_with_timeout "$CV_RIG_SYNC_FETCH_TIMEOUT_SECONDS" git -C "$rig_path" fetch origin 2>&1)"; then
    report_rig_state "$rig_name" "fetch_failed" "git fetch origin failed or timed out: ${fetch_out}" "$default_branch"
    return
  fi

  local current_branch
  current_branch="$(git -C "$rig_path" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$current_branch" != "$default_branch" ]; then
    report_rig_state "$rig_name" "other_branch" "checked out on '${current_branch}', not the default branch '${default_branch}'" "$default_branch"
    return
  fi

  if [ -n "$(git -C "$rig_path" status --porcelain 2>/dev/null)" ]; then
    report_rig_state "$rig_name" "dirty" "working tree has uncommitted changes" "$default_branch"
    return
  fi

  local merge_out
  if merge_out="$(git -C "$rig_path" merge --ff-only "origin/${default_branch}" 2>&1)"; then
    report_rig_state "$rig_name" "ok" "fast-forwarded (or already current): ${merge_out}" "$default_branch"
  else
    report_rig_state "$rig_name" "diverged" "local '${default_branch}' has commits origin does not (not fast-forwardable): ${merge_out}" "$default_branch"
  fi
}

# ---------------------------------------------------------------------------
# Rig discovery. `gc rig list --json` enumerates every registered rig; skip
# the HQ city root (no rig path of its own, managed by hand) and any rig with
# no configured default_branch (nothing to fast-forward).
# ---------------------------------------------------------------------------
RIGS_JSON="$("$GC" --city "$GC_CITY" rig list --json 2>/dev/null)"
RIG_LIST_FAILED=0
if [ -z "$RIGS_JSON" ]; then
  RIG_LIST_FAILED=1
  RIGS_JSON='{"rigs":[]}'
fi

RIGS_TSV="$(printf '%s' "$RIGS_JSON" | python3 -c "
import json, sys
SEP = '\x1f'
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
for r in data.get('rigs') or []:
    if not isinstance(r, dict) or r.get('hq'):
        continue
    name = r.get('name') or ''
    path = r.get('path') or ''
    branch = r.get('default_branch') or ''
    if not name or not path or not branch:
        continue
    row = [str(f).replace('\n', ' ').replace('\r', ' ').replace(SEP, ' ') for f in (name, path, branch)]
    print(SEP.join(row))
" 2>/dev/null)"
[ "$?" -eq 0 ] || RIG_LIST_FAILED=1

if [ "$RIG_LIST_FAILED" -eq 1 ]; then
  echo "con-voyage-rig-sync: WARNING: 'gc rig list --json' returned nothing/unparseable; skipping this cycle" >&2
  exit 0
fi

if [ -z "$RIGS_TSV" ]; then
  echo "con-voyage-rig-sync: no eligible rigs found (all HQ, or missing default_branch)"
  exit 0
fi

while IFS=$'\x1f' read -r rig_name rig_path default_branch; do
  [ -n "$rig_name" ] || continue

  if ! acquire_lock "$rig_name"; then
    echo "con-voyage-rig-sync: SKIP ${rig_name} — locked by a concurrent run"
    continue
  fi

  process_rig "$rig_name" "$rig_path" "$default_branch"

  release_lock "$rig_name"
done <<< "$RIGS_TSV"

exit 0
