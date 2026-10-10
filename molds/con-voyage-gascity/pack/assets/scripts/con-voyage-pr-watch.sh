#!/usr/bin/env bash
# con-voyage-pr-watch.sh — GitHub PR monitoring driver
#
# ############################################################################
# # HARD INVARIANT — AUTHOR SCOPING                                          #
# #                                                                          #
# # This monitor MUST only ever act on PRs authored by the single           #
# # configured user CV_PR_AUTHOR (default: the authenticated gh login).      #
# # It NEVER creates a repair bead for, and NEVER routes comments from, a    #
# # PR authored by anyone else.                                             #
# #                                                                          #
# # Rationale: an earlier unfiltered version acted on 43 PRs it did not own  #
# # across other people's repos and got the operator removed from the org.   #
# # Both duties below are author-scoped, and the script FAILS CLOSED (exits  #
# # non-zero before any GitHub work) if CV_PR_AUTHOR cannot be resolved.     #
# #                                                                          #
# # The native [[github.pr_monitor]] config cannot express an author filter  #
# # and `gc github pr backfill` has no --author flag, so author-scoping is   #
# # enforced HERE, in this script, which is the sole runtime driver of the   #
# # monitor (the native poll_interval is inert without it).                  #
# ############################################################################
#
# Drives two monitoring duties:
#
#   PART A: CI-failure repair (AUTHOR-SCOPED)
#     Runs `gc github pr backfill --json` (REPORT-ONLY, no --create-repair-beads)
#     against all configured [[github.pr_monitor]] blocks, then DROPS every PR
#     not authored by CV_PR_AUTHOR, SKIPS a PR that is only awaiting human
#     review (all CI green, mergeable, up to date, blocked solely on
#     reviewDecision=REVIEW_REQUIRED — con-voyage PRs never auto-merge, so
#     every one of them would otherwise end there forever), and creates a
#     deduped repair bead only for each remaining actionable PR. This script
#     is what actually invokes the backfill on a recurring basis — without it
#     the native monitor never fires (poll_interval is inert at runtime).
#
#     NOTE: we deliberately do NOT use `gc github pr backfill
#     --create-repair-beads`, because that native path creates a repair bead
#     for EVERY actionable PR regardless of author (it has no author filter).
#     Using the report-only JSON + our own per-PR author check + our own bead
#     creation is the only way to guarantee the author-scoping invariant.
#
#   PART B: Human PR-comment routing (best-effort polling)
#     The native [[github.pr_monitor]] watches CI checks and merge-state ONLY.
#     It does NOT watch human PR review comments or issue comments. This script
#     bridges that gap by polling open PRs for new human feedback and routing
#     it to the con-voyage implementor.
#
#     "Human" comments are those NOT prefixed with `[<rig>/<agent> — <lens>]`
#     (the con-voyage reviewer identity prefix). Bot/automation comments
#     typically carry a [bot] suffix or a well-known bot login.
#
#     Inline review-thread comments (reviewThreads) are also captured in
#     addition to top-level reviews and issue comments.
#
#     Deduplication uses GitHub GraphQL node-ID STRINGS (e.g. "PRR_kwDO...",
#     "IC_kwDO..."). IDs are stored newline-delimited in a per-PR state file.
#     The seen-set is capped each run to IDs from currently-open PRs to prevent
#     unbounded growth.
#
#     Routing uses `gc sling` to create a routed task bead assigned to the
#     implementor. This script NEVER merges or closes PRs — it only reads
#     GitHub and routes feedback.
#
#     This is BEST-EFFORT. Comment polling has no event-driven delivery
#     guarantee; a comment posted moments before this script runs might be
#     seen 10 minutes later. Use native GitHub webhooks (webhook_secret_env
#     in city.toml) for near-realtime comment delivery if available.
#
# Environment / configuration (all optional with sane defaults):
#
#   GC              Path to the gc binary (default: gc)
#   GH              Path to the gh binary (default: gh)
#   GC_CITY         City root passed to gc (default: current directory)
#   CV_STATE_DIR    Directory for idempotency state files (default: .gc/cv-pr-watch)
#   CV_IMPLEMENTOR  Implementor session/route target for routing human comments
#                   (default: gc.implementation-worker)
#   CV_PR_AUTHOR    REQUIRED (author-scoping). The single GitHub login whose PRs
#                   this monitor is allowed to act on. Defaults to the
#                   authenticated gh login. If it cannot be resolved, the script
#                   FAILS CLOSED (exit 1) before touching any repo.
#   CV_AUTHOR_GATE  Forwarded, NOT read, by this script (default: enabled). Every
#                   repair bead this script mints carries this value via
#                   --var cv_author_gate=..., so the con-voyage-ci-repair
#                   worker's own Step 0 gate and the con-voyage-ci-repair-guard
#                   order honor the same toggle. This script's OWN PART A/B
#                   author filtering above is always CV_PR_AUTHOR-scoped
#                   regardless of this value — see README.md's "Author-gate
#                   toggle" section.
#   CV_CONFLICT_STRATEGY  Forwarded, NOT read for branching, by this script
#                   (default: rebase). Every repair bead this script mints
#                   carries this value via --var cv_conflict_strategy=..., so
#                   the con-voyage-ci-repair worker's DIRTY (4b) and BEHIND
#                   (4c) steps know whether to rebase (linear history, the
#                   operator's default) or merge (explicit opt-in only). This
#                   is a rig-level config knob — set it once in
#                   con-voyage-pr-watch.toml's [order.env], not per invocation.
#   CV_LOCK_STALE_SECONDS  Seconds after which a held per-dedup_key lock is
#                   presumed abandoned (crashed holder) and stolen rather than
#                   left to wedge that PR's record forever. Default: 300 (5
#                   minutes) — same default and semantics as
#                   con-voyage-repair-watchdog.sh, which shares this lock
#                   implementation (con-voyage-lib.sh).
#   CV_MINT_MAX_ATTEMPTS  Consecutive failed fallback-mint attempts (bd create
#                   succeeded but the ci-repair sling failed, or bd create
#                   itself failed) allowed for the SAME PR before this script
#                   stops retrying and escalates instead (fk-zvkmd: an
#                   unbounded retry left ~61 orphaned, description-less
#                   repair beads behind in production, one per ~11-minute
#                   cycle, because each failed sling left its pre-created
#                   bead behind and was retried from scratch next cycle).
#                   Default: 3. Tracked per-PR in
#                   CV_STATE_DIR/<dedup_key>.mint-failures — a lightweight
#                   counter separate from the main per-PR state record (which
#                   deliberately records nothing on a failed dispatch, so a
#                   transient failure is still retried — see PART A).
#   CV_ESCALATE_TARGET  Mail recipient once CV_MINT_MAX_ATTEMPTS is reached
#                   for a PR. Default: the reserved `human` alias (same
#                   default as con-voyage-repair-watchdog.sh's own
#                   escalation target).
#   CV_NATIVE_PRLIST_LIMIT  `--limit` passed to PART A-native's own
#                   `gh pr list` call (fk-travno review BLOCKING-4: gh's own
#                   default page size is 30, so an author with more than 30
#                   open PRs across a monitored repo silently never saw the
#                   rest discovered by this path at all). Default: 100.
#   CV_SUPPRESSION_LOG_MAX_LINES  Cap on the per-PR durable
#                   `<dedup_key>.suppressions.log` (fk-dh3mkt review, mayor
#                   reopen — regraded LOW-4: this file is append-only with no
#                   rotation, same unbounded-file precedent as the
#                   `.seen-ids`/`.mint-failures` state files, and a PR left
#                   open for a long time would otherwise grow it forever).
#                   Once a write pushes the file past this many lines, it is
#                   trimmed back down to the most recent
#                   CV_SUPPRESSION_LOG_MAX_LINES lines. Default: 2000.
#                   Exported so the Python-side trim (log_suppression, below)
#                   observes the same value this shell resolved rather than
#                   re-deriving its own default independently.
#
# Exit codes:
#   0 — completed (some or all monitors may have had no actionable PRs)
#   Non-zero — fatal setup error (gh/gc not found, GITHUB_TOKEN missing, etc.)
#
# The order controller treats any non-zero exit as a transient failure and
# retries on the next cooldown interval.
#
# Requires: bash 4+, gh CLI (authenticated), gc CLI, python3.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GH="${GH:-gh}"
GC_CITY="${GC_CITY:-.}"

# Sourced early (functions only, no side effects at source time — see the
# file's own header) so cv_default_state_dir is available for CV_STATE_DIR's
# default below.
# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

CV_STATE_DIR="${CV_STATE_DIR:-$(cv_default_state_dir)}"
CV_IMPLEMENTOR="${CV_IMPLEMENTOR:-gc.implementation-worker}"
# Forwarded, NOT read for branching, by this script (see header) — declared
# here with the other tunables rather than left as an inline ${..:-default}
# at each use site, so every configuration knob resolves in one place.
CV_AUTHOR_GATE="${CV_AUTHOR_GATE:-enabled}"
# fk-dxswwi BLOCKING-2: PART A-native discovery (below) is a new, unexercised
# code path that fans out gh pr list/gh pr view against every configured
# monitor and can auto-mint con-voyage-ci-repair work. Keep it opt-in with a
# code-free rollback until it has production mileage.
CV_NATIVE_DISCOVERY="${CV_NATIVE_DISCOVERY:-disabled}"
CV_NATIVE_PRLIST_LIMIT="${CV_NATIVE_PRLIST_LIMIT:-100}"
CV_SUPPRESSION_LOG_MAX_LINES="${CV_SUPPRESSION_LOG_MAX_LINES:-2000}"
export CV_SUPPRESSION_LOG_MAX_LINES
CV_CONFLICT_STRATEGY="${CV_CONFLICT_STRATEGY:-rebase}"
CV_LOCK_STALE_SECONDS="${CV_LOCK_STALE_SECONDS:-300}"
CV_MINT_MAX_ATTEMPTS="${CV_MINT_MAX_ATTEMPTS:-3}"
CV_ESCALATE_TARGET="${CV_ESCALATE_TARGET:-human}"

# AUTHOR SCOPING (see HARD INVARIANT in the header). The single GitHub login
# whose PRs this monitor may act on. Defaults to the authenticated gh login.
# Never leave this empty — the preflight fails closed if it is unresolved.
#
# NOTE: we do NOT resolve the gh-login default here. Under `set -e`, a failing
# command substitution on this assignment line would abort the script BEFORE
# the fail-closed guard could report a clear error. The gh-login fallback is
# resolved (guarded against set -e) in the preflight below, after gh is known
# to exist. Here we only accept an explicit CV_PR_AUTHOR from the environment.
CV_PR_AUTHOR="${CV_PR_AUTHOR:-}"

# Con-voyage machine-identity banner prefix — comments starting with this
# pattern are the bot's OWN posts (via cv-pr-comment.sh), not human feedback.
# Without this exclusion, PART B would treat every automated reply as new
# human feedback and re-route it forever (both are authored by the operator's
# PAT-backed login, so author alone can't tell them apart). Must stay in sync
# with the BANNER prefix cv-pr-comment.sh actually emits — see that script's
# own copy of this same literal string.
CV_AGENT_PREFIX_PATTERN='^🤖 \*\*Automated con-voyage agent\*\*'

# A malformed CV_LOCK_STALE_SECONDS override must never silently break the
# stale-lock steal check in acquire_lock (con-voyage-lib.sh) — a non-numeric
# value already fails safe there (the python age comparison never matches, so
# a stale lock is simply never stolen), but coercing to the documented default
# here keeps this script's posture identical to
# con-voyage-repair-watchdog.sh, which shares the same lock implementation.
case "$CV_LOCK_STALE_SECONDS" in
  *[!0-9]*|'') CV_LOCK_STALE_SECONDS="300" ;;
esac

# Same posture as CV_LOCK_STALE_SECONDS above: a malformed override must
# fail safe (fall back to the documented default) rather than break the
# mint-attempt cap comparison below.
case "$CV_MINT_MAX_ATTEMPTS" in
  *[!0-9]*|'') CV_MINT_MAX_ATTEMPTS="3" ;;
esac

# Same posture again: a malformed CV_SUPPRESSION_LOG_MAX_LINES override must
# fail safe (fall back to the documented default) rather than break the
# suppression-log trim comparison below.
case "$CV_SUPPRESSION_LOG_MAX_LINES" in
  *[!0-9]*|'') CV_SUPPRESSION_LOG_MAX_LINES="2000" ;;
esac

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-pr-watch: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi

if ! command -v "$GH" >/dev/null 2>&1; then
  echo "con-voyage-pr-watch: ERROR: gh CLI not found at '${GH}'. Install github.com/cli/cli." >&2
  exit 1
fi

# Verify gh is authenticated (prints an error and exits non-zero if not)
if ! "$GH" auth status >/dev/null 2>&1; then
  echo "con-voyage-pr-watch: ERROR: gh is not authenticated. Run 'gh auth login' or set GITHUB_TOKEN." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-pr-watch: ERROR: python3 not found; required for PR comment filtering." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the CV_PR_AUTHOR gh-login default (guarded against set -e).
