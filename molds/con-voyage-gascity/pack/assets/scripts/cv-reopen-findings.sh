#!/usr/bin/env bash
# cv-reopen-findings.sh — fk-9iqxnx (design decided by the mayor, 2026-10-04):
# a real command for the mayor to re-open a con-voyage review with findings,
# replacing the "reply to the LOW-only mail" affordance that had no effect
# (fk-z1hpp4, fk-7xu9m, fk-6os73y, fk-dnjlg2: four cases where a "send back"
# reply never re-opened anything and the journey published anyway — apply-
# review-findings sets verdict=done on its own once every lane approves, so
# a mail reply alone was purely informational).
#
# Usage:
#   cv-reopen-findings.sh <work-bead> (--finding "<text>")... [--findings-file <path>]
#
# At least one --finding or --findings-file is required; both may be
# combined (the file's content is appended after any --finding text).
#
# Works in TWO modes, auto-detected from the work bead's current state:
#
#   PRE-publish:  a con-voyage workflow root still tracks this work bead and
#                 is not yet closed. Records the findings as metadata on that
#                 root (gc.build.mayor_reopen_requested=true,
#                 gc.build.mayor_reopen_findings=<text>). The NEXT
#                 apply-review-findings cycle (see main.apply-review-
#                 findings.md's LOW-only pause) treats them as BLOCKING and
#                 re-runs every active lane. No publish happens until that
#                 cycle resolves them.
#
#   POST-publish: no open workflow root is found, but a published PR's
#                 .finalize record (written by the publish step) names this
#                 work bead. Routes the findings to the PR's recorded
#                 implementor session (falling back to the rig's pool
#                 worker, exactly like con-voyage-pr-watch.sh's human-
#                 feedback routing) as a new task bead, using the SAME
#                 untrusted-content-fenced body shape. A fix pushed in
#                 response lands on the existing PR branch, which con-
#                 voyage-rereview-watch.sh already polls for and triggers
#                 the con-voyage-rereview formula against — this script does
#                 not invoke that formula itself.
#
# Idempotent: re-running with the same work bead and findings is safe in
# either mode (PRE-publish: a plain metadata overwrite; POST-publish: the
# idempotency key passed to cv_build_pr_feedback_body is derived from the
# findings text, so cv-pr-comment.sh-side dedup, where applicable, sees the
# same key on a repeat run).
#
# Environment:
#   GC                gc binary to invoke (default: gc)
#   GH                gh binary to invoke (default: gh)
#   CV_IMPLEMENTOR    pool-fallback role name for POST-publish routing
#                     (default: gc.implementation-worker, same as
#                     con-voyage-pr-watch.sh)
#   GC_CITY           city root used to resolve city.toml's
#                     [[github.pr_monitor]] rig mapping for the POST-publish
#                     pool-fallback route (default: .)
#   CV_STATE_DIR      directory holding per-PR .finalize records (default:
#                     cv_default_state_dir)
#   CV_LOCK_STALE_SECONDS  age (seconds) after which the POST-publish route's
#                     cv-ci-repair-<owner>-<repo>-<num> dedup lock is treated
#                     as abandoned and stolen (default: 300, see acquire_lock
#                     in con-voyage-lib.sh)
#
# Exit codes:
#   0 — findings recorded (PRE-publish) or routed (POST-publish).
#   1 — usage error, or neither an open workflow root nor a published PR
#       could be found for this work bead, or a required call failed.

set -uo pipefail

GC="${GC:-gc}"
GH="${GH:-gh}"
CV_IMPLEMENTOR="${CV_IMPLEMENTOR:-gc.implementation-worker}"
GC_CITY="${GC_CITY:-.}"

# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

die() {
  echo "cv-reopen-findings: $*" >&2
  exit 1
}

if [ $# -lt 1 ]; then
  die "usage: cv-reopen-findings.sh <work-bead> (--finding \"<text>\")... [--findings-file <path>]"
fi

WORK_BEAD="$1"
shift

FINDINGS=()
FINDINGS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --finding)
      [ $# -ge 2 ] || die "--finding requires a value"
      FINDINGS+=("$2")
      shift 2
      ;;
    --findings-file)
      [ $# -ge 2 ] || die "--findings-file requires a path"
      FINDINGS_FILE="$2"
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "${WORK_BEAD// /}" ] || die "work-bead id is required"
if [ "${#FINDINGS[@]}" -eq 0 ] && [ -z "$FINDINGS_FILE" ]; then
  die "at least one --finding or a --findings-file is required"
