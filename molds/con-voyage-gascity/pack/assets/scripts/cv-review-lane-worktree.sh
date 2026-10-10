#!/usr/bin/env bash
# cv-review-lane-worktree.sh — per-lane worktree isolation for con-voyage
# review lanes (fk-q659).
#
# WHY: every con-voyage review lane for a work item (acceptance, test-evidence,
# simplicity, security, code, and the optional persona roster) reads the
# review context's recorded source-anchor work_dir. Lanes that verify the
# implementation run build/test — and the floor lanes without a "do not modify
# code" restriction (acceptance, test-evidence, simplicity) may also do
# mutate-run-revert verification: temporarily edit a file, run a command,
# revert. When every lane points at the SAME physical directory, one lane's
# in-flight edit or build artifact can be observed mid-flight by another
# lane's concurrent build/test, producing a false BLOCKING or false-negative
# finding (LIVE finding: a transient edit to restore.go raced a concurrent go
# build/test). This script gives each lane its own throwaway linked git
# worktree, checked out at the exact commit the source anchor is sitting on,
# so lane-local execution can never be observed by another lane.
#
# Usage:
#   cv-review-lane-worktree.sh acquire <source-work-dir> <lane-id>
#   cv-review-lane-worktree.sh sweep <source-work-dir> [--force]
#
# acquire prints the absolute lane worktree path on stdout (and only that) on
# success. Idempotent and re-run-safe: calling acquire again with the same
# <source-work-dir> and <lane-id> reuses the same worktree path, but first
# resets it to the source's CURRENT HEAD commit and wipes any dirty/untracked
# state — con-voyage's review loop re-runs the same lane beads against a new
# diff after fixes are pushed, so a reused lane worktree must never serve
# stale content or a prior cycle's leftover mutation.
#
# sweep removes every lane worktree previously acquired for <source-work-dir>
# (matched by the `--review-` naming convention below) WHOSE LANE-ID RESOLVES
# AS A CLOSED BEAD (fk-vqzpq9). The lane-id passed to `acquire` is each lane's
# own review bead id, so sweep reads it back via `gc bd show <lane-id>
# --json` and only reaps a worktree whose bead is closed. A lane worktree
# whose bead is still open/in_progress — or whose status cannot be resolved
# at all (no `gc`/con-voyage-lib.sh on PATH, a lookup failure, ...) — is
# SKIPPED and reported, never removed: fail safe, not fail open. Evidence
# (2026-10-08, workflow fk-2l3c8i iteration 2): a review LANE (not
# synthesize-review) ran sweep after closing its own bead and reaped a
# still-in_progress sibling lane's worktree out from under it.
#
# Pass --force to also reap a lane worktree whose bead status could not be
# resolved at all (no gc/lib on PATH, lookup failure, timeout) — for
# synthesize-review's own post-cycle sweep, which runs once all lanes are
# expected to have reported and closed, so an unresolvable lookup shouldn't
# leak the worktree forever. --force never reaps a lane bead that resolves to
# a genuinely open/in_progress status: a lane can still be live (reopened by a
# finding regrade racing synthesis, fk-ekufmt) even during this "everyone
# should be closed" pass, and that must never be torn down regardless of
# --force.
#
# sweep never touches <source-work-dir> itself or any worktree that does not
# match the convention.
#
# Exit codes:
#   0 — success
#   1 — usage/validation error, or (acquire/sweep) an underlying git operation
#       failed
#
# Requires: bash 4+, git.

set -uo pipefail

die() {
  echo "cv-review-lane-worktree: ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  cv-review-lane-worktree.sh acquire <source-work-dir> <lane-id>
  cv-review-lane-worktree.sh sweep <source-work-dir> [--force]
USAGE
}

LANE_SUFFIX_MARK="--review-"

