#!/usr/bin/env bash
# con-voyage-rereview-watch.sh — post-publish re-review trigger (fk-pubvq).
#
# ############################################################################
# # HARD INVARIANT — AUTHOR SCOPING                                          #
# #                                                                          #
# # This monitor MUST only ever act on per-PR finalize records whose         #
# # recorded `pr_author` is the single configured user CV_PR_AUTHOR. Fail     #
# # closed on an empty/unresolved CV_PR_AUTHOR or pr_author, same as every    #
# # other author gate in this pack (con-voyage-finalize.sh,                  #
# # con-voyage-pr-watch.sh, con-voyage-ci-repair-guard.sh).                   #
# ############################################################################
#
# THE GAP THIS CLOSES: con-voyage's multi-lens review only ever runs once,
# inside the original graph.v2 workflow. Once publish opens the PR, that
# workflow root is free to close (con-voyage-finalize.sh tears it down on
# merge/close) — but the PR can keep moving BEFORE that: a human-feedback
# bead (con-voyage-pr-watch.sh PART B) or a ci-repair bead
# (con-voyage-ci-repair.formula.toml) can push a brand-new, code-changing
# commit to the SAME branch with no review lane ever re-running against it.
# Live evidence: replicatedhq/vandoor#10589 — a human-feedback fix flipped an
# entitlement filter from a blocklist to an allowlist (a security-sensitive
# change) and shipped with zero review.
#
# HOW IT WORKS: con-voyage's publish step (main.publish.md) now also records
# last_reviewed_head_sha (the head SHA actually reviewed), review_round (the
# next aggregated-comment round number), and roster_vars (the original
# enable_*/code_lens formula vars, flattened) on the SAME per-PR ".finalize"
# record con-voyage-finalize.sh already consumes. This script globs those
# records and, per OPEN PR:
#
#   1. Author-scope check (skip records not authored by CV_PR_AUTHOR).
#   2. Skip if a re-review round is already in flight for this record
#      (rereview_root_bead_id set) — avoid a duplicate dispatch; that round's
#      own finalize step clears the field when it completes.
#   3. Resolve the PR's CURRENT head SHA (one `gh pr view`). Identical to
#      last_reviewed_head_sha -> no new commit (a CI-only re-run, or nothing
#      happened) -> no-op.
#   4. A new head SHA: fetch it into a per-repo local mirror clone and reuse
#      cv_sync_patch_unchanged (con-voyage-lib.sh) to tell a content-identical
#      replay (e.g. a rebase-only sync, already detected upstream by that same
#      function in the live review loop) from a genuine patch change. Treat a
#      resolution error (exit 2) conservatively as "changed", per that
#      function's own documented caller contract.
#        - unchanged -> advance last_reviewed_head_sha, no re-review needed.
#        - changed   -> trigger a re-review round: mail the mayor "RE-REVIEW
#          PENDING: <repo>#<pr>", mark the work bead cv=re_reviewing (so the
#          PR does not look land-ready), pre-create a bead and `gc sling` the
#          con-voyage-rereview formula onto it with the SAME roster vars,
#          and record the new round's root bead id + incremented review_round
#          on the finalize record.
#
# Environment / configuration:
#   GC                  Path to the gc binary (default: gc)
#   GH                  Path to the gh binary (default: gh)
#   GC_CITY             City root passed to `gc --city` (default: .)
#   CV_STATE_DIR        Per-PR record directory (default: cv_default_state_dir)
#   CV_PR_AUTHOR        Required. The single GitHub login this monitor acts on.
#   CV_REREVIEW_RIG     Required to actually dispatch. The rig to mint the
#                       round's seed bead in and sling it within (the PR's
#                       GitHub repo is unrelated to this Gas City rig name).
#   CV_REREVIEW_FORMULA Formula to sling for a triggered round (default:
#                       con-voyage-rereview).
#   CV_REPO_CACHE_DIR   Local bare-mirror cache root for patch-id comparison
#                       (default: "${CV_STATE_DIR}/rereview-repo-cache").
#   CV_LENS_STORE_TIMEOUT_SECONDS  Bound on each external call (default: 30).
#
# Exit code: always 0 (monitor convention — a per-record failure is logged
# and retried next cycle, never fatal to the whole sweep).
#
# Run:  con-voyage-rereview-watch.sh