#
# If CV_PR_AUTHOR was not provided explicitly, fall back to the authenticated
# gh login. This runs AFTER the gh existence/auth preflight, and the command
# substitution is guarded with `|| true` so a gh failure leaves CV_PR_AUTHOR
# empty and lets the fail-closed guard below report a clear error and exit —
# rather than `set -e` aborting the script silently on this line.
# ---------------------------------------------------------------------------
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  CV_PR_AUTHOR="$("$GH" api user --jq .login 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# FAIL-CLOSED author-scoping guard (see HARD INVARIANT in the header).
#
# If CV_PR_AUTHOR is empty/unresolved we MUST NOT proceed: an unscoped run
# would act on every open PR in every configured repo, including PRs authored
# by other people. Exit non-zero BEFORE any PART A / PART B work — before we
# query a single repo.
# ---------------------------------------------------------------------------
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  echo "con-voyage-pr-watch: FATAL: CV_PR_AUTHOR is empty/unresolved." >&2
  echo "con-voyage-pr-watch: author-scoping is mandatory — refusing to act on any PR." >&2
  echo "con-voyage-pr-watch: set CV_PR_AUTHOR explicitly (e.g. CV_PR_AUTHOR=kriscoleman)" >&2
  echo "con-voyage-pr-watch: or ensure 'gh api user --jq .login' resolves." >&2
  exit 1
fi
echo "con-voyage-pr-watch: author-scoped to PRs authored by '${CV_PR_AUTHOR}' (all other PRs are ignored)"

# Ensure state directory exists
mkdir -p "$CV_STATE_DIR"

# Shared per-PR state/dispatch helpers (state_read, state_write, now_iso8601,
# bead_status, implementor_alive, close_if_open, cv_default_state_dir) were
# sourced above, before CV_STATE_DIR's default was computed — see
# con-voyage-lib.sh for the authoritative field-by-field state-record doc
# comment. Shared with con-voyage-repair-watchdog.sh (fk-wgqp Fix 2), which
# reads and writes the SAME state records.

# process_pr_record — evaluate and, if needed, act on exactly one backfill
# result (clean or actionable) from PART A's current cycle. Reads the a_*
# fields the main loop just parsed as globals (a_owner, a_repo, a_num,
# a_title, a_branch, a_sha, a_route, a_failure_kind, a_actionable, a_full,
# a_dedup_key) and this PR's per-dedup_key state record. Called with that
# record's lock already held (fk-8b5fl: two concurrent pr-watch cycles could
# both read the same state record before either wrote back, and both mint a
# fallback repair bead for the same PR — acquire_lock/release_lock now live
# in con-voyage-lib.sh, lifted from the same fk-11yuv mechanism
# con-voyage-repair-watchdog.sh already used, so both scripts share ONE lock
# implementation instead of each keeping a copy). Every early-out below is a
# `return` (not `continue` — this now runs inside a function, not the loop
# body directly) so the caller's lock release always runs regardless of which
# path this takes.
process_pr_record() {
  # CLEAN (non-actionable) PR (Task 5, re-detection, req 4): refresh the
  # per-PR state record to last_handled_state=clean so a LATER re-conflict
  # is detected as a real change instead of being compared against stale
  # pre-clean bookkeeping forever. No bead/comment is ever created here —
  # this is local bookkeeping only, so it is not author-gated. Skip the
  # write once already recorded clean (avoids a `bd show`/write every
  # cycle for a long-stable clean PR).
  if [ "$a_actionable" != "1" ]; then
    state_read "$a_dedup_key"
    if [ "$ST_LAST_STATE" != "clean" ]; then
      clean_implementor="$ST_IMPLEMENTOR"
      if [ -n "${ST_INFLIGHT// /}" ]; then
        # Req 2 parity (finding #4, fk-4o74 Fix-1 round 1): adopt a
        # fallback bead's claimant as the implementor here too, same as
        # the main dispatch path below — otherwise a PR that goes clean
        # in the same window a pool worker claimed its fallback bead
        # drops that claimant's identity, costing one extra needless
        # fallback on a later re-conflict.
        IFS=$'\x1f' read -r _ clean_tracked_assignee <<< "$(bead_status "$ST_INFLIGHT" assignee)"
        if [ -z "${clean_implementor// /}" ] && [ -n "${clean_tracked_assignee// /}" ]; then
          clean_implementor="$clean_tracked_assignee"
        fi
        close_if_open "$ST_INFLIGHT" "superseded: ${a_full}#${a_num} is now clean" "${a_full}#${a_num} is now clean"
      fi
      # Clean means no in-flight rework, so the redispatch-context fields
      # (repair_route/repo_full/pr_number/branch) and the watchdog's own
      # attempt_count/escalated bookkeeping are irrelevant — reset them
      # rather than carrying stale values forward. pr_author is left
      # empty too: this branch never resolves it (no `gh pr view` call),
      # and it is meaningless without an in-flight rework to guard.
      state_write "$a_dedup_key" "$clean_implementor" "" "clean" "" "" "" "" "" "0" "0" ""
    fi
    # A PR going clean means any prior mint-failure streak for this
    # dedup_key is no longer relevant — clear the counter/escalation
    # markers so a LATER, unrelated failure starts a fresh cap budget
    # instead of inheriting an already-exhausted one and silently
    # SKIPping forever (mirrors the reset already done on a successful
    # mint below). Must NOT be gated on the clean-transition guard above:
    # a mint-failure streak never calls state_write, so last_handled_state
    # never moves off "clean" during the streak — on a PR's second (or
    # later) clean observation the guard above is false and this would
    # never run, leaving stale markers forever (fk-n4c1a review BLOCKING-1).
    rm -f "${CV_STATE_DIR}/${a_dedup_key}.mint-failures" "${CV_STATE_DIR}/${a_dedup_key}.mint-escalated"
    return
  fi

  # a_log_tag selects this record's own part-of-the-script label for every
  # log line below ("[PART A]" for the engine-backed loop, "[PART A-native]"
  # for the base-agnostic discovery loop) — both call sites set it explicitly
  # immediately before calling this function (fk-travno review BLOCKING-2:
  # every log line here previously hardcoded the literal "[PART A]" tag, so a
  # native-discovered PR's own KEEP/DROP/SKIP/WARNING lines misreported
  # themselves as coming from the engine-backed path).
  a_log_tag="${a_log_tag:-[PART A]}"

  if [ -z "$a_failure_kind" ]; then
    echo "con-voyage-pr-watch: ${a_log_tag} WARNING: ${a_full}#${a_num} is actionable but its state/failed_checks did not classify into a known failure_kind (checks_failed|merge_conflict|behind_base|blocked); skipping rather than minting an undifferentiated bead" >&2
    return
  fi

  # Resolve the PR author AND the review/mergeability signals needed for
  # the ACTIONABLE FILTER (C6) below, in ONE gh call. The report JSON has
  # none of these fields, so we always ask gh directly — UNLESS the caller
  # already fetched this exact field set (fk-travno review BLOCKING-1): PART
  # A-native classifies failure_kind from its own `gh pr view` before ever
  # calling this function, so a second, identical call here just to re-derive
  # the author would double the gh calls for every native-discovered PR.
  if [ -n "${a_pr_view_json:-}" ]; then
    pr_view_json="$a_pr_view_json"
  else
    pr_view_json=$("$GH" pr view "$a_num" --repo "$a_full" \
      --json author,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null || echo "")
  fi

  # shellcheck disable=SC2016
  _PY_REVIEW_GATE='
import sys, json

SEP = "\x1f"
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}

author = (d.get("author") or {}).get("login", "") or ""
review_decision = d.get("reviewDecision", "") or ""
mergeable = d.get("mergeable", "") or ""
merge_state_status = d.get("mergeStateStatus", "") or ""
checks = d.get("statusCheckRollup") or []

def is_green(c):
    conclusion = c.get("conclusion")
    if conclusion is not None:
        return str(conclusion).upper() in ("SUCCESS", "NEUTRAL", "SKIPPED")
    state = c.get("state")
    if state is not None:
        return str(state).upper() == "SUCCESS"
    return False

checks_green = all(is_green(c) for c in checks)

skip_awaiting_human = (
    review_decision == "REVIEW_REQUIRED"
    and mergeable == "MERGEABLE"
    and merge_state_status != "BEHIND"
    and checks_green
)