fi

FINDINGS_TEXT=""
if [ "${#FINDINGS[@]}" -gt 0 ]; then
  FINDINGS_TEXT="$(printf '%s\n' "${FINDINGS[@]}")"
fi
if [ -n "$FINDINGS_FILE" ]; then
  [ -f "$FINDINGS_FILE" ] || die "findings file not found: $FINDINGS_FILE"
  FILE_TEXT="$(cat "$FINDINGS_FILE")"
  if [ -n "$FINDINGS_TEXT" ]; then
    FINDINGS_TEXT="$(printf '%s\n%s' "$FINDINGS_TEXT" "$FILE_TEXT")"
  else
    FINDINGS_TEXT="$FILE_TEXT"
  fi
fi
[ -n "${FINDINGS_TEXT// /}" ] || die "findings text is empty after reading input"

# ---------------------------------------------------------------------------
# PRE-publish resolution: find the convoy that TRACKS this work bead (the
# reverse of cv_resolve_work_bead's own forward lookup), then the still-open
# workflow root whose gc.build.source_anchor_id names that convoy.
# ---------------------------------------------------------------------------
CONVOY_ID="$("$GC" bd show "$WORK_BEAD" --json --include-dependents 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
for dep in (d.get('dependents') or []):
    if not isinstance(dep, dict):
        continue
    if dep.get('dependency_type') != 'tracks':
        continue
    meta = dep.get('metadata') or {}
    synthetic = str(meta.get('gc.synthetic', '')).lower() in ('true', '1', 'yes')
    is_convoy = (dep.get('issue_type') or '') == 'convoy'
    if synthetic or is_convoy:
        print(dep.get('id') or '')
        break
" 2>/dev/null)"

ROOT_ID=""
OPEN_ROOT_CANDIDATES=""
if [ -n "${CONVOY_ID// /}" ]; then
  # fk-jekxaw: unlike bd show/update above, this query takes no bead-id
  # positional for gc's own auto-routing to key off, so it silently defaults
  # to cwd-based single-store discovery — wrong whenever this script runs
  # from outside the work bead's own rig (e.g. the mayor, from the city
  # root). Resolve the rig explicitly from the work bead's own id prefix and
  # pass --rig so the lookup is correct regardless of cwd.
  WORK_BEAD_RIG="$(cv_rig_for_bead_id "$WORK_BEAD")"
  # fk-ykq66p BLOCKING-1/BLOCKING-2 (review): an unresolved rig is a
  # "can't verify whether a root is open" state, not a "no root is open"
  # state. The previous code silently dropped --rig and fell through to the
  # exact cwd-based, unrouted bd list this change exists to fix (a BLOCKING
  # verdict could get re-graded, never find the open root, and publish
  # anyway) — and because the fallback left RIG_ARGS a zero-length array,
  # expanding "${RIG_ARGS[@]}" unguarded also aborts with "unbound
  # variable" under `set -u` on bash 3.2 (stock macOS /bin/bash), which this
  # script's shebang can resolve to; that abort fired inside this command
  # substitution, so the error was swallowed by `2>/dev/null` too. Fail loud
  # instead: never query any store without the correct --rig.
  if [ -z "${WORK_BEAD_RIG// /}" ]; then
    die "could not resolve the rig that owns work bead ${WORK_BEAD} (cv_rig_for_bead_id returned empty); refusing to query the city store directly, which would silently miss this rig's own open workflow root — check 'gc rig list --json' and this bead's id prefix"
  fi
  RIG_ARGS=(--rig "$WORK_BEAD_RIG")
  ROOT_JSON="$("$GC" --city "$GC_CITY" "${RIG_ARGS[@]}" bd list --metadata-field "gc.build.source_anchor_id=${CONVOY_ID}" --json --limit=0 2>/dev/null || printf '[]')"
  OPEN_ROOT_CANDIDATES="$(printf '%s' "$ROOT_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for b in data:
    if not isinstance(b, dict):
        continue
    if (b.get('status') or '') != 'closed':
        print(b.get('id') or '')