set -uo pipefail

GC="${GC:-gc}"
GH="${GH:-gh}"
GC_CITY="${GC_CITY:-.}"
CV_REREVIEW_FORMULA="${CV_REREVIEW_FORMULA:-con-voyage-rereview}"
CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/con-voyage-lib.sh"
if [ ! -f "$LIB" ]; then
  echo "con-voyage-rereview-watch: FATAL: shared lib not found at ${LIB}" >&2
  exit 0
fi
# shellcheck source=./con-voyage-lib.sh
source "$LIB"

CV_PR_AUTHOR="${CV_PR_AUTHOR:-}"
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  echo "con-voyage-rereview-watch: FATAL: CV_PR_AUTHOR is not set — refusing to act on any PR (fail closed)" >&2
  exit 0
fi

if [ -z "${CV_STATE_DIR:-}" ]; then
  CV_STATE_DIR="$(cv_default_state_dir)"
fi
[ -n "${CV_STATE_DIR:-}" ] || CV_STATE_DIR="${GC_CITY:-.}/.gc/cv-pr-watch"
mkdir -p "$CV_STATE_DIR"

CV_REPO_CACHE_DIR="${CV_REPO_CACHE_DIR:-${CV_STATE_DIR}/rereview-repo-cache}"
mkdir -p "$CV_REPO_CACHE_DIR"

echo "con-voyage-rereview-watch: author-scoped to PRs authored by '${CV_PR_AUTHOR}' (all other records are ignored)"

# repo_cache_dir REPO_FULL — deterministic local clone path for a repo, one
# per owner/repo so repeated cycles reuse (fetch-only) instead of re-cloning.
# A REGULAR (non-bare) clone, not a bare mirror: classify_head_change must
# `git checkout` NEW_HEAD into a working tree so cv_sync_patch_unchanged can
# read it as the dir's current HEAD — `git checkout` is a no-op error in a
# bare repository.
repo_cache_dir() {
  local repo_full="$1"
  printf '%s/%s' "$CV_REPO_CACHE_DIR" "${repo_full//\//-}"
}

# ensure_repo_cache REPO_FULL -> prints the cache dir on success, empty on
# failure. Clones on first use; otherwise reused as-is (classify_head_change
# does its own targeted `git fetch` of the exact SHAs it needs).
ensure_repo_cache() {
  local repo_full="$1"
  local dir; dir="$(repo_cache_dir "$repo_full")"
  if [ ! -d "$dir" ]; then
    if ! cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" git clone -q "https://github.com/${repo_full}.git" "$dir" >&2; then
      echo "con-voyage-rereview-watch: ERROR: could not clone ${repo_full} into local cache" >&2
      rm -rf "$dir"
      return 1
    fi
  fi
  printf '%s' "$dir"
}

# fetch_shas CACHE_DIR SHA... -> best-effort fetch of specific commits into
# the bare cache (GitHub allows fetching a reachable SHA directly). Never
# fatal on its own — the caller's rev-parse/patch-id calls detect whether the
# needed commits actually landed.
fetch_shas() {
  local dir="$1"; shift
  local sha
  for sha in "$@"; do
    [ -n "${sha// /}" ] || continue
    cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" git -C "$dir" fetch -q origin "$sha" >&2 2>/dev/null || true
  done
}

