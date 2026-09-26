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
#   cv-pr-comment.sh reply-thread <pr> --repo <owner/repo> \
#       --comment-id <db_id> --body-file <path> \
#       [--formula <name>] [--agent <rig/agent>]
#
#   cv-pr-comment.sh comment-aggregate <pr> --repo <owner/repo> \
#       --manifest <path.json> [--city-root <path>] \
#       [--formula <name>] [--agent <rig/agent>]
#
# `comment-aggregate` renders ONE minimal, doomer-style root-level comment for
# a whole con-voyage review round from a JSON manifest (see "AGGREGATE REVIEW
# COMMENTS" below) and posts it — never per-lane comments, never an edit of an
# earlier round's comment. `comment` posts at ROOT level (general/summary feedback). `reply-thread` posts
# a THREADED reply INSIDE an existing inline review thread — use it when you are
# addressing one specific inline review-thread comment, so your reply lands in
# that conversation rather than as a new root-level comment. Its --comment-id is
# the review comment's numeric DATABASE id (not the GraphQL node-id); it posts
# via the review-comment replies API
# (POST repos/<owner>/<repo>/pulls/<pr>/comments/<comment_id>/replies).
#
# The body is always read from a FILE (--body-file), never an inline string —
# this keeps multi-line/markdown bodies out of argv entirely and avoids shell
# quoting foot-guns. The file's contents are copied verbatim after the banner;
# this script never mutates the caller's original file. (reply-thread carries the
# body the same foot-gun-free way: `gh api ... -F body=@<file>` reads the body
# from the file, so it never round-trips through argv either.)
#
# AGGREGATE REVIEW COMMENTS (comment-aggregate):
#
# One con-voyage review round == one NEW root-level comment, never an edit of
# an earlier round's comment (there is no edit mode anywhere in this script,
# for any subcommand — every post is a fresh `gh pr comment`). Individual
# review lanes never comment on the PR themselves; whichever step owns
# posting a round's result (publish, or the equivalent step on a later round)
# assembles a JSON manifest describing that round and calls comment-aggregate
# once. Manifest shape:
#
#   {
#     "rig": "foundry-kc",              // required
#     "root_bead_id": "fk-elkyf",       // required — identifies the marker
#     "round": 1,                       // required — identifies the marker
#     "overall_line": "Approved: 6 lanes, 0 blocking, 4 low.",  // required
#     "extra_line": "LOWs for the human reviewer below.",       // optional
#     "lanes": [                        // optional, 0 or more
#       {"agent": "reviewer-3", "lens": "security", "verdict": "approve",
#        "findings": 2, "body_file": "/abs/path/security-review.md"}
#     ],
#     "synthesis": {                    // optional
#       "agent": "gc.review-synthesizer", "lens": "synthesis",
#       "verdict": "approve", "findings": 4,
#       "body_file": "/abs/path/review-synthesis.md"
#     }
#   }
#
# Rendered structure: one surface line ("**[<rig>/con-voyage — review]**
# <overall_line>", plus <extra_line> if present), a hidden HTML marker
# (`<!-- con-voyage-review:<root_bead_id> round=<round> -->`, for
# IDENTIFYING agent comments — e.g. so pr-watch can skip them — never for
# editing), then one `<details><summary>[<rig>/<agent> — <lens>] <verdict> ·
# <findings> findings</summary>...</details>` block per lane, with the
# synthesis block rendered FIRST (the human's actionable LOW list, ahead of
# the full per-lane reports below it).
#
# Hygiene (applied automatically to every body_file's content before
# posting): any absolute path under --city-root (or $CV_CITY_ROOT) is
# rewritten to the neutral placeholder `<city-root>` — an internal
# filesystem layout should never leak into an enterprise-visible PR comment.
# A token-shaped string (a GitHub/Slack/AWS/API-key-looking substring) BLOCKS
# the post entirely (non-zero exit, gh never invoked) rather than risking a
# wrong redaction shipping to GitHub.
#
# Size (GitHub's 65536-char comment limit): if the fully-rendered body would
# exceed it, the largest entries are truncated — inside their OWN details
# block only, replaced with a pointer to where the full report lives — never
# by cutting the surface line or the marker.
#
# Environment / configuration:
#
#   GH            Path to the gh binary (default: gh)
#   CV_FORMULA    Default --formula when the flag is omitted (e.g.
#                 con-voyage-ci-repair, con-voyage). Optional.
#   CV_AGENT      Default --agent when the flag is omitted (e.g.
#                 foundry-kc/gc.implementation-worker). Optional.
#   CV_CITY_ROOT  Default --city-root when the flag is omitted
#                 (comment-aggregate only). Optional.
#
# Exit codes:
#   0 — posted successfully
#   1 — usage/validation error (missing/invalid args), or the comment-aggregate
#       hygiene scan blocked a token-shaped string; gh is never invoked
#   N — gh's own exit code, propagated verbatim, when gh itself fails
#
# Requires: bash 4+, gh CLI (authenticated), python3 (comment-aggregate only).

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
  cv-pr-comment.sh reply-thread <pr> --repo <owner/repo> --comment-id <db_id> --body-file <path> [--formula <name>] [--agent <rig/agent>]
  cv-pr-comment.sh comment-aggregate <pr> --repo <owner/repo> --manifest <path.json> [--city-root <path>] [--formula <name>] [--agent <rig/agent>]