" 2>/dev/null)"
fi

# fk-9iqxnx LOW-1: two still-open roots matching the same convoy is
# ambiguous (e.g. a stale, abandoned-looking root left behind by an earlier
# interrupted attempt alongside the real live one) — fail closed and name
# every candidate rather than silently acting on whichever happened to sort
# first.
N_OPEN_ROOTS="$(printf '%s\n' "$OPEN_ROOT_CANDIDATES" | grep -c . || true)"
if [ "${N_OPEN_ROOTS:-0}" -gt 1 ]; then
  die "multiple still-open workflow roots match convoy ${CONVOY_ID} — refusing to guess which one to reopen: $(printf '%s' "$OPEN_ROOT_CANDIDATES" | tr '\n' ' ')"
fi
ROOT_ID="$(printf '%s\n' "$OPEN_ROOT_CANDIDATES" | head -n1)"

if [ -n "${ROOT_ID// /}" ]; then
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$GC" bd update "$ROOT_ID" \
    --set-metadata 'gc.build.mayor_reopen_requested=true' \
    --set-metadata "gc.build.mayor_reopen_findings=${FINDINGS_TEXT}" \
    --set-metadata "gc.build.mayor_reopen_recorded_at=${TS}" \
    || die "failed to record reopen findings on workflow root ${ROOT_ID}"
  echo "cv-reopen-findings: PRE-publish — recorded mayor reopen findings on workflow root ${ROOT_ID} (work bead ${WORK_BEAD}); the next apply-review-findings cycle treats them as BLOCKING and re-runs every active lane"
  exit 0
fi

# ---------------------------------------------------------------------------
# POST-publish resolution: find the published PR's .finalize record naming
# this work bead (same dedup-key convention con-voyage-pr-watch.sh/publish
# use: "cv-finalize-<owner>-<repo>-<pr_number>"), then route the findings to
# its recorded implementor (or the pool fallback) exactly like a human PR
# comment would be routed.
# ---------------------------------------------------------------------------
CV_STATE_DIR="${CV_STATE_DIR:-$(cv_default_state_dir)}"
MATCH_FILE=""
if [ -d "$CV_STATE_DIR" ]; then
  for f in "${CV_STATE_DIR}"/cv-finalize-*.finalize; do
    [ -f "$f" ] || continue
    if grep -qxF "work_bead=${WORK_BEAD}" "$f"; then
      MATCH_FILE="$f"
      break
    fi
  done
fi

[ -n "$MATCH_FILE" ] || die "no open con-voyage workflow and no published PR found for work bead ${WORK_BEAD} — nothing to reopen"

DEDUP_KEY="$(basename "$MATCH_FILE" .finalize)"
finalize_read "$DEDUP_KEY"
[ -n "${FS_REPO_FULL// /}" ] && [ -n "${FS_PR_NUMBER// /}" ] \
  || die "finalize record ${DEDUP_KEY} is missing repo_full/pr_number — cannot route"

PR_URL="https://github.com/${FS_REPO_FULL}/pull/${FS_PR_NUMBER}"
HEAD_REF="$("$GH" pr view "$FS_PR_NUMBER" --repo "$FS_REPO_FULL" --json headRefName --jq .headRefName 2>/dev/null || true)"
[ -n "${HEAD_REF// /}" ] || die "could not resolve the head branch for ${FS_REPO_FULL}#${FS_PR_NUMBER}"

# Rig-scoped pool-fallback route: mirrors con-voyage-pr-watch.sh's own
# city.toml [[github.pr_monitor]] owner/repo -> rig lookup, via the SAME
# shared parser (fk-9iqxnx LOW-4) rather than a second hand-rolled regex
# parser only ever exercised against a single-block fixture.
MONITOR_RIG=""
while IFS=$'\x1f' read -r m_owner m_repo m_rig _m_route _m_bases; do
  [ -n "$m_owner" ] && [ -n "$m_repo" ] || continue
  if [ "${m_owner}/${m_repo}" = "$FS_REPO_FULL" ]; then
    MONITOR_RIG="$m_rig"
    break
  fi