# classify_head_change CACHE_DIR OLD_HEAD NEW_HEAD -> echoes "unchanged" or
# "changed" on stdout; diagnostics to stderr. No historical base SHA is
# persisted anywhere (only the reviewed HEAD is), so this resolves the
# repo's CURRENT default base (cv_worktree_prep_resolve_base: origin/HEAD ->
# origin/main -> main) and uses that SAME commit as the "base" for BOTH
# OLD_HEAD's own patch and NEW_HEAD's own patch — merge-base(current_base,
# old_head) still correctly isolates old_head's own commits since it forked
# from mainline, regardless of how far the base has advanced since. Reuses
# cv_sync_patch_unchanged's own patch-id-set comparison (fk-u8n34) by
# checking NEW_HEAD out as the cache dir's current HEAD first.
classify_head_change() {
  local dir="$1" old_head="$2" new_head="$3"
  if ! git -C "$dir" rev-parse --quiet --verify "${new_head}^{commit}" >/dev/null 2>&1 \
    || ! git -C "$dir" rev-parse --quiet --verify "${old_head}^{commit}" >/dev/null 2>&1; then
    echo "con-voyage-rereview-watch: classify_head_change: old=${old_head} or new=${new_head} did not fetch into the cache — treating conservatively as changed" >&2
    echo "changed"
    return 0
  fi
  local base_ref base_sha
  base_ref="$(cv_worktree_prep_resolve_base "$dir")"
  base_sha="$(git -C "$dir" rev-parse --quiet --verify "${base_ref}^{commit}" 2>/dev/null)"
  if [ -z "${base_sha// /}" ]; then
    echo "con-voyage-rereview-watch: classify_head_change: could not resolve a current base ref in ${dir} — treating conservatively as changed" >&2
    echo "changed"
    return 0
  fi
  if ! git -C "$dir" checkout -q --detach "$new_head" >&2; then
    echo "con-voyage-rereview-watch: classify_head_change: could not check out ${new_head} — treating conservatively as changed" >&2
    echo "changed"
    return 0
  fi
  if cv_sync_patch_unchanged "$dir" "$base_sha" "$old_head" >&2; then
    echo "unchanged"
  else
    echo "changed"
  fi
}

# flatten_roster_vars ROOT_BEAD_ID -> prints "key=value,key=value,..." built
# from the workflow root's gc.graphv2_vars.v1 JSON metadata, restricted to the
# enable_*/code_lens/implementation_target keys a re-review round needs to
# reproduce the SAME roster. Empty on any resolution failure (caller decides
# how to fail safe).
flatten_roster_vars() {
  local root_bead_id="$1"
  [ -n "${root_bead_id// /}" ] || return 0
  "$GC" --city "$GC_CITY" bd show "$root_bead_id" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
meta = (d or {}).get('metadata') or {}
raw = meta.get('gc.graphv2_vars.v1') or '{}'
try:
    vars_ = json.loads(raw)
except Exception:
    vars_ = {}
keep_prefixes = ('enable_',)
keep_exact = ('code_lens', 'implementation_target', 'cv_lens_claim_seconds',
              'cv_lens_max_redispatch', 'cv_lens_escalate_target')
parts = []
for k in sorted(vars_):
    if k in keep_exact or any(k.startswith(p) for p in keep_prefixes):
        parts.append('{}={}'.format(k, vars_[k]))
print(','.join(parts))
" 2>/dev/null
}