print(author + SEP + ("1" if skip_awaiting_human else "0"))
'
  pr_view_fields=$(printf '%s' "$pr_view_json" | python3 -c "$_PY_REVIEW_GATE" 2>/dev/null || printf '\x1f0')
  IFS=$'\x1f' read -r pr_author skip_awaiting_human <<< "$pr_view_fields"

  # AUTHOR FILTER — the airtight gate. Anything that is not exactly
  # CV_PR_AUTHOR (including an unresolved/empty author) is dropped.
  if [ "$pr_author" != "$CV_PR_AUTHOR" ]; then
    echo "con-voyage-pr-watch: ${a_log_tag} DROP ${a_full}#${a_num} (author='${pr_author:-<unresolved>}' != '${CV_PR_AUTHOR}') — no repair bead created"
    return
  fi

  # ACTIONABLE FILTER (C6): con-voyage PRs never auto-merge, so once every
  # real defect is resolved (CI green, mergeable, branch up to date) a PR
  # ends in reviewDecision=REVIEW_REQUIRED forever — that is a human-review
  # wait state, not something a machine can fix (live incident: #10494, 48
  # green checks + MERGEABLE, blocked solely on REVIEW_REQUIRED). Gate on
  # failure_kind == "blocked" only: checks_failed/merge_conflict/
  # behind_base already mean a real defect exists and must still be
  # repaired regardless of review state (review state alone must never
  # suppress a real defect).
  if [ "$a_failure_kind" = "blocked" ] && [ "$skip_awaiting_human" = "1" ]; then
    echo "con-voyage-pr-watch: ${a_log_tag} SKIP ${a_full}#${a_num} — awaiting human review only (CI green, MERGEABLE, branch up to date, reviewDecision=REVIEW_REQUIRED); not a repair"
    return
  fi

  # Survivor: author matches and there is a real defect to repair. Create
  # ONE deduped repair bead. The title is
  # state-aware (names the classified failure_kind) so the bead is
  # self-describing without opening it (R5.5).
  repair_title="Repair GitHub PR ${a_full}#${a_num} (${a_failure_kind}): ${a_title}"
  dedup_key="$a_dedup_key"

  if [ -z "$a_route" ]; then
    echo "con-voyage-pr-watch: ${a_log_tag} WARNING: ${a_full}#${a_num} has no repair_route in backfill result; cannot create bead safely; skipping" >&2
    return
  fi

  # Load this PR's per-PR repair state (Task 1/2, fk-4o74 Fix 1):
  # implementor_session (the worker mail send --notify should reach directly),
  # inflight_rework (a tracked bead id, when the last dispatch used the
  # pool fallback), last_handled_state (the failure_kind — or "clean" —
  # this monitor last reacted to for this PR).
  state_read "$dedup_key"
  st_implementor="$ST_IMPLEMENTOR"
  st_inflight="$ST_INFLIGHT"
  st_last_state="$ST_LAST_STATE"

  tracked_status=""
  tracked_assignee=""
  if [ -n "${st_inflight// /}" ]; then
    IFS=$'\x1f' read -r tracked_status tracked_assignee <<< "$(bead_status "$st_inflight" assignee)"
  fi

  # Req 2 ("the new worker becomes the implementor"): once a fallback-slung
  # bead's claimant becomes known (gc sets `assignee` once a pool worker
  # claims it — confirmed live, see Task 0 findings), adopt it as this
  # PR's implementor so future cycles reuse it instead of falling back
  # again.
  if [ -z "${st_implementor// /}" ] && [ -n "${tracked_assignee// /}" ]; then
    st_implementor="$tracked_assignee"
  fi

  # DE-DUPLICATION + RE-DETECTION (Task 4/5, fk-4o74 Fix 1; PR-NUMBER-ONLY
  # keying, FIX-C fk-zyh5): a repair is genuinely in-flight while the
  # tracked bead (if any) is still open — status alone gates it, NOT
  # assignee and NOT failure_kind. A pool-slung bead sits with an EMPTY
  # assignee for an unbounded time before a worker claims it (confirmed
  # live: vandoor #10494 — see the design doc and Task 0 findings), so
  # requiring a live assignee here is exactly the bug that made the
  # monitor re-mint every cycle.
  #
  # A failure_kind CHANGE while the tracked bead is still open no longer
  # supersedes+re-mints — that behavior implicitly keyed the in-flight
  # check on (PR-number, failure_kind), and turned kots#6067's
  # blocked<->checks_failed oscillation (a ~10min classifier cooldown)
  # into one new orphaned bead per flip. The SAME bead is now updated in
  # place (title + failure_kind metadata) so it reflects the current
  # classification without spawning a second implementor for one PR.
  # Mint fresh ONLY when no open repair bead is tracked for this PR.
  tracked_open=0
  if [ -n "${st_inflight// /}" ] && [ -n "$tracked_status" ] && [ "$tracked_status" != "closed" ]; then
    tracked_open=1
  fi

  # PENDING-ATTACH SELF-HEAL (fk-6belo): a bare repair bead whose `bd create`
  # succeeded but whose `gc sling --on con-voyage-ci-repair` attach never ran
  # (this script's own process killed mid-flight between the two calls — the
  # live trigger was the order's exec timeout under dolt store contention,
  # see con-voyage-pr-watch.toml's new `timeout` override) is recorded in a
  # SEPARATE side-channel marker file (never the main per-PR .state record —
  # that file is shared with con-voyage-repair-watchdog.sh, which treats
  # last_handled_state as a real failure_kind and would feed a garbage value
  # straight into the ci-repair formula if it ever saw a sentinel there) the
  # moment bd create succeeds, BEFORE the sling is attempted (see below), so a
  # kill at any point after that still leaves a trail. Such a bead passes the
  # tracked_open check above (it's open), but treating it as a steady-state
  # tracked repair would be wrong: the tracked_open branch below only
  # refreshes title/metadata on an ALREADY-attached bead, which does nothing
  # for one that was never attached in the first place, leaving it bare
  # forever (the live incident: vandoor#10585's va-fft3 sat bare 15+ min
  # until a human hand-slung it). Override tracked_open so this falls
  # through to the dispatch branch below, and remember the bare bead id so
  # that branch retries the SAME bead instead of minting a fresh one (which
  # would orphan the first bare bead permanently and could runaway-mint one
  # more per cycle under sustained contention — the exact fk-zvkmd failure
  # mode this pairs with).
  reattach_bead_id=""
  pending_attach_file="${CV_STATE_DIR}/${dedup_key}.pending-attach"
  if [ -f "$pending_attach_file" ]; then
    pending_bead_id="$(cat "$pending_attach_file" 2>/dev/null || true)"
    pending_status=""
    if [ -n "${pending_bead_id// /}" ]; then
      IFS=$'\x1f' read -r pending_status _ <<< "$(bead_status "$pending_bead_id" assignee)"
    fi
    if [ -n "${pending_bead_id// /}" ] && [ -n "$pending_status" ] && [ "$pending_status" != "closed" ]; then
      tracked_open=0
      reattach_bead_id="$pending_bead_id"
    else
      # The bare bead is gone/closed already (handled out of band, or a
      # previous run's rollback raced this marker write) — stale marker,
      # drop it so it never wedges a future cycle on a dead id.
      rm -f "$pending_attach_file"
    fi
  fi

  if [ "$tracked_open" -eq 1 ]; then
    new_last_state="$st_last_state"
    if [ "$st_last_state" = "$a_failure_kind" ]; then
      echo "con-voyage-pr-watch: ${a_log_tag} SKIP ${a_full}#${a_num} @ ${a_sha} — repair genuinely in-flight (dedup: ${dedup_key}, last_handled_state=${st_last_state})"
    # $st_inflight is an EXISTING, already-rig-prefixed repair bead
    # (minted below with --rig "$a_rig"), not a fresh id — the same
    # fk-7v3r bug class con-voyage-lib.sh's helpers hit: `--city` alone
    # (no `--rig`) routes an already-rig-prefixed id to the CITY store
    # instead of its owning rig's, so `bd update` silently "Issue not
    # found"s every cycle (fk-mr07). Rely on cwd auto-detection instead,
    # matching every other already-fixed bd call in this pack.
    elif "$GC" bd update "$st_inflight" \
      --title "$repair_title" \
      --set-metadata "failure_kind=${a_failure_kind}" \
      2>&1; then
      echo "con-voyage-pr-watch: ${a_log_tag} UPDATE ${a_full}#${a_num} @ ${a_sha} — repair still in-flight on ${st_inflight} (dedup: ${dedup_key}); failure_kind ${st_last_state} -> ${a_failure_kind}"
      new_last_state="$a_failure_kind"
    else
      echo "con-voyage-pr-watch: ${a_log_tag} WARNING: failed to update ${st_inflight} with the new failure_kind for ${a_full}#${a_num}; will retry next cycle" >&2
    fi
    # Persist the write-back (if any) even on a skip/update cycle, so a
    # known implementor is not silently lost/re-derived every cycle. The
    # tracked bead/implementor never change here — last_handled_state only
    # advances once the update actually lands (a failed update is retried
    # next cycle, mirroring the mint-failure discipline elsewhere in this
    # loop). The extended fields (pr_author/repair_route/repo_full/
    # pr_number/branch) and the watchdog's own attempt_count/escalated
    # bookkeeping are carried forward unchanged from the state_read above
    # — never reset here.
    state_write "$dedup_key" "$st_implementor" "$st_inflight" "$new_last_state" \
      "$ST_PR_AUTHOR" "$ST_REPAIR_ROUTE" "$ST_REPO_FULL" "$ST_PR_NUMBER" "$ST_BRANCH" \
      "$ST_ATTEMPT_COUNT" "$ST_ESCALATED" "$ST_LAST_DISPATCH_AT"
    return
  fi

  # Not in-flight (no tracked bead, or it is closed): sweep any leftover
  # markers from the old per-head-sha scheme for this same PR (glob is
  # dash-delimited so e.g. PR 1's marker never matches PR 11's), so
  # orphans never pile up across the dedup-scheme upgrade from the old
  # per-head-sha keying.
  for stale_marker in "${CV_STATE_DIR}/${dedup_key}"-*.minted; do
    [ -f "$stale_marker" ] || continue
    stale_bead_id="$(cat "$stale_marker" 2>/dev/null || true)"
    close_if_open "$stale_bead_id" "superseded: re-armed by a fresh PR-scoped repair mint for ${a_full}#${a_num}" "SUPERSEDE ${a_full}#${a_num}"
    rm -f "$stale_marker"
  done

  echo "con-voyage-pr-watch: ${a_log_tag} KEEP ${a_full}#${a_num} (author='${pr_author}') — dispatching repair (dedup: ${dedup_key})"

  # DISPATCH (Task 3, fk-4o74 Fix 1): every open con-voyage PR has exactly
  # one live implementor responsible for it. Reuse it — mail + notify,
  # the same durable-plus-wake path con-voyage already uses for review/CI
  # feedback — while it is alive; NO new pool workflow in that case. Only
  # when it is gone (or never known) do we fall back to spawning a fresh
  # implementor via the pool con-voyage-ci-repair formula, which then
  # becomes the PR's implementor once it claims the bead (see the
  # write-back above).
  dispatched=0
  new_inflight=""
  new_implementor="$st_implementor"
  if [ -n "${st_implementor// /}" ] && implementor_alive "$st_implementor"; then
    if "$GC" --city "$GC_CITY" mail send "$st_implementor" \
      -s "Repair needed: ${a_full}#${a_num} (${a_failure_kind})" \
      -m "PR ${a_full}#${a_num} (branch ${a_branch}) needs rework: ${a_failure_kind}. cv_pr_author=${CV_PR_AUTHOR} cv_author_gate=${CV_AUTHOR_GATE} cv_conflict_strategy=${CV_CONFLICT_STRATEGY}. ${a_title}" \
      --notify 2>&1; then
      dispatched=1
      echo "con-voyage-pr-watch: ${a_log_tag} ${a_full}#${a_num}: routed rework to existing implementor ${st_implementor} (mail+notify, no new pool worker)"
    else
      echo "con-voyage-pr-watch: ${a_log_tag} WARNING: mail to implementor ${st_implementor} failed for ${a_full}#${a_num}; will retry next cycle" >&2
    fi
  else
    # MINT-ATTEMPT CAP (fk-zvkmd): a fallback mint that keeps failing (bd
    # create failing, or the ci-repair sling being rejected every cycle —
    # e.g. a broken formula/route) must never be retried unboundedly. State
    # is deliberately never written on a failed dispatch (see the comment
    # above the final `state_write` in this function), so without a
    # dedicated counter every retry looks identical to the FIRST attempt and
    # pre-creates a FRESH bare repair bead each cycle — in production this
    # produced ~61 orphaned, description-less repair beads over ~12h, one
    # per ~11-minute cycle, because a persistently failing sling left every
    # pre-created bead behind and was retried from scratch next cycle. Track
    # consecutive failures per-PR in a lightweight counter file (separate
    # from the per-PR state record above, so it does not interact with that
    # record's own in-flight/skip/reset semantics), and once
    # CV_MINT_MAX_ATTEMPTS is reached, stop minting entirely and notify a
    # human exactly once instead of continuing to mint.
    mint_fail_file="${CV_STATE_DIR}/${dedup_key}.mint-failures"
    mint_escalated_file="${CV_STATE_DIR}/${dedup_key}.mint-escalated"
    mint_fail_count=0
    if [ -f "$mint_fail_file" ]; then
      mint_fail_count="$(cat "$mint_fail_file" 2>/dev/null || echo 0)"
      case "$mint_fail_count" in *[!0-9]*|'') mint_fail_count=0 ;; esac
    fi

    if [ "$mint_fail_count" -ge "$CV_MINT_MAX_ATTEMPTS" ]; then
      if [ -f "$mint_escalated_file" ]; then
        # Idempotent short-circuit: already escalated for this exact streak
        # of failures. The marker file IS the "still decided not to
        # dispatch" state this guard persists — checking it (rather than
        # re-sending mail) is what makes the short-circuit safe to
        # re-evaluate every cycle without side effects.
        echo "con-voyage-pr-watch: ${a_log_tag} SKIP ${a_full}#${a_num} — mint already escalated after ${mint_fail_count} failed attempt(s); not re-minting (dedup: ${dedup_key})"
      else
        echo "con-voyage-pr-watch: ${a_log_tag} ESCALATE ${a_full}#${a_num} — ${mint_fail_count} failed mint/sling attempt(s), notifying ${CV_ESCALATE_TARGET} and stopping automatic re-mint"
        if "$GC" --city "$GC_CITY" mail send "$CV_ESCALATE_TARGET" \
          -s "con-voyage pr-watch: giving up on minting a repair for ${a_full}#${a_num}" \
          -m "Repair-bead mint/sling for ${a_full}#${a_num} (branch ${a_branch}, ${a_failure_kind}) has failed ${mint_fail_count} consecutive attempt(s). This monitor is stopping automatic re-mint for this PR — please take a look." \
          2>&1; then
          : > "$mint_escalated_file"
        else
          echo "con-voyage-pr-watch: ${a_log_tag} WARNING: escalation mail to ${CV_ESCALATE_TARGET} failed for ${a_full}#${a_num}; will retry next cycle" >&2
        fi
      fi
      return
    fi

    # CROSS-RIG MINT GUARD (fk-4o74 Fix-1 round 1, finding #1): derive the
    # target rig from the repair_route (the part BEFORE the first "/",
    # e.g. "vandoor" from "vandoor/gc.implementation-worker") HERE,
    # immediately before the fallback bd create — not up front. Only this
    # fallback path mints a bead, and it MUST land in that rig so its
    # prefix matches the sling target; otherwise gc rejects the sling
    # with a "cross-rig routing" error (see PART A header). The
    # reuse-dispatch path above (mail+notify to a live implementor) never
    # mints a bead, so it never needed a rig — gating the whole PR on
    # rig-derivation before even trying that path dropped mail delivery
    # to a live implementor whenever repair_route happened to have no
    # "<rig>/" prefix. A route with NO "/" gives us no rig to derive, so
    # — mirroring the empty-a_route guard above — we skip the fallback
    # mint with a WARNING rather than mis-home a bead in the city store
    # that could never route.
    repair_bead_id=""
    if [ -n "$reattach_bead_id" ]; then
      # SELF-HEAL RE-ATTACH (fk-6belo): reuse the already-minted bare bead
      # instead of creating a new one — see the PENDING-ATTACH SELF-HEAL
      # comment above. No --rig derivation or bd create needed; the bead
      # already exists in the right rig (it was minted there last cycle).
      repair_bead_id="$reattach_bead_id"
      echo "con-voyage-pr-watch: ${a_log_tag} ${a_full}#${a_num}: re-attempting ci-repair attach on previously-bare bead ${repair_bead_id} (self-heal, dedup: ${dedup_key})"
    else
      a_rig="${a_route%%/*}"
      if [ "$a_rig" = "$a_route" ] || [ -z "$a_rig" ]; then
        echo "con-voyage-pr-watch: ${a_log_tag} WARNING: ${a_full}#${a_num} repair_route '${a_route}' has no '<rig>/' prefix; cannot derive a target rig; skipping fallback dispatch (would mis-home the repair bead and fail cross-rig routing)" >&2
      else
        # v2-formula mint (gc 1.4.1): con-voyage-ci-repair is a v2 workflow formula
        # that references {{convoy_id}} (the repair bead id). Such a formula CANNOT
        # be inline-created via `gc sling --on <formula> --title <text>` — gc rejects
        # that with "inline text requires explicit target", because {{convoy_id}}
        # has no bead to resolve against. The required form is:
        #   gc sling <target> <BEAD> --on <formula> --var ...
        # where <BEAD> is a PRE-CREATED bead. So we create the repair bead first,
        # capture its id, then attach the formula to it and route it. {{convoy_id}}
        # then resolves to that bead id inside the ci-repair prompt.
        #
        # --rig "$a_rig" is MANDATORY (see CROSS-RIG MINT GUARD above): it mints the
        # bead in the target agent's rig so its prefix matches the sling target. With
        # NO --rig the bead lands in the CITY store (prefix "rc") and the subsequent
        # sling to a rig agent fails the cross-rig gate — the runtime bug this fixes.
        # (--rig is a TOP-LEVEL gc flag; it must precede the `bd` subcommand.)
        repair_bead_id=$("$GC" --city "$GC_CITY" --rig "$a_rig" bd create "$repair_title" \
          --priority 1 \
          --silent 2>/dev/null || true)

        if [ -z "${repair_bead_id// /}" ]; then
          echo "con-voyage-pr-watch: ${a_log_tag} WARNING: failed to create repair bead for ${a_full}#${a_num}; will retry next cycle" >&2
          mint_fail_count=$((mint_fail_count + 1))
          printf '%s\n' "$mint_fail_count" > "$mint_fail_file"
        else
          # PENDING-ATTACH MARKER (fk-6belo): record the bare bead BEFORE
          # attempting the sling that attaches its real content, in the
          # SIDE-CHANNEL marker file (not the main per-PR .state record —
          # see the PENDING-ATTACH SELF-HEAL comment above for why). If this
          # process is killed between here and the sling's exit status (the
          # live trigger: the order's exec timeout under dolt store
          # contention — see con-voyage-pr-watch.toml), the next cycle's
          # PENDING-ATTACH SELF-HEAL check above finds this marker and
          # retries the attach on this SAME bead instead of minting a
          # fresh one and leaving this one bare forever.
          printf '%s\n' "$repair_bead_id" > "$pending_attach_file"
        fi
      fi
    fi

    if [ -n "${repair_bead_id// /}" ]; then
      if "$GC" --city "$GC_CITY" sling "$a_route" "$repair_bead_id" \
        --on con-voyage-ci-repair \
        --var "title=${a_title}" \
        --var "pr=${a_num}" \
        --var "repo=${a_full}" \
        --var "branch=${a_branch}" \
        --var "failure_kind=${a_failure_kind}" \
        --var "cv_pr_author=${CV_PR_AUTHOR}" \
        --var "cv_author_gate=${CV_AUTHOR_GATE}" \
        --var "cv_conflict_strategy=${CV_CONFLICT_STRATEGY}" \
        --var "repair_bead=${repair_bead_id}" \
        2>&1; then
        dispatched=1
        new_inflight="$repair_bead_id"
        new_implementor=""
        echo "con-voyage-pr-watch: ${a_log_tag} ${a_full}#${a_num}: repair bead ${repair_bead_id} created/attached and routed to ${a_route} (fallback — no live implementor)"
        # A successful mint clears any prior failure streak — the next
        # failure (if this bead's own dispatch later stalls) starts a fresh
        # cap budget rather than inheriting an unrelated earlier streak.
        rm -f "$mint_fail_file" "$mint_escalated_file"
        # The bead is now genuinely attached — the pending-attach marker (if
        # any; present on a self-heal re-attach, absent on a one-shot success)
        # no longer applies.
        rm -f "$pending_attach_file"
      else
        echo "con-voyage-pr-watch: ${a_log_tag} WARNING: repair-bead sling failed for ${a_full}#${a_num} (bead ${repair_bead_id}); will retry next cycle" >&2
        mint_fail_count=$((mint_fail_count + 1))
        printf '%s\n' "$mint_fail_count" > "$mint_fail_file"
        # ROLLBACK (fk-zvkmd, FIX EXPECTATION 3): the bead WAS pre-created,
        # but the sling that attaches its real description/metadata/assignee
        # just failed — it exists as a permanent bare, content-less task
        # bead unless we close it now. Never leave a repair bead half-formed:
        # either its content lands atomically (the sling succeeds) or the
        # bead is rolled back.
        # $repair_bead_id is already rig-prefixed (minted above with
        # --rig "$a_rig") — the same fk-mr07/fk-7v3r bug class: `--city`
        # alone (no `--rig`) routes an already-rig-prefixed id to the CITY
        # store instead of its owning rig's, so `bd close` silently "Issue
        # not found"s. Rely on cwd auto-detection instead, matching every
        # other already-fixed bd call in this pack (see :442-451).
        "$GC" bd close "$repair_bead_id" \
          --reason "rollback: sling to ${a_route} failed for ${a_full}#${a_num}, bead never received its real content" \
          2>&1 || echo "con-voyage-pr-watch: ${a_log_tag} WARNING: rollback close of orphaned bead ${repair_bead_id} failed for ${a_full}#${a_num}; it may be left bare" >&2
        # Clear the pending-attach marker (if any — written after bd create
        # on a fresh mint, or pre-existing on a self-heal retry) now that the
        # bead it pointed at is rolled back: a future cycle should see a
        # clean slate and retry fresh, not keep pointing at a dead bead id.
        rm -f "$pending_attach_file"
        # Non-fatal: continue to next PR / Part B.
      fi
    fi
  fi

  # Record the state ONLY after a successful dispatch, so a failed
  # mail/sling is retried next cycle rather than being silently suppressed.
  # This is a FRESH problem cycle (a state change or a superseded prior
  # attempt), so the watchdog's own bookkeeping resets: attempt_count=0,
  # escalated=0. pr_author/a_route/a_full/a_num/a_branch are all resolved
  # in THIS iteration (the only place this script has them), so this is
  # also the only call site that ever populates the redispatch-context
  # fields with real values. last_dispatch_at is stamped fresh here too
  # (fk-lfan B1): for the mail-only reuse path (new_inflight empty), this
  # is the ONLY staleness signal con-voyage-repair-watchdog.sh has — there
  # is no tracked bead whose updated_at it can key on instead.
  if [ "$dispatched" -eq 1 ]; then
    state_write "$dedup_key" "$new_implementor" "$new_inflight" "$a_failure_kind" \
      "$pr_author" "$a_route" "$a_full" "$a_num" "$a_branch" "0" "0" "$(now_iso8601)"
  fi
}

