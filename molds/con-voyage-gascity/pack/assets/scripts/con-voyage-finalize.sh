#!/usr/bin/env bash
# con-voyage-finalize.sh — work-bead finalize monitor (fk-hsca, the teardown
# side of fk-p7j9's work-bead lifecycle) AND repair-bead finalize sweep
# (fk-f1vp FIX-B — see "REPAIR-STATE SWEEP" below).
#
# ############################################################################
# # HARD INVARIANT — AUTHOR SCOPING                                          #
# #                                                                          #
# # This monitor MUST only ever act on per-PR finalize records whose         #
# # recorded `pr_author` is the single configured user CV_PR_AUTHOR. It      #
# # takes no action — not even closing a work bead — on any other record.    #
# #                                                                          #
# # The finalize records it reads were written by con-voyage's own publish   #
# # step for PRs the operator's own con-voyage opened, so they already carry #
# # the operator's login; re-checking here is defense in depth. The same     #
# # org-removal incident that hardened con-voyage-pr-watch.sh's author gate  #
# # applies: an unscoped monitor that closed/commented on other people's     #
# # work is exactly what got the operator removed from an org. Fail closed.  #
# ############################################################################
#
# THE GAP THIS CLOSES (operator report, fk-hsca): con-voyage runs complete but
# the WORK BEAD is never finalized. con-voyage-pr-watch.sh polls only OPEN PRs
# (for CI-repair + comment routing); its only merged/closed handling is GC of
# stale comment-dedup files. Nothing closes the work bead, closes the convoy,
# releases the long-lived implementor, or removes the per-PR record when a PR
# lands. Concretely, fk-eiw/#29 and fk-wgl/#27 sat `open` for ~2 days after
# their PRs merged. This monitor is that missing teardown.
#
# HOW IT WORKS: con-voyage's publish step writes a per-PR ".finalize" record
# under CV_STATE_DIR for EVERY PR it opens (work_bead, convoy_id, repo_full,
# pr_number, pr_author, implementor_session — see finalize_read/_write in
# con-voyage-lib.sh). This monitor globs those records and, per record:
#
#   1. Author-scope check (skip records not authored by CV_PR_AUTHOR).
#   2. Poll the PR's terminal state via ONE `gh pr view` (pr_finalize_state).
#   3. MERGED / CLOSED-without-merge:
#        - close the WORK BEAD with an accurate reason
#          ("landed: PR #N merged" | "abandoned: PR #N closed without merge")
#        - close the con-voyage convoy (convoy_id) if still open
#        - RELEASE the long-lived implementor (best-effort mail; this monitor
#          never force-kills a session — see the release note below)
#        - remove the ".finalize" record (its job is done)
#      All idempotent: a re-poll after the record is gone is a clean no-op, and
#      re-closing an already-closed bead/convoy is guarded by close_if_open.
#   4. Still OPEN: reflect the PR's live phase on the work bead as a `cv=`
#      dimension label so the dashboard shows where the PR is — `awaiting_merge`
#      when clean, `repairing` when CI is red / a rebase is needed. Idempotent
#      via the record's last_phase (no redundant set-state when unchanged).
#   5. Unknown state (gh error): FAIL SAFE — leave everything untouched, retry
#      next cycle. Never close a work bead on an unresolved PR state.
#
# This monitor NEVER merges, force-pushes, comments on a PR, or kills a
# session. It only closes beads/convoys the operator's own con-voyage created,
# reflects phase, and mails the implementor a release note.
#
# REPAIR-STATE SWEEP (fk-f1vp FIX-B): the loop above only ever reads
# ".finalize" records — con-voyage-pr-watch.sh/con-voyage-repair-watchdog.sh
# separately track CI-repair beads in ".state" records (inflight_rework=...)
# under the SAME CV_STATE_DIR, which this monitor never enumerated. So a
# monitored PR's repair bead(s) never closed on merge/close — the exact orphan
# class as kots#6067's 15 beads (cleaned by hand) and fk-eiw/#29, fk-wgl/#27.
# A second pass below globs those SAME ".state" records and, per record whose
# PR has reached a terminal state, closes the tracked repair bead
# ("superseded: PR #N merged" | "superseded: PR #N closed"), sweeps any
# sibling ".state" record for the identical repo+PR (never leave a
# differently-keyed record's own bead behind), and removes the record(s). A
# still-OPEN PR is untouched here — con-voyage-repair-watchdog.sh's own
# dead/stalled/escalate logic owns that case exclusively, so as not to race it.
#
# Environment / configuration (all optional with sane defaults):
#
#   GC              Path to the gc binary (default: gc)
#   GH              Path to the gh binary (default: gh)
#   GC_CITY         Local checkout root used only to compute CV_STATE_DIR's
#                   default (default: current directory). No longer passed to
#                   gc as --city (fk-7v3r) — bd/mail calls below rely on gc's
#                   own cwd-based store auto-detection instead.
#   CV_STATE_DIR    Directory holding the per-PR finalize records this script
#                   reads (default: .gc/cv-pr-watch — MUST match the dir
#                   con-voyage's publish step writes them to; that is the same
#                   default con-voyage-pr-watch.sh uses).
#   CV_PR_AUTHOR    REQUIRED (author-scoping). The single GitHub login whose
#                   PRs this monitor may act on. Defaults to the authenticated
#                   gh login. FAILS CLOSED (exit 1) if unresolved.
#   CV_RELEASE_IMPLEMENTOR  When "1" (default), mail the recorded implementor a
#                   release note on finalize. Set "0" to skip the release mail
#                   (the bead/convoy close still happens).
#
# Exit codes:
#   0 — completed (some, all, or none of the records needed action)
#   Non-zero — fatal setup error (gc/python3 missing, CV_PR_AUTHOR unresolved)
#
# The order controller treats any non-zero exit as a transient failure and
# retries on the next cooldown interval.
#
# Requires: bash 4+, gc CLI, gh CLI (authenticated), python3.

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
CV_RELEASE_IMPLEMENTOR="${CV_RELEASE_IMPLEMENTOR:-1}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-finalize: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi

