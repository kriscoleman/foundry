#!/usr/bin/env bash
# cv-pr-comment.sh — the ONLY structural path for posting con-voyage text to
# a GitHub PR/issue.
#
# ############################################################################
# # WHY THIS EXISTS                                                          #
# #                                                                          #
# # con-voyage runs under the operator's GitHub PAT. Any gh pr comment/      #
# # review/create it issues shows up as posted by the HUMAN (@kriscoleman),  #
# # not as a bot — so any text posted WITHOUT a machine-identity banner is   #
# # an impersonation of Kris. This used to be prose-only guidance inside     #
# # {target}.ci-repair.md ("every comment MUST lead with this banner") and a #
# # worker skipped it in production. This script makes the banner           #
# # STRUCTURAL: it is the only supported way this pack posts to GitHub, and  #
# # it unconditionally prepends the banner — there is no passthrough mode    #
# # and no way to post a body without it.                                    #
# #                                                                          #
# # Corollary: raw `gh pr comment` / `gh pr review` / `gh pr create` are     #
# # FORBIDDEN in every con-voyage worker path. Use this script instead.      #
# ############################################################################
#
# Usage:
#   cv-pr-comment.sh comment <pr> --repo <owner/repo> --body-file <path> \
#       [--formula <name>] [--agent <rig/agent>]
#
#   cv-pr-comment.sh review <pr> --repo <owner/repo> \
#       (--comment|--approve|--request-changes) --body-file <path> \
#       [--formula <name>] [--agent <rig/agent>]
#
#   cv-pr-comment.sh create --repo <owner/repo> --title <title> \
#       --body-file <path> [--base <branch>] [--head <branch>] [--draft] \
#       [--formula <name>] [--agent <rig/agent>]
#
# The body is always read from a FILE (--body-file), never an inline string —
# this keeps multi-line/markdown bodies out of argv entirely and avoids shell
# quoting foot-guns. The file's contents are copied verbatim after the banner;
# this script never mutates the caller's original file.
#
# Environment / configuration:
#
#   GH           Path to the gh binary (default: gh)
#   CV_FORMULA   Default --formula when the flag is omitted (e.g.
#                con-voyage-ci-repair, con-voyage). Optional.
#   CV_AGENT     Default --agent when the flag is omitted (e.g.
#                foundry-kc/gc.implementation-worker). Optional.
#
# Exit codes:
#   0 — posted successfully
#   1 — usage/validation error (missing/invalid args); gh is never invoked
#   N — gh's own exit code, propagated verbatim, when gh itself fails
#
# Requires: bash 4+, gh CLI (authenticated).

set -uo pipefail

GH="${GH:-gh}"

die() {
  echo "cv-pr-comment: ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  cv-pr-comment.sh comment <pr> --repo <owner/repo> --body-file <path> [--formula <name>] [--agent <rig/agent>]
  cv-pr-comment.sh review <pr> --repo <owner/repo> (--comment|--approve|--request-changes) --body-file <path> [--formula <name>] [--agent <rig/agent>]
  cv-pr-comment.sh create --repo <owner/repo> --title <title> --body-file <path> [--base <branch>] [--head <branch>] [--draft] [--formula <name>] [--agent <rig/agent>]
USAGE
}

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || { usage; die "missing subcommand"; }
shift || true

case "$SUBCOMMAND" in
  comment|review|create) ;;
  *)
    usage
    die "unknown subcommand '${SUBCOMMAND}' (expected comment, review, or create — no raw gh passthrough is supported)"
    ;;
esac

PR=""
REPO=""
BODY_FILE=""
FORMULA="${CV_FORMULA:-}"
AGENT="${CV_AGENT:-}"
TITLE=""
BASE=""
HEAD=""
DRAFT="false"
REVIEW_VERB=""

