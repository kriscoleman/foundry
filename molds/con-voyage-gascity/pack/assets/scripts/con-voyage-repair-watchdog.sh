#!/usr/bin/env bash
# con-voyage-repair-watchdog.sh — repair-worker watchdog (fk-wgqp, Fix 2 of the
# con-voyage-repair-implementor-reuse design).
#
# ############################################################################
# # HARD INVARIANT — AUTHOR SCOPING                                          #
# #                                                                          #
# # This watchdog MUST only ever act on per-PR state records whose recorded  #
# # `pr_author` is the single configured user CV_PR_AUTHOR. It takes no      #
# # action — not even a read of the tracked bead — on any other record.      #
# #                                                                          #
# # Author-scoping itself is decided PURELY from the local per-PR state      #
# # record that con-voyage-pr-watch.sh already wrote under CV_STATE_DIR,     #
# # which already carries the resolved `pr_author` from THAT script's own    #
# # author-scoped dispatch — NEVER from a fresh GitHub call. Checking it     #
# # again here is defense in depth, not the primary gate — see the design    #
# # rationale in con-voyage-pr-watch.sh's HARD INVARIANT banner for why an   #
# # earlier unscoped monitor got the operator removed from an org.          #
# #                                                                          #
# # This script now makes exactly ONE GitHub call, and only ever AFTER a     #
# # record has already cleared the author-scoping gate above (Fix 3,        #
# # fk-htx5p — see below): a pre-dispatch recheck of that SAME record's own  #
# # repo/PR. It can neither relax nor bypass this invariant.                 #
# ############################################################################
#
# Fix 1 (con-voyage-pr-watch.sh, landed as con-voyage-gascity 0.5.1) keeps
# "every open con-voyage PR has exactly one live implementor" true AT DISPATCH
# TIME: it reuses a live implementor via mail, or falls back to a fresh pool
# worker when none is known/alive, and records the outcome in a per-PR state
# record. That invariant can still drift AFTER dispatch: the reused
# implementor can die mid-rework, or a rework (mail-based or a fallback pool
# bead) can simply stop making progress. Nothing re-checks that between
# con-voyage-pr-watch.sh's own 10-minute cycles. This script is a SEPARATE,
# more frequent periodic order (not the prior inline staleness check — see
# below) that re-checks and self-heals:
#
#   - Implementor known but no longer alive -> supersede the tracked bead and
#     dispatch a fresh fallback worker (same mechanism con-voyage-pr-watch.sh
#     itself uses when no implementor is known).
#   - No known implementor yet AND the fallback bead has sat unclaimed past
#     the stall threshold -> same fallback re-dispatch (nobody ever picked it
#     up; a freshly-minted bead within the threshold is left alone).
#   - Implementor known and alive, but the tracked bead's `updated_at` has not
#     advanced past the stall threshold -> re-notify the SAME implementor
#     (mail + notify, no new bead — mirrors con-voyage-pr-watch.sh's own reuse
#     path) and keep watching the SAME bead (its updated_at is the ongoing
#     progress signal for the next cycle).
#   - Implementor known and alive and progressing (or no in-flight rework at
#     all) -> no action.
#   - After CV_MAX_ATTEMPTS consecutive re-dispatches with no progress ->
#     escalate to a human via `gc mail` and stop re-dispatching that PR until
#     con-voyage-pr-watch.sh records a genuinely fresh dispatch for it (a
#     real state change, not just this watchdog trying again).
#
# REBUILD NOTE: an earlier build (commit 13d403a, "C11") added this same
# self-heal idea as an INLINE staleness check inside con-voyage-pr-watch.sh's
# PART A loop. That build never shipped as a release and predates the
# implementor-reuse state schema (Fix 1). Per the design doc
# (con-voyage-repair-implementor-reuse-design.md, Fix 2), this is a REBUILD as
# a standalone periodic order against the CURRENT state schema — the inline
# version is not reused.
#
# Task 0 spike findings (recorded here per the bead's instructions):
#   1. Progress/stall signal: the tracked bead's `bd show --json` `updated_at`
#      (same signal the prior, unshipped C11 build used) — if it has not
#      advanced in more than CV_STALL_SECONDS, the rework is "stalled". A
#      missing/unparseable updated_at fails SAFE (never treated as stale), so
#      a live repair is never wrongly superseded on bad data.
#   2. Re-dispatch mechanics: reused verbatim from con-voyage-pr-watch.sh —
#      `gc mail send <implementor> ... --notify` while an implementor is
#      known and alive (no new bead); otherwise create a fresh bead and
#      `gc sling <repair_route> <bead> --on con-voyage-ci-repair --var ...`
#      (the exact fallback shape con-voyage-pr-watch.sh already uses).
#   3. State enumeration: this script iterates `CV_STATE_DIR/*.state` directly
#      — it never calls `gc github pr backfill` for its core logic. It DOES
#      call `gh pr view` in exactly one place (Fix 3, fk-htx5p, below): a
#      pre-dispatch recheck of the PR's own current CI/state, immediately
#      before acting on a record that already looks dead/stalled.
#      The per-PR attempt counter is a new field on that SAME state record
#      (`attempt_count`, plus `escalated`) — see con-voyage-pr-watch.sh's
#      state_read/state_write, which this script's copies below match
#      exactly so the two scripts can read/write the same files. That script
#      owns resetting/preserving attempt_count/escalated on ITS OWN writes
#      (fresh dispatch resets both; an unrelated in-flight-refresh preserves
#      both; going clean resets both); this script owns incrementing
#      attempt_count and setting escalated on ITS OWN writes.
#
# SCOPE NOTE: a pre-existing bare "<dedup_key>.minted" marker (the OLD,
# pre-Fix-1 format, with no ".state" file yet) is invisible to this script —
# it only globs "*.state" files. This is an accepted, self-healing gap: Fix 1
# has been live since con-voyage-gascity 0.5.1, so by the time this watchdog
# also runs, con-voyage-pr-watch.sh's own next 10-minute cycle has already
# converted every actively-tracked PR to the current ".state" format (it
# already treats a bare legacy marker as needing fresh evaluation — see its
# own back-compat comment). Duplicating that legacy-adoption logic here would
# guard against a window that closes on its own within one monitor cycle.
#
# SCOPE NOTE: this script never does "claimant adoption" (reading the tracked
# bead's `assignee` and adopting it as `implementor_session`) the way
# con-voyage-pr-watch.sh does. That stays that script's job; it already runs
# frequently enough (10m) for the adoption latency to be immaterial, and
# duplicating it here was judged out of scope for this bead (Fix 2 is about
# self-healing dead/stalled rework, not implementor discovery).
#
# Fix 2b (fk-11yuv): two overlapping invocations of THIS script (e.g. an order
# cycle firing again before the prior one finished, or two separate processes
# racing) could both read the same stale ".state" record before either wrote
# back, and both independently supersede the tracked bead and mint a FRESH
# fallback bead/lineage for the same PR — two live re-dispatch lineages doing
# duplicate (and potentially conflicting) work on the same shared worktree.
# Seen live on kriscoleman/foundry#81: a watchdog cycle superseded a
# never-claimed bead and re-dispatched, and ~2 seconds later a second cycle did
# the same thing again for the same PR before the first cycle's state_write
# was visible to it. Two fixes close this:
#
#   1. Per-dedup_key mutual exclusion (acquire_lock/release_lock, shared via
#      con-voyage-lib.sh): the read-decide-act-write section for one dedup_key
#      runs under an atomic `mkdir`-based lock (portable to plain bash on
#      macOS/Linux without `flock`). A concurrent invocation that cannot
#      acquire the lock SKIPS that record for this cycle rather than
#      blocking — the record is untouched, so the next cycle (this one's or
#      another's) re-evaluates it against whatever the lock-holder left
#      behind. A lock whose mtime is older than CV_LOCK_STALE_SECONDS is
#      presumed abandoned by a crashed holder and is stolen rather than
#      wedging that PR's record forever.
#   2. A fresh re-check immediately before acting (right before superseding
#      the tracked bead / re-notifying its implementor): re-fetch the tracked
#      bead's status/updated_at ONE more time and compare against the
#      snapshot the classification above used. If the bead went closed/
#      unknown, or its updated_at moved, something changed it since we looked
#      (a worker claimed it, or it made progress) — yield (skip, no state
#      change) instead of racing that fresh activity with a second lineage.
#      This is what makes "a superseded lineage gets claimed after all" safe
#      even within a single (now-serialized) run: the bead-less reuse case has
#      no bead to reclaim and is not subject to this recheck.
#
# Fix 3 (fk-htx5p): SEEN LIVE 2026-09-26 during and after a multi-hour usage
# freeze — every worker was frozen, so con-voyage-pr-watch.sh's own 10-minute
# backfill cycle could not run either, and its ST_LAST_STATE/ST_INFLIGHT
# records went stale while the PRs they described actually finished (checks
# went green, or the PR was merged/closed) out of band. This watchdog kept
# re-dispatching against that stale state every cycle: 5 duplicate ci-repair
# runs across #93/#94/#96, all created AFTER their PRs were already green.
# ci-repair's own Step 0b does not catch these on re-entry (foundry PRs carry
# an empty reviewDecision, which that guard's own author/review gate does not
# treat as "already done"). Two related problems, one fix:
#
#   DEFECT 1: a watchdog-minted fallback bead (`new_bead_id` below) was never
#   forwarded to the ci-repair formula as `--var repair_bead=...`. Without it,
#   the workflow's `{repair_bead}` placeholder resolves empty, so
#   cv_bead_mark_in_progress/cv_bead_close (con-voyage-lib.sh, fk-7mw7 FIX-A)
#   silently no-op on every terminal exit and the tracked bead orphans forever
#   unless a human notices. Fixed by forwarding `repair_bead=${new_bead_id}`
#   on every fallback sling, exactly like con-voyage-pr-watch.sh's own mint
#   already does (fk-7mw7).
#
#   DEFECT 2: nothing rechecked the PR's OWN current state before acting on a
#   dead/stalled classification derived purely from the (possibly stale)
#   tracked record. Fixed by `pr_ci_resolved` below: immediately before acting
#   on any record with a tracked bead (`ST_INFLIGHT` non-empty), one bounded
#   `gh pr view --json statusCheckRollup,state` call (wrapped in
#   `cv_with_timeout` — this Mac has no `timeout(1)` binary, same rationale as
#   con-voyage-review-watchdog.sh's own CV_LENS_STORE_TIMEOUT_SECONDS) checks
#   whether the PR is already merged/closed or its checks are not currently
#   failing. If so, the tracked bead is closed as a no-op — no fallback bead
#   is minted, no implementor is re-notified — instead of re-dispatching.
#   FAIL-SAFE: any gh error, timeout, or unparsable response is treated as
#   "cannot tell" and falls through to this script's PRE-Fix-3 behavior — an
#   inability to check must never suppress a real re-dispatch.
#
# Fix 4 (fk-6rj8zo): SEEN LIVE 2026-10-14 on replicatedhq/vandoor#10644 — 4
# simultaneously live ci-repair workers, 4 in_progress con-voyage-ci-repair
# roots, and 14 duplicate "Watchdog re-dispatch" beads on one PR, all in the
# same shared rig checkout; earlier on that PR, 61+ repair cycles. Root cause
# in process_state_record()'s use_fallback branch: it called close_if_open on
# the previously tracked bead but never checked whether that close actually
# succeeded before minting and slinging a replacement. Under load,
# close_if_open can time out (cv_with_timeout), warn, and leave the bead
# open; the per-dedup_key state record only remembers the newest bead, so the
# orphan is invisible to later cycles and a pool worker can still claim it,
# giving N live repairs on one PR. Three fixes:
#
#   DEFECT 1: check `CV_CLOSE_RC` (set by close_if_open) immediately after
#   the supersede close. If it is non-zero, skip minting/slinging this cycle
#   entirely — the attempt counter is left untouched (not a real attempt) —
#   and retry the close next cycle, same posture as the pre-existing
#   missing-repair_route guard just above.
#
#   DEFECT 2: tag every minted bead with its dedup_key as
#   `gc.repair_dedup_key` metadata. Before minting a replacement, sweep for
#   any OTHER open bead carrying that same tag (an orphan DEFECT 1 above
#   didn't prevent, or that slipped through before this fix existed) and
#   force-close it, so at most one repair bead per PR is ever open even if a
#   close failure happens more than once in a row.
#
#   DEFECT 3: `is_stale` for a tracked bead with no known implementor now
#   distinguishes "minted, unclaimed" (bd status "open" — claim latency
#   under pool contention, generous `CV_UNCLAIMED_STALL_SECONDS` threshold)
#   from "claimed, no progress" (bd status "in_progress" but this watchdog
#   has no implementor on record — the normal, shorter `CV_STALL_SECONDS`
#   threshold). Previously both used `CV_STALL_SECONDS`, so a bead merely
#   waiting its turn under pool contention could be misread as stalled and
#   re-dispatched on top of a worker about to claim it anyway (the
#   secondary cause named in the bead: `CV_STALL_SECONDS` had no claim-
#   latency allowance).
#
# Environment / configuration (all optional with sane defaults):
#
#   GC                Path to the gc binary (default: gc)
#   GH                Path to the gh binary (default: gh) — invoked to resolve
#                     the CV_PR_AUTHOR default (see below), and (Fix 3,
#                     fk-htx5p) for one pre-dispatch PR CI/state recheck per
#                     acted-on record with a tracked bead. gh remaining
#                     absent/erroring/timing out is still fail-safe: the
#                     recheck (pr_ci_resolved) then reports "cannot tell" and
#                     this script falls through to its pre-Fix-3 re-dispatch
#                     behavior, so gh is never a hard dependency even though
#                     it is now consulted more often than just CV_PR_AUTHOR.
#   GC_CITY           City root passed to gc (default: current directory)
#   CV_STATE_DIR      Directory holding the per-PR state records this script
#                     reads (default: .gc/cv-pr-watch — MUST match
#                     con-voyage-pr-watch.sh's CV_STATE_DIR so both scripts
#                     see the same records).
#   CV_PR_AUTHOR      REQUIRED (author-scoping). The single GitHub login this
#                     watchdog is allowed to act for. Defaults to the
#                     authenticated gh login (if gh is installed). If it
#                     cannot be resolved, the script FAILS CLOSED (exit 1)
#                     before reading any state record.
#   CV_STALL_SECONDS  Seconds of no progress (tracked bead `updated_at`
#                     unchanged) before a rework is considered stalled. Also
#                     the threshold for a tracked bead that WAS claimed but
#                     whose claimant this watchdog has not adopted as an
#                     implementor (bd status "in_progress", no known
#                     implementor_session — see CV_UNCLAIMED_STALL_SECONDS
#                     for the bd status "open" case). Default: 900 (15
#                     minutes).
#   CV_UNCLAIMED_STALL_SECONDS  Seconds a tracked bead may sit UNCLAIMED
#                     (bd status "open", no known implementor_session)
#                     before being treated as stalled (fk-6rj8zo DEFECT 3).
#                     Deliberately longer than CV_STALL_SECONDS: claim
#                     latency under pool contention is expected and must
#                     not be misread as a stalled rework and re-dispatched
#                     on top of a worker that is about to claim it anyway.
#                     Default: 1800 (30 minutes).
#   CV_MAX_ATTEMPTS   Consecutive watchdog re-dispatches allowed for the SAME
#                     problem cycle before escalating instead. Default: 3.
#   CV_LOCK_STALE_SECONDS  Seconds after which a held per-dedup_key lock is
#                     presumed abandoned (crashed holder) and stolen rather
#                     than left to wedge that PR's record forever. Default:
#                     300 (5 minutes) — generous relative to the handful of
#                     `bd`/`gc` calls a single record's processing needs.
#   CV_ESCALATE_TARGET  Mail recipient when a PR's rework exhausts
#                     CV_MAX_ATTEMPTS. Default: the reserved `human` alias
#                     (same convention as escalation_target in
#                     con-voyage-ci-repair.formula.toml).
#   CV_AUTHOR_GATE    Forwarded, NOT read, by this script — threaded into any
#                     fallback bead it mints via --var cv_author_gate=...,
#                     same as con-voyage-pr-watch.sh. Default: enabled.
#   CV_CONFLICT_STRATEGY  Forwarded, NOT read, by this script — threaded into
#                     any fallback bead it mints via --var
#                     cv_conflict_strategy=..., same as
#                     con-voyage-pr-watch.sh. Default: rebase.
#   CV_GH_TIMEOUT_SECONDS  Wall-clock bound (via cv_with_timeout) on the Fix 3
#                     pre-dispatch `gh pr view` recheck. Default: 20.
#
# Exit codes:
#   0 — completed (some, all, or none of the tracked records needed action)
#   Non-zero — fatal setup error (gc/python3 missing, CV_PR_AUTHOR unresolved)
#
# The order controller treats any non-zero exit as a transient failure and
# retries on the next cooldown interval.
#
# Requires: bash 4+, gc CLI, python3. gh CLI is optional (see CV_PR_AUTHOR).

