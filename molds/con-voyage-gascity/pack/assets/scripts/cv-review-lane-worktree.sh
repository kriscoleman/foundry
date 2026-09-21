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
#   cv-review-lane-worktree.sh sweep <source-work-dir>
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
# (matched by the `--review-` naming convention below). Intended to run once
# per review cycle (synthesize-review, after all lanes have reported) so lane
# worktrees do not accumulate across rounds. It never touches
# <source-work-dir> itself or any worktree that does not match the
# convention.
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
  cv-review-lane-worktree.sh sweep <source-work-dir>
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

cmd_acquire() {
  local src="$1" lane_id_raw="${2:-}"
  require_git_worktree "$src" "acquire"
  [ -n "$lane_id_raw" ] || { usage; die "acquire: a lane-id argument is required"; }
  src="$(canonicalize_dir "$src")" || die "acquire: could not resolve real path of '${1}'"

  local lane_id lane_dir
  lane_id="$(sanitize_lane_id "$lane_id_raw")"
  lane_dir="$(lane_dir_for "$src" "$lane_id")"

  local head_commit
  head_commit="$(git -C "$src" rev-parse HEAD 2>/dev/null)" \
    || die "acquire: could not resolve HEAD in '${src}'"

  if [ -d "$lane_dir" ]; then
    git -C "$src" worktree list --porcelain 2>/dev/null | grep -qxF "worktree ${lane_dir}" \
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
  require_git_worktree "$src" "sweep"
  src="$(canonicalize_dir "$src")" || die "sweep: could not resolve real path of '${1}'"

  local base pattern
  base="$(basename "$src")"
  pattern="${base}${LANE_SUFFIX_MARK}"

  local any=0
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        local path="${line#worktree }"
        case "$(basename "$path")" in
          "${pattern}"*)
            git -C "$src" worktree remove --force "$path" >/dev/null 2>&1 \
              && { echo "cv-review-lane-worktree: removed ${path}"; any=1; } \
              || echo "cv-review-lane-worktree: WARNING: could not remove ${path}" >&2
            ;;
        esac
        ;;
    esac
  done < <(git -C "$src" worktree list --porcelain 2>/dev/null)

  if [ "$any" -eq 0 ]; then
    echo "cv-review-lane-worktree: sweep clean — no lane worktrees found for ${src}"
  fi
  git -C "$src" worktree prune >/dev/null 2>&1 || true
}

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || { usage; die "missing subcommand"; }
shift || true

case "$SUBCOMMAND" in
  acquire) cmd_acquire "${1:-}" "${2:-}" ;;
  sweep) cmd_sweep "${1:-}" ;;
  *)
    usage
    die "unknown subcommand '${SUBCOMMAND}' (expected acquire or sweep)"
    ;;
esac