if ! command -v "$GH" >/dev/null 2>&1; then
  echo "con-voyage-finalize: ERROR: gh CLI not found at '${GH}'. Install github.com/cli/cli." >&2
  exit 1
fi

if ! "$GH" auth status >/dev/null 2>&1; then
  echo "con-voyage-finalize: ERROR: gh is not authenticated. Run 'gh auth login' or set GITHUB_TOKEN." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-finalize: ERROR: python3 not found; required for state/JSON parsing." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the CV_PR_AUTHOR default (guarded — this script does not use `set -e`,
# but the command substitution is guarded with `|| true` for parity with
# con-voyage-pr-watch.sh so a missing/unauthenticated gh produces an empty,
# cleanly-handled value rather than aborting mid-line).
# ---------------------------------------------------------------------------
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  CV_PR_AUTHOR="$("$GH" api user --jq .login 2>/dev/null || true)"
fi

# FAIL-CLOSED author-scoping guard (see HARD INVARIANT above).
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  echo "con-voyage-finalize: FATAL: CV_PR_AUTHOR is empty/unresolved." >&2
  echo "con-voyage-finalize: author-scoping is mandatory — refusing to act on any record." >&2
  echo "con-voyage-finalize: set CV_PR_AUTHOR explicitly (e.g. CV_PR_AUTHOR=kriscoleman)." >&2
  exit 1
fi
echo "con-voyage-finalize: author-scoped to PRs authored by '${CV_PR_AUTHOR}' (all other records are ignored)"

mkdir -p "$CV_STATE_DIR"

# Shared helpers (finalize_read/_write, cv_resolve_work_bead,
# cv_close_reason_for_pr, pr_finalize_state, bead_status, close_if_open,
# cv_default_state_dir) were sourced above, before CV_STATE_DIR's default was
# computed — see con-voyage-lib.sh for the authoritative record/field docs.
# Shared with con-voyage-pr-watch.sh and con-voyage-repair-watchdog.sh.

# set_work_bead_phase WORK_BEAD PHASE — set the `cv=<phase>` dimension on the
# work bead (renders as a `cv:<phase>` dashboard label). Best-effort: a failure
# is logged and ignored (phase is cosmetic; it must never abort finalize).
set_work_bead_phase() {
  local work_bead="$1" phase="$2"
  [ -n "${work_bead// /}" ] && [ -n "${phase// /}" ] || return 0
  "$GC" bd set-state "$work_bead" "cv=${phase}" \
    --reason "con-voyage-finalize: PR phase ${phase}" >/dev/null 2>&1 \
    || echo "con-voyage-finalize: WARNING: could not set cv=${phase} on ${work_bead}" >&2
}

