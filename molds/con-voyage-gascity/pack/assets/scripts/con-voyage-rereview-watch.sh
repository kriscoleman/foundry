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
#   CV_LENS_STORE_TIMEOUT_SECONDS  Bound on each quick store call — `bd
#                       create`, `bd show`, `bd set-state`, `gh pr view`,
#                       `mail send` (default: 30).
#   CV_REREVIEW_SLING_TIMEOUT_SECONDS  Bound on the `gc sling` call alone
#                       (default: 300). `gc sling` compiles a graph.v2
#                       formula and mints many beads — under real load this
#                       routinely takes far longer than a quick store read
#                       (live evidence 2026-10-04: a manual sling of this
#                       SAME formula took ~96s on a loaded host), so it needs
#                       its own, much larger bound; wrapping it in
#                       CV_LENS_STORE_TIMEOUT_SECONDS (30s) killed it on
#                       every tick and no re-review round ever started.
#                       MATH: the order's own exec timeout is 8m (480s —
#                       con-voyage-rereview-watch.toml). This script dispatches
#                       AT MOST ONE re-review round per sweep (see
#                       dispatched_this_sweep below) specifically so only one
#                       CV_REREVIEW_SLING_TIMEOUT_SECONDS-bounded call can ever
#                       be in flight in a single run, regardless of how many
#                       .finalize records exist — at the 300s default that
#                       leaves ~180s of headroom for every other record's
#                       quick, CV_LENS_STORE_TIMEOUT_SECONDS-bounded checks
#                       plus the mail/bd-create/bd-show calls around the one
#                       dispatch. Raise the order's own timeout instead if a
#                       larger value than 300s is ever needed here.
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
CV_REREVIEW_SLING_TIMEOUT_SECONDS="${CV_REREVIEW_SLING_TIMEOUT_SECONDS:-300}"
case "$CV_REREVIEW_SLING_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_REREVIEW_SLING_TIMEOUT_SECONDS="300" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/con-voyage-lib.sh"
if [ ! -f "$LIB" ]; then
  echo "con-voyage-rereview-watch: FATAL: shared lib not found at ${LIB}" >&2
  exit 0
fi
# shellcheck source=./con-voyage-lib.sh
source "$LIB"

# The dedup lock below (acquire_lock/release_lock) is held across the
# read-decide-write section. The real worst case is the orphan->redispatch
# path (a pending seed from a previous timed-out sling never attached): it
# holds the lock across five CV_LENS_STORE_TIMEOUT_SECONDS-bounded store
# calls (seed_bead_dependent_count's bd show, bd close on the orphaned seed,
# the mayor mail, dispatch_rereview's bd create, and bd set-state) plus the
# CV_REREVIEW_SLING_TIMEOUT_SECONDS-bounded dispatch_rereview sling — a
# legitimate worst-case hold of CV_REREVIEW_SLING_TIMEOUT_SECONDS +
# 5*CV_LENS_STORE_TIMEOUT_SECONDS. Every one of those calls must actually be
# wrapped in cv_with_timeout for that bound to hold (review fk-k4gebi
# BLOCKING-1: an unwrapped bd set-state here previously made the bound
# false). CV_LOCK_STALE_SECONDS (read by acquire_lock in con-voyage-lib.sh)
# must strictly exceed that hold time with real margin, or a slow legitimate
# holder gets its own lock stolen mid-hold by a concurrent sweep. Derive it
# here with headroom to spare (one extra store-call's worth) rather than
# relying on con-voyage-lib.sh's generic 300s default, which an operator
# raising CV_REREVIEW_SLING_TIMEOUT_SECONDS would otherwise outrun. The
# derivation and its non-numeric-fallback guard live in
# resolve_lock_stale_seconds (con-voyage-lib.sh, review fk-k4gebi BLOCKING-1
# narrowed) so they can be pinned directly by a sourced-and-called test.
CV_LOCK_STALE_SECONDS="$(resolve_lock_stale_seconds "$CV_REREVIEW_SLING_TIMEOUT_SECONDS" "$CV_LENS_STORE_TIMEOUT_SECONDS" "${CV_LOCK_STALE_SECONDS:-}")"

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

