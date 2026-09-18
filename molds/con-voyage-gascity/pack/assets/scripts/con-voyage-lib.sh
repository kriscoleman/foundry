# shellcheck shell=bash
# con-voyage-lib.sh — shared per-PR state/dispatch helpers for
# con-voyage-pr-watch.sh (Fix 1) and con-voyage-repair-watchdog.sh (Fix 2).
#
# Both scripts read and write the SAME per-PR state record format under
# CV_STATE_DIR (see the field-by-field doc comment on state_read below) and
# share the same author-scoping/session-liveness primitives. This file is
# sourced, not executed — it defines functions only and has no shebang-level
# side effects (no `set -...`, so it never overrides either caller's own
# shell-option choice: con-voyage-pr-watch.sh runs `set -euo pipefail`,
# con-voyage-repair-watchdog.sh runs `set -uo pipefail` without `-e`).
#
# Callers must already have GC and GC_CITY set (both scripts resolve these in
# their own Configuration block before sourcing this file) — every function
# below reads them as globals at CALL time, not at source time.
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
  json=$("$GC" --city "$GC_CITY" bd show "$bead_id" --json 2>/dev/null) || json=""
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
close_if_open() {
  local bead_id="$1" reason="$2" pr_label="${3:-}" known_status="${4:-}"
  [ -n "${bead_id// /}" ] || return 0
  local status="$known_status"
  if [ -z "$status" ]; then
    IFS=$'\x1f' read -r status _ <<< "$(bead_status "$bead_id" assignee)"
  fi
  [ -n "$status" ] && [ "$status" != "closed" ] || return 0
  "$GC" --city "$GC_CITY" bd close "$bead_id" --reason "$reason" >/dev/null 2>&1 || true
  if [ -n "$pr_label" ]; then
    echo "con-voyage-pr-watch: [PART A] ${pr_label}: closed prior open repair bead ${bead_id} (was status=${status})"
  fi
}