# pr_live_phase REPO PR_NUMBER — for an OPEN PR, classify its live phase as
# "repairing" (a real defect: a failed check, DIRTY conflict, or BEHIND base)
# or "awaiting_merge" (clean / only awaiting human review). Prints the phase,
# or empty on a gh error (caller leaves the phase unchanged). Mirrors the
# actionable-vs-awaiting-human signal con-voyage-pr-watch.sh's PART A uses.
pr_live_phase() {
  local repo="$1" pr_number="$2"
  case "$pr_number" in
    ''|*[!0-9]*) return 0 ;;
  esac
  local json
  json=$("$GH" pr view "$pr_number" --repo "$repo" \
    --json mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null) || json=""
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(d, dict):
    raise SystemExit(0)
mergeable = (d.get('mergeable') or '').upper()
merge_state = (d.get('mergeStateStatus') or '').upper()
checks = d.get('statusCheckRollup') or []
def is_bad(c):
    conclusion = c.get('conclusion')
    if conclusion is not None:
        return str(conclusion).upper() in ('FAILURE', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE')
    state = c.get('state')
    if state is not None:
        return str(state).upper() in ('FAILURE', 'ERROR')
    return False
checks_failing = any(is_bad(c) for c in checks)
needs_repair = checks_failing or mergeable == 'CONFLICTING' or merge_state in ('DIRTY', 'BEHIND')
print('repairing' if needs_repair else 'awaiting_merge')
"
}

