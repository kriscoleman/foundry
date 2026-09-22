# shellcheck shell=bash
# con-voyage-lib.sh — shared per-PR state/dispatch helpers for
# con-voyage-pr-watch.sh (Fix 1), con-voyage-repair-watchdog.sh (Fix 2), and
# con-voyage-review-watchdog.sh (fk-loo1 FIX-F, review-lane liveness).
#
# The first two scripts read and write the SAME per-PR state record format under
# CV_STATE_DIR (see the field-by-field doc comment on state_read below) and
# share the same author-scoping/session-liveness primitives. This file is
# sourced, not executed — it defines functions only and has no shebang-level
# side effects (no `set -...`, so it never overrides either caller's own
# shell-option choice: con-voyage-pr-watch.sh runs `set -euo pipefail`,
# con-voyage-repair-watchdog.sh runs `set -uo pipefail` without `-e`).
#
# Callers must already have GC set (each caller resolves it in its own
# Configuration block before sourcing this file) — every function below reads
# it as a global at CALL time, not at source time.
#
# Bead/mail calls below intentionally omit --city/--rig (fk-7v3r): passing
# --city alone routed an already-rig-prefixed bead id to the CITY store
# instead of its owning rig's store, so bd show/close/update silently
# no-op'd against the wrong store ("Issue not found") — invisible because
# every helper here already fails safe (warns, never aborts). Every caller's
# cwd is already inside the correct rig checkout when these scripts run, so
# omitting both flags lets gc's own cwd-based store auto-detection resolve
# the right store instead.
#
# Requires: bash 4+, gc CLI, python3.

# ---------------------------------------------------------------------------
# Per-PR repair state record (fk-4o74 Fix 1; extended by Fix 2's watchdog,
# fk-lfan's B1 round). File: "<CV_STATE_DIR>/<dedup_key>.state", plain
# key=value lines:
#   implementor_session=<value, or empty if unknown>
#   inflight_rework=<tracked bead id, or empty>
#   last_handled_state=<failure_kind | clean | unknown>
#   pr_author=<the resolved PR author login at dispatch time, or empty>
#   repair_route=<the "<rig>/<agent>" pool route for this PR, or empty>
#   repo_full=<owner/repo, or empty>
#   pr_number=<PR number, or empty>
#   branch=<PR head ref, or empty>
#   attempt_count=<watchdog re-dispatch attempts against the CURRENT
#     inflight_rework (or bead-less reuse) cycle, default 0 — owned by
#     con-voyage-repair-watchdog.sh, this script only ever resets it (fresh
#     dispatch / clean) or preserves it (in-flight refresh). Coerced to a
#     validated base-10 integer on read — see state_read below. NOTE: one
#     counter serves two different actions by design — a STALLED+alive
#     re-notify (same implementor, same or no tracked bead — a "nudge") and a
#     DEAD/never-claimed fallback re-dispatch (a fresh implementor, a
#     superseded-and-reminted bead — a "re-mint") both increment it. This is
#     intentional, not a bug: CV_MAX_ATTEMPTS bounds total watchdog
#     intervention for one problem cycle regardless of which remedy was tried,
#     so a PR that alternates nudge/re-mint across cycles still escalates
#     after CV_MAX_ATTEMPTS total attempts rather than resetting the count
#     each time the remedy changes.>
#   escalated=<1 once the watchdog has escalated this PR's stalled rework to
#     the operator and stopped re-dispatching it, default 0 — owned by the
#     watchdog, this script only ever clears it (fresh dispatch / clean) or
#     preserves it (in-flight refresh). Coerced to a validated base-10
#     integer on read — see state_read below.>
#   last_dispatch_at=<ISO-8601 UTC timestamp of the last dispatch/re-notify
#     action for this record, or empty. Written by con-voyage-pr-watch.sh at
#     dispatch time and by con-voyage-repair-watchdog.sh at each re-notify.
#     This is the ONLY staleness signal available for a mail-only reuse
#     dispatch (inflight_rework empty, implementor_session set — Fix 1's
#     PRIMARY dispatch path): there is no tracked bead whose updated_at can
#     serve that role, so the watchdog keys off this field instead. Not
#     consulted while inflight_rework is non-empty (the tracked bead's own
#     updated_at is authoritative there).>
#
# pr_author/repair_route/repo_full/pr_number/branch exist so the watchdog can
# (a) defensively re-verify author scope from local state alone, with no gh
# call, before acting on a record, and (b) re-dispatch fallback work (mint a
# fresh pool bead) without re-deriving PR context. They are populated ONLY on
# a fresh dispatch (the only place con-voyage-pr-watch.sh has them all
# resolved) and are irrelevant whenever inflight_rework is empty AND
# implementor_session is empty (clean / never-dispatched), so that
# combination's write always writes them empty.
#
# Back-compat: a pre-existing "<dedup_key>.minted" file (the OLD, pre-Fix-1
# format, with no ".state" file yet) is read as inflight_rework=<that id>,
# implementor_session=<empty>, last_handled_state=unknown — "unknown" never
# matches a real observed state, so the first post-upgrade cycle re-evaluates
# the PR fresh instead of trusting stale pre-upgrade bookkeeping. A pre-Fix-2
# 3-field ".state" file (no pr_author/repair_route/etc.) reads those newer
# fields as empty and attempt_count/escalated/last_dispatch_at as their
# defaults.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # ST_* globals are consumed by the sourcing
# scripts (con-voyage-pr-watch.sh, con-voyage-repair-watchdog.sh), invisible
# to shellcheck when this file is checked standalone.