# rereview_pending_file DEDUP_KEY -> prints the side-channel marker path that
# records a seed bead whose `gc sling` attempt timed out without a confirmed
# result (fk-marojd item 3: a timed-out sling may still finish server-side —
# live evidence: a manual retry of the identical formula took ~96s and
# succeeded). Never written to the shared .finalize record itself (that file
# is also consumed by con-voyage-finalize.sh, which has no notion of this
# in-flight-but-unconfirmed state) — same separate-marker-file convention
# con-voyage-pr-watch.sh's PENDING-ATTACH SELF-HEAL uses for the identical
# "bd create succeeded, the follow-on call did not confirm" shape.
rereview_pending_file() {
  printf '%s/%s.rereview-pending' "$CV_STATE_DIR" "$1"
}

# seed_bead_dependent_count SEED_BEAD_ID -> prints the bead's dependent_count
# (0 on any resolution failure — fail-safe: an unresolvable count is treated
# as "not yet attached" so the caller falls through to closing it as
# orphaned and minting a fresh seed, rather than silently losing a result it
# could not verify). A re-review round compiled onto a seed bead gives that
# seed at least one dependent once `gc sling` has actually attached the
# formula, the same signal this pack's workflow roots carry (see any
# claimed graph.v2 bead's own BLOCKS/TRACKS listing).
seed_bead_dependent_count() {
  local seed_bead_id="$1"
  [ -n "${seed_bead_id// /}" ] || { printf '0'; return 0; }
  local json
  json="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" bd show "$seed_bead_id" --json 2>/dev/null)"
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
print((d or {}).get('dependent_count') or 0)
" 2>/dev/null || printf '0'
}