set -uo pipefail

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
CV_PR_AUTHOR="${CV_PR_AUTHOR:-}"
CV_STALL_SECONDS="${CV_STALL_SECONDS:-900}"
CV_UNCLAIMED_STALL_SECONDS="${CV_UNCLAIMED_STALL_SECONDS:-1800}"
CV_MAX_ATTEMPTS="${CV_MAX_ATTEMPTS:-3}"
CV_ESCALATE_TARGET="${CV_ESCALATE_TARGET:-human}"
CV_LOCK_STALE_SECONDS="${CV_LOCK_STALE_SECONDS:-300}"
CV_GH_TIMEOUT_SECONDS="${CV_GH_TIMEOUT_SECONDS:-20}"
# Bound on the DEFECT-2 orphan-sweep `bd list`/`bd update` store calls below,
# same knob and default as every sibling store-enumeration call in this pack
# (con-voyage-marshal-bead-sweep.sh, con-voyage-orphan-sweep.sh).
CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
# Forwarded, NOT read, by this script (see header) — declared here with the
# other tunables rather than left as an inline ${..:-default} at each use
# site, so every configuration knob resolves in one place.
CV_AUTHOR_GATE="${CV_AUTHOR_GATE:-enabled}"
CV_CONFLICT_STRATEGY="${CV_CONFLICT_STRATEGY:-rebase}"