# create has no positional PR argument; comment/review do.
if [ "$SUBCOMMAND" != "create" ]; then
  if [ "${1:-}" != "" ] && [ "${1#--}" = "$1" ]; then
    PR="$1"
    shift || true
  fi
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 || true ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 || true ;;
    --formula) FORMULA="${2:-}"; shift 2 || true ;;
    --agent) AGENT="${2:-}"; shift 2 || true ;;
    --title) TITLE="${2:-}"; shift 2 || true ;;
    --base) BASE="${2:-}"; shift 2 || true ;;
    --head) HEAD="${2:-}"; shift 2 || true ;;
    --draft) DRAFT="true"; shift || true ;;
    --comment) REVIEW_VERB="--comment"; shift || true ;;
    --approve) REVIEW_VERB="--approve"; shift || true ;;
    --request-changes) REVIEW_VERB="--request-changes"; shift || true ;;
    *) usage; die "unrecognized argument '$1'" ;;
  esac
done

[ -n "$REPO" ] || { usage; die "--repo is required"; }
[ -n "$BODY_FILE" ] || { usage; die "--body-file is required (inline --body is not supported — always write to a file first)"; }
[ -f "$BODY_FILE" ] || die "--body-file '${BODY_FILE}' does not exist or is not a regular file"

if [ "$SUBCOMMAND" != "create" ]; then
  [ -n "$PR" ] || { usage; die "a PR number is required"; }
  case "$PR" in
    ''|*[!0-9]*) die "PR number must be numeric, got '${PR}'" ;;
  esac
fi

if [ "$SUBCOMMAND" = "review" ]; then
  [ -n "$REVIEW_VERB" ] || { usage; die "review requires exactly one of --comment, --approve, or --request-changes"; }
fi

if [ "$SUBCOMMAND" = "create" ]; then
  [ -n "$TITLE" ] || { usage; die "--title is required for create"; }
fi

command -v "$GH" >/dev/null 2>&1 || die "gh CLI not found at '${GH}'. Install github.com/cli/cli."

# ---------------------------------------------------------------------------
# Build the banner-prefixed body in a throwaway temp file. Never mutate the
# caller's original --body-file.
# ---------------------------------------------------------------------------
FORMULA_DISPLAY="${FORMULA:-con-voyage}"
AGENT_DISPLAY="${AGENT:-unknown/unknown}"

# The literal prefix "🤖 **Automated con-voyage agent**" is also matched by
# con-voyage-pr-watch.sh's CV_AGENT_PREFIX_PATTERN, which excludes the bot's
# own posts from "new human feedback" detection. Changing this prefix without
# updating that pattern reintroduces a self-feedback routing loop.
BANNER="🤖 **Automated con-voyage agent** (${FORMULA_DISPLAY} / ${AGENT_DISPLAY})"

POSTED_BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/cv-pr-comment-body.XXXXXX")"
cleanup() { rm -f "$POSTED_BODY_FILE"; }
trap cleanup EXIT

{
  printf '%s\n' "$BANNER"
  printf '\n'
  cat "$BODY_FILE"
} > "$POSTED_BODY_FILE"

# ---------------------------------------------------------------------------
# Dispatch to gh. --body-file only — never --body — so the (now
# banner-prefixed) content never round-trips through argv.
# ---------------------------------------------------------------------------
case "$SUBCOMMAND" in
  comment)
    "$GH" pr comment "$PR" --repo "$REPO" --body-file "$POSTED_BODY_FILE"
    ;;
  review)
    "$GH" pr review "$PR" --repo "$REPO" "$REVIEW_VERB" --body-file "$POSTED_BODY_FILE"
    ;;
  create)
    set -- pr create --repo "$REPO" --title "$TITLE" --body-file "$POSTED_BODY_FILE"
    [ -n "$BASE" ] && set -- "$@" --base "$BASE"
    [ -n "$HEAD" ] && set -- "$@" --head "$HEAD"
    [ "$DRAFT" = "true" ] && set -- "$@" --draft
    "$GH" "$@"
    ;;
esac
exit $?