# ---------------------------------------------------------------------------
# PART A: CI-failure repair (author-scoped)
# ---------------------------------------------------------------------------
#
# AUTHOR-SCOPED FLOW (see HARD INVARIANT in the header):
#
#   1. Run `gc github pr backfill --json` REPORT-ONLY (NO --create-repair-beads).
#      This evaluates all [[github.pr_monitor]] blocks and reports every
#      actionable PR (failed checks, DIRTY, BEHIND, BLOCKED) as JSON — but
#      creates NO beads.
#   2. For each actionable result, resolve the PR's author login AND its
#      review/mergeability signals (via ONE `gh pr view`) and DROP the PR
#      unless its author == CV_PR_AUTHOR. Then SKIP it (no bead, no comment)
#      if it is only awaiting human review — see the ACTIONABLE FILTER (C6)
#      comment below.
#   3. For each remaining PR, create ONE deduped repair bead and attach the
#      `con-voyage-ci-repair` v2-formula to it, then route it to the monitor's
#      repair_route. Because that formula references {{convoy_id}}, gc 1.4.1
#      requires a PRE-CREATED bead as the sling positional:
#        gc --rig <rig> bd create "<title>"   # -> repair_bead_id (in <rig>'s store)
#        gc sling <repair_route> <repair_bead_id> --on con-voyage-ci-repair --var ...
#      where <rig> is parsed from repair_route (the part BEFORE the first "/").
#
#      {{convoy_id}} is NOT reliably the same id as repair_bead_id (fk-7mw7): it
#      is a gc-internal v2 work-item id for the ci-repair STEP, which can differ
#      from the human-facing bead minted above. So this call also forwards
#      `--var repair_bead=${repair_bead_id}` — the ci-repair workflow closes
#      THAT known id on every terminal exit instead of inferring one from
#      {{convoy_id}}, which was the #1 driver of orphaned repair beads.
#
#      CROSS-RIG ROUTING (why --rig is mandatory): gc refuses to route a bead to
#      an agent in a DIFFERENT rig ("cross-rig routing — bead <id> (prefix ...)
#      → agent <rig>/<agent> (rig prefix ...)"), exiting non-zero so nothing is
#      routed. A repair_route like "vandoor/gc.implementation-worker" targets the
#      "vandoor" rig, so the bead MUST be minted in that rig (prefix "va") for the
#      sling to be same-rig. `gc bd create` with NO --rig mints in the CITY store
#      (prefix "rc"), which then FAILS the cross-rig gate at sling time. So we
#      pass --rig "${a_route%%/*}" to mint the bead in the target agent's rig.
#      (Neither `gc sling --dry-run` nor a hermetic stub caught this — it only
#      surfaced against REAL gc — so the test below emulates the cross-rig gate.)
#      matching the native title shape (the title also names the classified
#      failure_kind — see R5.5):
#        title: "Repair GitHub PR <owner>/<repo>#<n> (<failure_kind>): <title>"
#        dedup: repo + PR number ONLY (not head-sha) — a per-PR marker file
#               under CV_STATE_DIR tracks at most one repair bead per PR. A new
#               head-sha does NOT by itself block a fresh mint (a head-sha-keyed
#               dedup let a stale marker or a reset-to-an-old-head block needed
#               re-mints and let orphaned beads pile up). The tracked bead
#               blocks a re-mint ONLY while it is genuinely in-flight (open —
#               status only, NOT assignee; keyed on last_handled_state);
#               otherwise it is superseded (closed) and a fresh bead is
#               minted, so a new head always re-arms the mint.
#
# We deliberately AVOID `--create-repair-beads` because that native path has no
# author filter and would create a bead for every actionable PR. The report +
# per-PR author check + our own bead creation is the ONLY way to guarantee the
# invariant: ZERO repair beads for PRs not authored by CV_PR_AUTHOR.
#
# ZERO-BEAD-FOR-OTHERS GUARANTEE: bead creation happens strictly inside the
# `author == CV_PR_AUTHOR` branch below. Any PR whose author cannot be resolved
# (empty login, gh error) is treated as "not ours" and skipped — fail closed.
# It is always better to create NO bead than to create one for someone else.

echo "con-voyage-pr-watch: [PART A] report-only backfill (gc github pr backfill --json), author-filtering to '${CV_PR_AUTHOR}'"

backfill_json=$("$GC" --city "$GC_CITY" github pr backfill --json 2>/dev/null) || {
  echo "con-voyage-pr-watch: [PART A] WARNING: report-only backfill returned non-zero; skipping repair-bead creation this cycle" >&2
  backfill_json=""
}