done <<< "$(cv_parse_pr_monitor_blocks "${GC_CITY}/city.toml")"
if [ -n "${MONITOR_RIG// /}" ]; then
  POOL_ROUTE="${MONITOR_RIG}/${CV_IMPLEMENTOR}"
else
  POOL_ROUTE="${CV_IMPLEMENTOR}"
fi

ROUTE_TARGET="$POOL_ROUTE"
if [ -n "${FS_IMPLEMENTOR// /}" ] && implementor_alive "$FS_IMPLEMENTOR"; then
  ROUTE_TARGET="$FS_IMPLEMENTOR"
fi

FEEDBACK_SUMMARY="Mayor re-opened findings for ${PR_URL} (work bead ${WORK_BEAD}):
${FINDINGS_TEXT}"

FINDINGS_HASH="$(printf '%s' "$FINDINGS_TEXT" | (shasum -a 256 2>/dev/null || sha256sum 2>/dev/null) | cut -c1-16)"
[ -n "$FINDINGS_HASH" ] || FINDINGS_HASH="nohash"
IDEMPOTENCY_KEY="mayor-reopen-${FS_REPO_FULL//\//_}-${FS_PR_NUMBER}-${FINDINGS_HASH}"
ROUTE_BODY="$(cv_build_pr_feedback_body "$PR_URL" "$HEAD_REF" "$FEEDBACK_SUMMARY" "$IDEMPOTENCY_KEY" "mayor_reopen")" \
  || die "could not build a dispatchable feedback body for ${FS_REPO_FULL}#${FS_PR_NUMBER} (cv-pr-comment.sh unresolvable or nonce failure) — refusing to route an empty findings bead"
ROUTE_TITLE="Mayor re-opened findings on ${FS_REPO_FULL}#${FS_PR_NUMBER}: ${HEAD_REF}"

# fk-9iqxnx LOW-2: this route can fire in the same cycle con-voyage-pr-watch.sh
# is independently evaluating the SAME PR for a CI-repair mint. Take the
# identical per-PR dedup lock PART A/PART A-native already use
# ("cv-ci-repair-<owner>-<repo>-<num>") so the two paths can never double-mint
# a bead for this PR at once — never race it.
CI_REPAIR_DEDUP_KEY="cv-ci-repair-${FS_REPO_FULL%%/*}-${FS_REPO_FULL#*/}-${FS_PR_NUMBER}"
if ! acquire_lock "$CI_REPAIR_DEDUP_KEY"; then
  die "PR ${FS_REPO_FULL}#${FS_PR_NUMBER} is locked by a concurrent con-voyage-pr-watch.sh CI-repair cycle (dedup: ${CI_REPAIR_DEDUP_KEY}) — try again shortly instead of double-minting"
fi
trap 'release_lock "$CI_REPAIR_DEDUP_KEY"' EXIT

SLING_OUT=""
if SLING_OUT="$(printf '%s\n\n%s\n' "$ROUTE_TITLE" "$ROUTE_BODY" | "$GC" --city "$GC_CITY" sling "$ROUTE_TARGET" --stdin 2>&1)"; then
  echo "cv-reopen-findings: POST-publish — routed mayor findings for ${FS_REPO_FULL}#${FS_PR_NUMBER} to ${ROUTE_TARGET}; a fix push triggers the existing post-publish re-review"
  exit 0
elif [ "$ROUTE_TARGET" != "$POOL_ROUTE" ]; then
  echo "cv-reopen-findings: WARNING: sling to recorded implementor ${ROUTE_TARGET} failed (${SLING_OUT}) — falling back to pool route ${POOL_ROUTE}" >&2
  if SLING_OUT="$(printf '%s\n\n%s\n' "$ROUTE_TITLE" "$ROUTE_BODY" | "$GC" --city "$GC_CITY" sling "$POOL_ROUTE" --stdin 2>&1)"; then
    echo "cv-reopen-findings: POST-publish — routed mayor findings for ${FS_REPO_FULL}#${FS_PR_NUMBER} to pool fallback ${POOL_ROUTE}; a fix push triggers the existing post-publish re-review"
    exit 0
  fi
  die "sling to pool route ${POOL_ROUTE} also failed: ${SLING_OUT}"
else
  die "sling to ${ROUTE_TARGET} failed: ${SLING_OUT}"
fi