# ---------------------------------------------------------------------------
# Communal-duty reminder (PR #45 human review, fk-doh9): the mold's AGENTS.md
# states that every worker the pack dispatches — one-off, formula, order, or
# convoy — shares the duty to surface system-level trouble by mailing the
# mayor, not just the TDD implementor. AGENTS.md itself never reaches a
# dispatched worker (it lives at the mold root, outside pack/, so `ailloy
# cast` never ships it into a target rig) — the bead a worker claims is what
# actually reaches it. Every formula-dispatched task's text is a literal copy
# of this reminder appended to its description_file template (they are
# static assets, not shell, so they cannot source this constant directly —
# tests/agents-contract.test.sh diffs them against it instead, driven by the
# formulas' own description_file lists). cv_build_pr_feedback_body below is
# the one surface that composes a bead body in shell, so it is the one
# surface that references this constant instead of duplicating it.
CV_COMMUNAL_DUTY_REMINDER='You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.'

# ---------------------------------------------------------------------------
# Review-lane worktree isolation reminder (fk-q659 LIVE finding): every
# con-voyage review lane for a work item used to read the review context's
# recorded source-anchor work_dir and run its own verification directly
# inside that ONE shared directory. A lane doing mutate-run-revert
# verification (temporarily edit a file, run a command, revert) races another
# lane's concurrent build/test in the same directory, producing a false
# BLOCKING or false-negative finding. cv-review-lane-worktree.sh gives each
# lane its own throwaway linked git worktree instead. Like
# CV_COMMUNAL_DUTY_REMINDER above, every review-lane description_file carries
# a literal copy of this text (static assets, not shell, so they cannot
# source the constant directly) — tests/review-lane-worktree-isolation.test.sh
# diffs them against it, driven by the con-voyage-review-loop's own
# `[[template.children]]` list in the formula, not a hand-maintained lane list.
CV_REVIEW_LANE_WORKTREE_REMINDER='This review lane never runs a command that touches the implementation on disk directly inside the shared source-anchor work_dir recorded in the review context. Every active lane can read and execute against that same directory at the same time, so a local edit (including a temporary mutate-run-revert check) or a build/test invocation there can race a concurrent build or test run from another lane and produce a false BLOCKING or false-negative finding (fk-q659). Acquire your own private worktree copy first with `cv-review-lane-worktree.sh acquire`, and run every such command inside it instead — never inside the shared work_dir.'

# ---------------------------------------------------------------------------
# Shell-safety reminder (fk-k14n): the Bash tool runs the operator's zsh
# profile, not bash — zsh does NOT word-split unquoted parameter expansions
# by default, so a pattern that behaves correctly under bash/POSIX sh
# (`for x in $var`, `set -- $pair`) silently collapses to one iteration (or a
# no-op on empty input) under zsh instead of splitting on whitespace. It
# reads like a tool malfunction rather than a shell semantics difference, and
# has already cost real turns (a rig-hygiene loop, a research-sling loop).
# Distributed the same way as CV_COMMUNAL_DUTY_REMINDER, for the same reason
# documented in the comment above it: static template assets cannot source
# this constant directly, so tests/agents-contract.test.sh diffs them against
# it instead, driven by the formulas' own description_file lists.
# shellcheck disable=SC2016  # backticks/$VAR below are literal reminder text for the reader, not expansion
CV_SHELL_SAFETY_REMINDER='This Bash tool runs your zsh profile, not bash — zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array (`arr=(...)`; `for x in "${arr[@]}"`), an explicit split (`IFS=... read -r -a arr <<<"$var"`), or pipe through `xargs`/`while read`.'