require_git_worktree() {
  local dir="$1" label="$2"
  [ -n "$dir" ] || { usage; die "${label}: a source-work-dir argument is required"; }
  case "$dir" in
    /*) : ;;
    *) die "${label}: '${dir}' must be an absolute path" ;;
  esac
  [ -d "$dir" ] || die "${label}: '${dir}' is not a directory"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "${label}: '${dir}' is not inside a git working tree"
}

# canonicalize_dir <dir> — resolve symlinks (e.g. macOS /var -> /private/var)
# so the path we build lane worktree names from matches, byte for byte, what
# `git worktree list` reports. Without this, the reuse/idempotency check below
# can spuriously treat a freshly created lane worktree as "not a worktree of"
# its own source.
canonicalize_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# sanitize_lane_id <lane-id> — collapse anything outside [A-Za-z0-9_-] to '_'
# so an unexpected lane-id (path separators, "..", whitespace) can never
# escape the worktrees/ parent directory or break the deterministic path. '.'
# is deliberately excluded from the allowed set so ".." can never survive
# sanitization as a literal substring.
sanitize_lane_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

lane_dir_for() {
  local src="$1" lane_id="$2"
  local parent base
  parent="$(dirname "$src")"
  base="$(basename "$src")"
  printf '%s/%s%s%s' "$parent" "$base" "$LANE_SUFFIX_MARK" "$lane_id"
}

# sync_lock_dir SRC — fk-dy2ygk: MUST derive the identical path
# con-voyage-lib.sh's cv_worktree_sync_lock_dir computes for the same SRC —
# the two files intentionally duplicate this one-line convention rather than
# share a sourced dependency, so this standalone script keeps working with no
# con-voyage-lib.sh on PATH. If you change this, change the other side too.
sync_lock_dir() {
  printf '%s' "${1%/}.cvsynclock"
}

# sync_lock_is_dead_or_stale LOCKDIR STALE_SECONDS — review fk-hbsmk
# BLOCKING-2: true (0) only when LOCKDIR is both older than STALE_SECONDS AND
# its recorded holder pid is no longer alive (or never recorded). Mirrors
# con-voyage-lib.sh's _cv_worktree_sync_lock_is_dead_or_stale exactly; see
# that function's doc comment for why mtime age alone is insufficient. Caller
# must already hold the steal mutex before calling this.
sync_lock_is_dead_or_stale() {
  local lockdir="$1" stale="$2"
  python3 -c "
import os, sys, time
try:
    age = time.time() - os.stat(sys.argv[1]).st_mtime
except Exception:
    sys.exit(1)
sys.exit(0 if age > float(sys.argv[2]) else 1)
" "$lockdir" "$stale" 2>/dev/null || return 1
  local holder_pid
  holder_pid="$(cat "${lockdir}/pid" 2>/dev/null || true)"
  if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
    return 1
  fi
  return 0
}

# sync_lock_acquire SRC — blocks (bounded, with stale-lock reclaim) until no
# cv_sync_worktree_to_base call holds the lock on SRC. THE BUG this closes:
# acquire below reads SRC's HEAD and forks a private lane worktree from it;
# without this, that read can land mid-fetch/rebase in
# cv_sync_worktree_to_base and observe a transient or stale HEAD (live
# evidence 2026-10-04..2026-10-06: review lanes grading phantom/stale code on
# the shared rereview worktree). Mirrors
# con-voyage-lib.sh's cv_worktree_sync_lock_acquire exactly (including the
# steal-mutex-serialized, liveness-checked reclaim added for review fk-hbsmk
# BLOCKING-2, and the ownership token printed to stdout for BLOCKING-1); kept
# duplicated here rather than sourced for the same standalone-script reason
# as the path convention above.
sync_lock_acquire() {
  local dir="$1"
  local timeout="${CV_WORKTREE_SYNC_LOCK_TIMEOUT_SECONDS:-120}"
  local stale="${CV_WORKTREE_SYNC_LOCK_STALE_SECONDS:-600}"
  local lockdir
  lockdir="$(sync_lock_dir "$dir")"
  local waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    local reclaimed=0
    local steal_mutex="${lockdir}.stealing"
    if mkdir "$steal_mutex" 2>/dev/null; then
      if sync_lock_is_dead_or_stale "$lockdir" "$stale"; then
        rm -rf "$lockdir" 2>/dev/null
        if mkdir "$lockdir" 2>/dev/null; then
          echo "cv-review-lane-worktree: NOTICE: reclaimed a stale worktree sync lock for ${dir} (>${stale}s; prior holder presumed dead)" >&2
          reclaimed=1
        fi
      fi
      rm -rf "$steal_mutex" 2>/dev/null
    fi
    if [ "$reclaimed" -eq 1 ]; then
      break
    fi
    if [ "$waited" -ge "$timeout" ]; then
      echo "cv-review-lane-worktree: ERROR: timed out after ${timeout}s waiting for the sync lock on ${dir}" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  local token
  token="$$-${RANDOM}${RANDOM}-$(date +%s%N 2>/dev/null || date +%s)"
  printf '%s\n' "$$" > "${lockdir}/pid" 2>/dev/null || true
  printf '%s\n' "$token" > "${lockdir}/owner" 2>/dev/null || true
  printf '%s\n' "$token"
  return 0
}

# sync_lock_release SRC [TOKEN] — review fk-hbsmk BLOCKING-1: when TOKEN is
# given (the value sync_lock_acquire printed), refuses to delete the lockdir
# unless it is still the recorded owner — see
# con-voyage-lib.sh's cv_worktree_sync_lock_release for the full rationale.
sync_lock_release() {
  local dir="$1" token="${2:-}"
  local lockdir
  lockdir="$(sync_lock_dir "$dir")"
  [ -d "$lockdir" ] || return 0
  if [ -n "$token" ]; then
    local stored
    stored="$(cat "${lockdir}/owner" 2>/dev/null || true)"
    if [ "$stored" != "$token" ]; then
      echo "cv-review-lane-worktree: WARNING: owner token mismatch for ${dir} — not releasing a lock we no longer hold (reclaimed by another holder)" >&2
      return 0
    fi
  fi
  rm -rf "$lockdir" 2>/dev/null || true
}

# lane_bead_state <lane-id> — prints "<status>\x1f<reason>" on stdout.
# <status> is "closed", a known non-closed status such as "open"/"in_progress",
# or empty when the status could not be resolved at all. <reason> is only
# meaningful when <status> is empty, and distinguishes WHY it could not be
# resolved (review fk-hbsmk/fk-9h3nwk BLOCKING-1 — these three cases must
# never be collapsed into one sentinel, they carry different reap-safety):
#   - "absent"   — structurally confirmed unresolvable: con-voyage-lib.sh or
#                  the `gc` binary itself is not present at all. There is no
#                  store to ever consult, so this can never resolve later —
#                  safe for --force to reap immediately, same as before.
#   - "failed"   — a lookup was actually attempted against a real store and
#                  did not return a usable status (timeout, parse error). The
#                  store exists and might resolve differently on a retry, so
#                  a single inconclusive result is NOT enough for --force to
#                  treat this as reapable.
# Sources con-voyage-lib.sh's `bead_status` (same directory as this script)
# for the actual `gc bd show` lookup, wrapped in `cv_with_timeout` (review
# fk-o0f68q BLOCKING-1) so a slow/stuck store call under lock contention or
# pool load can't hang this function indefinitely. Always exits 0; the caller
# must only ever treat a resolved non-closed status as un-reapable even with
# --force (fk-ekufmt: a lane can be genuinely reopened mid-cycle).
lane_bead_state() {
  local lane_id="$1"
  [ -n "$lane_id" ] || { printf '%s\x1f%s' "" "absent"; return 0; }
  local script_dir cv_lib
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  cv_lib="${script_dir}/con-voyage-lib.sh"
  if [ ! -f "$cv_lib" ] || ! command -v "${GC:-gc}" >/dev/null 2>&1; then
    printf '%s\x1f%s' "" "absent"
    return 0
  fi
  local cv_lens_store_timeout="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
  case "$cv_lens_store_timeout" in
    *[!0-9]*|'') cv_lens_store_timeout="30" ;;
  esac
  local result status
  if ! result="$(source "$cv_lib" && cv_with_timeout "$cv_lens_store_timeout" bead_status "$lane_id" id)"; then
    printf '%s\x1f%s' "" "failed"
    return 0
  fi
  status="${result%%$'\x1f'*}"
  if [ -z "$status" ]; then
    printf '%s\x1f%s' "" "failed"
    return 0
  fi
  printf '%s\x1f%s' "$status" "resolved"
}

cmd_acquire() {
  local src="$1" lane_id_raw="${2:-}"
  require_git_worktree "$src" "acquire"
  [ -n "$lane_id_raw" ] || { usage; die "acquire: a lane-id argument is required"; }
  src="$(canonicalize_dir "$src")" || die "acquire: could not resolve real path of '${1}'"

  local lane_id lane_dir
  lane_id="$(sanitize_lane_id "$lane_id_raw")"
  lane_dir="$(lane_dir_for "$src" "$lane_id")"

  # fk-dy2ygk: hold the lock only across the HEAD read itself — never let it
  # observe a concurrent cv_sync_worktree_to_base mutation of $src mid-flight.
  # Review fk-hbsmk BLOCKING-3: the lock previously stayed held through the
  # `git worktree add` fork below too, which takes real wall-clock time and
  # is keyed only on $src — that serialized lane-vs-lane (every lane in this
  # same review round queuing behind each other for the fork duration),
  # regressing the parallel-review throughput this script exists to provide.
  # The worktree is forked from $head_commit, already pinned at read time, so
  # nothing below needs the lock held. An EXIT trap (not RETURN) is required
  # here: a failure further down calls `die`, which `exit`s the whole
  # one-shot script process rather than returning from this function, and a
  # RETURN trap never fires on `exit` — the trap is cleared immediately after
  # the deliberate early release below so a later `die` never tries to
  # release a lock this call no longer holds.
  local lock_token
  lock_token="$(sync_lock_acquire "$src")" || die "acquire: could not acquire the worktree sync lock for '${src}'"
  trap 'sync_lock_release "'"$src"'" "'"$lock_token"'"' EXIT

  local head_commit
  head_commit="$(git -C "$src" rev-parse HEAD 2>/dev/null)" \
    || die "acquire: could not resolve HEAD in '${src}'"

  sync_lock_release "$src" "$lock_token"
  trap - EXIT

  if [ -d "$lane_dir" ]; then
    # Capture first, then match — never pipe a live 'git worktree list' into
    # 'grep -q'. grep -q exits the instant it finds a match, and if git is
    # still mid-write on trailing output when that happens, its next write()
    # gets SIGPIPE; under `set -o pipefail` that nonzero exit status wins over
    # grep's own successful one, turning a CORRECT match into a false refusal
    # here (fk-iw972). Capturing via command substitution fully drains git's
    # output before grep (now matching against an in-memory string via a here
    # string, not a pipe) ever runs, so no live producer can race its reader.
    local wt_list
    wt_list="$(git -C "$src" worktree list --porcelain 2>/dev/null)"
    grep -qxF "worktree ${lane_dir}" <<<"$wt_list" \
      || die "acquire: '${lane_dir}' exists but is not a worktree of '${src}' — refusing to reuse or overwrite"
    # Re-run mechanics: refresh a reused lane worktree to the source's CURRENT
    # commit and discard any leftover mutation from a prior review cycle.
    git -C "$lane_dir" checkout --detach --force "$head_commit" >/dev/null 2>&1 \
      || die "acquire: could not check out ${head_commit} in existing lane worktree '${lane_dir}'"
    git -C "$lane_dir" clean -fdx >/dev/null 2>&1
    printf '%s\n' "$lane_dir"
    return 0
  fi

  git -C "$src" worktree add "$lane_dir" --detach "$head_commit" >/dev/null 2>&1 \
    || die "acquire: 'git worktree add ${lane_dir} --detach ${head_commit}' failed"

  printf '%s\n' "$lane_dir"
}

cmd_sweep() {
  local src="$1"
  shift || true
  local force=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      *) usage; die "sweep: unknown argument '${arg}'" ;;
    esac
  done
  require_git_worktree "$src" "sweep"
  local src_orig="$src"
  src="$(canonicalize_dir "$src")" || die "sweep: could not resolve real path of '${src_orig}'"

  local base pattern
  base="$(basename "$src")"
  pattern="${base}${LANE_SUFFIX_MARK}"

  # fk-o0f68q LOW-5: lane_bead_state's per-lookup timeout (CV_LENS_STORE_TIMEOUT_SECONDS,
  # default 30s) was applied per lane, so a sweep over N slow/stuck lanes could
  # block for up to N x timeout. Share one deadline across the whole sweep
  # call instead: once the budget is spent, every remaining lane is treated
  # as budget-exhausted (see "budget" reason below — skipped every time, never
  # reaped even with --force; it is swept again next cycle at no cost) rather
  # than paying its own full per-lane timeout.
  local sweep_budget_seconds="${CV_LANE_SWEEP_BUDGET_SECONDS:-${CV_LENS_STORE_TIMEOUT_SECONDS:-30}}"
  case "$sweep_budget_seconds" in
    *[!0-9]*|'') sweep_budget_seconds="30" ;;
  esac
  local sweep_deadline=$(( $(date +%s) + sweep_budget_seconds ))

  local any=0
  local skipped=0
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        local path="${line#worktree }"
        local name="$(basename "$path")"
        case "$name" in
          "${pattern}"*)
            local lane_id="${name#"${pattern}"}"
            local state reason lookup
            if [ "$(date +%s)" -ge "$sweep_deadline" ]; then
              # review fk-hbsmk/fk-9h3nwk BLOCKING-1: budget exhaustion means
              # NO lookup was ever attempted for this lane — it is not "this
              # lane's status is unresolvable", it is "we never asked". Never
              # treat that as reapable, even with --force: a budget-skipped
              # lane costs nothing to leave for the next sweep cycle, where it
              # gets a real lookup attempt.
              state=""
              reason="budget"
            else
              lookup="$(lane_bead_state "$lane_id")"
              state="${lookup%%$'\x1f'*}"
              reason="${lookup#*$'\x1f'}"
            fi
            if [ "$state" = "closed" ]; then
              git -C "$src" worktree remove --force "$path" >/dev/null 2>&1 \
                && { echo "cv-review-lane-worktree: removed ${path} (lane bead confirmed closed)"; any=1; } \
                || echo "cv-review-lane-worktree: WARNING: could not remove ${path}" >&2
            elif [ -n "$state" ]; then
              echo "cv-review-lane-worktree: skip ${path} — lane bead '${lane_id}' is still '${state}' (live sibling, never reaped even with --force)"
              skipped=1
            elif [ "$reason" = "budget" ]; then
              echo "cv-review-lane-worktree: skip ${path} — lane bead '${lane_id}' status lookup was never attempted (sweep budget exhausted); never reaped even with --force, will retry next sweep"
              skipped=1
            elif [ "$reason" = "absent" ] && [ "$force" -eq 1 ]; then
              git -C "$src" worktree remove --force "$path" >/dev/null 2>&1 \
                && { echo "cv-review-lane-worktree: removed ${path} (--force: lane bead status structurally unresolvable, no gc/lib on PATH)"; any=1; } \
                || echo "cv-review-lane-worktree: WARNING: could not remove ${path}" >&2
            elif [ "$reason" = "failed" ] && [ "$force" -eq 1 ]; then
              # review fk-hbsmk/fk-9h3nwk BLOCKING-1: a single inconclusive
              # lookup (timeout, parse hiccup, store contention) is not
              # evidence the lane is closed — the store exists and may
              # resolve cleanly on a second, independently-timed attempt.
              # Only reap if that second attempt ALSO succeeds and confirms
              # closed; any other outcome (including a second failure) is
              # left alone, exactly like a genuinely open lane.
              local lookup2 state2
              lookup2="$(lane_bead_state "$lane_id")"
              state2="${lookup2%%$'\x1f'*}"
              if [ "$state2" = "closed" ]; then
                git -C "$src" worktree remove --force "$path" >/dev/null 2>&1 \
                  && { echo "cv-review-lane-worktree: removed ${path} (--force: lane bead confirmed closed on second attempt after an initial lookup failure)"; any=1; } \
                  || echo "cv-review-lane-worktree: WARNING: could not remove ${path}" >&2
              else
                echo "cv-review-lane-worktree: skip ${path} — lane bead '${lane_id}' status lookup failed twice (never reaped on an unresolved result, even with --force)"
                skipped=1
              fi
            else
              echo "cv-review-lane-worktree: skip ${path} — lane bead '${lane_id}' status could not be resolved"
              skipped=1
            fi
            ;;
        esac
        ;;
    esac
  done < <(git -C "$src" worktree list --porcelain 2>/dev/null)

  if [ "$any" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "cv-review-lane-worktree: sweep clean — no lane worktrees found for ${src}"
  fi
  git -C "$src" worktree prune >/dev/null 2>&1 || true
}

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || { usage; die "missing subcommand"; }
shift || true

case "$SUBCOMMAND" in
  acquire) cmd_acquire "${1:-}" "${2:-}" ;;
  sweep) cmd_sweep "${1:-}" "${@:2}" ;;
  *)
    usage
    die "unknown subcommand '${SUBCOMMAND}' (expected acquire or sweep)"
    ;;
esac
