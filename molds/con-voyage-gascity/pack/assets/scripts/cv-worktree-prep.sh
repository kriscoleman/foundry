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
#   guard <dir> [base-ref]
#                 — a commit-step backstop: detect any hygiene path this work
#                   branch would push upstream, and refuse to let it ride
#                   quietly. Two kinds of offense:
#                     * STAGED but not committed — unstaged (DROPPED) so a
#                       retry can succeed cleanly. This check is
#                       base-independent: a staged hygiene path is always
#                       wrong, period.
#                     * COMMITTED and ADDED BY THIS BRANCH relative to its
#                       base — BLOCKED. This script never rewrites history —
#                       the operator must fix it by hand (git rm --cached,
#                       then amend/rebase).
#                   Crucially, a hygiene path that already exists in the BASE
#                   (e.g. an upstream repo that legitimately tracks .claude/
#                   agents+commands) is NOT an offense — the branch did not
#                   introduce it, so blocking it would be a false positive that
#                   wedges every publish on that repo. Only paths the branch
#                   ADDS on top of its base are blocked.
#
#                   The base is resolved in this order: the optional [base-ref]
#                   arg (callers that already know the PR base pass it here),
#                   then origin/HEAD, then origin/main, then main. If none
#                   resolve (no remote, detached with no upstream), guard fails
#                   SAFE by using the empty tree as the base — so EVERY
#                   committed hygiene path is flagged, degrading to the old
#                   absolute-tracked-ness behavior rather than silently passing
#                   a real offender.
#
# Usage:
#   cv-worktree-prep.sh exclude <dir>
#   cv-worktree-prep.sh guard <dir> [base-ref]
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
  cv-worktree-prep.sh guard <dir> [base-ref]
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

# EMPTY_TREE — git's well-known empty-tree object. Diffing HEAD against it
# yields every path HEAD introduces, which is the fail-safe base when no real
# base ref can be resolved.
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# resolve_base <dir> [explicit-base] — echo a base ref for guard's
# added-on-branch diff. Resolution order: explicit arg, origin/HEAD,
# origin/main, main. Each candidate is accepted only if it resolves to a real
# commit (git rev-parse --verify). If nothing resolves, echo the empty-tree
# hash so guard fails SAFE (flags every committed hygiene path) instead of
# silently passing a real offender. Never fails; always echoes something.
resolve_base() {
  local dir="$1" explicit="${2:-}"
  local cand origin_head

  if [ -n "$explicit" ] \
    && git -C "$dir" rev-parse --verify --quiet "${explicit}^{commit}" >/dev/null 2>&1; then
    printf '%s' "$explicit"
    return 0
  fi

  # origin/HEAD (e.g. -> origin/main) is the repo's declared default branch.
  origin_head="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  for cand in "$origin_head" "origin/main" "main"; do
    [ -n "$cand" ] || continue
    if git -C "$dir" rev-parse --verify --quiet "${cand}^{commit}" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done

  printf '%s' "$EMPTY_TREE"
}

cmd_guard() {
  local dir="$1" base_arg="${2:-}"
  require_git_dir "$dir" "guard"

  mapfile -t PATHSPECS < <(pathspecs)

  # Everything git currently tracks or has staged under the hygiene pathspecs:
  # the universe of things that could ride upstream.
  local offenders
  offenders="$(git -C "$dir" ls-files -- "${PATHSPECS[@]}" 2>/dev/null || true)"

  if [ -z "$offenders" ]; then
    echo "cv-worktree-prep: guard clean — no hygiene paths staged or tracked in ${dir}"
    return 0
  fi

  # Paths already committed to HEAD (staged-but-uncommitted paths are absent
  # here). Used to tell a staged-only offender from a committed one.
  local head_files
  head_files="$(git -C "$dir" ls-tree -r --name-only HEAD -- "${PATHSPECS[@]}" 2>/dev/null || true)"

  # Committed hygiene paths this branch ADDED relative to its base. A path that
  # exists in the base (legitimately tracked upstream) is absent here and so is
  # never blocked — that is the false-positive fix. If the base can't be
  # resolved, resolve_base returns the empty tree, so this becomes "every
  # committed hygiene path" — the safe old behavior.
  local base added_files
  base="$(resolve_base "$dir" "$base_arg")"
  local mb="$base"
  if [ "$base" != "$EMPTY_TREE" ]; then
    mb="$(git -C "$dir" merge-base "$base" HEAD 2>/dev/null || printf '%s' "$EMPTY_TREE")"
  fi
  added_files="$(git -C "$dir" diff --name-only --diff-filter=A "${mb}..HEAD" -- "${PATHSPECS[@]}" 2>/dev/null || true)"

  local any_offense=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$head_files" | grep -qxF "$f"; then
      # Committed. Only an offense if THIS branch added it on top of base.
      if printf '%s\n' "$added_files" | grep -qxF "$f"; then
        echo "cv-worktree-prep: BLOCKED ${f} was added on this branch (vs ${base}) and is committed to HEAD in ${dir} — this cannot be safely auto-fixed. Remove it from history (git rm --cached '${f}', then amend/rebase) before continuing." >&2
        any_offense=1
      fi
      # Else: present in base, not introduced by this branch — legitimately
      # tracked upstream, so not an offense. Leave it untouched.
    else
      git -C "$dir" reset -q -- "$f" 2>/dev/null || true
      echo "cv-worktree-prep: DROPPED ${f} was staged in ${dir} — unstaged before commit (hygiene path, never committed upstream)." >&2
      any_offense=1
    fi
  done <<< "$offenders"

  if [ "$any_offense" -eq 0 ]; then
    echo "cv-worktree-prep: guard clean — no hygiene paths added on this branch (vs ${base}) or staged in ${dir}"
  fi

  [ "$any_offense" -eq 0 ]
}

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || { usage; die "missing subcommand"; }
shift || true

case "$SUBCOMMAND" in
  exclude) cmd_exclude "${1:-}" ;;
  guard) cmd_guard "${1:-}" "${2:-}" ;;
  *)
    usage
    die "unknown subcommand '${SUBCOMMAND}' (expected exclude or guard)"
    ;;
esac
