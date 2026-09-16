#!/usr/bin/env bash
# cv-worktree-prep.sh — external-rig / worktree artifact hygiene for con-voyage.
#
# WHY: con-voyage (and the ci-repair path) prepares a working copy — its own
# worktree or a clone of an external target rig — before any implementation
# work happens. That working copy sits alongside LOCAL, operator-specific
# scratch directories this toolchain writes as it works: .beads/ (beads store
# config/cache), .gc/ (Gas City runtime state), .claude/ (Claude Code project
# config), and dolt data paths (.dolt/ — Dolt's on-disk database dir). None
# of these belong in the clone's history or its upstream remote — they are
# local-only, operator-specific, and would leak internal tooling state into a
# PR if ever committed.
#
# Two-layer defense:
#   exclude <dir> — write these paths into the clone's LOCAL
#                   .git/info/exclude (resolved via `git rev-parse --git-path
#                   info/exclude`, which correctly finds the shared exclude
#                   file even from inside a linked worktree, where .git is a
#                   FILE, not a directory). Never touches the tracked
#                   .gitignore — that file is shared/committed, and this
#                   hygiene is a local-only concern that should not impose
#                   tooling opinions on every consumer of the repo, or
#                   require a PR of its own.
#   guard <dir>   — a commit-step backstop: detect any hygiene path that is
#                   currently staged or already tracked, and refuse to let it
#                   ride quietly. A staged-only offender is unstaged (DROPPED)
#                   so a retry can succeed cleanly. An offender already
#                   committed to HEAD is BLOCKED — this script never rewrites
#                   history — the operator must fix it by hand (git rm
#                   --cached, then amend/rebase).
#
# Usage:
#   cv-worktree-prep.sh exclude <dir>
#   cv-worktree-prep.sh guard <dir>
#
# Environment:
#   CV_HYGIENE_PATTERNS   Space-separated gitignore-style patterns.
#                         Default: ".beads/ .gc/ .claude/ .dolt/"
#
# Exit codes:
#   0 — clean (exclude: written or already present; guard: nothing offending)
#   1 — usage/validation error, OR (guard only) an offending path was found —
#       the caller must NOT proceed to commit/push until a re-run of `guard`
#       reports clean.
#
# Requires: bash 4+, git.

set -uo pipefail

die() {
  echo "cv-worktree-prep: ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  cv-worktree-prep.sh exclude <dir>
  cv-worktree-prep.sh guard <dir>
USAGE
}

MARKER_BEGIN="# >>> con-voyage artifact hygiene (auto-managed; local only, never committed) >>>"
MARKER_END="# <<< con-voyage artifact hygiene <<<"
PATTERNS_DEFAULT=".beads/ .gc/ .claude/ .dolt/"
read -r -a PATTERNS_ARR <<< "${CV_HYGIENE_PATTERNS:-$PATTERNS_DEFAULT}"

require_git_dir() {
  local dir="$1" label="$2"
  [ -n "$dir" ] || { usage; die "${label}: a directory argument is required"; }
  [ -d "$dir" ] || die "${label}: '${dir}' is not a directory"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "${label}: '${dir}' is not inside a git working tree"
}

# pathspecs — patterns with a trailing slash stripped, suitable as git
# pathspec arguments (a bare directory-prefix pathspec matches recursively).
pathspecs() {
  local p
  for p in "${PATTERNS_ARR[@]}"; do
    printf '%s\n' "${p%/}"
  done
}

cmd_exclude() {
  local dir="$1"
  require_git_dir "$dir" "exclude"

  local exclude_file
  exclude_file="$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null)" \
    || die "exclude: could not resolve info/exclude for '${dir}'"
  case "$exclude_file" in
    /*) : ;;
    *) exclude_file="${dir}/${exclude_file}" ;;
  esac

  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"

  if grep -qF "$MARKER_BEGIN" "$exclude_file" 2>/dev/null; then
    echo "cv-worktree-prep: hygiene patterns already present in ${exclude_file}"
    return 0
  fi

  {
    printf '%s\n' "$MARKER_BEGIN"
    printf '%s\n' "${PATTERNS_ARR[@]}"
    printf '%s\n' "$MARKER_END"
  } >> "$exclude_file"

  echo "cv-worktree-prep: wrote hygiene patterns to ${exclude_file} (local only; nothing committed upstream)"
}

cmd_guard() {
  local dir="$1"
  require_git_dir "$dir" "guard"

  mapfile -t PATHSPECS < <(pathspecs)

  local offenders
  offenders="$(git -C "$dir" ls-files -- "${PATHSPECS[@]}" 2>/dev/null || true)"

  if [ -z "$offenders" ]; then
    echo "cv-worktree-prep: guard clean — no hygiene paths staged or tracked in ${dir}"
    return 0
  fi

  local head_files
  head_files="$(git -C "$dir" ls-tree -r --name-only HEAD -- "${PATHSPECS[@]}" 2>/dev/null || true)"

  local any_offense=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$head_files" | grep -qxF "$f"; then
      echo "cv-worktree-prep: BLOCKED ${f} is already committed to HEAD in ${dir} — this cannot be safely auto-fixed. Remove it from history (git rm --cached '${f}', then amend/rebase) before continuing." >&2
      any_offense=1
    else
      git -C "$dir" reset -q -- "$f" 2>/dev/null || true
      echo "cv-worktree-prep: DROPPED ${f} was staged in ${dir} — unstaged before commit (hygiene path, never committed upstream)." >&2
      any_offense=1
    fi
  done <<< "$offenders"

  [ "$any_offense" -eq 0 ]
}

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || { usage; die "missing subcommand"; }
shift || true

case "$SUBCOMMAND" in
  exclude) cmd_exclude "${1:-}" ;;
  guard) cmd_guard "${1:-}" ;;
  *)
    usage
    die "unknown subcommand '${SUBCOMMAND}' (expected exclude or guard)"
    ;;
esac