# ---------------------------------------------------------------------------
# Main loop: iterate every per-PR finalize record under CV_STATE_DIR. Glob-safe
# against an empty/missing directory (same idiom as the other two scripts).
# ---------------------------------------------------------------------------
for finalize_file in "${CV_STATE_DIR}"/*.finalize; do
  [ -f "$finalize_file" ] || continue

  dedup_key="${finalize_file##*/}"
  dedup_key="${dedup_key%.finalize}"

  finalize_read "$dedup_key"

  label="${dedup_key}"
  if [ -n "${FS_REPO_FULL// /}" ] && [ -n "${FS_PR_NUMBER// /}" ]; then
    label="${FS_REPO_FULL}#${FS_PR_NUMBER}"
  fi

  # A record missing the fields we need to act is not safe to act on. Leave it
  # for the next cycle (publish may still be repopulating it) — never guess.
  if [ -z "${FS_WORK_BEAD// /}" ] || [ -z "${FS_REPO_FULL// /}" ] || [ -z "${FS_PR_NUMBER// /}" ]; then
    echo "con-voyage-finalize: SKIP ${dedup_key} — record missing work_bead/repo_full/pr_number; deferring"
    continue
  fi

  # HARD INVARIANT — AUTHOR SCOPING (defensive re-check; see header). An
  # empty/unresolved pr_author is treated as "not verifiably ours" and skipped
  # — fail closed, exactly like every other author gate in this pack.
  if [ -z "${FS_PR_AUTHOR// /}" ] || [ "$FS_PR_AUTHOR" != "$CV_PR_AUTHOR" ]; then
    echo "con-voyage-finalize: SKIP ${dedup_key} — author scoping (pr_author='${FS_PR_AUTHOR}' != CV_PR_AUTHOR='${CV_PR_AUTHOR}')"
    continue
  fi

  # Poll the PR's terminal state (ONE gh call). Fail safe on unknown.
  IFS=$'\x1f' read -r pr_state _merged_at _closed_at <<< "$(pr_finalize_state "$FS_REPO_FULL" "$FS_PR_NUMBER")"

  if [ -z "${pr_state// /}" ]; then
    echo "con-voyage-finalize: SKIP ${label} — PR state unresolved (gh error?); retrying next cycle" >&2
    continue
  fi

  case "$pr_state" in
    OPEN)
      # Still open — reflect the live phase on the work bead (idempotent).
      live_phase="$(pr_live_phase "$FS_REPO_FULL" "$FS_PR_NUMBER")"
      if [ -n "${live_phase// /}" ] && [ "$live_phase" != "$FS_LAST_PHASE" ]; then
        echo "con-voyage-finalize: ${label} still OPEN — phase ${FS_LAST_PHASE:-<none>} -> ${live_phase} on work bead ${FS_WORK_BEAD}"
        set_work_bead_phase "$FS_WORK_BEAD" "$live_phase"
        finalize_write "$dedup_key" "$FS_WORK_BEAD" "$FS_CONVOY_ID" "$FS_REPO_FULL" \
          "$FS_PR_NUMBER" "$FS_PR_AUTHOR" "$FS_IMPLEMENTOR" "$live_phase"
      else
        echo "con-voyage-finalize: OK ${label} — still OPEN, phase unchanged (${FS_LAST_PHASE:-<none>})"
      fi
      continue
      ;;
    MERGED|CLOSED)
      : # fall through to finalize
      ;;
    *)
      echo "con-voyage-finalize: SKIP ${label} — unexpected PR state '${pr_state}'; retrying next cycle" >&2
      continue
      ;;
  esac

  # ---- Terminal: MERGED or CLOSED-without-merge -> finalize teardown --------
  reason="$(cv_close_reason_for_pr "$pr_state" "$FS_PR_NUMBER")"
  echo "con-voyage-finalize: FINALIZE ${label} — PR ${pr_state}; closing work bead ${FS_WORK_BEAD} (${reason})"

  # 1. Close the work bead (idempotent — no-op if already closed).
  close_if_open "$FS_WORK_BEAD" "$reason"
  work_bead_close_rc="$CV_CLOSE_RC"

  # 2. Close the con-voyage convoy if we recorded one and it is still open. A
  #    synthetic input convoy autocloses when its tracked work bead closes, but
  #    close it explicitly too (idempotent) so a non-autoclosing convoy is not
  #    left dangling.
  convoy_close_rc=0
  if [ -n "${FS_CONVOY_ID// /}" ] && [ "$FS_CONVOY_ID" != "$FS_WORK_BEAD" ]; then
    close_if_open "$FS_CONVOY_ID" "con-voyage finalized: ${reason}"
    convoy_close_rc="$CV_CLOSE_RC"
  fi

  # 3. Release the long-lived implementor (best-effort mail). This monitor
  #    NEVER force-kills a session: the implementor may be shared or mid-task on
  #    unrelated work, and we cannot prove exclusive ownership from a finalize
  #    record alone (same reticence con-voyage-repair-watchdog.sh applies to
  #    sessions). A release NOTE lets the session (or its supervisor) reclaim
  #    the slot; the bead/convoy close is what actually ends the work.
  if [ "$CV_RELEASE_IMPLEMENTOR" = "1" ] && [ -n "${FS_IMPLEMENTOR// /}" ]; then
    if "$GC" mail send "$FS_IMPLEMENTOR" \
      -s "con-voyage finalized: ${label}" \
      -m "PR ${label} is ${pr_state}. The work bead ${FS_WORK_BEAD} and its convoy are closed (${reason}). You are released from this con-voyage — no further rework is expected. If you are idle, you may drain." \
      2>&1; then
      echo "con-voyage-finalize: released implementor ${FS_IMPLEMENTOR} for ${label}"
    else
      echo "con-voyage-finalize: WARNING: release mail to ${FS_IMPLEMENTOR} failed for ${label} (continuing; bead/convoy already closed)" >&2
    fi
  fi

  # 4. Remove the finalize record — ONLY once every close attempted this cycle
  #    actually succeeded (fk-7v3r: close_if_open used to swallow a failed `bd
  #    close`'s exit status, so this removal ran unconditionally and deleted
  #    the retry record on the very first close failure — self-destructing the
  #    idempotent-retry safety net). A failed close leaves the record in place
  #    so the next cycle retries close_if_open against the still-open bead(s);
  #    re-running a close that already succeeded is a safe no-op. Do this LAST
  #    so a crash before here just re-runs the (idempotent) close next cycle.
  if [ "$work_bead_close_rc" -eq 0 ] && [ "$convoy_close_rc" -eq 0 ]; then
    rm -f "$finalize_file"
    echo "con-voyage-finalize: done ${label} — finalize record removed"
  else
    echo "con-voyage-finalize: WARNING: ${label} — bd close failed (work_bead_rc=${work_bead_close_rc}, convoy_rc=${convoy_close_rc}); keeping finalize record for retry next cycle" >&2
  fi
done