# cv_build_pr_feedback_body PR_URL HEAD_REF FEEDBACK_SUMMARY IDEMPOTENCY_KEY
# Composes the routed bead body for a human-PR-comment routing event
# (con-voyage-pr-watch.sh Part B). Extracted out of the scan loop so it is
# directly unit-testable without re-running PR discovery.
cv_build_pr_feedback_body() {
  local pr_url="$1" head_ref="$2" feedback_summary="$3" idempotency_key="$4"
  cat <<BODY
New human review feedback on PR ${pr_url} (branch: ${head_ref}).

Please read and respond to the following comments. Address any requested
changes on the branch '${head_ref}' using TDD. Push the fix — do NOT merge.

New feedback:
${feedback_summary}

${CV_COMMUNAL_DUTY_REMINDER}

${CV_SHELL_SAFETY_REMINDER}

Routing from con-voyage-pr-watch (idempotency: ${idempotency_key})
BODY
}

state_read() {
  local dedup_key="$1"
  local state_file="${CV_STATE_DIR}/${dedup_key}.state"
  local legacy_file="${CV_STATE_DIR}/${dedup_key}.minted"
  ST_IMPLEMENTOR=""
  ST_INFLIGHT=""
  ST_LAST_STATE="unknown"
  ST_PR_AUTHOR=""
  ST_REPAIR_ROUTE=""
  ST_REPO_FULL=""
  ST_PR_NUMBER=""
  ST_BRANCH=""
  ST_ATTEMPT_COUNT="0"
  ST_ESCALATED="0"
  ST_LAST_DISPATCH_AT=""
  if [ -f "$state_file" ]; then
    local k v
    while IFS='=' read -r k v || [ -n "$k" ]; do
      case "$k" in
        implementor_session) ST_IMPLEMENTOR="$v" ;;
        inflight_rework) ST_INFLIGHT="$v" ;;
        last_handled_state) [ -n "$v" ] && ST_LAST_STATE="$v" ;;
        pr_author) ST_PR_AUTHOR="$v" ;;
        repair_route) ST_REPAIR_ROUTE="$v" ;;
        repo_full) ST_REPO_FULL="$v" ;;
        pr_number) ST_PR_NUMBER="$v" ;;
        branch) ST_BRANCH="$v" ;;
        attempt_count) [ -n "$v" ] && ST_ATTEMPT_COUNT="$v" ;;
        escalated) [ -n "$v" ] && ST_ESCALATED="$v" ;;
        last_dispatch_at) ST_LAST_DISPATCH_AT="$v" ;;
      esac
    done < "$state_file"
  elif [ -f "$legacy_file" ]; then
    ST_INFLIGHT="$(cat "$legacy_file" 2>/dev/null || true)"
  fi

  # SECURITY (fk-lfan B2): attempt_count/escalated are read from an on-disk
  # file this process does not exclusively own (con-voyage-pr-watch.sh and
  # con-voyage-repair-watchdog.sh both write it, under a predictable path).
  # Both fields are later used in bash arithmetic (`$((ST_ATTEMPT_COUNT + 1))`,
  # `-ge` comparisons), and bash arithmetic recursively expands anything that
  # LOOKS like an array subscript inside the expression — an
  # attacker-controlled value such as `dedup_key[$(touch /tmp/PWNED)]`
  # executes arbitrary commands (dedup_key is the watchdog's own already-bound
  # loop variable, which is what lets the subscript evaluate instead of
  # tripping `set -u`'s unbound-variable guard first — proven live). Coerce
  # both to a validated base-10 integer HERE, at read time, so no unvalidated
  # value ever reaches arithmetic context downstream. A non-digit value (or
  # empty) resets to "0" rather than aborting the whole pass — same fail-safe
  # posture as every other malformed-field guard in this pack.
  # Trim surrounding whitespace first so a space-padded value like "  7  "
  # still coerces to 7 instead of tripping the non-numeric fail-safe below
  # (only real non-digit content should hit the "0" reset).
  ST_ATTEMPT_COUNT="${ST_ATTEMPT_COUNT#"${ST_ATTEMPT_COUNT%%[![:space:]]*}"}"
  ST_ATTEMPT_COUNT="${ST_ATTEMPT_COUNT%"${ST_ATTEMPT_COUNT##*[![:space:]]}"}"
  ST_ESCALATED="${ST_ESCALATED#"${ST_ESCALATED%%[![:space:]]*}"}"
  ST_ESCALATED="${ST_ESCALATED%"${ST_ESCALATED##*[![:space:]]}"}"
  case "$ST_ATTEMPT_COUNT" in
    *[!0-9]*|'') ST_ATTEMPT_COUNT="0" ;;
  esac
  case "$ST_ESCALATED" in
    *[!0-9]*|'') ST_ESCALATED="0" ;;
  esac
}