USAGE
}

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || { usage; die "missing subcommand"; }
shift || true

case "$SUBCOMMAND" in
  comment|review|create|reply-thread|comment-aggregate) ;;
  *)
    usage
    die "unknown subcommand '${SUBCOMMAND}' (expected comment, review, create, reply-thread, or comment-aggregate — no raw gh passthrough is supported)"
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
COMMENT_ID=""
MANIFEST=""
CITY_ROOT="${CV_CITY_ROOT:-}"

# create has no positional PR argument; comment/review/reply-thread do.
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
    --comment-id) COMMENT_ID="${2:-}"; shift 2 || true ;;
    --manifest) MANIFEST="${2:-}"; shift 2 || true ;;
    --city-root) CITY_ROOT="${2:-}"; shift 2 || true ;;
    --draft) DRAFT="true"; shift || true ;;
    --comment) REVIEW_VERB="--comment"; shift || true ;;
    --approve) REVIEW_VERB="--approve"; shift || true ;;
    --request-changes) REVIEW_VERB="--request-changes"; shift || true ;;
    *) usage; die "unrecognized argument '$1'" ;;
  esac
done

[ -n "$REPO" ] || { usage; die "--repo is required"; }
if [ "$SUBCOMMAND" = "comment-aggregate" ]; then
  [ -n "$MANIFEST" ] || { usage; die "--manifest is required for comment-aggregate"; }
  [ -f "$MANIFEST" ] || die "--manifest '${MANIFEST}' does not exist or is not a regular file"
else
  [ -n "$BODY_FILE" ] || { usage; die "--body-file is required (inline --body is not supported — always write to a file first)"; }
  [ -f "$BODY_FILE" ] || die "--body-file '${BODY_FILE}' does not exist or is not a regular file"
fi

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

if [ "$SUBCOMMAND" = "reply-thread" ]; then
  # --comment-id is the review comment's numeric DATABASE id (the reply target).
  # Validate presence + numeric-ness the same way the PR number is validated —
  # fail closed before gh is ever invoked, never interpolate a non-numeric value
  # into the replies endpoint path below.
  [ -n "$COMMENT_ID" ] || { usage; die "--comment-id is required for reply-thread (the review comment's numeric database id)"; }
  case "$COMMENT_ID" in
    ''|*[!0-9]*) die "--comment-id must be numeric (the review comment's database id), got '${COMMENT_ID}'" ;;
  esac
fi

command -v "$GH" >/dev/null 2>&1 || die "gh CLI not found at '${GH}'. Install github.com/cli/cli."