# dispatch_rereview DEDUP_KEY REPO_FULL PR_NUMBER BRANCH ROSTER_VARS \
#                    NEW_ROUND -> on success, echoes the new root bead id on
# stdout (empty on failure). Mints a seed bead in CV_REREVIEW_RIG's store and
# slings con-voyage-rereview onto it, same two-step pattern
# con-voyage-pr-watch.sh uses for con-voyage-ci-repair (gc rejects an inline
# v2-formula sling with no pre-created bead to resolve {{convoy_id}} against).
dispatch_rereview() {
  local dedup_key="$1" repo_full="$2" pr_number="$3" branch="$4"
  local roster_vars="$5" new_round="$6"

  if [ -z "${CV_REREVIEW_RIG:-}" ]; then
    echo "con-voyage-rereview-watch: ERROR: CV_REREVIEW_RIG is not set — cannot mint/sling a re-review round for ${repo_full}#${pr_number}" >&2
    return 1
  fi
  local route="${CV_REREVIEW_RIG}/gc.run-operator"

  local seed_title="Con-voyage re-review: ${repo_full}#${pr_number} round ${new_round}"
  local seed_bead_id
  seed_bead_id=$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
    "$GC" --city "$GC_CITY" --rig "$CV_REREVIEW_RIG" bd create "$seed_title" --priority 1 --silent 2>/dev/null || true)
  if [ -z "${seed_bead_id// /}" ]; then
    echo "con-voyage-rereview-watch: ERROR: failed to create re-review seed bead for ${repo_full}#${pr_number}" >&2
    return 1
  fi

  local -a var_args=()
  local IFS_OLD="$IFS"
  IFS=','
  local pair
  for pair in $roster_vars; do
    [ -n "${pair// /}" ] || continue
    var_args+=(--var "$pair")
  done
  IFS="$IFS_OLD"

  local sling_out
  if ! sling_out=$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
    "$GC" --city "$GC_CITY" sling "$route" "$seed_bead_id" --on "$CV_REREVIEW_FORMULA" \
      --var "repo=${repo_full}" --var "pr=${pr_number}" --var "branch=${branch}" \
      --var "finalize_key=${dedup_key}" --var "review_round=${new_round}" \
      "${var_args[@]}" 2>&1); then
    echo "con-voyage-rereview-watch: ERROR: gc sling con-voyage-rereview failed for ${repo_full}#${pr_number}: ${sling_out}" >&2
    return 1
  fi
  printf '%s' "$seed_bead_id"
}

  for finalize_file in "${CV_STATE_DIR}"/*.finalize; do
    [ -f "$finalize_file" ] || continue

    dedup_key="${finalize_file##*/}"
    dedup_key="${dedup_key%.finalize}"
    finalize_read "$dedup_key"

    label="$dedup_key"
    if [ -n "${FS_REPO_FULL// /}" ] && [ -n "${FS_PR_NUMBER// /}" ]; then
      label="${FS_REPO_FULL}#${FS_PR_NUMBER}"
    fi

    if [ -z "${FS_WORK_BEAD// /}" ] || [ -z "${FS_REPO_FULL// /}" ] || [ -z "${FS_PR_NUMBER// /}" ]; then
      echo "con-voyage-rereview-watch: SKIP ${dedup_key} — record missing work_bead/repo_full/pr_number"
      continue
    fi

    if [ -z "${FS_PR_AUTHOR// /}" ] || [ "$FS_PR_AUTHOR" != "$CV_PR_AUTHOR" ]; then
      echo "con-voyage-rereview-watch: SKIP ${label} — author scoping (pr_author='${FS_PR_AUTHOR}' != CV_PR_AUTHOR='${CV_PR_AUTHOR}')"
      continue
    fi

    if [ -n "${FS_REREVIEW_ROOT_BEAD_ID// /}" ]; then
      echo "con-voyage-rereview-watch: SKIP ${label} — re-review round already in flight (root ${FS_REREVIEW_ROOT_BEAD_ID})"
      continue
    fi

    if [ -z "${FS_LAST_REVIEWED_HEAD_SHA// /}" ]; then
      echo "con-voyage-rereview-watch: SKIP ${label} — record has no last_reviewed_head_sha (older record, or publish has not run the fk-pubvq finalize write yet)"
      continue
    fi

    pr_json=$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
      "$GH" pr view "$FS_PR_NUMBER" --repo "$FS_REPO_FULL" --json state,headRefOid,headRefName 2>/dev/null) || pr_json=""
    if [ -z "${pr_json// /}" ]; then
      echo "con-voyage-rereview-watch: SKIP ${label} — gh pr view failed; retrying next cycle" >&2
      continue
    fi
    IFS=$'\x1f' read -r pr_state new_head branch <<< "$(printf '%s' "$pr_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print('{}\x1f{}\x1f{}'.format(d.get('state') or '', d.get('headRefOid') or '', d.get('headRefName') or ''))