# state_write DEDUP_KEY IMPLEMENTOR INFLIGHT LAST_STATE [PR_AUTHOR] [REPAIR_ROUTE]
#             [REPO_FULL] [PR_NUMBER] [BRANCH] [ATTEMPT_COUNT] [ESCALATED]
#             [LAST_DISPATCH_AT]
# The extended fields are optional (default empty / 0) so every pre-Fix-2
# call site keeps working unmodified; every call site in both scripts now
# passes them explicitly (either fresh values or the prior ones read back via
# state_read, per call site) so the choice to reset vs. preserve is visible at
# the call site, not hidden in here.
state_write() {
  local dedup_key="$1" implementor="$2" inflight="$3" last_state="$4"
  local pr_author="${5:-}" repair_route="${6:-}" repo_full="${7:-}"
  local pr_number="${8:-}" branch="${9:-}" attempt_count="${10:-0}" escalated="${11:-0}"
  local last_dispatch_at="${12:-}"
  local state_file="${CV_STATE_DIR}/${dedup_key}.state"
  {
    printf 'implementor_session=%s\n' "$implementor"
    printf 'inflight_rework=%s\n' "$inflight"
    printf 'last_handled_state=%s\n' "$last_state"
    printf 'pr_author=%s\n' "$pr_author"
    printf 'repair_route=%s\n' "$repair_route"
    printf 'repo_full=%s\n' "$repo_full"
    printf 'pr_number=%s\n' "$pr_number"
    printf 'branch=%s\n' "$branch"
    printf 'attempt_count=%s\n' "${attempt_count:-0}"
    printf 'escalated=%s\n' "${escalated:-0}"
    printf 'last_dispatch_at=%s\n' "$last_dispatch_at"
  } > "$state_file"
  rm -f "${CV_STATE_DIR}/${dedup_key}.minted"
}

# now_iso8601 — current UTC time in the same ISO-8601 'Z' format is_stale()
# (con-voyage-repair-watchdog.sh) parses. Used to stamp last_dispatch_at.
now_iso8601() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# bead_status BEAD_ID FIELD — prints "<status><0x1f><FIELD-value>". FIELD is
# any top-level key `bd show --json` returns (this pack only ever asks for
# "assignee" or "updated_at"). Empty SEP-only output for an empty bead id, a
# `bd show` failure, or a bead unknown to gc.
bead_status() {
  local bead_id="$1" field="$2"
  local SEP=$'\x1f'
  [ -n "${bead_id// /}" ] || { printf '%s' "$SEP"; return 0; }
  local json
  json=$("$GC" bd show "$bead_id" --json 2>/dev/null) || json=""
  if [ -z "$json" ]; then printf '%s' "$SEP"; return 0; fi
  printf '%s' "$json" | python3 -c "
import sys, json
SEP = '\x1f'
field = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print(SEP)
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    print(SEP)
    raise SystemExit(0)
print((data.get('status') or '') + SEP + (data.get(field) or ''))
" "$field" 2>/dev/null || printf '%s' "$SEP"
}

# implementor_alive SESSION_IDENT — exit 0 if a session matching this
# identifier (checked against id/alias/name/session_name) exists and is not
# closed (both active and suspended count — mail persists regardless, and
# --notify attempts a wake either way; see Task 0 findings).
implementor_alive() {
  local ident="$1"
  [ -n "${ident// /}" ] || return 1
  local json
  json=$("$GC" --city "$GC_CITY" session list --json 2>/dev/null) || json=""
  [ -n "$json" ] || return 1
  printf '%s' "$json" | python3 -c "
import sys, json
ident = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    sys.exit(1)
for s in sessions:
    if not isinstance(s, dict):
        continue
    idents = {s.get('id'), s.get('alias'), s.get('name'), s.get('session_name')}
    if ident in idents and (s.get('state') or '') != 'closed':
        sys.exit(0)
sys.exit(1)
" "$ident"
}

# session_id_for_ident IDENT — print the canonical session `id` of a live
# session (state != closed) whose id/alias/name/session_name matches IDENT.
# Empty output if none found. Shares implementor_alive's identity-matching
# rule but resolves to the `id` field specifically, since `gc session nudge`
# documents accepting only "a session ID or session alias" and a recorded
# identity (e.g. a bead's `assignee`) is often in the longer session_name
# form instead. Used by con-voyage-review-watchdog.sh (fk-loo1 FIX-F) to turn
# a claimed review-lane bead's assignee into a nudge-able session id.
session_id_for_ident() {
  local ident="$1"
  [ -n "${ident// /}" ] || return 0
  local json
  json=$("$GC" --city "$GC_CITY" session list --json 2>/dev/null) || json=""
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c "
import sys, json
ident = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    raise SystemExit(0)
for s in sessions:
    if not isinstance(s, dict):
        continue
    idents = {s.get('id'), s.get('alias'), s.get('name'), s.get('session_name')}
    if ident in idents and (s.get('state') or '') != 'closed':
        print(s.get('id') or '')
        raise SystemExit(0)
" "$ident"
}