# ---------------------------------------------------------------------------
# Repair-state sweep (fk-f1vp FIX-B) — see the REPAIR-STATE SWEEP header
# comment above. Iterates the SAME per-PR ".state" records con-voyage-pr-
# watch.sh/con-voyage-repair-watchdog.sh read and write. Glob-safe against an
# empty/missing directory, same idiom as every loop in this pack.
# ---------------------------------------------------------------------------
for state_file in "${CV_STATE_DIR}"/*.state; do
  [ -f "$state_file" ] || continue

  dedup_key="${state_file##*/}"
  dedup_key="${dedup_key%.state}"

  state_read "$dedup_key"
  # Capture before the sibling-sweep loop below re-runs state_read and
  # clobbers these same ST_* globals.
  # ST_REPO_FULL/ST_PR_NUMBER are state_read's own globals (con-voyage-lib.sh),
  # not a typo for finalize_read's FS_REPO_FULL/FS_PR_NUMBER.
  # shellcheck disable=SC2153
  primary_repo_full="$ST_REPO_FULL"
  # shellcheck disable=SC2153
  primary_pr_number="$ST_PR_NUMBER"
  primary_pr_author="$ST_PR_AUTHOR"
  primary_inflight="$ST_INFLIGHT"

  label="${dedup_key}"
  if [ -n "${primary_repo_full// /}" ] && [ -n "${primary_pr_number// /}" ]; then
    label="${primary_repo_full}#${primary_pr_number}"
  fi

  # A record missing the fields needed to poll a terminal state is not safe to
  # act on — defer to the next cycle (e.g. still being populated, or a
  # bead-less "clean" record with nothing to poll for).
  if [ -z "${primary_repo_full// /}" ] || [ -z "${primary_pr_number// /}" ]; then
    echo "con-voyage-finalize: SKIP ${dedup_key} — repair record missing repo_full/pr_number; deferring"
    continue
  fi

  # HARD INVARIANT — AUTHOR SCOPING (defensive re-check; see header). Mirrors
  # the ".finalize" loop's own gate above.
  if [ -z "${primary_pr_author// /}" ] || [ "$primary_pr_author" != "$CV_PR_AUTHOR" ]; then
    echo "con-voyage-finalize: SKIP ${dedup_key} — repair record author scoping (pr_author='${primary_pr_author}' != CV_PR_AUTHOR='${CV_PR_AUTHOR}')"
    continue
  fi

  # Poll the PR's terminal state (ONE gh call). Fail safe on unknown.
  IFS=$'\x1f' read -r pr_state _merged_at _closed_at <<< "$(pr_finalize_state "$primary_repo_full" "$primary_pr_number")"

  if [ -z "${pr_state// /}" ]; then
    echo "con-voyage-finalize: SKIP ${label} — repair record PR state unresolved (gh error?); retrying next cycle" >&2
    continue
  fi

  case "$pr_state" in
    OPEN)
      # Acceptance: "PR still OPEN -> no-op." con-voyage-repair-watchdog.sh
      # owns dead/stalled/escalate handling while the PR is open; racing it
      # here would risk double-dispatch/double-close.
      echo "con-voyage-finalize: OK ${label} — repair record, PR still OPEN (watchdog owns dead/stalled handling)"
      continue
      ;;
    MERGED|CLOSED)
      : # fall through to teardown
      ;;
    *)
      echo "con-voyage-finalize: SKIP ${label} — repair record, unexpected PR state '${pr_state}'; retrying next cycle" >&2
      continue
      ;;
  esac

  # ---- Terminal: MERGED or CLOSED-without-merge -> close the repair bead ---
  repair_reason="$(cv_repair_close_reason_for_pr "$pr_state" "$primary_pr_number")"
  echo "con-voyage-finalize: FINALIZE ${label} — repair record, PR ${pr_state}; closing tracked repair bead ${primary_inflight:-<none>} (superseded: ${repair_reason})"
  cv_bead_close "$primary_inflight" "superseded" "$repair_reason"

  # Sweep sibling records: any OTHER ".state" file for the IDENTICAL repo+PR
  # (e.g. a stale/differently-keyed record) must never leave its own tracked
  # bead open or its own record lingering. Acceptance: "sibling orphan repair
  # beads exist for the same merged PR -> swept closed too."
  for sibling_file in "${CV_STATE_DIR}"/*.state; do
    [ -f "$sibling_file" ] || continue
    [ "$sibling_file" != "$state_file" ] || continue
    sibling_key="${sibling_file##*/}"
    sibling_key="${sibling_key%.state}"
    state_read "$sibling_key"
    [ "$ST_REPO_FULL" = "$primary_repo_full" ] && [ "$ST_PR_NUMBER" = "$primary_pr_number" ] || continue
    # Defensive author re-check on the sibling too — same HARD INVARIANT
    # posture as every other gate in this pack.
    if [ -z "${ST_PR_AUTHOR// /}" ] || [ "$ST_PR_AUTHOR" != "$CV_PR_AUTHOR" ]; then
      continue
    fi
    echo "con-voyage-finalize: FINALIZE ${label} — sweeping sibling repair record ${sibling_key} (bead ${ST_INFLIGHT:-<none>})"
    cv_bead_close "$ST_INFLIGHT" "superseded" "$repair_reason"
    rm -f "$sibling_file"
  done

  # Remove the primary record LAST — a crash before here just re-runs the
  # (idempotent) close next cycle, same posture as the ".finalize" loop above.
  rm -f "$state_file"
  echo "con-voyage-finalize: done ${label} — repair .state record removed"
done

echo "con-voyage-finalize: done"
exit 0