# flatten_roster_vars ROOT_BEAD_ID -> prints "key=value,key=value,..." built
# from the workflow root's gc.graphv2_vars.v1 JSON metadata, restricted to the
# enable_*/code_lens/implementation_target keys a re-review round needs to
# reproduce the SAME roster. Empty on any resolution failure (caller decides
# how to fail safe). The bd-show call here keeps its own "$GC" --city
# "$GC_CITY" form (this script runs outside the rig's own cwd, unlike
# con-voyage-lib.sh's bare-call convention); only the JSON-parse-and-filter
# logic is shared, via cv_flatten_roster_vars_from_json (review fk-n74o9
# BLOCKING-2 — this used to duplicate that logic inline and had already
# drifted cosmetically from con-voyage-lib.sh's copy).
flatten_roster_vars() {
  local root_bead_id="$1"
  [ -n "${root_bead_id// /}" ] || return 0
  local raw
  raw="$("$GC" --city "$GC_CITY" bd show "$root_bead_id" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
meta = (d or {}).get('metadata') or {}
print(meta.get('gc.graphv2_vars.v1') or '{}')
" 2>/dev/null)"
  cv_flatten_roster_vars_from_json "$raw"
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
  local pending_file; pending_file="$(rereview_pending_file "$dedup_key")"

  local seed_title="Con-voyage re-review: ${repo_full}#${pr_number} round ${new_round}"
  local seed_bead_id
  seed_bead_id=$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
    "$GC" --city "$GC_CITY" --rig "$CV_REREVIEW_RIG" bd create "$seed_title" --priority 1 --silent 2>/dev/null || true)
  if [ -z "${seed_bead_id// /}" ]; then
    echo "con-voyage-rereview-watch: ERROR: failed to create re-review seed bead for ${repo_full}#${pr_number}" >&2
    return 1
  fi

  # Record the pending seed BEFORE the sling attempt (same ordering as
  # con-voyage-pr-watch.sh's PENDING-ATTACH SELF-HEAL): a kill at any point
  # from here on still leaves a trail the next sweep can check instead of
  # minting a second seed and orphaning this one.
  { printf 'seed_bead_id=%s\n' "$seed_bead_id"; printf 'round=%s\n' "$new_round"; } > "$pending_file"

  local -a var_args=()
  local IFS_OLD="$IFS"
  IFS=','
  local pair
  for pair in $roster_vars; do
    [ -n "${pair// /}" ] || continue
    var_args+=(--var "$pair")
  done
  IFS="$IFS_OLD"

  local sling_out sling_rc sling_start sling_end sling_duration
  sling_start=$(date +%s)
  sling_out=$(cv_with_timeout "$CV_REREVIEW_SLING_TIMEOUT_SECONDS" \
    "$GC" --city "$GC_CITY" sling "$route" "$seed_bead_id" --on "$CV_REREVIEW_FORMULA" \
      --var "repo=${repo_full}" --var "pr=${pr_number}" --var "branch=${branch}" \
      --var "finalize_key=${dedup_key}" --var "review_round=${new_round}" \
      "${var_args[@]}" 2>&1)
  sling_rc=$?
  sling_end=$(date +%s)
  sling_duration=$((sling_end - sling_start))

  if [ "$sling_rc" -eq 0 ]; then
    rm -f "$pending_file"
    printf '%s' "$seed_bead_id"
    return 0
  fi

  if [ "$sling_rc" -eq 124 ]; then
    # Ambiguous, not a confirmed failure: cv_with_timeout only guarantees
    # the CLIENT-SIDE `gc sling` process was killed — live evidence shows
    # the server-side dispatch it kicked off can still land afterward.
    # Leave the seed bead open and the marker in place; the next sweep's
    # seed_bead_dependent_count check is the one place that decides whether
    # it actually attached (recovered) or must be closed as orphaned.
    echo "con-voyage-rereview-watch: WARNING: gc sling con-voyage-rereview timed out after ${CV_REREVIEW_SLING_TIMEOUT_SECONDS}s (ran ~${sling_duration}s) for ${repo_full}#${pr_number} on seed ${seed_bead_id} — it may still complete server-side; leaving it pending for next cycle to check before treating it as orphaned" >&2
    return 1
  fi

  echo "con-voyage-rereview-watch: ERROR: gc sling con-voyage-rereview failed after ~${sling_duration}s (exit ${sling_rc}) for ${repo_full}#${pr_number}: ${sling_out}" >&2
  if ! cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
    "$GC" --city "$GC_CITY" bd close "$seed_bead_id" --reason "gc sling con-voyage-rereview failed (exit ${sling_rc})" >/dev/null 2>&1; then
    echo "con-voyage-rereview-watch: WARNING: could not close orphaned seed bead ${seed_bead_id} after a confirmed sling failure for ${repo_full}#${pr_number}" >&2
  fi
  rm -f "$pending_file"
  return 1
}

  # dispatched_this_sweep bounds this run to at most ONE `gc sling` attempt
  # (see CV_REREVIEW_SLING_TIMEOUT_SECONDS doc comment above for the math):
  # with N .finalize records needing a re-review this cycle, only the first
  # pays the up-to-CV_REREVIEW_SLING_TIMEOUT_SECONDS cost; every other
  # trigger is deferred to the next sweep instead of stacking several slow
  # sling attempts inside the order's single 8m exec timeout.
  dispatched_this_sweep=0

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

    # BLOCKING-2 (SRE): a single record's dispatch can now legitimately run up
    # to CV_REREVIEW_SLING_TIMEOUT_SECONDS (default 300s), widening the window
    # where two overlapping sweeps both see no rereview_root_bead_id, both
    # mint a seed bead, and both sling the same PR+round — the pending-marker
    # logic above assumes single-flight and does not catch that. Same
    # mkdir-based mutex sibling monitors con-voyage-pr-watch.sh and
    # con-voyage-repair-watchdog.sh already use (precedent: fk-11yuv,
    # kriscoleman/foundry#81) guards the whole read-decide-write section below.
    if ! acquire_lock "$dedup_key"; then
      echo "con-voyage-rereview-watch: SKIP ${label} — locked by a concurrent rereview-watch run (dedup: ${dedup_key})"
      continue
    fi

    roster_vars="$FS_ROSTER_VARS"
    if [ -z "${roster_vars// /}" ] && [ -n "${FS_ROOT_BEAD_ID// /}" ]; then
      roster_vars="$(flatten_roster_vars "$FS_ROOT_BEAD_ID")"
    fi

    next_round="${FS_REVIEW_ROUND:-1}"
    case "$next_round" in
      *[!0-9]*|'') next_round=1 ;;
    esac
    next_round=$((10#$next_round + 1))

    # A previous sweep's sling may have timed out client-side without a
    # confirmed result (fk-marojd item 4): check for that pending seed
    # FIRST, before minting a new one or counting against this sweep's
    # one-dispatch budget — this check is a cheap store read, not a sling.
    new_root=""
    pending_file="$(rereview_pending_file "$dedup_key")"
    pending_seed_bead_id=""
    pending_round=""
    if [ -f "$pending_file" ]; then
      while IFS='=' read -r pkey pval || [ -n "$pkey" ]; do
        case "$pkey" in
          seed_bead_id) pending_seed_bead_id="$pval" ;;
          round) pending_round="$pval" ;;
        esac
      done < "$pending_file"
    fi
    if [ -n "${pending_seed_bead_id// /}" ]; then
      dep_count="$(seed_bead_dependent_count "$pending_seed_bead_id")"
      case "$dep_count" in
        *[!0-9]*|'') dep_count=0 ;;
      esac
      if [ "$dep_count" -gt 0 ]; then
        echo "con-voyage-rereview-watch: ${label} — a previously timed-out sling (seed ${pending_seed_bead_id}) completed server-side; recording it instead of dispatching again"
        new_root="$pending_seed_bead_id"
        [ -n "${pending_round// /}" ] && next_round="$pending_round"
        rm -f "$pending_file"
      else
        echo "con-voyage-rereview-watch: ${label} — pending seed ${pending_seed_bead_id} from a previous timed-out sling never attached; closing it as orphaned and retrying fresh"
        if ! cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
          "$GC" --city "$GC_CITY" bd close "$pending_seed_bead_id" --reason "superseded: previous re-review sling for ${label} never attached" >/dev/null 2>&1; then
          echo "con-voyage-rereview-watch: WARNING: could not close stale pending seed ${pending_seed_bead_id} for ${label}" >&2
        fi
        rm -f "$pending_file"
        [ -n "${pending_round// /}" ] && next_round="$pending_round"
      fi
    fi

    if [ -z "${new_root// /}" ]; then
      if [ "$dispatched_this_sweep" -eq 1 ]; then
        echo "con-voyage-rereview-watch: SKIP ${label} — already dispatched one re-review round this sweep; deferring to next cycle to bound sweep runtime under the order's exec timeout"
        release_lock "$dedup_key"
        continue
      fi

      mail_out=$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
        "$GC" --city "$GC_CITY" mail send mayor \
          -s "RE-REVIEW PENDING: ${label}" \
          -m "con-voyage-rereview-watch: ${label} received a code-changing push to ${new_head} after publish. Starting a fresh review round (round ${next_round}) with the original roster before the PR may land." \
          --json 2>/dev/null)
      mail_rc=$?
      if [ "$mail_rc" -ne 0 ]; then
        echo "con-voyage-rereview-watch: WARNING: mayor mail (RE-REVIEW PENDING) failed for ${label}: ${mail_out}; continuing anyway (the re-review dispatch itself is the primary signal)" >&2
      fi

      new_root="$(dispatch_rereview "$dedup_key" "$FS_REPO_FULL" "$FS_PR_NUMBER" "$branch" "$roster_vars" "$next_round")"
      dispatched_this_sweep=1
      if [ -z "${new_root// /}" ]; then
        echo "con-voyage-rereview-watch: ERROR: could not dispatch a re-review round for ${label}; will retry next cycle" >&2
        release_lock "$dedup_key"
        continue
      fi
    fi

    cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
      "$GC" --city "$GC_CITY" bd set-state "$FS_WORK_BEAD" cv=re_reviewing \
      --reason "con-voyage-rereview-watch: re-review round ${next_round} started for ${new_head}" >/dev/null 2>&1 \
      || echo "con-voyage-rereview-watch: WARNING: could not set cv=re_reviewing on ${FS_WORK_BEAD}" >&2

    finalize_write "$dedup_key" "$FS_WORK_BEAD" "$FS_CONVOY_ID" "$FS_REPO_FULL" \
      "$FS_PR_NUMBER" "$FS_PR_AUTHOR" "$FS_IMPLEMENTOR" "re_reviewing" "$FS_ROOT_BEAD_ID" \
      "$roster_vars" "$new_head" "$next_round" "$new_root"
    echo "con-voyage-rereview-watch: dispatched re-review round ${next_round} for ${label} -> seed bead ${new_root}"
    release_lock "$dedup_key"
  done

exit 0