# first_alive_session_id_for_route ROUTE — print the `id` of the first live
# session (state != closed) whose `template` equals ROUTE (the "<rig>/<role>"
# form recorded as a lane bead's gc.routed_to metadata). Empty output means
# the routed pool has no live session at all — the unambiguous "pool is
# drained" signal con-voyage-review-watchdog.sh uses to decide re-route
# (gc sling) vs. a direct nudge to an already-alive pool member.
first_alive_session_id_for_route() {
  local route="$1"
  [ -n "${route// /}" ] || return 0
  local json
  json=$("$GC" --city "$GC_CITY" session list --json 2>/dev/null) || json=""
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c "
import sys, json
route = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    raise SystemExit(0)
for s in sessions:
    if not isinstance(s, dict):
        continue
    if (s.get('template') or '') == route and (s.get('state') or '') != 'closed':
        print(s.get('id') or '')
        raise SystemExit(0)
" "$route"
}

# close_if_open BEAD_ID REASON [PR_LABEL] [KNOWN_STATUS] — closes BEAD_ID if
# it is currently open (any status other than empty/unknown or "closed").
# No-op if BEAD_ID is empty or already closed/unknown. When PR_LABEL is
# given, logs a standard SUPERSEDE line tagged with it (con-voyage-pr-watch.sh's
# 3 call sites, which share this one "read status, close if open, log"
# sequence across the clean-PR path, the genuinely-in-flight supersede, and
# the legacy stale-marker sweep); omitted, the caller logs its own labeled
# line instead (con-voyage-repair-watchdog.sh's call site). KNOWN_STATUS lets
# a caller that already fetched this SAME bead's status earlier in the same
# iteration (e.g. the watchdog's tracked-bead DEAD/STALLED branch, which
# already called `bead_status ... updated_at` to decide it needs closing)
# skip the redundant second `bd show` — when empty (the default), the status
# is fetched fresh, same as before.
#
# CV_CLOSE_RC (fk-7v3r): set on every call to the real `bd close` exit status
# — 0 for a no-op (empty id / already closed) and for a successful close,
# non-zero when `bd close` itself fails. The function's OWN return value
# stays 0 in every case: con-voyage-pr-watch.sh calls this as a bare statement
# under `set -e` and must never abort mid-scan over a single PR's failed
# close. A caller that must not proceed past a failed close (e.g.
# con-voyage-finalize.sh deleting its retry record) checks CV_CLOSE_RC
# immediately after the call instead of the call's own return code.
close_if_open() {
  local bead_id="$1" reason="$2" pr_label="${3:-}" known_status="${4:-}"
  CV_CLOSE_RC=0
  [ -n "${bead_id// /}" ] || return 0
  local status="$known_status"
  if [ -z "$status" ]; then
    IFS=$'\x1f' read -r status _ <<< "$(bead_status "$bead_id" assignee)"
  fi
  [ -n "$status" ] && [ "$status" != "closed" ] || return 0
  if "$GC" bd close "$bead_id" --reason "$reason" >/dev/null 2>&1; then
    if [ -n "$pr_label" ]; then
      echo "con-voyage-pr-watch: [PART A] ${pr_label}: closed prior open repair bead ${bead_id} (was status=${status})"
    fi
  else
    CV_CLOSE_RC=$?
    echo "close_if_open: WARNING: bd close failed for ${bead_id} (status=${status}, rc=${CV_CLOSE_RC}); leaving it open for retry" >&2
  fi
  return 0
}

# ===========================================================================
# GLOBAL BEAD-STATE-EVENT HELPERS (fk-7mw7 FIX-A)
#
# OPERATOR DIRECTIVE (north star): beads MUST update deterministically on
# formula STATE EVENTS as a GLOBAL pack norm — a step/work bead goes
# in_progress when its step starts (never left sitting at READY) and CLOSES on
# terminal (landed / abandoned / no-op / superseded). These two helpers are
# the foundation every workflow step in this pack should call at claim time
# and at each terminal exit, instead of hand-rolling `bd update`/`bd close`
# per call site. The primary consumer is con-voyage-ci-repair (the "Repair
# GitHub PR ..." bead that con-voyage-pr-watch.sh mints and slings the ci-repair
# formula onto): that workflow closed only `{{convoy_id}}` — a gc-internal
# work-item id, NOT the human-facing repair bead — at every exit, so the
# repair bead itself was left open forever. That was the #1 driver of a batch
# of orphaned ko-*/va-* repair beads found in a live sweep.
# ===========================================================================