# Every temp file this script creates (rendered manifest, banner-prefixed
# post body) is cleaned up by one trap, registered up front so a die() from
# ANY branch below — including inside comment-aggregate's rendering step —
# still cleans up whatever was already created.
RENDER_PY=""
RENDERED_FILE=""
POSTED_BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/cv-pr-comment-body.XXXXXX")"
cleanup() { rm -f "$POSTED_BODY_FILE" "$RENDER_PY" "$RENDERED_FILE"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# comment-aggregate: render the manifest into a throwaway temp file FIRST,
# then treat that rendered file exactly like any other --body-file below —
# same banner treatment, same gh dispatch, same "always a new comment, never
# an edit" posture. Never mutate the caller's original manifest or any
# body_file it references.
# ---------------------------------------------------------------------------
if [ "$SUBCOMMAND" = "comment-aggregate" ]; then
  command -v python3 >/dev/null 2>&1 || die "python3 not found — required to render comment-aggregate"

  RENDER_PY="$(mktemp "${TMPDIR:-/tmp}/cv-pr-comment-render.XXXXXX.py")"
  RENDERED_FILE="$(mktemp "${TMPDIR:-/tmp}/cv-pr-comment-aggregate.XXXXXX")"

  cat > "$RENDER_PY" <<'PYEOF'
import json
import re
import sys

MAX_BODY = 65000  # headroom under GitHub's 65536-char comment limit for the banner
TRUNCATE_POINTER = "\n\n...[truncated -- full report at {path}]\n"

TOKEN_RE = re.compile(
    r'ghp_[A-Za-z0-9]{36}'
    r'|gho_[A-Za-z0-9]{36}'
    r'|ghs_[A-Za-z0-9]{36}'
    r'|ghr_[A-Za-z0-9]{36}'
    r'|github_pat_[A-Za-z0-9_]{22,}'
    r'|xox[baprs]-[A-Za-z0-9-]{10,}'
    r'|AKIA[0-9A-Z]{16}'
    r'|sk-ant-[A-Za-z0-9-]{20,}'
    r'|sk-[A-Za-z0-9]{20,}'
)


def die(msg):
    sys.stderr.write("cv-pr-comment: ERROR: " + msg + "\n")
    sys.exit(1)


def hygiene_rewrite(text, city_root):
    if city_root:
        text = text.replace(city_root, "<city-root>")
    return text


def read_entry(entry, city_root):
    path = entry.get("body_file", "") or ""
    try:
        with open(path) as f:
            content = f.read()
    except Exception:
        content = "(report file unavailable)"
    return hygiene_rewrite(content, city_root), hygiene_rewrite(path, city_root)


def render_details(rig, entry, content):
    identity = "[{}/{} — {}]".format(rig, entry.get("agent", "unknown"), entry.get("lens", "unknown"))
    summary = "{} {} · {} findings".format(identity, entry.get("verdict", "unknown"), entry.get("findings", 0))
    return "<details>\n<summary>{}</summary>\n\n{}\n\n</details>".format(summary, content.strip())


def assemble(surface_lines, marker, entries, rig):
    parts = list(surface_lines)
    parts.append("")
    parts.append(marker)
    parts.append("")
    for _kind, entry, content in entries:
        parts.append(render_details(rig, entry, content))
        parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def main():
    manifest_path = sys.argv[1]
    city_root = sys.argv[2] if len(sys.argv) > 2 else ""

    with open(manifest_path) as f:
        manifest = json.load(f)

    rig = manifest.get("rig") or "unknown-rig"
    root_bead_id = manifest.get("root_bead_id") or "unknown"
    round_n = manifest.get("round", 1)
    overall_line = manifest.get("overall_line") or ""

    surface_lines = ["**[{}/con-voyage — review]** {}".format(rig, overall_line)]
    extra_line = manifest.get("extra_line") or ""
    if extra_line:
        surface_lines.append(extra_line)
    marker = "<!-- con-voyage-review:{} round={} -->".format(root_bead_id, round_n)

    # Synthesis renders FIRST ("LOW list first" -- the actionable summary
    # ahead of the full per-lane reports below it).
    entries = []
    synthesis = manifest.get("synthesis")
    if synthesis:
        content, path = read_entry(synthesis, city_root)
        entries.append(("synthesis", dict(synthesis, body_file=path), content))
    for lane in manifest.get("lanes") or []:
        content, path = read_entry(lane, city_root)
        entries.append(("lane", dict(lane, body_file=path), content))

    # Hygiene: block entirely on a token-shaped string anywhere in the
    # assembled text, rather than trying to redact it.
    probe = assemble(surface_lines, marker, entries, rig)
    if TOKEN_RE.search(probe):
        die("refusing to post -- matched a token-shaped string (hygiene scan)")

    body = probe
    guard = 0
    while len(body) > MAX_BODY and guard < 1000:
        guard += 1
        sizes = [len(e[2]) for e in entries]
        if not sizes or max(sizes) <= 300:
            break
        i_max = max(range(len(entries)), key=lambda i: len(entries[i][2]))
        kind, entry, content = entries[i_max]
        pointer = TRUNCATE_POINTER.format(path=entry.get("body_file", ""))
        shrink_to = max(200, len(content) - 2000)
        new_content = content[:shrink_to].rstrip() + pointer
        entries[i_max] = (kind, entry, new_content)
        body = assemble(surface_lines, marker, entries, rig)

    sys.stdout.write(body)


main()
PYEOF

  python3 "$RENDER_PY" "$MANIFEST" "$CITY_ROOT" > "$RENDERED_FILE" || die "comment-aggregate rendering failed (see above)"
  BODY_FILE="$RENDERED_FILE"
fi

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
  comment|comment-aggregate)
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
  reply-thread)
    # Threaded reply inside an existing inline review thread, via the
    # review-comment replies API. `-F body=@<file>` makes gh read the field value
    # FROM the file, so the (banner-prefixed) body never round-trips through argv
    # — the same foot-gun avoidance as --body-file in the other modes (never a
    # `-f body=<inline text>`). $REPO is <owner>/<repo>, which is exactly the
    # path segment the endpoint wants.
    "$GH" api --method POST \
      "repos/${REPO}/pulls/${PR}/comments/${COMMENT_ID}/replies" \
      -F body=@"$POSTED_BODY_FILE"
    ;;
esac
exit $?