# A malformed CV_STALL_SECONDS/CV_MAX_ATTEMPTS override must never silently
# break the staleness/escalation checks that gate this watchdog's core
# behavior (is_stale already fails safe on a bad threshold via its own
# float() guard, but the CV_MAX_ATTEMPTS `-ge` comparison has no such guard —
# a non-numeric value would make the escalation cap never trip, re-dispatching
# forever). Coerce both to their documented defaults when not a valid
# non-negative base-10 integer, same fail-safe posture as every other
# malformed-field guard in this pack.
case "$CV_STALL_SECONDS" in
  *[!0-9]*|'') CV_STALL_SECONDS="900" ;;
esac
case "$CV_UNCLAIMED_STALL_SECONDS" in
  *[!0-9]*|'') CV_UNCLAIMED_STALL_SECONDS="1800" ;;
esac
case "$CV_MAX_ATTEMPTS" in
  *[!0-9]*|'') CV_MAX_ATTEMPTS="3" ;;
esac
case "$CV_LOCK_STALE_SECONDS" in
  *[!0-9]*|'') CV_LOCK_STALE_SECONDS="300" ;;
esac
case "$CV_GH_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_GH_TIMEOUT_SECONDS="20" ;;
esac
case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
esac

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-repair-watchdog: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-repair-watchdog: ERROR: python3 not found; required for state/JSON parsing." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the CV_PR_AUTHOR default (guarded against set -e-equivalent
# failures — this script does not use `set -e`, but the command substitution
# is still guarded with `|| true` for parity with con-voyage-pr-watch.sh and
# to keep a missing/unauthenticated gh from producing anything but an empty,
# cleanly-handled value). gh is OPTIONAL here (see header): it is only ever
# consulted when CV_PR_AUTHOR is not already set.
# ---------------------------------------------------------------------------
if [ -z "${CV_PR_AUTHOR// /}" ] && command -v "$GH" >/dev/null 2>&1; then
  CV_PR_AUTHOR="$("$GH" api user --jq .login 2>/dev/null || true)"