# cv_bead_mark_in_progress BEAD_ID — idempotently claim BEAD_ID (assignee=you,
# status=in_progress) the moment a step starts working it, so a routed bead is
# never left sitting at READY for the duration of the work. `bd update
# --claim` is already idempotent for the same actor (see con-voyage's own
# {target}.setup-con-voyage-review.md "Claim -> in_progress (idempotent)"
# precedent), so this does not special-case an already-in_progress bead —
# re-claiming it is a harmless no-op. It DOES pre-check existence/terminal
# state (below) before calling `bd update` at all.
#
# FAIL-SAFE: warns to stderr and no-ops — never aborts the caller — for an
# empty BEAD_ID, a bead unknown to `bd show` (gc hiccup or bad id), or a bead
# that is already closed (a terminal bead never reopens here). A `bd update`
# failure itself is also swallowed (warn only) so a transient gc/bd error
# never fails the step that is just trying to mark its own progress.
cv_bead_mark_in_progress() {
  local bead_id="$1"
  [ -n "${bead_id// /}" ] || { echo "cv_bead_mark_in_progress: empty bead id, skipping" >&2; return 0; }
  local status
  IFS=$'\x1f' read -r status _ <<< "$(bead_status "$bead_id" assignee)"
  if [ -z "$status" ]; then
    echo "cv_bead_mark_in_progress: bead ${bead_id} not found, skipping" >&2
    return 0
  fi
  if [ "$status" = "closed" ]; then
    echo "cv_bead_mark_in_progress: bead ${bead_id} already closed, skipping" >&2
    return 0
  fi
  "$GC" bd update "$bead_id" --claim >/dev/null 2>&1 \
    || echo "cv_bead_mark_in_progress: failed to claim ${bead_id}" >&2
  return 0
}

# cv_bead_close BEAD_ID OUTCOME REASON — idempotently close BEAD_ID with a
# reason stamped "<OUTCOME>: <REASON>" (mirrors cv_close_reason_for_pr's
# existing "landed: PR #N merged" / "abandoned: PR #N closed without merge"
# shape, so every bead-close reason in this pack reads the same way). OUTCOME
# is the GLOBAL pack vocabulary from the OPERATOR DIRECTIVE above: landed |
# abandoned | no-op | superseded — this helper does not hard-enforce the enum,
# a caller passes whichever token fits its own terminal state.
#
# FAIL-SAFE: warns to stderr and no-ops — never aborts the caller — for an
# empty BEAD_ID, a bead unknown to `bd show`, or a bead that is already closed
# (idempotent: re-running the same terminal exit twice never errors). A
# `bd close` failure itself is also swallowed (warn only).
cv_bead_close() {
  local bead_id="$1" outcome="$2" reason="$3"
  [ -n "${bead_id// /}" ] || { echo "cv_bead_close: empty bead id, skipping" >&2; return 0; }
  local status
  IFS=$'\x1f' read -r status _ <<< "$(bead_status "$bead_id" assignee)"
  if [ -z "$status" ]; then
    echo "cv_bead_close: bead ${bead_id} not found, skipping" >&2
    return 0
  fi
  if [ "$status" = "closed" ]; then
    echo "cv_bead_close: bead ${bead_id} already closed, skipping" >&2
    return 0
  fi
  "$GC" bd close "$bead_id" --reason "${outcome}: ${reason}" >/dev/null 2>&1 \
    || echo "cv_bead_close: failed to close ${bead_id}" >&2
  return 0
}

# ===========================================================================
# WORK-BEAD LIFECYCLE HELPERS (fk-p7j9 / fk-hsca)
#
# The helpers above track REPAIR beads (CI failures). The helpers below track
# the WORK BEAD itself — the bead a con-voyage delivers — across its full
# lifecycle (setup -> reviewing -> awaiting_merge -> closed on PR land) so it
# moves on the dashboard, carries a real description, and is closed when its PR
# merges/closes instead of sitting open forever.
#
# Bead-id note (verified against a live con-voyage run, fk-c0t): the con-voyage
# graph.v2 formula's `{{convoy_id}}` token resolves to a SYNTHETIC input convoy
# (e.g. fk-8ba: `gc.synthetic=true`, `issue_type=convoy`) that `tracks` the REAL
# work bead (e.g. fk-2co). cv_resolve_work_bead() below maps convoy_id -> the
# real work bead; the con-voyage-finalize monitor and the con-voyage workflow
# steps both go through it so the lifecycle acts on the right bead.
# ===========================================================================