" 2>/dev/null)"

    if [ "$pr_state" != "OPEN" ]; then
      echo "con-voyage-rereview-watch: SKIP ${label} — PR not OPEN (state=${pr_state:-unknown}); con-voyage-finalize.sh owns terminal teardown"
      continue
    fi
    if [ -z "${new_head// /}" ]; then
      echo "con-voyage-rereview-watch: SKIP ${label} — could not resolve current head SHA; retrying next cycle" >&2
      continue
    fi

    if [ "$new_head" = "$FS_LAST_REVIEWED_HEAD_SHA" ]; then
      echo "con-voyage-rereview-watch: OK ${label} — head unchanged (${new_head}), nothing to re-review"
      continue
    fi

    cache_dir="$(ensure_repo_cache "$FS_REPO_FULL")"
    if [ -z "${cache_dir// /}" ]; then
      echo "con-voyage-rereview-watch: SKIP ${label} — could not prepare local mirror; retrying next cycle" >&2
      continue
    fi
    fetch_shas "$cache_dir" "$FS_LAST_REVIEWED_HEAD_SHA" "$new_head"
    classification="$(classify_head_change "$cache_dir" "$FS_LAST_REVIEWED_HEAD_SHA" "$new_head")"

    if [ "$classification" = "unchanged" ]; then
      echo "con-voyage-rereview-watch: OK ${label} — new head ${new_head} is a content-identical replay (rebase-only); advancing bookkeeping, no re-review"
      finalize_write "$dedup_key" "$FS_WORK_BEAD" "$FS_CONVOY_ID" "$FS_REPO_FULL" \
        "$FS_PR_NUMBER" "$FS_PR_AUTHOR" "$FS_IMPLEMENTOR" "$FS_LAST_PHASE" "$FS_ROOT_BEAD_ID" \
        "$FS_ROSTER_VARS" "$new_head" "$FS_REVIEW_ROUND" "$FS_REREVIEW_ROOT_BEAD_ID"
      continue
    fi

    echo "con-voyage-rereview-watch: TRIGGER ${label} — new head ${new_head} carries a real code change since ${FS_LAST_REVIEWED_HEAD_SHA}; starting a re-review round"

    roster_vars="$FS_ROSTER_VARS"
    if [ -z "${roster_vars// /}" ] && [ -n "${FS_ROOT_BEAD_ID// /}" ]; then
      roster_vars="$(flatten_roster_vars "$FS_ROOT_BEAD_ID")"
    fi

    next_round="${FS_REVIEW_ROUND:-1}"
    case "$next_round" in
      *[!0-9]*|'') next_round=1 ;;
    esac
    next_round=$((10#$next_round + 1))

    mail_out=$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
      "$GC" --city "$GC_CITY" mail send mayor \
        -s "RE-REVIEW PENDING: ${label}" \
        -m "con-voyage-rereview-watch: ${label} received a code-changing push to ${new_head} after publish. Starting a fresh review round (round ${next_round}) with the original roster before the PR may land." \
        --json 2>&1)
    mail_rc=$?
    if [ "$mail_rc" -ne 0 ]; then
      echo "con-voyage-rereview-watch: WARNING: mayor mail (RE-REVIEW PENDING) failed for ${label}: ${mail_out}; continuing anyway (the re-review dispatch itself is the primary signal)" >&2
    fi

    new_root="$(dispatch_rereview "$dedup_key" "$FS_REPO_FULL" "$FS_PR_NUMBER" "$branch" "$roster_vars" "$next_round")"
    if [ -z "${new_root// /}" ]; then
      echo "con-voyage-rereview-watch: ERROR: could not dispatch a re-review round for ${label}; will retry next cycle" >&2
      continue
    fi

    "$GC" --city "$GC_CITY" bd set-state "$FS_WORK_BEAD" cv=re_reviewing \
      --reason "con-voyage-rereview-watch: re-review round ${next_round} started for ${new_head}" >/dev/null 2>&1 \
      || echo "con-voyage-rereview-watch: WARNING: could not set cv=re_reviewing on ${FS_WORK_BEAD}" >&2

    finalize_write "$dedup_key" "$FS_WORK_BEAD" "$FS_CONVOY_ID" "$FS_REPO_FULL" \
      "$FS_PR_NUMBER" "$FS_PR_AUTHOR" "$FS_IMPLEMENTOR" "re_reviewing" "$FS_ROOT_BEAD_ID" \
      "$roster_vars" "$new_head" "$next_round" "$new_root"
    echo "con-voyage-rereview-watch: dispatched re-review round ${next_round} for ${label} -> seed bead ${new_root}"
  done

exit 0