if [ -n "$backfill_json" ]; then
  # Emit EVERY result (actionable AND clean) as one JSON object per line for
  # the shell loop. Clean (non-actionable) rows are still needed here — Task 5
  # (fk-4o74 Fix 1, re-detection) refreshes their per-PR state record to
  # last_handled_state=clean so a LATER re-conflict compares against the real
  # last-observed state instead of stale pre-clean bookkeeping forever. (No
  # bead/comment is ever created for a clean PR — see the actionable branch
  # below — so this bookkeeping carries no author-scoping risk.)
  # (report-only JSON never contains a per-PR author field, so we resolve the
  # author separately below via gh — see ZERO-BEAD-FOR-OTHERS guarantee.)
  all_prs=$(printf '%s' "$backfill_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in data.get('results', []):
    print(json.dumps(r))
" 2>/dev/null || true)

  if [ -z "$all_prs" ]; then
    echo "con-voyage-pr-watch: [PART A] no PRs reported; nothing to do"
  else
    while IFS= read -r result_json; do
      [ -n "$result_json" ] || continue

      # Extract per-PR fields AND classify the canonical failure_kind in one
      # python invocation (tab-separated output; classification stays in
      # python so the shell doesn't need list-emptiness/state-precedence
      # logic).
      #
      # REAL-SAMPLE FINDING (verify-gate, cv-b-fk-08o-design.md §1c decision
      # 6): a live `gc github pr backfill --json` against this city's own
      # configured monitors shows gc ALREADY computes and emits a
      # `failure_kind` field on each result, using exactly this vocabulary
      # (checks_failed/merge_conflict/blocked confirmed live; behind_base not
      # observed live because no monitored PR was in that state at
      # sample-time, but it is the same gc mechanism). It also shows `state`
      # values that do NOT match the design doc's `strings`-recovered guess:
      # real values seen were "conflicted" (not "dirty") and "failed" (not in
      # the original guessed set at all) alongside the expected "blocked".
      # So: TRUST gc's own failure_kind field when present, EXCEPT that a
      # non-empty failed_checks[] always overrides a gc-reported "blocked"
      # (see fk-6belo precedence note on the classifier below — a live
      # failing-required-check PR was misclassified "blocked" this way and
      # left unrepaired). Fall back to deriving one from state/failed_checks
      # (first-match order below) only when gc omits failure_kind entirely
      # (e.g. an older gc version).
      # shellcheck disable=SC2016
      _PY_CLASSIFY_PR='
import sys, json

d = json.load(sys.stdin)
owner  = d.get("owner", "") or ""
repo   = d.get("repo", "") or ""
number = d.get("number", "")
title  = d.get("title", "") or ""
branch = d.get("head_ref_name", "") or ""
sha    = d.get("head_sha", "") or ""
route  = d.get("repair_route", "") or ""
state  = d.get("state", "") or ""
failed_checks = d.get("failed_checks") or []
gc_failure_kind = d.get("failure_kind", "") or ""

VALID_KINDS = {"checks_failed", "merge_conflict", "behind_base", "blocked"}

# PRECEDENCE (fk-6belo): a non-empty failed_checks[] ALWAYS wins, even over
# a gc-reported failure_kind="blocked" -- a real check failure is CI-repair
# work regardless of mergeStateStatus. Live incident: vandoor#10585 had 2
# FAILING required checks (depot integration-test + gate) but the gc field
# said "blocked" (mergeStateStatus=BLOCKED dominates there), so this monitor
# misclassified a checks_failed PR as a review-escalation ("blocked"), which
# then risked tripping the C6 "awaiting human review" skip below on a PR
# that was actually failing CI. The gc-reported failure_kind is still
# trusted ahead of the local state/failed_checks fallback for every OTHER
# case (it carries richer signal than these two fields alone) -- only
# "blocked" is downgraded, and only when failed_checks proves it wrong.
if failed_checks:
    failure_kind = "checks_failed"
elif gc_failure_kind in VALID_KINDS:
    failure_kind = gc_failure_kind
elif state == "failed":
    failure_kind = "checks_failed"
elif state in ("dirty", "conflicted"):
    failure_kind = "merge_conflict"
elif state == "behind":
    failure_kind = "behind_base"
elif state == "blocked":
    failure_kind = "blocked"
else:
    failure_kind = ""

# Field delimiter: the ASCII Unit Separator (0x1f), NOT a tab. Tab is
# "IFS whitespace" in bash, so a tab-delimited read COLLAPSES consecutive
# tabs and strips leading/trailing runs. The schema marks title/head_sha/
# repair_route as OPTIONAL -- when any of them is empty, tab-collapse shifts
# every later field left by one, silently landing failure_kind (the last
# field) empty and tripping the empty-failure_kind guard below, which then
# drops a PR that needs repair. 0x1f is never treated as whitespace, so bash
# preserves empty fields exactly regardless of position.
actionable = "1" if d.get("actionable") else "0"
fields = [owner, repo, number, title, branch, sha, route, failure_kind, actionable]
print("\x1f".join(str(f).replace("\x1f", " ").replace("\n", " ") for f in fields))
'
      pr_fields=$(printf '%s' "$result_json" | python3 -c "$_PY_CLASSIFY_PR" 2>/dev/null || echo "")
      IFS=$'\x1f' read -r a_owner a_repo a_num a_title a_branch a_sha a_route a_failure_kind a_actionable <<<"$pr_fields"

      if [ -z "$a_owner" ] || [ -z "$a_repo" ] || [ -z "$a_num" ]; then
        echo "con-voyage-pr-watch: [PART A] skipping malformed backfill result: ${result_json}" >&2
        continue
      fi
      a_full="${a_owner}/${a_repo}"
      a_dedup_key="cv-ci-repair-${a_owner}-${a_repo}-${a_num}"

      if ! acquire_lock "$a_dedup_key"; then
        echo "con-voyage-pr-watch: [PART A] SKIP ${a_full}#${a_num} — locked by a concurrent pr-watch run (dedup: ${a_dedup_key})"
        continue
      fi

      a_log_tag="[PART A]"
      a_pr_view_json=""
      process_pr_record

      release_lock "$a_dedup_key"
    done <<< "$all_prs"
  fi
fi

# ---------------------------------------------------------------------------
# PART A (native): base-agnostic discovery for unlisted-base con-voyage PRs
# ---------------------------------------------------------------------------
#
# fk-dnjlg2 — the engine's own `gc github pr backfill` (PART A above) only
# ever evaluates a PR whose base branch is an EXACT, case-insensitive literal
# in that monitor's configured `base_branches` (gascity's own
# `normalizedBranchSet`/`EvaluatePullRequests` has no glob support). A
# stacked con-voyage PR (base `con-voyage/<bead-id>`, not `main`) is
# therefore invisible to the engine path unless an operator hand-edits
# `base_branches` per stacked slice — exactly the friction fk-qppb4 named and
# shipped without fixing.
#
# This section mirrors PART B's already-proven, fully dynamic model (list
# this author's own open PRs directly via `gh pr list`, no base-branch
# filter) instead of widening the engine's own config schema. For each
# monitor's repo, list every OPEN PR authored by CV_PR_AUTHOR, skip any whose
# base IS already one of that monitor's configured `base_branches` (the
# engine path above already owns those — this is what makes spec 2/3's
# "no double mint" hold), classify the survivors' failure_kind from raw
# GitHub signals via cv_classify_pr_signals, and feed each one through the
# SAME process_pr_record()/dedup/mint machinery PART A already uses. The
# dedup key is identical in shape to PART A's own
# ("cv-ci-repair-<owner>-<repo>-<num>"), so a PR that somehow becomes
# reachable by BOTH paths in the same cycle is still only ever minted once —
# dedup is keyed on repo+PR number, never on which path discovered it.
if [ "$CV_NATIVE_DISCOVERY" != "enabled" ]; then
  echo "con-voyage-pr-watch: [PART A-native] skipped — CV_NATIVE_DISCOVERY is '${CV_NATIVE_DISCOVERY}' (set to 'enabled' to opt in)"
else
echo "con-voyage-pr-watch: [PART A-native] unlisted-base discovery for '${CV_PR_AUTHOR}'-authored PRs"

# shellcheck disable=SC2034  # n_rig is part of cv_parse_pr_monitor_blocks's
# fixed row shape; this loop only needs owner/repo/route/bases, same as PART
# B leaves its own unused rig-adjacent fields alone elsewhere in this file.
while IFS=$'\x1f' read -r n_owner n_repo n_rig n_route n_bases; do
  [ -n "$n_owner" ] && [ -n "$n_repo" ] || continue
  n_full="${n_owner}/${n_repo}"

  # Build the listed-base lookup for THIS monitor only — a base listed on one
  # monitor's repo says nothing about another repo's own base_branches.
  IFS=',' read -r -a n_base_arr <<< "$n_bases"

  n_prs_json=$("$GH" pr list --repo "$n_full" --author "$CV_PR_AUTHOR" --state open \
    --limit "$CV_NATIVE_PRLIST_LIMIT" \
    --json number,title,headRefName,headRefOid,baseRefName 2>/dev/null) || {
    echo "con-voyage-pr-watch: [PART A-native] WARNING: gh pr list failed for ${n_full}; skipping" >&2
    continue
  }
  [ -n "$n_prs_json" ] || continue

  n_pr_rows=$(printf '%s' "$n_prs_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for pr in data:
    fields = [pr.get('number', ''), pr.get('title', '') or '', pr.get('headRefName', '') or '', pr.get('headRefOid', '') or '', pr.get('baseRefName', '') or '']
    print('\x1f'.join(str(f).replace('\x1f', ' ').replace('\n', ' ') for f in fields))
" 2>/dev/null || true)
  [ -n "$n_pr_rows" ] || continue

  while IFS=$'\x1f' read -r n_num n_title n_branch n_sha n_base; do
    [ -n "$n_num" ] || continue

    # UNRESOLVED BASE: fail closed, never guess. An empty/unresolved
    # baseRefName is NOT confirmation the base is unlisted — it could just as
    # easily be a listed base (e.g. "main") whose field failed to populate
    # this cycle. Treating it as "unlisted -> process" risks the exact
    # double-mint spec 2/3 exists to prevent; the engine-backed path above
    # already owns this PR on any cycle where ITS OWN base resolution
    # succeeds, so skipping here on an unresolved base costs nothing but a
    # retry next cycle.
    if [ -z "$n_base" ]; then
      # NOTE: deliberately does not say "SKIP <full>#<num>" — that exact shape
      # is PART A's own vocabulary for "a tracked repair is genuinely
      # in-flight" and existing tests grep combined output for it generically
      # (not scoped to [PART A] vs [PART A-native]); reusing it here for an
      # unrelated reason (an unresolved field) would read as a false positive
      # for that check.
      echo "con-voyage-pr-watch: [PART A-native] DEFER ${n_full}#${n_num} — baseRefName unresolved; cannot confirm it is unlisted" >&2
      continue
    fi

    # ALREADY COVERED: this base is one of the monitor's own listed
    # base_branches, so the engine-backed path above already evaluated this
    # PR this cycle (or will, on any config that lists it) — never double-mint.
    n_base_listed=0
    if [ "${#n_base_arr[@]}" -gt 0 ]; then
      for n_listed in "${n_base_arr[@]}"; do
        if [ "$n_listed" = "$n_base" ]; then
          n_base_listed=1
          break
        fi
      done
    fi
    [ "$n_base_listed" -eq 1 ] && continue

    # Fetch author,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup
    # in ONE call (fk-travno review BLOCKING-1): this is the exact superset
    # process_pr_record needs for its own author/review-gate resolution
    # below, so that call reuses this JSON (via a_pr_view_json) instead of
    # asking gh again — a native-discovered PR previously paid for two
    # identical `gh pr view` round-trips every cycle.
    n_view_json=$("$GH" pr view "$n_num" --repo "$n_full" \
      --json author,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null) || {
      echo "con-voyage-pr-watch: [PART A-native] WARNING: gh pr view failed for ${n_full}#${n_num}; skipping" >&2
      continue
    }
    n_classify=$(printf '%s' "$n_view_json" | cv_classify_pr_signals)
    IFS=$'\x1f' read -r n_failure_kind n_actionable <<< "$n_classify"

    # process_pr_record reads its inputs from the a_* globals — this is the
    # SAME convention the engine-backed loop above uses, so the shared
    # function needs no native-vs-engine branch of its own.
    a_owner="$n_owner"; a_repo="$n_repo"; a_num="$n_num"; a_title="$n_title"
    a_branch="$n_branch"; a_sha="$n_sha"; a_route="$n_route"
    a_failure_kind="$n_failure_kind"; a_actionable="$n_actionable"
    a_full="$n_full"
    a_dedup_key="cv-ci-repair-${n_owner}-${n_repo}-${n_num}"

    if ! acquire_lock "$a_dedup_key"; then
      # Same naming note as the DEFER case above — "LOCKED", not "SKIP", so
      # this never collides with PART A's own in-flight-SKIP vocabulary in a
      # combined-output grep.
      echo "con-voyage-pr-watch: [PART A-native] LOCKED ${a_full}#${a_num} — locked by a concurrent pr-watch run (dedup: ${a_dedup_key})"
      continue
    fi

    a_log_tag="[PART A-native]"
    a_pr_view_json="$n_view_json"
    process_pr_record

    release_lock "$a_dedup_key"
  done <<< "$n_pr_rows"
done <<< "$(cv_parse_pr_monitor_blocks "${GC_CITY}/city.toml")"
fi

# ---------------------------------------------------------------------------
# PART B: Human PR-comment routing
# ---------------------------------------------------------------------------
#
# For each [[github.pr_monitor]] we enumerate open PRs targeting the monitored
# base branches, then look for new human review comments/feedback that has not
# been seen in the previous run. When new human feedback is found, we route it
# to the implementor.
#
# The gc config does not provide a CLI to enumerate monitors directly, so we
# read the city.toml to extract owner/repo pairs. If city.toml is not
# accessible or parseable, we skip Part B gracefully.

CITY_TOML="${GC_CITY}/city.toml"
if [ ! -f "$CITY_TOML" ]; then
  echo "con-voyage-pr-watch: [PART B] city.toml not found at ${CITY_TOML}; skipping comment routing"
  exit 0
fi

echo "con-voyage-pr-watch: [PART B] scanning for human PR comments to route"

# Extract unique owner/repo pairs from [[github.pr_monitor]] blocks using awk.
# Block-scoped extraction: awk activates at [[github.pr_monitor]], captures
# owner= and repo= lines until the next top-level [...] header, then emits
# the pair. Handles monitor blocks where owner/repo appear many lines below
# the header (no fixed-line-count limit). Handles multiple monitor blocks.
#
# PORTABILITY: use POSIX bracket classes ([[:space:]]) rather than the GNU
# extension `\s`. Under BSD awk (macOS) `\s` matches a LITERAL 's', so a
# `\s`-based parser silently matches ZERO owner/repo lines and PART B no-ops
# ("no [[github.pr_monitor]] blocks found"). [[:space:]] works under BOTH BSD
# awk and gawk, and matches both `owner = "x"` (spaced) and `owner="x"`.
#
# Output format: one "OWNER/REPO|RIG" per line (RIG may be empty).
mapfile -t MONITOR_REPOS < <(awk '
  /^\[\[github\.pr_monitor\]\]/ {
    # A new block starts. Emit the pair for the PRIOR block first — consecutive
    # pr_monitor blocks (only comments between them) would otherwise be dropped,
    # because this rule preempts the emit rule below via next; without it only
    # the last monitor block (via END) is ever polled.
    if (in_block && owner != "" && repo != "") {
      print owner "/" repo "|" rig
    }
    in_block = 1
    owner = ""
    repo  = ""
    rig   = ""
    next
  }
  in_block && /^\[/ {
    # Next top-level header — emit pair if complete, then reset
    if (owner != "" && repo != "") {
      print owner "/" repo "|" rig
    }
    in_block = 0
    owner = ""
    repo  = ""
    rig   = ""
    # Check if this new header is itself a pr_monitor block
    if (/^\[\[github\.pr_monitor\]\]/) {
      in_block = 1
    }
    next
  }
  in_block && /^[[:space:]]*owner[[:space:]]*=/ {
    val = $0
    sub(/.*=[[:space:]]*"/, "", val)
    sub(/".*/, "", val)
    owner = val
    next
  }
  in_block && /^[[:space:]]*repo[[:space:]]*=/ {
    val = $0
    sub(/.*=[[:space:]]*"/, "", val)
    sub(/".*/, "", val)
    repo = val
    next
  }
  in_block && /^[[:space:]]*rig[[:space:]]*=/ {
    val = $0
    sub(/.*=[[:space:]]*"/, "", val)
    sub(/".*/, "", val)
    rig = val
    next
  }
  END {
    # Emit last block if file ends without another header
    if (in_block && owner != "" && repo != "") {
      print owner "/" repo "|" rig
    }
  }
' "$CITY_TOML")

if [ "${#MONITOR_REPOS[@]}" -eq 0 ]; then
  echo "con-voyage-pr-watch: [PART B] no [[github.pr_monitor]] blocks found in city.toml; nothing to poll"
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper: load seen node-IDs for a PR from its state file.
# State file: one node-ID string per line (e.g. PRR_kwDO... or IC_kwDO...).
# Returns a newline-delimited list to stdout.
# ---------------------------------------------------------------------------
load_seen_ids() {
  local state_file="$1"
  if [ -f "$state_file" ]; then
    cat "$state_file" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Helper: persist seen node-IDs back to the state file.
# Accepts newline-delimited ids on stdin; writes them (sorted, deduped).
# ---------------------------------------------------------------------------
save_seen_ids() {
  local state_file="$1"
  sort -u > "$state_file"
}

# Process each monitor's repo
for monitor_repo in "${MONITOR_REPOS[@]}"; do
  # Split "owner/repo|rig" — use parameter expansion, not IFS tricks
  monitor_rig="${monitor_repo#*|}"
  owner_repo="${monitor_repo%%|*}"
  owner="${owner_repo%%/*}"
  repo="${owner_repo#*/}"
  # Pool fallback route for THIS repo's rig worker. A bare "gc.implementation-worker"
  # is not a valid sling target — it must be rig-scoped (mirrors PART A's repair_route).
  # This is only the FALLBACK: each PR below first tries its own recorded
  # implementor_session from the publish step's .finalize record (fk-krsvc) so
  # feedback reaches the SAME session that built the PR, not a fresh pool
  # worker. pool_route_target is used only when that record is missing or its
  # implementor_session is empty.
  if [ -n "$monitor_rig" ] && [ "$monitor_rig" != "$monitor_repo" ]; then
    pool_route_target="${monitor_rig}/${CV_IMPLEMENTOR}"
  else
    pool_route_target="${CV_IMPLEMENTOR}"
  fi
  if [ -z "$owner" ] || [ -z "$repo" ]; then
    echo "con-voyage-pr-watch: [PART B] skipping malformed entry '${monitor_repo}'" >&2
    continue
  fi
  full_repo="${owner}/${repo}"

  echo "con-voyage-pr-watch: [PART B] checking ${full_repo} for human comments"

  # List open PRs. We only care about non-draft PRs (con-voyage PRs are
  # always non-draft by the time they reach review).
  #
  # AUTHOR SCOPING (see HARD INVARIANT in the header): --author "$CV_PR_AUTHOR"
  # restricts the enumeration to the operator's own PRs, so we never poll or
  # route comments from anyone else's PR. This is the first gate for PART B; a
  # SECOND, defensive per-PR author re-check (below, mirroring PART A's exact
  # match) verifies each PR's author == CV_PR_AUTHOR before routing any comment.
  open_prs_json=$("$GH" pr list \
    --repo "$full_repo" \
    --author "$CV_PR_AUTHOR" \
    --state open \
    --json number,headRefName,url,isDraft,author \
    2>/dev/null) || {
    echo "con-voyage-pr-watch: [PART B] WARNING: gh pr list failed for ${full_repo}; skipping" >&2
    continue
  }

  # Iterate over open, non-draft PRs
  pr_count=$(printf '%s' "$open_prs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len([p for p in data if not p.get('isDraft', False)]))" 2>/dev/null || echo 0)

  if [ "$pr_count" -eq 0 ]; then
    echo "con-voyage-pr-watch: [PART B] ${full_repo}: no open non-draft PRs"
    continue
  fi

  # Collect open PR numbers for state-file GC (cap seen-set to open PRs only)
  open_pr_numbers=$(printf '%s' "$open_prs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data:
    if not p.get('isDraft', False):
        print(p['number'])" 2>/dev/null || true)

  # Process each PR
  while IFS= read -r pr_json; do
    pr_number=$(printf '%s' "$pr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['number'])" 2>/dev/null) || continue

    pr_url=$(printf '%s' "$pr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['url'])" 2>/dev/null || echo "")

    head_ref=$(printf '%s' "$pr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['headRefName'])" 2>/dev/null || echo "")

    # DEFENSIVE AUTHOR RE-CHECK (belt-and-suspenders, mirrors PART A's exact
    # gate). `gh pr list --author "$CV_PR_AUTHOR"` should already restrict this
    # set to the operator's own PRs, but we re-verify the author of EACH PR
    # before routing any comment. This makes it impossible for a comment from a
    # PR not authored by CV_PR_AUTHOR to ever be routed — even if the upstream
    # --author filter were bypassed, misbehaved, or the JSON were malformed.
    #
    # INVARIANT: PART B routes comments ONLY from CV_PR_AUTHOR-authored PRs.
    # An unresolved/empty author is treated as "not ours" and dropped (fail
    # closed) — it is always better to route NOTHING than to route a comment
    # from someone else's PR.
    pr_author=$(printf '%s' "$pr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print((d.get('author') or {}).get('login', ''))" 2>/dev/null || echo "")

    if [ "$pr_author" != "$CV_PR_AUTHOR" ]; then
      echo "con-voyage-pr-watch: [PART B] DROP ${full_repo}#${pr_number} (author='${pr_author:-<unresolved>}' != '${CV_PR_AUTHOR}') — not routing any comment" >&2
      continue
    fi

    # Resolve THIS PR's own implementor from its .finalize record (fk-krsvc),
    # written by the publish step under the same dedup_key convention the
    # con-voyage-finalize monitor uses ("cv-finalize-<owner>-<repo>-<pr_number>").
    # Prefer it over the generic pool route so feedback on an awaiting-merge PR
    # reaches the SAME session that built it, not a fresh pool worker with no
    # context. Fall back to the pool route with an explicit log line — never
    # silently — when there is no record yet, its implementor_session is
    # empty (e.g. the publish step could not resolve one), OR the recorded
    # session is no longer alive (review fk-hbsmk BLOCKING-2: the DONE
    # criteria require this fallback "when [implementor_session] is missing
    # or the session is dead" — a recorded-but-dead session used to pin
    # route_target forever with no liveness check, unlike PART A's identical
    # dispatch decision a few hundred lines above, which already gates on
    # implementor_alive). A drained/evicted implementor, or a city restart,
    # while a PR sits awaiting_merge is a real, hours-to-days-long window.
    finalize_read "cv-finalize-${owner}-${repo}-${pr_number}"
    if [ -n "${FS_IMPLEMENTOR// /}" ] && implementor_alive "$FS_IMPLEMENTOR"; then
      route_target="$FS_IMPLEMENTOR"
    else
      route_target="$pool_route_target"
      if [ -n "${FS_IMPLEMENTOR// /}" ]; then
        echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: recorded implementor_session '${FS_IMPLEMENTOR}' is dead/unresolvable — falling back to pool route ${route_target}"
      else
        echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: no recorded implementor_session (missing/empty .finalize record) — falling back to pool route ${route_target}"
      fi
    fi

    # State file tracks seen node-ID strings per PR (keyed by repo+PR number)
    state_key=$(printf '%s' "${full_repo}/${pr_number}" | tr '/' '_')
    state_file="${CV_STATE_DIR}/${state_key}.seen-ids"

    # Load seen IDs into a temp file so we can pass to python3 via stdin
    seen_ids_content=$(load_seen_ids "$state_file")

    # Fetch PR reviews, issue comments, and inline review-thread comments, then
    # merge them into a single {reviews, comments, reviewThreads} object for the
    # parser below (which walks all three).
    #
    # WHY TWO CALLS: `gh pr view --json` does NOT support a `reviewThreads`
    # field (its field set has no such key — the whole call errors "Unknown
    # JSON field: reviewThreads" and exits non-zero, taking reviews/comments
    # down with it). reviewThreads (inline review-thread comments) is only
    # exposed via the GraphQL API. So we fetch:
    #   1. reviews + comments via `gh pr view --json reviews,comments` (the
    #      only valid fields here) — the PRIMARY fetch, which MUST succeed to
    #      route anything. Capture stderr to a file (rather than discarding it)
    #      so a failure's WARNING can surface gh's real error text instead of a
    #      bare "skipping" that gives an operator nothing to diagnose.
    #   2. reviewThreads via `gh api graphql` — BEST-EFFORT; a failure here is
    #      non-fatal (logged as a NOTE) and defaults to an empty threads list,
    #      so reviews+comments still route rather than losing all feedback.
    # Pass JSON via STDIN to python3 (avoids ARG_MAX limits on large PRs).
    gh_view_err_file="$(mktemp "${TMPDIR:-/tmp}/cv-pr-watch-gh-view-err.XXXXXX")"
    pr_view_json=$("$GH" pr view "$pr_number" \
      --repo "$full_repo" \
      --json reviews,comments \
      2>"$gh_view_err_file") || {
      gh_view_err="$(cat "$gh_view_err_file" 2>/dev/null)"
      rm -f "$gh_view_err_file"
      echo "con-voyage-pr-watch: [PART B] WARNING: gh pr view failed for ${full_repo}#${pr_number}: ${gh_view_err:-<no error output from gh>}; skipping" >&2
      continue
    }
    rm -f "$gh_view_err_file"

    # Best-effort inline review-thread comments via GraphQL. Caps at the first
    # 100 threads / 100 comments-per-thread, which comfortably covers a
    # con-voyage PR's inline feedback for a single cycle. A failure here is
    # non-fatal: log a NOTE and fall back to an empty threads set so
    # reviews+comments still route.
    #
    # We also select each comment's `databaseId` (the numeric REST id) plus its
    # `path`/`line`, so PART B can tell the implementor the EXACT reply target
    # per inline item (C10 / fk-bhz). `id` (the GraphQL node-id) stays the dedup
    # key, but a threaded reply is posted via the review-comment replies API,
    # which is keyed on the REST databaseId — so `cv-pr-comment.sh reply-thread
    # --comment-id <databaseId>` needs the databaseId, not the node-id.
    # shellcheck disable=SC2016
    _GQL_REVIEW_THREADS='query($owner:String!,$repo:String!,$num:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$num){reviewThreads(first:100){nodes{comments(first:100){nodes{id databaseId path line author{login} body}}}}}}}'
    review_threads_json=$("$GH" api graphql \
      -f query="$_GQL_REVIEW_THREADS" \
      -F owner="$owner" \
      -F repo="$repo" \
      -F num="$pr_number" \
      2>/dev/null) || {
      echo "con-voyage-pr-watch: [PART B] NOTE: reviewThreads GraphQL fetch failed for ${full_repo}#${pr_number}; routing reviews+comments only (inline thread comments skipped this cycle)" >&2
      review_threads_json=""
    }

    # Merge the two payloads into one {reviews, comments, reviewThreads} object.
    # reviewThreads is lifted out of the GraphQL envelope
    # (data.repository.pullRequest.reviewThreads.nodes) into a top-level
    # "reviewThreads" list, matching the scanner's expected shape below. If the
    # GraphQL fetch failed/was empty, reviewThreads defaults to [] (fail-soft).
    # shellcheck disable=SC2016
    _PY_MERGE_PR_JSON='
import sys, json
view = json.loads(sys.argv[1] or "{}")
raw  = sys.argv[2]
threads = []
if raw.strip():
    try:
        gq = json.loads(raw)
        pr = ((gq.get("data") or {}).get("repository") or {}).get("pullRequest") or {}
        threads = ((pr.get("reviewThreads") or {}).get("nodes")) or []
    except (ValueError, AttributeError):
        threads = []
out = {
    "reviews":       view.get("reviews", []) or [],
    "comments":      view.get("comments", []) or [],
    "reviewThreads": threads,
}
print(json.dumps(out))
'
    pr_comments_json=$(python3 -c "$_PY_MERGE_PR_JSON" "$pr_view_json" "$review_threads_json" 2>/dev/null) || {
      echo "con-voyage-pr-watch: [PART B] WARNING: failed to merge PR comment payloads for ${full_repo}#${pr_number}; skipping" >&2
      continue
    }

    # Extract new human comments using python3.
    # Reads PR JSON from stdin (fd 0) and seen-IDs + config from argv.
    # A comment is "human" if:
    #   1. The author login is not a known bot (no [bot] suffix, not in BOT_LOGINS)
    #   2. The comment body does NOT start with the con-voyage agent prefix pattern
    #   3. The comment's node-ID STRING is NOT in the seen-IDs set
    #
    # Examines: reviews, comments (issue/timeline), reviewThreads (inline).
    # Outputs: JSON array of new items, or "NONE".
    # Also outputs "SEEN_IDS:<newline-delimited-ids>" of ALL seen IDs after
    # including new ones (for state-file update).
    # shellcheck disable=SC2016
    _PY_SCAN_COMMENTS='
import sys, json, re, os
from datetime import datetime, timezone

pr_data    = json.load(sys.stdin)   # PR JSON from stdin
seen_ids   = set(line.strip() for line in sys.argv[1].splitlines() if line.strip())
agent_re   = re.compile(sys.argv[2])
full_repo  = sys.argv[3] if len(sys.argv) > 3 else ""
pr_number  = sys.argv[4] if len(sys.argv) > 4 else ""
suppression_log_path = sys.argv[5] if len(sys.argv) > 5 else ""

BOT_SUFFIXES = ["[bot]"]
BOT_LOGINS   = {"github-actions", "dependabot", "renovate", "stale", "codecov", "netlify"}
# AI-reviewer bots (doomer-ai, other "-ai" logins) are a DISTINCT category from
# plain infra bots above: a plain infra bot comment is always noise and is
# always skipped, but an AI reviewer can carry a real finding, so it gets the
# content-aware is_bot_approval_noise check below instead of a blanket skip.
AI_REVIEWER_SUFFIXES = ["-ai"]

def is_bot(login):
    ll = (login or "").lower()
    for s in BOT_SUFFIXES:
        if ll.endswith(s):
            return True
    return ll in BOT_LOGINS

# Strip a trailing "[bot]" App suffix before the AI-reviewer-suffix check, so
# an AI reviewer whose GitHub App login is rendered "doomer-ai[bot]" is still
# recognized as an AI reviewer (and gets its content checked) instead of
# matching only the literal "-ai" ending.
def _strip_bot_suffix(login):
    ll = login or ""
    for s in BOT_SUFFIXES:
        if ll.lower().endswith(s):
            return ll[: -len(s)]
    return ll

def is_ai_reviewer_bot(login):
    base = _strip_bot_suffix(login).lower()
    return any(base.endswith(s) for s in AI_REVIEWER_SUFFIXES)

def is_agent_comment(body):
    return bool(agent_re.match(body or ""))

# A bot-trigger slash command ("/doomer run", "/retry", ...) is an operator
# instruction to a bot, not change-request feedback — never route it,
# regardless of who posted it (fk-9xyo4 recurrence, mail rc-wisp-3hoqm3y).
# The command token must end at whitespace or end-of-string so ordinary
# prose that merely starts with a slash-prefixed path (e.g. "/etc/foo is
# broken") is not mistaken for a bot command (PR#160 human feedback).
SLASH_COMMAND_RE = re.compile(r"^/\w+(?:\s|$)")

def is_slash_command(body):
    return bool(SLASH_COMMAND_RE.match((body or "").strip()))

# A bot review/comment that is pure no-issues/approval noise (doomer-ai own
# stampy-stamp banner, a clean APPROVED state) must not mint human feedback.
# A bot flagging a CRITICAL finding or refusing to auto-approve is a real
# signal and must still be routed -- only the no-op banner is noise (fk-9xyo4:
# a doomer-ai comment reading not automatically approving / classified as
# critical was dropped outright on 2026-10-02 because it carried a bot login;
# operator ruling says it should have been picked up). The escape hatch
# requires the explicit "classified as critical" phrase, not a bare
# "critical" substring, so a genuine no-op banner that merely mentions
# "critical" in passing (e.g. "No critical problems noted") still gets
# classified as noise instead of leaking into routed feedback (PR#160 human
# feedback).
def is_bot_approval_noise(body, state):
    b = (body or "").lower()
    if "classified as critical" in b or "not automatically approving" in b or "refus" in b or state == "CHANGES_REQUESTED":
        return False
    if state == "APPROVED":
        return True
    if "ran successfully" in b and "no issues" in b:
        return True
    if "stampy-stamp" in b:
        return True
    return False

# A bot reply that carries no finding at all -- no severity/critical marker,
# no code reference, no requested change -- is pure acknowledgement noise and
# must not mint a feedback bead, even when its phrasing does not match one of
# the specific known noise banners above (fk-7xu9m: a doomer-ai[bot] reply
# "Got it -- thanks for the feedback!" to a human reply became a feedback
# bead a worker had to claim and close no-op, va-e6p7u/vandoor#10590,
# 2026-10-03). This is deliberately a catch-all, broader net than the
# specific phrases is_bot_approval_noise matches: it fires whenever NONE of
# the finding markers below are present, so a reply that still carries a
# severity word, a code reference, or requested-change language keeps
# routing regardless of how it opens.
# Narrowed (mayor regrade of fk-igqet1 LOW-3): "please", "update", and
# "change" were dropped from this set. Each is common in pure bot chatter
# that carries no finding at all ("status update", "no changes needed",
# "please let us know if you have questions"), so on their own they routed
# acks/summaries as if they were findings -- the exact PR noise this feature
# exists to cut. Every remaining word/pattern here is still finding-shaped
# (a severity term, a code/location reference, or an explicit
# fix/requested-change phrase), so no currently-pinned real finding (CASE
# 50-61) stopped matching -- see CASE 62 for the new negative pins proving
# bare "please"/"update"/"change" chatter no longer routes.
FINDING_MARKER_RE = re.compile(
    r"critical|blocking|severity|vulnerab|\bbugs?\b|\berrors?\b|"
    r"`[^`]+`|\bline\s+\d+\b|:\d+\b|%3a\d+|"
    r"\bshould\b|\bmust\b|\bneed(?:s|ed)?\s+to\b|recommend|\bfix\b|"
    r"\bbreak(?:s|ing)?\b|\bregress(?:ion)?\b|migration path|\bintentional\b|"
    r"worth confirming|before this ships",
    re.IGNORECASE,
)

def is_bot_ack(body, state):
    b = (body or "").strip()
    if not b:
        return False
    bl = b.lower()
    if state == "CHANGES_REQUESTED" or "not automatically approving" in bl or "refus" in bl or "classified as critical" in bl:
        return False
    return not FINDING_MARKER_RE.search(b)

# ADVERSARY MARKERS (fk-igqet1, extended fk-yztb54 design doc slice E / AC5):
# Doomer stamps every one of its own comments with a stable, machine-readable
# HTML-comment marker -- `adversary-review:v2 ... finding=<id>` on a real
# finding, `adversary-feedback-ack:v1` on its own acknowledgement of a human
# reply with no finding attached. These are ground truth from the producer
# itself and must be checked BEFORE the prose heuristic below, not as a
# supplement to it: on 2026-10-08 ~14:00Z Doomer posted a real finding
# (replicatedhq/vandoor#10620, review comment 4219884349) whose prose happened
# to avoid every FINDING_MARKER_RE word (no backticks, no
# should/must/fix/change, the "loc=...%3A529" ref was URL-encoded so the old
# `:\d+` missed it, and "needs a migration path" did not match `need(s) to`)
# -- classify_suppression() dropped it as bot_ack with no durable trace. A
# marker-bearing comment must never depend on prose phrasing to route. The ack
# marker is ALSO checked in the inline review-thread loop below, where "a
# thread we already replied to" is observable (the full thread history is in
# hand) -- that is the only place a bare ack marker (no finding marker) is
# itself treated as a suppression reason.
ADVERSARY_FINDING_MARKER_RE = re.compile(r"adversary-review:v2\b.*?\bfinding=", re.IGNORECASE | re.DOTALL)
ADVERSARY_ACK_MARKER_RE = re.compile(r"adversary-feedback-ack:v1\b", re.IGNORECASE)

def has_adversary_finding_marker(body):
    return bool(ADVERSARY_FINDING_MARKER_RE.search(body or ""))

def has_adversary_ack_marker(body):
    return bool(ADVERSARY_ACK_MARKER_RE.search(body or ""))

# fk-dh3mkt review (mayor reopen, regraded LOW-3; widened fk-yztb54 iteration-3
# BLOCKING-2): a bare "?" in body" matched a "?" inside a URL query string, a
# code span, or optional-chaining syntax (y?.foo) just as readily as a real
# question -- none of those should ever win the adversary-ack "genuine
# question" gate below. A real sentence-ending "?" is followed only by
# whitespace, a closing quote/paren/bracket, or end-of-string; a "?" embedded
# in foo?bar=1 or a backtick code span is followed by more non-space token
# characters instead. The first cut of this lookahead (straight/curly-free,
# no "<") under-matched two real Doomer comment shapes: a question ending in
# a closing quote (straight or curly), and a question immediately followed by
# the HTML ack marker with no separating whitespace. Both are reachable
# whenever Doomer omits a leading space before the marker or quotes the
# question it is acknowledging, and both wrongly read as "not a question",
# letting a genuine question fall into the unconditional ack-marker
# suppression in classify_suppression() below. Deliberately still conservative toward
# routing (a "?" this misses as a question falls through to the pre-existing
# FINDING_MARKER_RE/bot_ack path, which can still route on other real
# content) -- only the classification of what counts as a "genuine question"
# gets tighter here.
QUESTION_MARK_RE = re.compile(r"\?(?=\s|[)\]\x22\x27<]|$)")

def is_question(body):
    return bool(QUESTION_MARK_RE.search(body or ""))

# ONE shared classifier used by all three scan loops below (reviews, issue
# comments, inline review-thread comments). fk-9xyo4/PR#160 recurred TWICE
# because each loop carried its own hand-copied is_bot/is_ai_reviewer_bot/
# is_slash_command/is_agent_comment sequence, and a second copy drifted out of
# order (is_bot ran before is_ai_reviewer_bot), silently dropping a real
# CRITICAL finding. A single predicate makes that class of drift impossible —
# every loop now calls this and ONLY this to decide whether an item is
# suppressed. Returns a short machine-readable reason string ("slash_command",
# "bot_noise", "bot_approval_noise", "bot_ack", "agent_comment") when the item
# must be dropped, or None when it is a real candidate (the caller still
# applies its own type-specific empty-body/PENDING rules on top of a None
# result).
def classify_suppression(author, body, state):
    if is_slash_command(body):
        return "slash_command"
    if is_ai_reviewer_bot(author):
        if has_adversary_finding_marker(body):
            return None
        if has_adversary_ack_marker(body):
            # fk-yztb54 iteration-3 BLOCKING-2 follow-on: an ack marker alone
            # is not proof the thread needs no human/agent reply -- a real
            # question riding along with it (Doomer asking "does this look
            # okay?" while also stamping its own ack) must still route, and
            # so must ordinary prose that trips the same FINDING_MARKER_RE
            # heuristic a marker-free bot reply would ("you should be fine
            # now" alongside the ack marker is still a finding-shaped reply).
            # Mirrors the "a question or a finding always overrides" rule the
            # inline-thread doomer_ack_thread_closed gate already applies, but
            # as a blanket classify_suppression() rule shared by all three
            # scan loops, not only the inline-thread loop. Falls through to
            # the same is_bot_approval_noise/is_bot_ack prose checks below
            # instead of returning "bot_ack" unconditionally.
            if is_question(body):
                return None
        if is_bot_approval_noise(body, state):
            return "bot_approval_noise"
        if is_bot_ack(body, state):
            return "bot_ack"
        return None
    if is_bot(author):
        return "bot_noise"
    if is_agent_comment(body):
        return "agent_comment"
    return None

# SUPPRESSION LOG (fk-1ff6ge / PR#160 round 2, finding 5; durable record added
# fk-igqet1): a comment that gets filtered out here leaves zero trace
# anywhere else, so a WRONGLY dropped human comment is invisible until
# someone notices feedback never arrived -- that is exactly how the original
# Doomer drop (fk-9xyo4) went unnoticed for as long as it did, and how the
# 2026-10-08 recurrence went unnoticed for 7 hours (the stderr-only line was
# nowhere to be found afterwards; this run log is not retained). Every
# suppression now prints one line to stderr naming the PR, the dropped items
# dedup id, its author, and the reason, AND appends the same record to a
# per-PR state file under CV_STATE_DIR (when a path is supplied) so the drop
# survives past this run -- an operator can answer "why was this dropped?"
# after the fact instead of only during a live tail of the monitors own log.
# This covers EVERY suppression reason, including the newer
# doomer_ack_thread_closed case (fk-yztb54) -- durable-only-for-one-reason
# would silently regress this audit coverage for every other suppression
# type (review fk-yztb54 BLOCKING-1: a landed sibling, #188/fk-igqet1, made
# durable-for-all the real design; a thread-local durable-only gate is never
# layered back in during a rebase reconciliation).
#
# CAP (mayor regrade of fk-igqet1 LOW-1): this file is append-only and this
# monitor runs every few minutes forever, so left unbounded it grows without
# limit. Trim to the most recent SUPPRESSION_LOG_MAX_LINES lines on every
# write -- cheap at this cap (a bounded read+rewrite), and keeps the exact
# same "why was this dropped" answer for anything recent, which is the only
# thing an operator actually needs. Override via CV_SUPPRESSION_LOG_MAX_LINES
# for tests that need a small, deterministic cap.
SUPPRESSION_LOG_MAX_LINES = int(os.environ.get("CV_SUPPRESSION_LOG_MAX_LINES") or "2000")

def _trim_suppression_log(path):
    try:
        with open(path, "r") as f:
            lines = f.readlines()
        if len(lines) > SUPPRESSION_LOG_MAX_LINES:
            with open(path, "w") as f:
                f.writelines(lines[-SUPPRESSION_LOG_MAX_LINES:])
    except OSError:
        pass  # best-effort trim; a trim failure must never block suppression itself

def log_suppression(item_type, nid, author, reason):
    sys.stderr.write(
        "con-voyage-pr-watch: [PART B] SUPPRESS %s#%s %s id=%s author=%s reason=%s\n"
        % (full_repo, pr_number, item_type, nid, author, reason)
    )
    if suppression_log_path:
        try:
            with open(suppression_log_path, "a") as f:
                f.write(
                    "%s SUPPRESS %s#%s %s id=%s author=%s reason=%s\n"
                    % (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), full_repo, pr_number, item_type, nid, author, reason)
                )
        except OSError as e:
            sys.stderr.write(
                "con-voyage-pr-watch: [PART B] WARNING: suppression_log write failed for %s: %s\n"
                % (suppression_log_path, e)
            )
            return
        _trim_suppression_log(suppression_log_path)

found      = []
new_ids    = set()

# --- PR review summaries ---
for review in pr_data.get("reviews", []):
    nid = str(review.get("id") or "").strip()
    if not nid or nid in seen_ids:
        continue
    author = review.get("author", {}).get("login", "")
    body   = review.get("body", "") or ""
    state  = review.get("state", "") or ""
    reason = classify_suppression(author, body, state)
    if reason:
        log_suppression("review", nid, author, reason)
        continue
    if state == "PENDING":
        continue
    if not body.strip() and state not in ("APPROVED", "CHANGES_REQUESTED"):
        continue
    found.append({
        "id":     nid,
        "type":   "review",
        "author": author,
        "body":   body[:200],
        "state":  state,
    })
    new_ids.add(nid)

# --- Issue / timeline comments ---
for comment in pr_data.get("comments", []):
    nid = str(comment.get("id") or "").strip()
    if not nid or nid in seen_ids:
        continue
    author = comment.get("author", {}).get("login", "")
    body   = comment.get("body", "") or ""
    reason = classify_suppression(author, body, "")
    if reason:
        log_suppression("comment", nid, author, reason)
        continue
    if not body.strip():
        continue
    found.append({
        "id":     nid,
        "type":   "comment",
        "author": author,
        "body":   body[:200],
        "state":  "",
    })
    new_ids.add(nid)

# --- Inline review-thread comments ---
for thread in pr_data.get("reviewThreads", []):
    # fk-yztb54 (design doc slice E / AC5): track, as we walk this thread in
    # order, whether OUR OWN agent reply already appears in it -- this is the
    # "a thread we already replied to" condition, only observable here where
    # the whole threads comment history is in hand (never in the
    # reviews/issue-comments loops, which see single items with no thread
    # context at all).
    agent_replied_in_thread = False
    for comment in thread.get("comments", {}).get("nodes", []):
        nid = str(comment.get("id") or "").strip()
        author = comment.get("author", {}).get("login", "")
        body   = comment.get("body", "") or ""
        if is_agent_comment(body):
            agent_replied_in_thread = True
        if not nid or nid in seen_ids:
            continue
        if (
            agent_replied_in_thread
            and is_ai_reviewer_bot(author)
            and has_adversary_ack_marker(body)
            and not has_adversary_finding_marker(body)
            and not is_question(body)
        ):
            reason = "doomer_ack_thread_closed"
        else:
            reason = classify_suppression(author, body, "")
        if reason:
            log_suppression("inline", nid, author, reason)
            if reason == "doomer_ack_thread_closed":
                # fk-yztb54 BLOCKING-1: this suppression is durably appended
                # to suppression_log_file above. Without also marking nid
                # seen here, this monitor (a periodic poller against the same
                # open PR) re-evaluates and re-appends the identical line on
                # every future cycle for the life of the PR -- unbounded by
                # polling frequency, not just by GitHub activity.
                new_ids.add(nid)
            continue
        if not body.strip():
            continue
        # databaseId (numeric REST id) is the reply target for a threaded reply;
        # path/line pin the inline location. All three come from the C10 GraphQL
        # selection above. Guard for None (older gh, or a non-inline shape).
        db_id = comment.get("databaseId")
        comment_id = "" if db_id is None else str(db_id)
        path = comment.get("path") or ""
        line = comment.get("line")
        line_str = "" if line is None else str(line)
        found.append({
            "id":         nid,
            "type":       "inline",
            "author":     author,
            "body":       body[:200],
            "state":      "",
            "comment_id": comment_id,
            "path":       path,
            "line":       line_str,
        })
        new_ids.add(nid)

# Emit results
if not found:
    print("NONE")
else:
    # Stable order: new items first (their relative order from the API)
    print(json.dumps(found))

# Always emit updated seen-IDs set (existing + newly routed) on a sentinel
# line so the shell can persist it without a second python invocation.
all_ids = seen_ids | new_ids
print("SEEN_IDS:" + "\n".join(sorted(all_ids)))
'
    suppression_log_file="${CV_STATE_DIR}/${state_key}.suppressions.log"
    new_comments=$(printf '%s' "$pr_comments_json" | python3 -c "$_PY_SCAN_COMMENTS" "$seen_ids_content" "$CV_AGENT_PREFIX_PATTERN" "$full_repo" "$pr_number" "$suppression_log_file") || {
      echo "con-voyage-pr-watch: [PART B] WARNING: comment parsing failed for ${full_repo}#${pr_number}" >&2
      continue
    }

    # Split python3 output into the result and the SEEN_IDS block
    result_line=$(printf '%s\n' "$new_comments" | grep -v '^SEEN_IDS:' | head -1)
    updated_seen_ids=$(printf '%s\n' "$new_comments" | awk '/^SEEN_IDS:/{found=1; sub(/^SEEN_IDS:/,""); print; next} found{print}')

    if [ "$result_line" = "NONE" ] || [ -z "$result_line" ]; then
      echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: no new human comments"
      # Persist seen-IDs even when nothing new (idempotent — same content)
      if [ -n "$updated_seen_ids" ]; then
        printf '%s\n' "$updated_seen_ids" | save_seen_ids "$state_file"
      fi
      continue
    fi

    echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: new human feedback found — routing to ${route_target}"

    # Build a routing message summarizing the new feedback.
    # Pass JSON via stdin to avoid ARG_MAX issues.
    #
    # For INLINE review-thread items we ALSO surface the reply TARGET per item
    # (C10 / fk-bhz): the REST comment databaseId plus its path:line. This is
    # what tells the implementor to reply IN-thread via
    # `cv-pr-comment.sh reply-thread ... --comment-id <databaseId>` instead of at
    # root. The node-id [id:...] stays too (dedup key). Root/general comments and
    # reviews carry no comment_id, so their line is unchanged.
    # shellcheck disable=SC2016
    _PY_SUMMARIZE='
import sys, json
items = json.load(sys.stdin)
lines = []
for item in items[:5]:   # cap at 5 items per run to avoid info overload
    author = item.get("author", "?")
    kind   = item.get("type", "comment")
    state  = item.get("state", "")
    body   = item.get("body", "").strip()
    nid    = item.get("id", "")
    label  = (" (" + state + ")") if state else ""
    target = ""
    comment_id = item.get("comment_id", "") or ""
    if comment_id:
        path = item.get("path", "") or ""
        line = item.get("line", "") or ""
        loc = ""
        if path:
            loc = " @ " + path + ((":" + line) if line else "")
        # reply IN-thread with: cv-pr-comment.sh reply-thread --comment-id <id>
        target = "  [reply-thread comment-id:" + comment_id + loc + "]"
    lines.append("  [" + kind + "] @" + author + label + ": " + body[:120] + "  [id:" + nid + "]" + target)
if len(items) > 5:
    lines.append("  ... and " + str(len(items)-5) + " more comment(s)")
print("\n".join(lines))
'
    feedback_summary=$(printf '%s' "$result_line" | python3 -c "$_PY_SUMMARIZE" 2>/dev/null || echo "  (summary unavailable)")

    # Dedup key uses the set of new node-IDs (stable across retries with same comments)
    new_ids_for_key=$(printf '%s\n' "$result_line" | python3 -c "
import sys, json
items = json.load(sys.stdin)
print(','.join(sorted(x['id'] for x in items)))" 2>/dev/null || echo "unknown")

    route_title="Human PR feedback on ${full_repo}#${pr_number}: ${head_ref}"
    route_body="$(cv_build_pr_feedback_body "$pr_url" "$head_ref" "$feedback_summary" \
      "pr-comment-${full_repo//\//_}-${pr_number}-nodeids-${new_ids_for_key}")" || {
      echo "con-voyage-pr-watch: [PART B] WARNING: could not build a trustworthy fenced body for ${full_repo}#${pr_number} (nonce generation failed), skipping this cycle" >&2
      continue
    }

    # Route the feedback as a new task bead to the implementor. gc 1.4.1's
    # `gc sling` has NO --body flag; the create-bead-from-text forms are inline
    # positional text or --stdin (first line = title, remaining lines = body).
    # We use --stdin so the multi-line body is passed cleanly (no ARG_MAX / quoting
    # issues), with the title as the first line and a blank line before the body.
    #
    # If route_target is the PR's own recorded implementor (not already the
    # pool fallback) and the sling call itself fails — e.g. a recorded
    # implementor_session that resolves ALIVE but whose handle `gc sling`
    # still rejects live — fall through to pool_route_target once instead of
    # retrying the same unroutable target forever (review fk-pbadx
    # BLOCKING-1: the old code never fell back here, so a live-but-unroutable
    # implementor silently black-holed every cycle's feedback for that PR).
    sling_out=""
    if sling_out="$(printf '%s\n\n%s\n' "$route_title" "$route_body" \
      | "$GC" --city "$GC_CITY" sling "$route_target" --stdin 2>&1)"; then
      echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: routed to ${route_target}"
      [ -z "$sling_out" ] || printf '%s\n' "$sling_out"
      # Persist updated seen-IDs only on successful route
      if [ -n "$updated_seen_ids" ]; then
        printf '%s\n' "$updated_seen_ids" | save_seen_ids "$state_file"
      fi
    elif [ "$route_target" != "$pool_route_target" ]; then
      echo "con-voyage-pr-watch: [PART B] WARNING: gc sling to recorded implementor ${route_target} failed for ${full_repo}#${pr_number} (${sling_out}) — falling back to pool route ${pool_route_target}" >&2
      if sling_out="$(printf '%s\n\n%s\n' "$route_title" "$route_body" \
        | "$GC" --city "$GC_CITY" sling "$pool_route_target" --stdin 2>&1)"; then
        echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: routed to pool fallback ${pool_route_target}"
        if [ -n "$updated_seen_ids" ]; then
          printf '%s\n' "$updated_seen_ids" | save_seen_ids "$state_file"
        fi
      else
        echo "con-voyage-pr-watch: [PART B] WARNING: gc sling also failed for pool route ${pool_route_target} for ${full_repo}#${pr_number} (${sling_out}); will retry next cycle" >&2
        # Do NOT update state file — we'll retry on next cycle
      fi
    else
      echo "con-voyage-pr-watch: [PART B] WARNING: gc sling failed for ${full_repo}#${pr_number} (${sling_out}); will retry next cycle" >&2
      # Do NOT update state file — we'll retry on next cycle
    fi

  done < <(printf '%s' "$open_prs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pr in data:
    if not pr.get('isDraft', False):
        print(json.dumps(pr))" 2>/dev/null)

  # ---------------------------------------------------------------------------
  # State-file GC: remove state files for PRs that are no longer open.
  # This prevents unbounded accumulation of seen-ID files for merged/closed PRs.
  # ---------------------------------------------------------------------------
  if [ -n "$open_pr_numbers" ]; then
    # Build set of expected state-file basenames for open PRs
    for existing_state in "${CV_STATE_DIR}/${owner}_${repo}_"*.seen-ids; do
      [ -f "$existing_state" ] || continue
      basename_no_ext="${existing_state%.seen-ids}"
      # Extract PR number suffix: state key is owner_repo_<number>
      pr_num_from_file="${basename_no_ext##*_}"
      if ! printf '%s\n' "$open_pr_numbers" | grep -qx "$pr_num_from_file"; then
        echo "con-voyage-pr-watch: [PART B] GC: removing stale state for closed PR #${pr_num_from_file} (${full_repo})"
        rm -f "$existing_state"
      fi
    done
  fi

done

echo "con-voyage-pr-watch: done"