# cv_resolve_work_bead CONVOY_ID — print the REAL work bead id for a con-voyage
# `{{convoy_id}}`. If CONVOY_ID is a synthetic input convoy (or otherwise an
# issue_type=convoy bead), the work bead is its first `tracks` dependency;
# otherwise CONVOY_ID is already the work bead and is echoed unchanged.
#
# FAIL-SAFE: on any error (empty id, `bd show` failure, unparseable JSON, no
# dependency found) this echoes the INPUT id unchanged rather than an empty
# string, so a caller never accidentally runs a lifecycle `bd` command against
# an empty/garbage id. A caller that must distinguish "resolved to a different
# bead" from "fell back to the input" can compare the output to the input.
cv_resolve_work_bead() {
  local convoy_id="$1"
  [ -n "${convoy_id// /}" ] || { printf '%s' "$convoy_id"; return 0; }
  local json
  json=$("$GC" bd show "$convoy_id" --json 2>/dev/null) || json=""
  if [ -z "$json" ]; then printf '%s' "$convoy_id"; return 0; fi
  printf '%s' "$json" | python3 -c "
import sys, json
convoy_id = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print(convoy_id); raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    print(convoy_id); raise SystemExit(0)
meta = data.get('metadata') or {}
synthetic = str(meta.get('gc.synthetic', '')).lower() in ('true', '1', 'yes')
is_convoy = (data.get('issue_type') or '') == 'convoy'
if synthetic or is_convoy:
    for dep in (data.get('dependencies') or []):
        if not isinstance(dep, dict):
            continue
        # A single-item input convoy 'tracks' exactly one work bead. Prefer a
        # 'tracks' edge; fall back to the first dependency id if the type field
        # is absent (older records) but never to an empty/self id.
        dtype = dep.get('dependency_type') or dep.get('type') or ''
        dep_id = dep.get('id') or ''
        if dep_id and dep_id != convoy_id and (dtype == 'tracks' or dtype == ''):
            print(dep_id); raise SystemExit(0)
    # Convoy with no usable dependency — fail safe to the input id.
    print(convoy_id); raise SystemExit(0)
# Not a convoy: convoy_id is already the work bead.
print(convoy_id)
" "$convoy_id" 2>/dev/null || printf '%s' "$convoy_id"
}

# cv_close_reason_for_pr PR_STATE PR_NUMBER — canonical work-bead close reason
# for a finalized PR. PR_STATE is the GitHub PR state ("MERGED" or "CLOSED",
# case-insensitive). Any merged state -> "landed: PR #N merged"; a closed-
# without-merge state -> "abandoned: PR #N closed without merge". These strings
# match the reasons the facilitator runbook and the operator already use by
# hand (README Phase 6 / orchestration template).
cv_close_reason_for_pr() {
  local pr_state="$1" pr_number="$2"
  local lc
  lc="$(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]')"
  if [ "$lc" = "merged" ]; then
    printf 'landed: PR #%s merged' "$pr_number"
  else
    printf 'abandoned: PR #%s closed without merge' "$pr_number"
  fi
}

# cv_repair_close_reason_for_pr PR_STATE PR_NUMBER — the REASON half (no
# outcome prefix) for closing a repair bead once its PR reaches a terminal
# state (fk-f1vp FIX-B). Unlike cv_close_reason_for_pr, a repair bead's own
# OUTCOME is always "superseded" regardless of merged vs. closed-without-merge
# — the CI failure it existed to fix is moot either way once the PR itself is
# terminal — so the caller passes this string to cv_bead_close's own REASON
# argument (which prepends the outcome): cv_bead_close "$bead" "superseded"
# "$(cv_repair_close_reason_for_pr "$state" "$num")".
cv_repair_close_reason_for_pr() {
  local pr_state="$1" pr_number="$2"
  local lc
  lc="$(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]')"
  if [ "$lc" = "merged" ]; then
    printf 'PR #%s merged' "$pr_number"
  else
    printf 'PR #%s closed' "$pr_number"
  fi
}

# pr_finalize_state REPO PR_NUMBER — resolve a PR's terminal state via ONE
# `gh pr view`. Prints "<state><0x1f><merged_at><0x1f><closed_at>" where state
# is one of MERGED | CLOSED | OPEN | "" (unknown/error). merged_at/closed_at are
# the raw ISO timestamps (empty when absent). A gh failure or unparseable body
# yields an empty state (SEP-only) so the caller FAILS SAFE — never treats an
# unknown PR as merged/closed. GitHub reports a merged PR as state=CLOSED with a
# non-null mergedAt, so this normalizes that to MERGED for the caller.
pr_finalize_state() {
  local repo="$1" pr_number="$2"
  local SEP=$'\x1f'
  [ -n "${repo// /}" ] && [ -n "${pr_number// /}" ] || { printf '%s%s' "$SEP" "$SEP"; return 0; }
  # PR number must be numeric — never interpolate anything else into the gh call.
  case "$pr_number" in
    ''|*[!0-9]*) printf '%s%s' "$SEP" "$SEP"; return 0 ;;
  esac
  local json
  json=$("$GH" pr view "$pr_number" --repo "$repo" --json state,mergedAt,closedAt 2>/dev/null) || json=""
  if [ -z "$json" ]; then printf '%s%s' "$SEP" "$SEP"; return 0; fi
  printf '%s' "$json" | python3 -c "