fi

# FAIL-CLOSED author-scoping guard (see HARD INVARIANT above): an unresolved
# allow-list must never be treated as "work everything".
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  echo "con-voyage-repair-watchdog: FATAL: CV_PR_AUTHOR is empty/unresolved." >&2
  echo "con-voyage-repair-watchdog: author-scoping is mandatory — refusing to act on any state record." >&2
  echo "con-voyage-repair-watchdog: set CV_PR_AUTHOR explicitly (e.g. CV_PR_AUTHOR=kriscoleman)." >&2
  exit 1
fi
echo "con-voyage-repair-watchdog: author-scoped to '${CV_PR_AUTHOR}'; stall=${CV_STALL_SECONDS}s max_attempts=${CV_MAX_ATTEMPTS} escalate_target=${CV_ESCALATE_TARGET}"

# Shared per-PR state/dispatch helpers (state_read, state_write, now_iso8601,
# bead_status, implementor_alive, close_if_open, cv_default_state_dir) were
# sourced above, before CV_STATE_DIR's default was computed — see
# con-voyage-lib.sh for the authoritative field-by-field state-record doc
# comment. Shared with con-voyage-pr-watch.sh, which writes and reads the
# SAME state records.

# is_stale UPDATED_AT THRESHOLD_SECONDS — exit 0 if UPDATED_AT is more than
# THRESHOLD_SECONDS in the past. A missing/unparseable UPDATED_AT fails SAFE
# (never stale) — a live repair must never be superseded on bad data. Same
# ISO-8601 parsing approach as the prior (unshipped) C11 build.
is_stale() {
  local updated_at="$1" threshold="$2"
  [ -n "${updated_at// /}" ] || return 1
  python3 -c "
import sys
from datetime import datetime, timezone

updated_at = sys.argv[1]
try:
    threshold_s = float(sys.argv[2])
except Exception:
    sys.exit(1)
try:
    ts = updated_at.strip()
    if ts.endswith('Z'):
        ts = ts[:-1] + '+00:00'
    parsed = datetime.fromisoformat(ts)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    age = (datetime.now(timezone.utc) - parsed).total_seconds()
except Exception:
    sys.exit(1)
sys.exit(0 if age > threshold_s else 1)
" "$updated_at" "$threshold"
}

# pr_ci_resolved REPO PR_NUMBER — Fix 3 (fk-htx5p): exit 0 when REPO#PR_NUMBER
# is already merged/closed, or its checks are not currently failing (green);
# exit 1 otherwise, INCLUDING "cannot tell" (empty REPO/PR_NUMBER, a gh error,
# a timeout, or an unparsable response). Same is_bad() conclusion/state
# classification con-voyage-finalize.sh's pr_live_phase already uses for
# statusCheckRollup, narrowed to just the failing-vs-not signal this watchdog
# needs (mergeable/mergeStateStatus are pr_live_phase's own concern, not
# this one's). FAIL-SAFE: every "cannot tell" path returns 1 (not resolved),
# same posture as is_stale's own missing-data guard — an inability to check
# must never be read as "safe to skip a real re-dispatch".
pr_ci_resolved() {
  local repo="$1" pr_number="$2"
  [ -n "${repo// /}" ] || return 1
  case "$pr_number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  local json
  json="$(cv_with_timeout "$CV_GH_TIMEOUT_SECONDS" "$GH" pr view "$pr_number" --repo "$repo" \
    --json statusCheckRollup,state 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | python3 -c "
import sys, json

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)

if (d.get('state') or '').upper() in ('MERGED', 'CLOSED'):
    sys.exit(0)

def is_bad(c):
    conclusion = c.get('conclusion')
    if conclusion is not None:
        return str(conclusion).upper() in ('FAILURE', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE')
    state = c.get('state')
    if state is not None:
        return str(state).upper() in ('FAILURE', 'ERROR')
    return False

checks = d.get('statusCheckRollup') or []
sys.exit(1 if any(is_bad(c) for c in checks) else 0)
"
}

