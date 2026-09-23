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
# # Unlike con-voyage-pr-watch.sh and con-voyage-ci-repair-guard.sh, this    #
# # script makes NO GitHub API calls of its own (see Task 0 spike notes      #
# # below): its only signal is the local per-PR state record that           #
# # con-voyage-pr-watch.sh already wrote under CV_STATE_DIR, which already   #
# # carries the resolved `pr_author` from THAT script's own author-scoped    #
# # dispatch. Checking it again here is defense in depth, not the primary    #
# # gate — see the design rationale in con-voyage-pr-watch.sh's HARD         #
# # INVARIANT banner for why an earlier unscoped monitor got the operator    #
# # removed from an org.                                                    #
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
#      — it never calls `gc github pr backfill` or any `gh` command for its
#      core logic (only the optional CV_PR_AUTHOR auto-resolve fallback does).
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
# Environment / configuration (all optional with sane defaults):
#
#   GC                Path to the gc binary (default: gc)
#   GH                Path to the gh binary (default: gh) — ONLY ever invoked
#                     to resolve the CV_PR_AUTHOR default (see below); this
#                     script makes no other GitHub calls, so gh need not even
#                     be installed when CV_PR_AUTHOR is set explicitly (it
#                     always is in the shipped order — see the .toml).
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
#                     unchanged) before a rework is considered stalled.
#                     Default: 900 (15 minutes).
#   CV_MAX_ATTEMPTS   Consecutive watchdog re-dispatches allowed for the SAME
#                     problem cycle before escalating instead. Default: 3.
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
CV_MAX_ATTEMPTS="${CV_MAX_ATTEMPTS:-3}"
CV_ESCALATE_TARGET="${CV_ESCALATE_TARGET:-human}"
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
case "$CV_MAX_ATTEMPTS" in
  *[!0-9]*|'') CV_MAX_ATTEMPTS="3" ;;
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

# ---------------------------------------------------------------------------
# Main loop: iterate every per-PR state record under CV_STATE_DIR. Glob-safe
# against an empty/missing directory (mirrors con-voyage-pr-watch.sh's own
# `[ -f "$x" ] || continue` idiom for a possibly-empty glob).
# ---------------------------------------------------------------------------
for state_file in "${CV_STATE_DIR}"/*.state; do
  [ -f "$state_file" ] || continue

  dedup_key="${state_file##*/}"
  dedup_key="${dedup_key%.state}"

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
    continue
  fi

  # HARD INVARIANT — AUTHOR SCOPING (defensive re-check; see header). An
  # empty/unresolved pr_author (e.g. a pre-Fix-2 record con-voyage-pr-watch.sh
  # has not yet rewritten) is treated as "not verifiably ours" and skipped —
  # fail closed, exactly like every other author gate in this pack.
  if [ -z "${ST_PR_AUTHOR// /}" ] || [ "$ST_PR_AUTHOR" != "$CV_PR_AUTHOR" ]; then
    echo "con-voyage-repair-watchdog: SKIP ${dedup_key} — author scoping (pr_author='${ST_PR_AUTHOR}' != CV_PR_AUTHOR='${CV_PR_AUTHOR}')"
    continue
  fi

  # "stop re-dispatching that one" — a prior cycle already escalated this
  # exact problem cycle to a human; do nothing further (including no repeated
  # escalation mail) until con-voyage-pr-watch.sh records a genuinely fresh
  # dispatch (which resets escalated=0).
  if [ "$ST_ESCALATED" = "1" ]; then
    echo "con-voyage-repair-watchdog: SKIP ${label} — already escalated; not re-dispatching"
    continue
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
      continue
    fi

    if [ "$implementor_known" -eq 1 ] && [ "$alive" -eq 0 ]; then
      # Acceptance: "Implementor dead + in-flight rework -> assigns a new
      # implementor (re-dispatch)." No staleness threshold gates this case —
      # a confirmed-dead session is an unambiguous signal on its own.
      needs_action=1
      use_fallback=1
      action_desc="DEAD"
    elif is_stale "$tracked_updated_at" "$CV_STALL_SECONDS"; then
      needs_action=1
      if [ "$implementor_known" -eq 1 ]; then
        # Acceptance: "Rework stalled past threshold, implementor alive ->
        # supersede + re-dispatch to same implementor."
        use_fallback=0
        action_desc="STALLED (implementor alive)"
      else
        # No implementor was ever known and the fallback bead has sat unclaimed
        # past the threshold — nobody ever picked it up. Same remedy as a dead
        # implementor: a fresh fallback dispatch.
        use_fallback=1
        action_desc="STALLED (never claimed)"
      fi
    fi
  fi

  if [ "$needs_action" -eq 0 ]; then
    # Acceptance: "Implementor alive + rework progressing -> no action" (and
    # symmetrically, an unclaimed-but-still-fresh fallback bead within its
    # grace period, or a bead-less reuse whose last_dispatch_at is fresh).
    echo "con-voyage-repair-watchdog: OK ${label} — no action (implementor_known=${implementor_known} alive=${alive} updated_at=${tracked_updated_at} last_dispatch_at=${ST_LAST_DISPATCH_AT})"
    continue
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
    continue
  fi

  new_attempt_count=$((ST_ATTEMPT_COUNT + 1))

  if [ "$use_fallback" -eq 1 ]; then
    # Missing redispatch context (e.g. a record predating this watchdog's
    # schema fields) — never guess at where/what to re-dispatch. Leave the
    # attempt counter untouched: this was not a real attempt.
    if [ -z "${ST_REPAIR_ROUTE// /}" ] || [ -z "${ST_REPO_FULL// /}" ] || [ -z "${ST_PR_NUMBER// /}" ]; then
      echo "con-voyage-repair-watchdog: WARNING: ${label} is ${action_desc} but its state record is missing repair_route/repo_full/pr_number; cannot safely re-dispatch (will re-check next cycle once con-voyage-pr-watch.sh repopulates it)" >&2
      continue
    fi
    rig="${ST_REPAIR_ROUTE%%/*}"
    if [ "$rig" = "$ST_REPAIR_ROUTE" ] || [ -z "$rig" ]; then
      echo "con-voyage-repair-watchdog: WARNING: ${label} repair_route '${ST_REPAIR_ROUTE}' has no '<rig>/' prefix; cannot derive a target rig; skipping re-dispatch" >&2
      continue
    fi

    echo "con-voyage-repair-watchdog: ${action_desc} ${label} — reassigning to a new implementor (attempt ${new_attempt_count}/${CV_MAX_ATTEMPTS})"
    # tracked_status is already known here for the tracked-bead branch (it was
    # fetched above to decide DEAD/STALLED) — pass it through to skip a
    # redundant second `bd show` for the same bead. Empty for the bead-less
    # branch, where close_if_open no-ops immediately on the empty bead id
    # anyway (no lookup is ever made either way).
    close_if_open "$ST_INFLIGHT" "superseded: watchdog reassigning ${label} (${action_desc})" "" "$tracked_status"

    new_bead_id=$("$GC" --city "$GC_CITY" --rig "$rig" bd create \
      "Watchdog re-dispatch: GitHub PR ${label} (${ST_LAST_STATE})" \
      --priority 1 --silent 2>/dev/null || true)

    if [ -z "${new_bead_id// /}" ]; then
      echo "con-voyage-repair-watchdog: WARNING: failed to create a fallback repair bead for ${label}; will retry next cycle" >&2
      continue
    fi

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
done

exit 0