import sys, json
SEP = '\x1f'
try:
    d = json.load(sys.stdin)
except Exception:
    print(SEP + SEP, end=''); raise SystemExit(0)
if not isinstance(d, dict):
    print(SEP + SEP, end=''); raise SystemExit(0)
state = (d.get('state') or '').upper()
merged_at = d.get('mergedAt') or ''
closed_at = d.get('closedAt') or ''
# GitHub returns MERGED directly in the GraphQL 'state' for gh>=2, but older
# gh reports a merged PR as CLOSED with a non-null mergedAt — normalize both.
if merged_at:
    state = 'MERGED'
print(state + SEP + merged_at + SEP + closed_at, end='')
" 2>/dev/null || printf '%s%s' "$SEP" "$SEP"
}

# ---------------------------------------------------------------------------
# Per-PR FINALIZE record (fk-p7j9 / fk-hsca). File:
# "<CV_STATE_DIR>/<dedup_key>.finalize", plain key=value lines:
#   work_bead=<the real work bead id the con-voyage delivers>
#   convoy_id=<the con-voyage {{convoy_id}} = synthetic input convoy id>
#   repo_full=<owner/repo>
#   pr_number=<PR number>
#   pr_author=<the PR author login recorded at publish time>
#   implementor_session=<the long-lived implementor to release on land, or empty>
#   last_phase=<the last cv=<phase> the finalize monitor set on the work bead:
#     reviewing | awaiting_merge | repairing — used to avoid a redundant
#     set-state every poll (idempotence), or empty for a fresh record>
#
# This is a SEPARATE record type from the repair ".state" file: the repair
# state only exists for PRs with an actionable CI failure, so it cannot serve
# as the work-bead<->PR map for a clean, review-approved PR that is simply
# awaiting a human merge. The publish step writes THIS record for EVERY
# con-voyage PR it opens (via the finalize-record snippet in publish.md), and
# the con-voyage-finalize monitor is the sole consumer/GC of it.
#
# dedup_key convention: "cv-finalize-<owner>-<repo>-<pr_number>" (mirrors the
# repair state's "cv-ci-repair-..." shape). The monitor globs "*.finalize".
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # FS_* globals are consumed by the sourcing script
# (con-voyage-finalize.sh), invisible to shellcheck when this file is checked
# standalone.
finalize_read() {
  local dedup_key="$1"
  local f="${CV_STATE_DIR}/${dedup_key}.finalize"
  FS_WORK_BEAD=""
  FS_CONVOY_ID=""
  FS_REPO_FULL=""
  FS_PR_NUMBER=""
  FS_PR_AUTHOR=""
  FS_IMPLEMENTOR=""
  FS_LAST_PHASE=""
  [ -f "$f" ] || return 0
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      work_bead) FS_WORK_BEAD="$v" ;;
      convoy_id) FS_CONVOY_ID="$v" ;;
      repo_full) FS_REPO_FULL="$v" ;;
      pr_number) FS_PR_NUMBER="$v" ;;
      pr_author) FS_PR_AUTHOR="$v" ;;
      implementor_session) FS_IMPLEMENTOR="$v" ;;
      last_phase) FS_LAST_PHASE="$v" ;;
    esac
  done < "$f"
}

# finalize_write DEDUP_KEY WORK_BEAD CONVOY_ID REPO_FULL PR_NUMBER PR_AUTHOR
#                IMPLEMENTOR LAST_PHASE
finalize_write() {
  local dedup_key="$1" work_bead="$2" convoy_id="$3" repo_full="$4"
  local pr_number="$5" pr_author="$6" implementor="${7:-}" last_phase="${8:-}"
  local f="${CV_STATE_DIR}/${dedup_key}.finalize"
  {
    printf 'work_bead=%s\n' "$work_bead"
    printf 'convoy_id=%s\n' "$convoy_id"
    printf 'repo_full=%s\n' "$repo_full"
    printf 'pr_number=%s\n' "$pr_number"
    printf 'pr_author=%s\n' "$pr_author"
    printf 'implementor_session=%s\n' "$implementor"
    printf 'last_phase=%s\n' "$last_phase"
  } > "$f"
}