# ---------------------------------------------------------------------------
# Per-dedup_key mutual exclusion (fk-11yuv Fix 2b — see header). acquire_lock
# and release_lock now live in con-voyage-lib.sh (fk-8b5fl — lifted so
# con-voyage-pr-watch.sh can share the exact same mkdir-based lock instead of
# duplicating it) and were sourced above along with the other shared helpers.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# process_state_record DEDUP_KEY — evaluate and, if needed, act on exactly one
# per-PR state record. Called with that record's lock already held (see the
# main loop below). Every early-out below is a `return` (not `continue` — this
# now runs inside a function, not the loop body directly) so the caller's lock
# release always runs regardless of which path this takes.
# ---------------------------------------------------------------------------
process_state_record() {
  local dedup_key="$1"
  state_read "$dedup_key"

  label="${dedup_key}"
  if [ -n "${ST_REPO_FULL// /}" ] && [ -n "${ST_PR_NUMBER// /}" ]; then
    label="${ST_REPO_FULL}#${ST_PR_NUMBER}"
  fi

  # Acceptance: "PR clean / no in-flight rework -> no action." Extended for
  # fk-lfan B1: skip only when BOTH inflight_rework AND implementor_session
  # are empty — nothing at all to monitor. A mail-only reuse dispatch (Fix
  # 1's PRIMARY dispatch path, con-voyage-pr-watch.sh:739,747,823) writes
  # inflight_rework empty but implementor_session set — that case IS
  # monitorable (see the bead-less branch below), so it must not be skipped
  # here just because there is no tracked bead.
  if [ -z "${ST_INFLIGHT// /}" ] && [ -z "${ST_IMPLEMENTOR// /}" ]; then
    echo "con-voyage-repair-watchdog: SKIP ${dedup_key} — no in-flight rework and no known implementor"
    return
  fi

  # HARD INVARIANT — AUTHOR SCOPING (defensive re-check; see header). An
  # empty/unresolved pr_author (e.g. a pre-Fix-2 record con-voyage-pr-watch.sh
  # has not yet rewritten) is treated as "not verifiably ours" and skipped —
  # fail closed, exactly like every other author gate in this pack.
  if [ -z "${ST_PR_AUTHOR// /}" ] || [ "$ST_PR_AUTHOR" != "$CV_PR_AUTHOR" ]; then
    echo "con-voyage-repair-watchdog: SKIP ${dedup_key} — author scoping (pr_author='${ST_PR_AUTHOR}' != CV_PR_AUTHOR='${CV_PR_AUTHOR}')"
    return
  fi

  # "stop re-dispatching that one" — a prior cycle already escalated this
  # exact problem cycle to a human; do nothing further (including no repeated
  # escalation mail) until con-voyage-pr-watch.sh records a genuinely fresh
  # dispatch (which resets escalated=0).
  if [ "$ST_ESCALATED" = "1" ]; then
    echo "con-voyage-repair-watchdog: SKIP ${label} — already escalated; not re-dispatching"
    return
  fi

  implementor_known=0
  [ -n "${ST_IMPLEMENTOR// /}" ] && implementor_known=1

  alive=0
  if [ "$implementor_known" -eq 1 ] && implementor_alive "$ST_IMPLEMENTOR"; then
    alive=1
  fi

  use_fallback=0
  needs_action=0
  action_desc=""
  # Declared up front (not just inside the tracked-bead branch below) so the
  # "OK ... no action" log line can always reference them under `set -u` —
  # they stay empty for a bead-less record (fk-lfan B1).
  tracked_status=""
  tracked_updated_at=""

  if [ -z "${ST_INFLIGHT// /}" ]; then
    # fk-lfan B1: bead-less mail-only reuse dispatch (Fix 1's PRIMARY
    # dispatch path — con-voyage-pr-watch.sh:739,747,823) — implementor_known
    # is guaranteed 1 here (the combined skip above already dropped the
    # truly-empty case), but there is no tracked bead to check, so staleness
    # is keyed off last_dispatch_at (written by con-voyage-pr-watch.sh at
    # dispatch time and by this watchdog at each re-notify below) instead of
    # a bead's updated_at.
    if [ "$alive" -eq 0 ]; then
      # Hermetic case (a): implementor set + inflight empty + session dead.
      needs_action=1
      use_fallback=1
      action_desc="DEAD (bead-less reuse)"
    elif is_stale "$ST_LAST_DISPATCH_AT" "$CV_STALL_SECONDS"; then
      # Hermetic case (b): same + alive + last_dispatch_at stale.
      needs_action=1
      use_fallback=0
      action_desc="STALLED (bead-less reuse, implementor alive)"
    fi
    # Hermetic case (c): same + fresh -> needs_action stays 0, "no action" below.
  else
    tracked_fields="$(bead_status "$ST_INFLIGHT" updated_at)"
    IFS=$'\x1f' read -r tracked_status tracked_updated_at <<< "$tracked_fields"

    # A closed/unknown tracked bead is not this watchdog's problem to fix: the
    # rework either finished (con-voyage-pr-watch.sh's own next cycle will see
    # the PR's real current state and re-evaluate with full context) or the
    # bead was deleted out of band. Guessing here risks racing that script's
    # own supersede/re-mint logic. Leave the record untouched.
    if [ -z "$tracked_status" ] || [ "$tracked_status" = "closed" ]; then
      echo "con-voyage-repair-watchdog: SKIP ${label} — tracked bead ${ST_INFLIGHT} is closed/unknown; deferring to the monitor's next cycle"
      return
    fi

    if [ "$implementor_known" -eq 1 ] && [ "$alive" -eq 0 ]; then
      # Acceptance: "Implementor dead + in-flight rework -> assigns a new
      # implementor (re-dispatch)." No staleness threshold gates this case —
      # a confirmed-dead session is an unambiguous signal on its own.
      needs_action=1
      use_fallback=1
      action_desc="DEAD"
    elif [ "$implementor_known" -eq 1 ]; then
      if is_stale "$tracked_updated_at" "$CV_STALL_SECONDS"; then
        # Acceptance: "Rework stalled past threshold, implementor alive ->
        # supersede + re-dispatch to same implementor."
        needs_action=1
        use_fallback=0
        action_desc="STALLED (implementor alive)"
      fi
    else
      # fk-6rj8zo DEFECT 3 (claim-latency-aware stall detection): no
      # implementor is known for this tracked bead. It may be a freshly
      # minted fallback bead nobody has claimed yet (bd status "open" —
      # claim latency under pool contention is expected and must not read
      # as a stalled rework), or one that WAS claimed but whose claimant
      # this watchdog has not adopted as an implementor (bd status
      # "in_progress" — claimant adoption is con-voyage-pr-watch.sh's job,
      # see its own SCOPE NOTE above). An unclaimed bead gets the more
      # generous CV_UNCLAIMED_STALL_SECONDS threshold; a claimed-but-
      # unadopted bead still uses the normal CV_STALL_SECONDS progress
      # threshold, since it has a live worker and "no progress" is the real
      # signal there, not claim latency.
      never_claimed_threshold="$CV_STALL_SECONDS"
      [ "$tracked_status" = "open" ] && never_claimed_threshold="$CV_UNCLAIMED_STALL_SECONDS"
      if is_stale "$tracked_updated_at" "$never_claimed_threshold"; then
        # Nobody ever picked it up (or picked it up but made no progress).
        # Same remedy as a dead implementor: a fresh fallback dispatch.
        needs_action=1
        use_fallback=1
        action_desc="STALLED (no implementor known)"
      fi
    fi
  fi

  if [ "$needs_action" -eq 0 ]; then
    # Acceptance: "Implementor alive + rework progressing -> no action" (and
    # symmetrically, an unclaimed-but-still-fresh fallback bead within its
    # grace period, or a bead-less reuse whose last_dispatch_at is fresh).
    echo "con-voyage-repair-watchdog: OK ${label} — no action (implementor_known=${implementor_known} alive=${alive} updated_at=${tracked_updated_at} last_dispatch_at=${ST_LAST_DISPATCH_AT})"
    return
  fi

  # Acceptance: "3 failed attempts -> escalate via gc mail, stop
  # re-dispatching." Checked BEFORE acting: CV_MAX_ATTEMPTS re-dispatches have
  # already been made against this SAME problem cycle and it is STILL
  # dead/stalled — escalate instead of trying a 4th time.
  if [ "$ST_ATTEMPT_COUNT" -ge "$CV_MAX_ATTEMPTS" ] 2>/dev/null; then
    echo "con-voyage-repair-watchdog: ESCALATE ${label} — ${ST_ATTEMPT_COUNT} failed attempt(s), notifying ${CV_ESCALATE_TARGET} and stopping re-dispatch"
    if "$GC" --city "$GC_CITY" mail send "$CV_ESCALATE_TARGET" \
      -s "con-voyage watchdog: giving up on ${label}" \
      -m "Repair rework for ${label} (branch ${ST_BRANCH}, last_handled_state=${ST_LAST_STATE}) has made no progress after ${ST_ATTEMPT_COUNT} watchdog re-dispatch attempt(s). Tracked bead: ${ST_INFLIGHT}. This watchdog is stopping automatic re-dispatch for this PR — please take a look." \
      2>&1; then
      state_write "$dedup_key" "$ST_IMPLEMENTOR" "$ST_INFLIGHT" "$ST_LAST_STATE" \
        "$ST_PR_AUTHOR" "$ST_REPAIR_ROUTE" "$ST_REPO_FULL" "$ST_PR_NUMBER" "$ST_BRANCH" \
        "$ST_ATTEMPT_COUNT" "1" "$ST_LAST_DISPATCH_AT"
    else
      echo "con-voyage-repair-watchdog: WARNING: escalation mail to ${CV_ESCALATE_TARGET} failed for ${label}; will retry next cycle" >&2
    fi
    return
  fi

  # Re-check immediately before acting (fk-11yuv Fix 2b — see header): the
  # tracked bead may have been claimed or otherwise updated in the window
  # between the classification read above and this point — including by the
  # very lineage we are about to supersede, if it got claimed after all. A
  # fresh updated_at (or the bead having gone closed/unknown) means real
  # progress happened since our snapshot; re-dispatching now would race that
  # activity with a second, redundant lineage. Yield instead: leave the record
  # untouched so the next cycle re-evaluates against current state. The
  # bead-less reuse case (no ST_INFLIGHT) has no bead to reclaim and is not
  # rechecked here — its own staleness (last_dispatch_at) is written only by
  # this watchdog, so there is no third party that could have moved it.
  if [ -n "${ST_INFLIGHT// /}" ]; then
    recheck_fields="$(bead_status "$ST_INFLIGHT" updated_at)"
    IFS=$'\x1f' read -r recheck_status recheck_updated_at <<< "$recheck_fields"
    if [ -z "$recheck_status" ] || [ "$recheck_status" = "closed" ]; then
      echo "con-voyage-repair-watchdog: SKIP ${label} — tracked bead ${ST_INFLIGHT} went closed/unknown since evaluation; yielding, not re-dispatching"
      return
    fi
    if [ "$recheck_updated_at" != "$tracked_updated_at" ]; then
      echo "con-voyage-repair-watchdog: SKIP ${label} — tracked bead ${ST_INFLIGHT} was claimed/updated since evaluation (${tracked_updated_at} -> ${recheck_updated_at}); yielding, not re-dispatching"
      return
    fi

    # Fix 3 (fk-htx5p DEFECT 2): re-check the PR's OWN current CI/state right
    # before acting — same "recheck right before acting" posture as the
    # fk-11yuv block above, but against GitHub instead of the tracked bead's
    # own updated_at. A PR that already went green (or merged/closed) since
    # con-voyage-pr-watch.sh's last cycle wrote ST_LAST_STATE means the rework
    # already succeeded or is moot; re-dispatching would be a duplicate no-op
    # repair, not "catching up a stalled repair" (SEEN LIVE: 5 duplicate
    # ci-repair runs across #93/#94/#96 during a usage freeze that also froze
    # con-voyage-pr-watch.sh's own backfill). Close the tracked bead as a
    # no-op instead of superseding it into a fresh lineage or re-notifying.
    if pr_ci_resolved "$ST_REPO_FULL" "$ST_PR_NUMBER"; then
      echo "con-voyage-repair-watchdog: SKIP ${label} — PR is already green/merged/closed; closing tracked bead ${ST_INFLIGHT} as no-op instead of re-dispatching"
      close_if_open "$ST_INFLIGHT" "no-op: PR already green/merged/closed, watchdog re-dispatch not needed" "" "$recheck_status"
      return
    fi
  fi

  new_attempt_count=$((ST_ATTEMPT_COUNT + 1))

  if [ "$use_fallback" -eq 1 ]; then
    # Missing redispatch context (e.g. a record predating this watchdog's
    # schema fields) — never guess at where/what to re-dispatch. Leave the
    # attempt counter untouched: this was not a real attempt.
    if [ -z "${ST_REPAIR_ROUTE// /}" ] || [ -z "${ST_REPO_FULL// /}" ] || [ -z "${ST_PR_NUMBER// /}" ]; then
      echo "con-voyage-repair-watchdog: WARNING: ${label} is ${action_desc} but its state record is missing repair_route/repo_full/pr_number; cannot safely re-dispatch (will re-check next cycle once con-voyage-pr-watch.sh repopulates it)" >&2
      return
    fi
    rig="${ST_REPAIR_ROUTE%%/*}"
    if [ "$rig" = "$ST_REPAIR_ROUTE" ] || [ -z "$rig" ]; then
      echo "con-voyage-repair-watchdog: WARNING: ${label} repair_route '${ST_REPAIR_ROUTE}' has no '<rig>/' prefix; cannot derive a target rig; skipping re-dispatch" >&2
      return
    fi

    echo "con-voyage-repair-watchdog: ${action_desc} ${label} — reassigning to a new implementor (attempt ${new_attempt_count}/${CV_MAX_ATTEMPTS})"
    # tracked_status is already known here for the tracked-bead branch (it was
    # fetched above to decide DEAD/STALLED) — pass it through to skip a
    # redundant second `bd show` for the same bead. Empty for the bead-less
    # branch, where close_if_open no-ops immediately on the empty bead id
    # anyway (no lookup is ever made either way).
    close_if_open "$ST_INFLIGHT" "superseded: watchdog reassigning ${label} (${action_desc})" "" "$tracked_status"

    # fk-6rj8zo DEFECT 1: close_if_open is fail-safe (it warns and leaves the
    # bead open rather than aborting), so its own return value can't be
    # trusted to tell us whether the supersede actually happened — check
    # CV_CLOSE_RC (set by close_if_open on every real close attempt) instead.
    # A non-empty ST_INFLIGHT whose close failed/timed out must NOT be
    # followed by minting a replacement this cycle: that is exactly how the
    # old bead was left open and claimable while a fresh lineage got
    # dispatched on top of it (SEEN LIVE: replicatedhq/vandoor#10644, 4
    # simultaneously live ci-repair workers on one PR). Leave the attempt
    # counter untouched — this was not a real attempt — and retry the close
    # next cycle.
    if [ -n "${ST_INFLIGHT// /}" ] && [ "${CV_CLOSE_RC:-0}" -ne 0 ]; then
      echo "con-voyage-repair-watchdog: WARNING: ${label} supersede of ${ST_INFLIGHT} did not complete (close rc=${CV_CLOSE_RC}); not minting a replacement this cycle, will retry the close next cycle" >&2
      return
    fi

    # fk-6rj8zo DEFECT 2: catch an orphan that already slipped through a
    # PRIOR cycle's close failure above (or any other path that left a
    # duplicate repair bead for this same PR open and claimable, invisible to
    # this cycle's single-bead ST_INFLIGHT pointer). Every bead this watchdog
    # and con-voyage-pr-watch.sh mint for a given PR is tagged with the same
    # gc.repair_dedup_key metadata (tagged on THIS mint below); sweeping and
    # force-closing every OTHER open-or-in_progress bead carrying that tag
    # before minting keeps "at most one repair bead per PR is ever open" true
    # even after a close failure already happened once.
    #
    # review fk-wmhr96 BLOCKING-1 (acceptance fk-s0cniq, code-review
    # fk-7ai3uo BLOCKING-2): the live incident this defect targets
    # (replicatedhq/vandoor#10644) was simultaneously-live workers that had
    # already claimed their bead — i.e. status in_progress, not open — so
    # the sweep must query both statuses, matching every sibling sweep
    # (con-voyage-marshal-bead-sweep.sh, con-voyage-orphan-sweep.sh). Bound
    # by cv_with_timeout, same knob/default as those siblings, since this
    # call runs while holding the per-dedup_key lock (review fk-wmhr96
    # BLOCKING-5, SRE) and an unbounded read here would turn that lock into a
    # stall point for the PR under exactly the store-contention load this fix
    # exists to survive. A `bd list` failure (timeout, bad JSON, gc error) is
    # logged with a WARNING and skipped — it must never block the real
    # re-dispatch below.
    orphan_json="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
      "$GC" --city "$GC_CITY" --rig "$rig" bd list --status open,in_progress \
      --metadata-field "gc.repair_dedup_key=${dedup_key}" --json --limit 0 2>/dev/null)" || orphan_json=""
    if [ -z "$orphan_json" ]; then
      echo "con-voyage-repair-watchdog: WARNING: orphan sweep bd list failed or returned empty for ${label} (dedup_key=${dedup_key}); skipping the sweep this cycle, proceeding with re-dispatch" >&2
    else
      orphan_rows="$(printf '%s' "$orphan_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for item in data:
    if isinstance(item, dict) and item.get('id'):
        print('%s|%s' % (item['id'], item.get('status') or ''))
" 2>/dev/null || true)"
      if [ -z "$orphan_rows" ]; then
        echo "con-voyage-repair-watchdog: WARNING: orphan sweep bd list returned unparseable JSON for ${label} (dedup_key=${dedup_key}); skipping the sweep this cycle, proceeding with re-dispatch" >&2
      else
        # review fk-wmhr96 BLOCKING-4 (QA/test-engineering fk-5lhtbk,
        # test-evidence fk-wjpega): close_if_open is fail-safe by design — a
        # failed force-close logs a WARNING and leaves the bead open rather
        # than aborting, so its own return value can't be trusted here any
        # more than it could for the ST_INFLIGHT supersede above. Track
        # CV_CLOSE_RC across every orphan in the loop and skip minting a
        # replacement this cycle if any orphan's force-close failed — minting
        # on top of a still-open, still-claimable orphan reproduces the exact
        # live-incident shape (N simultaneously-live repair workers on one
        # PR) this bead exists to close, just reached via this sweep instead
        # of the main supersede path DEFECT 1 already guards.
        orphan_close_failed=0
        while IFS='|' read -r orphan_id orphan_status; do
          [ -n "${orphan_id// /}" ] || continue
          [ "$orphan_id" = "$ST_INFLIGHT" ] && continue
          close_if_open "$orphan_id" "superseded: orphaned duplicate repair bead for ${label} (dedup_key=${dedup_key})" "" "$orphan_status" "1"
          if [ "${CV_CLOSE_RC:-0}" -ne 0 ]; then
            orphan_close_failed=1
          fi
        done <<< "$orphan_rows"
        if [ "$orphan_close_failed" -eq 1 ]; then
          echo "con-voyage-repair-watchdog: WARNING: ${label} orphan-sweep force-close of at least one duplicate (dedup_key=${dedup_key}) did not complete; not minting a replacement this cycle, will retry the sweep next cycle" >&2
          return
        fi
      fi
    fi

    new_bead_id=$("$GC" --city "$GC_CITY" --rig "$rig" bd create \
      "Watchdog re-dispatch: GitHub PR ${label} (${ST_LAST_STATE})" \
      --priority 1 --silent 2>/dev/null || true)

    if [ -z "${new_bead_id// /}" ]; then
      echo "con-voyage-repair-watchdog: WARNING: failed to create a fallback repair bead for ${label}; will retry next cycle" >&2
      return
    fi

    # Tag the freshly-minted bead with its dedup_key (fk-6rj8zo DEFECT 2) so
    # a FUTURE cycle's orphan sweep (above) can find and force-close it if it
    # is ever superseded-but-not-actually-closed the same way. A failed tag
    # is logged but not fatal — the mint/sling below still proceeds; worst
    # case a later orphan sweep simply can't see this one bead by tag (same
    # exposure as before this fix existed).
    #
    # review fk-wmhr96 BLOCKING-2 (acceptance fk-s0cniq, code-review
    # fk-7ai3uo BLOCKING-1): scope with --city/--rig like every sibling gc
    # call in this block (bd list above, bd create above, sling below).
    # Cross-rig repair routing is the normal case (rig is parsed from
    # ST_REPAIR_ROUTE and commonly differs from the watchdog's own
    # city/rig) — an unscoped bd update can route to the wrong store,
    # leaving the newly minted bead untagged in its real target rig, which
    # defeats this sweep's own mechanism for the watchdog's own mints.
    # review fk-wmhr96 LOW-3 (SRE): also bound by cv_with_timeout, folded
    # into this same fix pass since the line is already being touched for
    # the scoping fix above.
    cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" \
      "$GC" --city "$GC_CITY" --rig "$rig" bd update "$new_bead_id" --set-metadata "gc.repair_dedup_key=${dedup_key}" >/dev/null 2>&1 \
      || echo "con-voyage-repair-watchdog: WARNING: failed to tag ${new_bead_id} with gc.repair_dedup_key=${dedup_key}; a future orphan sweep for ${label} will not find it by tag" >&2

    if "$GC" --city "$GC_CITY" sling "$ST_REPAIR_ROUTE" "$new_bead_id" \
      --on con-voyage-ci-repair \
      --var "title=Watchdog re-dispatch: ${label}" \
      --var "pr=${ST_PR_NUMBER}" \
      --var "repo=${ST_REPO_FULL}" \
      --var "branch=${ST_BRANCH}" \
      --var "failure_kind=${ST_LAST_STATE}" \
      --var "cv_pr_author=${CV_PR_AUTHOR}" \
      --var "cv_author_gate=${CV_AUTHOR_GATE}" \
      --var "cv_conflict_strategy=${CV_CONFLICT_STRATEGY}" \
      --var "repair_bead=${new_bead_id}" \
      2>&1; then
      state_write "$dedup_key" "" "$new_bead_id" "$ST_LAST_STATE" \
        "$ST_PR_AUTHOR" "$ST_REPAIR_ROUTE" "$ST_REPO_FULL" "$ST_PR_NUMBER" "$ST_BRANCH" \
        "$new_attempt_count" "0" "$(now_iso8601)"
    else
      echo "con-voyage-repair-watchdog: WARNING: fallback sling failed for ${label} (bead ${new_bead_id}); will retry next cycle" >&2
    fi
  else
    # STALLED (implementor alive): re-notify the SAME implementor directly.
    # No new bead, and the CURRENTLY tracked bead is left open and still
    # tracked — its own updated_at is the ongoing progress signal the next
    # watchdog cycle will check.
    echo "con-voyage-repair-watchdog: ${action_desc} ${label} — re-notifying ${ST_IMPLEMENTOR} (attempt ${new_attempt_count}/${CV_MAX_ATTEMPTS})"
    if "$GC" --city "$GC_CITY" mail send "$ST_IMPLEMENTOR" \
      -s "Rework stalled: ${label} (${ST_LAST_STATE})" \
      -m "Watchdog: rework for ${label} (branch ${ST_BRANCH}) has shown no progress in over ${CV_STALL_SECONDS}s. Re-dispatching to you as the PR's implementor. Attempt ${new_attempt_count}/${CV_MAX_ATTEMPTS}." \
      --notify 2>&1; then
      state_write "$dedup_key" "$ST_IMPLEMENTOR" "$ST_INFLIGHT" "$ST_LAST_STATE" \
        "$ST_PR_AUTHOR" "$ST_REPAIR_ROUTE" "$ST_REPO_FULL" "$ST_PR_NUMBER" "$ST_BRANCH" \
        "$new_attempt_count" "0" "$(now_iso8601)"
    else
      echo "con-voyage-repair-watchdog: WARNING: mail to implementor ${ST_IMPLEMENTOR} failed for ${label}; will retry next cycle" >&2
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main loop: iterate every per-PR state record under CV_STATE_DIR. Glob-safe
# against an empty/missing directory (mirrors con-voyage-pr-watch.sh's own
# `[ -f "$x" ] || continue` idiom for a possibly-empty glob). Each record is
# processed under its own per-dedup_key lock (fk-11yuv Fix 2b — see header) so
# a concurrent invocation never races this one on the same PR.
# ---------------------------------------------------------------------------
for state_file in "${CV_STATE_DIR}"/*.state; do
  [ -f "$state_file" ] || continue

  dedup_key="${state_file##*/}"
  dedup_key="${dedup_key%.state}"

  if ! acquire_lock "$dedup_key"; then
    echo "con-voyage-repair-watchdog: SKIP ${dedup_key} — locked by a concurrent watchdog run"
    continue
  fi

  process_state_record "$dedup_key"

  release_lock "$dedup_key"
done

exit 0
