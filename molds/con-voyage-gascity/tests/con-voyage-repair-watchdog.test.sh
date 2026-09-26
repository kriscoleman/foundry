#!/usr/bin/env bash
# con-voyage-repair-watchdog.test.sh — hermetic, offline test for the con-voyage
# repair-worker watchdog (fk-wgqp, Fix 2 of the con-voyage-repair-implementor-
# reuse design).
#
# Fix 1 (con-voyage-pr-watch.sh, landed as con-voyage-gascity 0.5.1) routes PR
# rework to the PR's long-lived implementor and records a per-PR state record
# under CV_STATE_DIR. This watchdog is a SEPARATE, periodic order that reads
# those SAME state records and self-heals: it reassigns a new implementor when
# the tracked one has died, and re-dispatches a rework that has made no
# progress past a staleness threshold — up to a bounded number of attempts,
# after which it escalates to a human instead of re-dispatching forever.
#
# HOW IT WORKS (no network, no real gc/gh): a recording STUB `gc` (and a
# minimal `gh`, only for the CV_PR_AUTHOR auto-resolve fallback) is built in a
# temp dir; state fixtures are written directly as ".state" files under a temp
# CV_STATE_DIR (this script never calls con-voyage-pr-watch.sh — it only reads
# the state format Fix 1 writes). The script under test honors GC=/GH=
# (default gc/gh) so we point it at the stubs.
#
# Run:  bash tests/con-voyage-repair-watchdog.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-repair-watchdog.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-repair-watchdog-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Timestamp helpers (pure python3 — portable across BSD/GNU, no `date` math).
# ---------------------------------------------------------------------------
iso_ago() {
  # iso_ago SECONDS — an ISO-8601 UTC timestamp SECONDS in the past.
  python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(seconds=int('$1'))).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

# ---------------------------------------------------------------------------
# The `gh` stub. Only ever consulted for the CV_PR_AUTHOR auto-resolve
# fallback (this script makes no other GitHub calls — see its header).
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
sub="${1:-}"
case "$sub" in
  api)
    if [ "${STUB_GH_USER_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    if [ -n "${STUB_GH_USER_LOGIN:-}" ]; then
      printf '%s\n' "${STUB_GH_USER_LOGIN}"
    fi
    exit 0
    ;;
esac
exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv, returns canned JSON, and no-ops writes.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

# gc is invoked as: gc [--city <dir>] <subcommand> ... — skip the leading
# --city pair (order-independent with any other leading top-level flag this
# script might one day add) to find the real subcommand.
args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city) i=$((i+2)) ;;
    --rig)  i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"

case "$sub" in
  bd)
    bdsub="${args[$((i+1))]:-}"
    if [ "$bdsub" = "create" ]; then
      if [ "${STUB_BD_CREATE_FAIL:-0}" = "1" ]; then
        exit 1
      fi
      # STUB_BD_CREATE_SLEEP: seconds to sleep before returning, so a real
      # concurrent second invocation has a deterministic window to attempt
      # (and fail) the same dedup_key's lock while this call is "in flight".
      if [ -n "${STUB_BD_CREATE_SLEEP:-}" ]; then
        sleep "$STUB_BD_CREATE_SLEEP"
      fi
      printf '%s\n' "${STUB_BD_CREATE_ID:-wd-newbead}"
      exit 0
    fi
    if [ "$bdsub" = "show" ]; then
      show_id="${args[$((i+2))]:-}"
      # STUB_BDSHOW_MAP: newline-delimited "<id>|<status>|<updated_at>" rows.
      # An id with no matching row returns an empty JSON object (unknown bead).
      # Multiple rows for the SAME id are returned in order across successive
      # `bd show` calls for that id within one script run (1st call -> row 1,
      # 2nd call -> row 2, ...), clamped to the last row once calls exceed the
      # rows given — this is what lets a test simulate "the bead was updated
      # between the initial read and the pre-action recheck" without any real
      # concurrency. The call count is tracked per-id under GC_CITY (fresh per
      # test case, see setup_case_env) so it never leaks across cases.
      match=""
      if [ -n "${STUB_BDSHOW_MAP:-}" ]; then
        all_matches="$(printf '%s\n' "$STUB_BDSHOW_MAP" | awk -F'|' -v id="$show_id" '$1==id{print}')"
        if [ -n "$all_matches" ]; then
          n_matches="$(printf '%s\n' "$all_matches" | wc -l | tr -d ' ')"
          count_dir="${GC_CITY:-.}/.bdshow-counts"
          mkdir -p "$count_dir" 2>/dev/null
          count_file="${count_dir}/${show_id}.count"
          prev="0"
          [ -f "$count_file" ] && prev="$(cat "$count_file" 2>/dev/null || echo 0)"
          case "$prev" in *[!0-9]*|'') prev=0 ;; esac
          next=$((prev + 1))
          echo "$next" > "$count_file"
          idx="$next"
          [ "$idx" -gt "$n_matches" ] && idx="$n_matches"
          match="$(printf '%s\n' "$all_matches" | awk -v n="$idx" 'NR==n{print; exit}')"
        fi
      fi
      if [ -n "$match" ]; then
        show_status="$(printf '%s' "$match" | awk -F'|' '{print $2}')"
        show_updated="$(printf '%s' "$match" | awk -F'|' '{print $3}')"
        printf '{"id":"%s","status":"%s","updated_at":"%s"}\n' "$show_id" "$show_status" "$show_updated"
      else
        printf '{}\n'
      fi
      exit 0
    fi
    # bd close / bd update — generic accept, still logged above for assertions.
    exit 0
    ;;
  sling)
    if [ "${STUB_SLING_FAIL:-0}" = "1" ]; then
      echo "gc sling: failed to route bead (simulated)" >&2
      exit 1
    fi
    exit 0
    ;;
  mail)
    mailsub="${args[$((i+1))]:-}"
    if [ "$mailsub" = "send" ]; then
      if [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ]; then
        echo "gc mail send: failed to deliver (simulated)" >&2
        exit 1
      fi
      exit 0
    fi
    exit 0
    ;;
  session)
    sessub="${args[$((i+1))]:-}"
    if [ "$sessub" = "list" ]; then
      # STUB_SESSION_LIST_JSON: real shape {"sessions":[{"id":...,"alias":...,
      # "name":...,"session_name":...,"state":"active|suspended|closed"}]}.
      # Default: empty list (nobody is alive).
      if [ -n "${STUB_SESSION_LIST_JSON:-}" ]; then
        printf '%s' "$STUB_SESSION_LIST_JSON"
      else
        printf '{"ok":true,"sessions":[]}'
      fi
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# ---------------------------------------------------------------------------
# Test harness bookkeeping (same idioms as con-voyage-pr-watch.test.sh).
# ---------------------------------------------------------------------------
FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

log_count() {
  local logfile="$1" pattern="$2"
  [ -f "$logfile" ] || { echo 0; return; }
  local n
  n="$(grep -E -c -- "$pattern" "$logfile")"
  printf '%s' "${n:-0}"
}

assert_log_count() {
  local n; n="$(log_count "$1" "$2")"
  assert_eq "$3" "$n" "$4"
}

state_field() {
  local f="${1}/${2}.state" field="$3"
  [ -f "$f" ] || return 0
  awk -F= -v k="$field" '$1==k{ sub(/^[^=]*=/, ""); print; exit }' "$f"
}

# write_state DIR DEDUP_KEY implementor inflight last_state pr_author route repo_full pr_number branch attempt_count escalated [last_dispatch_at]
write_state() {
  local dir="$1" key="$2"
  {
    printf 'implementor_session=%s\n' "${3}"
    printf 'inflight_rework=%s\n' "${4}"
    printf 'last_handled_state=%s\n' "${5}"
    printf 'pr_author=%s\n' "${6}"
    printf 'repair_route=%s\n' "${7}"
    printf 'repo_full=%s\n' "${8}"
    printf 'pr_number=%s\n' "${9}"
    printf 'branch=%s\n' "${10}"
    printf 'attempt_count=%s\n' "${11}"
    printf 'escalated=%s\n' "${12}"
    printf 'last_dispatch_at=%s\n' "${13:-}"
  } > "${dir}/${key}.state"
}

CITY_DIR=""
STATE_DIR=""
GC_LOG=""
OUT=""
RC=0

setup_case_env() {
  CITY_DIR="${SANDBOX}/city-${1}"
  STATE_DIR="${SANDBOX}/state-${1}"
  GC_LOG="${SANDBOX}/gc-${1}.log"
  mkdir -p "$CITY_DIR" "$STATE_DIR"
  : > "$GC_LOG"
}

# run_script — invoke the script under test with the stubs wired in.
run_script() {
  OUT="$(
    env \
      GH="${STUBDIR}/gh" \
      GC="${STUBDIR}/gc" \
      GC_CITY="$CITY_DIR" \
      CV_STATE_DIR="$STATE_DIR" \
      STUB_GC_LOG="$GC_LOG" \
      "$@" \
      bash "$SCRIPT" 2>&1
  )"
  RC=$?
}

DEFAULT_ENV=(CV_PR_AUTHOR="kriscoleman" CV_STALL_SECONDS="900" CV_MAX_ATTEMPTS="3" CV_ESCALATE_TARGET="human")

# ===========================================================================
# CASE 1 — Fail-closed: CV_PR_AUTHOR unset AND gh api user resolves empty.
# ===========================================================================
start_case "1: fail-closed when author unresolved"
setup_case_env "1"
run_script CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="" STUB_GH_USER_FAIL=1
assert_eq "1" "$RC" "script exits 1 (fail closed)"
assert_log_count "$GC_LOG" 'bd show' 0 "zero 'bd show' calls made before the fail-closed exit"

# ===========================================================================
# CASE 2 — Empty state dir: nothing to do, exits 0.
# ===========================================================================
start_case "2: empty state dir is a clean no-op"
setup_case_env "2"
run_script "${DEFAULT_ENV[@]}"
assert_eq "0" "$RC" "script exits 0 with no state files"
assert_log_count "$GC_LOG" '.' 0 "no gc subcommands are invoked at all"

# ===========================================================================
# CASE 3 — Acceptance: "PR clean / no in-flight rework -> no action."
# ===========================================================================
start_case "3: empty inflight_rework is left alone"
setup_case_env "3"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-30" \
  "" "" "clean" "" "" "" "" "" "0" "0"
run_script "${DEFAULT_ENV[@]}"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd show' 0 "no bd show for a record with no in-flight rework"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail for a record with no in-flight rework"
assert_log_count "$GC_LOG" 'sling' 0 "no sling for a record with no in-flight rework"

# ===========================================================================
# CASE 4 — Acceptance: "Author scoping respected (no action on non-CV_PR_AUTHOR
#   state, defensively)." pr_author on the record does not match CV_PR_AUTHOR.
# ===========================================================================
start_case "4: defensive author-scope skip on a mismatched pr_author"
setup_case_env "4"
write_state "$STATE_DIR" "cv-ci-repair-someone-else-repo-40" \
  "" "wd-bead40" "checks_failed" "someone-else" "vandoor/gc.implementation-worker" \
  "someone-else/repo" "40" "feature/x" "0" "0"
run_script "${DEFAULT_ENV[@]}"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd show' 0 "no bd show for a non-CV_PR_AUTHOR record"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail for a non-CV_PR_AUTHOR record"
assert_log_count "$GC_LOG" 'sling' 0 "no sling for a non-CV_PR_AUTHOR record"
if printf '%s' "$OUT" | grep -q 'author scop'; then
  pass "logs an author-scoping SKIP"
else
  fail "expected an author-scoping SKIP log"
fi
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-someone-else-repo-40" "attempt_count")" "attempt_count is untouched on an author-scope skip"

# An empty/unresolved pr_author (e.g. a pre-Fix-2 record) must ALSO be
# skipped, never treated as "ours" by default (fail closed, same posture as
# the rest of this pack).
start_case "4b: defensive author-scope skip on an empty (unresolved) pr_author"
setup_case_env "4b"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-41" \
  "" "wd-bead41" "checks_failed" "" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "41" "feature/x" "0" "0"
run_script "${DEFAULT_ENV[@]}"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd show' 0 "no bd show for an empty-pr_author record"

# ===========================================================================
# CASE 5 — Already escalated: "stop re-dispatching that one." No further
#   action of any kind, even though the tracked bead would otherwise qualify
#   as dead/stalled.
# ===========================================================================
start_case "5: an already-escalated record takes no further action"
setup_case_env "5"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-50" \
  "" "wd-bead50" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "50" "feature/x" "3" "1"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead50|open|$(iso_ago 99999)"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd show' 0 "no bd show once already escalated — nothing left to check"
assert_log_count "$GC_LOG" 'mail send' 0 "no repeated escalation mail once already escalated"
assert_log_count "$GC_LOG" 'sling' 0 "no re-dispatch once already escalated"

# ===========================================================================
# CASE 6 — Tracked bead is closed/unknown: defer to the monitor's next cycle
#   rather than guessing. (Transient: the monitor's OWN next backfill cycle
#   will see the real current PR state and re-evaluate from scratch.)
# ===========================================================================
start_case "6: a closed tracked bead defers to the monitor, no watchdog action"
setup_case_env "6"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-60" \
  "gc__impl-rc-1" "wd-bead60" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "60" "feature/x" "0" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead60|closed|$(iso_ago 99999)" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail for a closed tracked bead"
assert_log_count "$GC_LOG" 'sling' 0 "no re-dispatch for a closed tracked bead"
assert_eq "wd-bead60" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-60" "inflight_rework")" "state is left untouched (unchanged) for the monitor's own next cycle"

# ===========================================================================
# CASE 7 — Acceptance: "Implementor alive + rework progressing -> no action."
# ===========================================================================
start_case "7: alive implementor with a fresh (progressing) bead -> no action"
setup_case_env "7"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-70" \
  "gc__impl-rc-1" "wd-bead70" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "70" "feature/x" "0" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead70|open|$(iso_ago 30)" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail — the implementor is alive and the bead was updated 30s ago"
assert_log_count "$GC_LOG" 'sling' 0 "no re-dispatch — nothing is stalled"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-70" "attempt_count")" "attempt_count stays at 0 when nothing needed re-dispatch"
if printf '%s' "$OUT" | grep -qE 'foundry#70.*no action|no action.*foundry#70'; then
  pass "logs a no-action line for the healthy PR"
else
  fail "expected a no-action log line for the healthy PR"
fi

# ===========================================================================
# CASE 8 — Acceptance: "Implementor dead + in-flight rework -> assigns a new
#   implementor (re-dispatch); state updated." The stale bead is superseded
#   (closed) and a fresh fallback bead is minted and slung to the PR's own
#   repair_route, exactly like con-voyage-pr-watch.sh's own fallback path.
# ===========================================================================
start_case "8: dead implementor triggers a fallback re-dispatch"
setup_case_env "8"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-80" \
  "gc__impl-rc-dead" "wd-bead80" "merge_conflict" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "80" "fix/thing" "0" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead80|open|$(iso_ago 30)" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}' \
  STUB_BD_CREATE_ID="wd-bead80b"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close wd-bead80 .*superseded' 1 "the dead implementor's stale bead is superseded"
assert_log_count "$GC_LOG" '\-\-rig vandoor bd create' 1 "a fresh fallback bead is minted in the target rig"
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker wd-bead80b --on con-voyage-ci-repair' 1 "the fresh bead is routed via the con-voyage-ci-repair formula"
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker wd-bead80b --on con-voyage-ci-repair .*pr=80 .*repo=kriscoleman/foundry .*branch=fix/thing .*failure_kind=merge_conflict' 1 "the re-dispatch forwards pr/repo/branch/failure_kind vars"
assert_log_count "$GC_LOG" 'mail send' 0 "the dead-implementor path never mails a dead session"
assert_eq "wd-bead80b" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-80" "inflight_rework")" "state now tracks the freshly-minted fallback bead"
assert_eq "" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-80" "implementor_session")" "the new fallback bead has no known implementor yet"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-80" "attempt_count")" "attempt_count increments to 1 on the first re-dispatch"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-80" "escalated")" "not escalated after only one attempt"
assert_eq "merge_conflict" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-80" "last_handled_state")" "last_handled_state is unchanged by a watchdog re-dispatch"

# ===========================================================================
# CASE 9 — Acceptance: "Rework stalled past threshold, implementor alive ->
#   supersede + re-dispatch to same implementor; attempt counter increments."
#   No new bead: the same live implementor is re-notified directly (mirrors
#   con-voyage-pr-watch.sh's own reuse-dispatch path), and the SAME tracked
#   bead keeps being watched (its own updated_at is the ongoing progress
#   signal for the NEXT watchdog cycle).
# ===========================================================================
start_case "9: stalled-but-alive implementor is re-notified (no new bead)"
setup_case_env "9"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-90" \
  "gc__impl-rc-1" "wd-bead90" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "90" "fix/thing" "0" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead90|open|$(iso_ago 1800)" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd create' 0 "no new bead is minted — the live implementor is reused"
assert_log_count "$GC_LOG" 'sling' 0 "no sling — reuse is mail-based, exactly like con-voyage-pr-watch.sh's reuse path"
assert_log_count "$GC_LOG" 'bd close' 0 "the still-open tracked bead is NOT closed — its updated_at is next cycle's progress signal"
assert_log_count "$GC_LOG" 'mail send gc__impl-rc-1' 1 "the SAME implementor is re-notified"
assert_eq "wd-bead90" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-90" "inflight_rework")" "the same tracked bead keeps being watched"
assert_eq "gc__impl-rc-1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-90" "implementor_session")" "implementor is unchanged (reuse, not reassignment)"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-90" "attempt_count")" "attempt counter increments"

# ===========================================================================
# CASE 10 — No known implementor yet (fallback bead unclaimed) AND it has been
#   open past the stall threshold: this is "stalled" too (nobody ever picked
#   it up) and needs the SAME fallback re-dispatch as a dead implementor.
# ===========================================================================
start_case "10: never-claimed fallback bead stalled past threshold -> re-dispatch"
setup_case_env "10"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-100" \
  "" "wd-bead100" "blocked" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "100" "fix/thing" "0" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead100|open|$(iso_ago 5000)" \
  STUB_BD_CREATE_ID="wd-bead100b"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close wd-bead100 .*superseded' 1 "the never-claimed stale bead is superseded"
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker wd-bead100b --on con-voyage-ci-repair' 1 "a fresh fallback bead is dispatched"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-100" "attempt_count")" "attempt counter increments"

# ===========================================================================
# CASE 11 — No known implementor yet, but the fallback bead is still FRESH
#   (just minted, within the grace/stall window): leave it alone. A brand new
#   pool-slung bead legitimately sits unclaimed for a little while.
# ===========================================================================
start_case "11: never-claimed fallback bead within grace period -> no action"
setup_case_env "11"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-110" \
  "" "wd-bead110" "blocked" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "110" "fix/thing" "0" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead110|open|$(iso_ago 30)"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close' 0 "no supersede within the grace period"
assert_log_count "$GC_LOG" 'sling' 0 "no re-dispatch within the grace period"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-110" "attempt_count")" "attempt_count stays 0"

# ===========================================================================
# CASE 12 — Acceptance: "3 failed attempts -> escalate via gc mail, stop
#   re-dispatching." attempt_count is already at CV_MAX_ATTEMPTS, so this
#   detection escalates instead of a 4th re-dispatch.
# ===========================================================================
start_case "12: attempt cap reached -> escalate instead of re-dispatching"
setup_case_env "12"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-120" \
  "gc__impl-rc-dead" "wd-bead120" "merge_conflict" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "120" "fix/thing" "3" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead120|open|$(iso_ago 30)" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd create' 0 "no re-dispatch once the attempt cap is reached"
assert_log_count "$GC_LOG" 'sling' 0 "no re-dispatch sling once the attempt cap is reached"
assert_log_count "$GC_LOG" 'bd close' 0 "the tracked bead is left open for a human to inspect"
assert_log_count "$GC_LOG" 'mail send human' 1 "exactly one escalation mail to the operator (human)"
assert_log_count "$GC_LOG" 'mail send human .*kriscoleman/foundry#120' 1 "the escalation mail names the PR"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-120" "escalated")" "escalated flag is now set"
assert_eq "wd-bead120" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-120" "inflight_rework")" "the tracked bead id is preserved through escalation"

# A CUSTOM escalation target must be honored (rig-level config knob, same
# convention as escalation_target in con-voyage-ci-repair.formula.toml).
start_case "12b: escalation honors a custom CV_ESCALATE_TARGET"
setup_case_env "12b"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-121" \
  "gc__impl-rc-dead" "wd-bead121" "merge_conflict" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "121" "fix/thing" "3" "0"
run_script CV_PR_AUTHOR="kriscoleman" CV_STALL_SECONDS="900" CV_MAX_ATTEMPTS="3" \
  CV_ESCALATE_TARGET="oncall-lead" \
  STUB_BDSHOW_MAP="wd-bead121|open|$(iso_ago 30)" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send oncall-lead' 1 "escalation goes to the configured CV_ESCALATE_TARGET"

# ===========================================================================
# CASE 13 — Escalation failure (mail send fails) must NOT set escalated=1 —
#   otherwise a transient mail outage would silently and permanently suppress
#   re-dispatch for a PR the operator was never actually told about.
# ===========================================================================
start_case "13: a failed escalation mail is retried next cycle (no false escalated=1)"
setup_case_env "13"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-130" \
  "gc__impl-rc-dead" "wd-bead130" "merge_conflict" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "130" "fix/thing" "3" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead130|open|$(iso_ago 30)" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}' STUB_MAIL_SEND_FAIL=1
assert_eq "0" "$RC" "script exits 0 (a failed escalation is non-fatal to the whole run)"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-130" "escalated")" "escalated stays 0 when the escalation mail itself failed to send"
if printf '%s' "$OUT" | grep -q 'WARNING'; then
  pass "logs a WARNING for the failed escalation mail"
else
  fail "expected a WARNING for the failed escalation mail"
fi

# ===========================================================================
# CASE 14 — Robustness: a dead implementor but missing redispatch context
#   (e.g. a record written before this watchdog's schema extension existed —
#   con-voyage-pr-watch.sh back-compat leaves these fields empty). The
#   watchdog must not guess at a repair_route/repo/pr/branch it does not have
#   — it logs a WARNING and leaves the attempt counter untouched so a later
#   cycle (once con-voyage-pr-watch.sh has re-populated the record via a
#   fresh dispatch) can act on real data.
# ===========================================================================
start_case "14: missing redispatch context is a no-op WARNING, not a guess"
setup_case_env "14"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-140" \
  "gc__impl-rc-dead" "wd-bead140" "merge_conflict" "kriscoleman" "" \
  "" "" "" "0" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead140|open|$(iso_ago 30)" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd create' 0 "no guessed re-dispatch without a repair_route"
assert_log_count "$GC_LOG" 'bd close' 0 "the tracked bead is left alone — nothing safe to supersede it with"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-140" "attempt_count")" "attempt_count is left untouched — this was not a real attempt"
if printf '%s' "$OUT" | grep -q 'WARNING'; then
  pass "logs a WARNING for the missing redispatch context"
else
  fail "expected a WARNING for the missing redispatch context"
fi

# ===========================================================================
# CASE 15 — Multiple independent records in one run: each is judged solely on
#   its own fields, in the same pass.
# ===========================================================================
start_case "15: multiple state records are each judged independently"
setup_case_env "15"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-150" \
  "gc__impl-rc-1" "wd-bead150" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "150" "fix/a" "0" "0"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-151" \
  "gc__impl-rc-dead" "wd-bead151" "blocked" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "151" "fix/b" "0" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_BDSHOW_MAP="$(printf 'wd-bead150|open|%s\nwd-bead151|open|%s' "$(iso_ago 30)" "$(iso_ago 30)")" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}' \
  STUB_BD_CREATE_ID="wd-bead151b"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send gc__impl-rc-1' 0 "PR #150 is healthy — no mail"
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker wd-bead151b' 1 "PR #151's dead implementor is reassigned"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-150" "attempt_count")" "PR #150 untouched"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-151" "attempt_count")" "PR #151 re-dispatched"

# ===========================================================================
# CASE 16 — End-to-end integration: a persistently stalled, alive implementor
#   is re-notified on three consecutive watchdog cycles (attempt_count climbs
#   1, 2, 3), and the FOURTH consecutive detection escalates and stops.
#   Mirrors con-voyage-pr-watch.test.sh's own multi-cycle CASE 9 style.
# ===========================================================================
start_case "16: 3 stalled cycles then escalation on the 4th (end-to-end)"
setup_case_env "16"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-160" \
  "gc__impl-rc-1" "wd-bead160" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "160" "fix/thing" "0" "0"
STALE_TS="$(iso_ago 1800)"

for n in 1 2 3; do
  GC_LOG="${SANDBOX}/gc-16-${n}.log"; : > "$GC_LOG"
  run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead160|open|${STALE_TS}" \
    STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}'
  assert_eq "0" "$RC" "cycle ${n} exits 0"
  assert_log_count "$GC_LOG" 'mail send gc__impl-rc-1' 1 "cycle ${n} re-notifies the implementor"
  assert_eq "$n" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-160" "attempt_count")" "cycle ${n} advances attempt_count to ${n}"
  assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-160" "escalated")" "cycle ${n} has not escalated yet"
done

GC_LOG="${SANDBOX}/gc-16-4.log"; : > "$GC_LOG"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead160|open|${STALE_TS}" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}'
assert_eq "0" "$RC" "cycle 4 exits 0"
assert_log_count "$GC_LOG" 'mail send gc__impl-rc-1' 0 "cycle 4 does not re-notify the implementor again — it escalates instead"
assert_log_count "$GC_LOG" 'mail send human' 1 "cycle 4 escalates to the operator"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-160" "escalated")" "cycle 4 sets escalated=1"

GC_LOG="${SANDBOX}/gc-16-5.log"; : > "$GC_LOG"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead160|open|${STALE_TS}" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}'
assert_eq "0" "$RC" "cycle 5 exits 0"
assert_log_count "$GC_LOG" 'mail send' 0 "cycle 5 sends no mail of any kind — escalation already happened, no repeated spam"

# ===========================================================================
# CASE 17 — fk-lfan B2 (security): a tampered attempt_count in a state file
#   must never reach bash arithmetic unvalidated. Bash arithmetic (both
#   `$((X + 1))` and the `-ge`/`-lt`/etc test operators) recursively expands
#   anything that LOOKS like an array subscript inside the expression, so a
#   state file with attempt_count=dedup_key[$(evil command)] executes that
#   command the moment the watchdog evaluates it — `dedup_key` is not an
#   arbitrary name, it is THIS watchdog's own already-bound loop variable
#   (the record's dedup key, always set before state_read runs), which is
#   exactly what makes the injection fire instead of tripping `set -u`'s
#   unbound-variable guard first. Proven live against the pre-fix code (see
#   the sibling command substitution below: it touches a marker file inside
#   THIS test's own sandbox, never a shared path, so the assertion is
#   hermetic and self-cleaning via the EXIT trap). The state file is
#   untrusted input (both con-voyage-pr-watch.sh and this watchdog write it,
#   under a predictable path), so it must be coerced to a validated base-10
#   integer at read time, defaulting to 0 rather than ever reaching
#   arithmetic context unvalidated.
# ===========================================================================
start_case "17: B2 — a malicious attempt_count is neutralized, not evaluated"
setup_case_env "17"
PWNED_MARKER="${SANDBOX}/pwned-b2-marker"
rm -f "$PWNED_MARKER"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-170" \
  "gc__impl-rc-dead" "wd-bead170" "merge_conflict" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "170" "fix/thing" "dedup_key[\$(touch ${PWNED_MARKER})]" "0"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead170|open|$(iso_ago 30)" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}' STUB_BD_CREATE_ID="wd-bead170b"
assert_eq "0" "$RC" "script exits 0 (a malformed attempt_count does not crash the whole pass)"
if [ -f "$PWNED_MARKER" ]; then
  fail "SECURITY: malicious attempt_count was evaluated as bash arithmetic (marker file was created)"
else
  pass "malicious attempt_count was never evaluated as arithmetic (no marker file created)"
fi
assert_log_count "$GC_LOG" 'bd close wd-bead170 .*superseded' 1 "the dead implementor's stale bead is still superseded normally"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-170" "attempt_count")" "a non-numeric attempt_count is treated as 0 and increments to 1, not aborted"

# A malicious `escalated` value must be neutralized the same way — it gates
# the `[ "$ST_ESCALATED" = "1" ]` string-equality skip (not arithmetic), but
# it is written back through state_write on every subsequent cycle, so it
# must still normalize to "0"/"1" rather than propagating attacker-controlled
# bytes into the state file indefinitely.
start_case "17b: B2 — a malicious escalated value normalizes to 0, not propagated"
setup_case_env "17b"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-171" \
  "gc__impl-rc-dead" "wd-bead171" "merge_conflict" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "171" "fix/thing" "0" "1[\$(true)]"
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead171|open|$(iso_ago 30)" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}' STUB_BD_CREATE_ID="wd-bead171b"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close wd-bead171 .*superseded' 1 "a garbled (non-'1') escalated value is NOT treated as already-escalated — the dead implementor is still reassigned"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-171" "escalated")" "escalated normalizes to 0 on write-back, not the garbled input"

# ===========================================================================
# CASE 18 — fk-lfan B1, hermetic case (a): implementor set + inflight_rework
#   EMPTY (Fix-1's PRIMARY dispatch path — a mail-only reuse dispatch, see
#   con-voyage-pr-watch.sh:739,747,823) + session dead -> fallback reassign,
#   exactly like the tracked-bead DEAD case (CASE 8), but with no tracked bead
#   to supersede (close_if_open on an empty id is a no-op) and no `bd show`
#   call at all, since there is nothing to look up.
# ===========================================================================
start_case "18: B1 case (a) — bead-less reuse, implementor dead -> fallback reassign"
setup_case_env "18"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-180" \
  "gc__impl-rc-dead" "" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "180" "fix/thing" "0" "0" "$(iso_ago 30)"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}' STUB_BD_CREATE_ID="wd-bead180b"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd show' 0 "no bd show — there is no tracked bead for a bead-less record"
assert_log_count "$GC_LOG" 'bd close' 0 "nothing to close — there was no tracked bead to supersede"
assert_log_count "$GC_LOG" '\-\-rig vandoor bd create' 1 "a fresh fallback bead is minted for the dead bead-less reuse"
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker wd-bead180b --on con-voyage-ci-repair' 1 "the fresh bead is routed via the con-voyage-ci-repair formula"
assert_log_count "$GC_LOG" 'mail send' 0 "the dead-implementor path never mails a dead session"
assert_eq "wd-bead180b" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-180" "inflight_rework")" "state now tracks the freshly-minted fallback bead (no longer bead-less)"
assert_eq "" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-180" "implementor_session")" "the new fallback bead has no known implementor yet"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-180" "attempt_count")" "attempt_count increments to 1 on the first re-dispatch"

# ===========================================================================
# CASE 19 — fk-lfan B1, hermetic case (b): implementor set + inflight_rework
#   EMPTY + implementor ALIVE + last_dispatch_at STALE (past CV_STALL_SECONDS)
#   -> re-notify the same implementor and increment attempt_count, exactly
#   like the tracked-bead STALLED-alive case (CASE 9), but staleness is keyed
#   off last_dispatch_at (there is no tracked bead's updated_at to check).
# ===========================================================================
start_case "19: B1 case (b) — bead-less reuse, implementor alive + last_dispatch_at stale -> re-notify"
setup_case_env "19"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-190" \
  "gc__impl-rc-1" "" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "190" "fix/thing" "0" "0" "$(iso_ago 1800)"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd show' 0 "no bd show — there is no tracked bead for a bead-less record"
assert_log_count "$GC_LOG" 'bd create' 0 "no new bead is minted — the live implementor is reused"
assert_log_count "$GC_LOG" 'sling' 0 "no sling — reuse is mail-based"
assert_log_count "$GC_LOG" 'mail send gc__impl-rc-1' 1 "the SAME implementor is re-notified"
assert_eq "" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-190" "inflight_rework")" "still bead-less after the re-notify"
assert_eq "gc__impl-rc-1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-190" "implementor_session")" "implementor is unchanged (reuse, not reassignment)"
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-190" "attempt_count")" "attempt counter increments"
new_last_dispatch_19="$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-190" "last_dispatch_at")"
if [ -n "$new_last_dispatch_19" ] && [ "$new_last_dispatch_19" != "$(iso_ago 1800)" ]; then
  pass "last_dispatch_at is refreshed to a new timestamp on re-notify"
else
  fail "expected last_dispatch_at to be refreshed after the re-notify (got '${new_last_dispatch_19}')"
fi

# ===========================================================================
# CASE 20 — fk-lfan B1, hermetic case (c): implementor set + inflight_rework
#   EMPTY + implementor ALIVE + last_dispatch_at FRESH (within
#   CV_STALL_SECONDS) -> no action. A live implementor working a mail-only
#   reuse dispatch must be left alone exactly like a live implementor
#   progressing on a tracked bead (CASE 7).
# ===========================================================================
start_case "20: B1 case (c) — bead-less reuse, implementor alive + last_dispatch_at fresh -> no action"
setup_case_env "20"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-200" \
  "gc__impl-rc-1" "" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "200" "fix/thing" "0" "0" "$(iso_ago 30)"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__impl-rc-1","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail — the implementor is alive and last_dispatch_at is fresh"
assert_log_count "$GC_LOG" 'bd create' 0 "no fallback bead"
assert_log_count "$GC_LOG" 'sling' 0 "no sling"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-200" "attempt_count")" "attempt_count stays at 0 when nothing needed re-dispatch"

# ===========================================================================
# CASE 21 — fk-11yuv Fix 2b: the tracked bead was claimed/updated in the
#   window between the initial classification read and the moment this
#   watchdog is about to act on it (e.g. it just got claimed after all, or its
#   implementor just made progress). The fresh pre-action recheck must see
#   that and yield — no fallback bead minted, no supersede, no state change —
#   rather than racing a second lineage against activity that just happened.
#   STUB_BDSHOW_MAP gives TWO rows for the same bead id: the classification
#   read gets the first (stale) row, the pre-action recheck gets the second
#   (fresh) row — see the gc stub's per-id call sequencing above.
# ===========================================================================
start_case "21: fk-11yuv Fix 2b — tracked bead claimed since evaluation yields (no second lineage)"
setup_case_env "21"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-210" \
  "" "wd-bead210" "blocked" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "210" "fix/thing" "0" "0"
STALE_TS_210="$(iso_ago 5000)"
FRESH_TS_210="$(iso_ago 10)"
run_script "${DEFAULT_ENV[@]}" \
  STUB_BDSHOW_MAP="$(printf 'wd-bead210|open|%s\nwd-bead210|open|%s' "$STALE_TS_210" "$FRESH_TS_210")" \
  STUB_BD_CREATE_ID="wd-bead210b"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd create' 0 "no fallback bead minted — the bead was claimed/updated since the initial read"
assert_log_count "$GC_LOG" 'sling' 0 "no re-dispatch — yielding to the fresh activity instead of racing it"
assert_log_count "$GC_LOG" 'bd close' 0 "the newly-active bead is not superseded"
assert_eq "wd-bead210" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-210" "inflight_rework")" "state is left untouched for the next cycle"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-210" "attempt_count")" "attempt_count is left untouched — this was not a real attempt"
if printf '%s' "$OUT" | grep -q 'claimed/updated since evaluation'; then
  pass "logs a yield for the late claim"
else
  fail "expected a yield log line naming the late claim"
fi

# ===========================================================================
# CASE 22 — fk-11yuv Fix 2b, the actual bug: two REAL concurrent watchdog
#   invocations racing the SAME stale, never-claimed state record must produce
#   exactly ONE re-dispatch lineage, not two. Seen live on kriscoleman/
#   foundry#81: two overlapping cycles both observed the same "STALLED, never
#   claimed" record and both superseded + re-minted a fallback bead before
#   either one's state_write was visible to the other. Process A acquires the
#   dedup_key's lock and sleeps INSIDE its `bd create` call (holding the lock
#   the whole time via STUB_BD_CREATE_SLEEP); process B is launched a beat
#   later and is guaranteed to find the lock already held — a deterministic
#   race, not a timing coin flip.
# ===========================================================================
start_case "22: fk-11yuv Fix 2b — two concurrent invocations produce ONE lineage, not two"
setup_case_env "22"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-220" \
  "" "wd-bead220" "blocked" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "220" "fix/thing" "0" "0"
STALE_TS_220="$(iso_ago 5000)"

GC_LOG_A="${SANDBOX}/gc-22-a.log"; : > "$GC_LOG_A"
GC_LOG_B="${SANDBOX}/gc-22-b.log"; : > "$GC_LOG_B"
OUT_A="${SANDBOX}/out-22-a.log"
OUT_B="${SANDBOX}/out-22-b.log"

env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
  CV_STATE_DIR="$STATE_DIR" STUB_GC_LOG="$GC_LOG_A" \
  "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead220|open|${STALE_TS_220}" \
  STUB_BD_CREATE_ID="wd-bead220a" STUB_BD_CREATE_SLEEP="1" \
  bash "$SCRIPT" > "$OUT_A" 2>&1 &
PID_A=$!

sleep 0.3

env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
  CV_STATE_DIR="$STATE_DIR" STUB_GC_LOG="$GC_LOG_B" \
  "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead220|open|${STALE_TS_220}" \
  STUB_BD_CREATE_ID="wd-bead220b" \
  bash "$SCRIPT" > "$OUT_B" 2>&1 &
PID_B=$!

wait "$PID_A"; RC_A=$?
wait "$PID_B"; RC_B=$?

assert_eq "0" "$RC_A" "process A exits 0"
assert_eq "0" "$RC_B" "process B exits 0"

total_create=$(( $(log_count "$GC_LOG_A" 'bd create') + $(log_count "$GC_LOG_B" 'bd create') ))
total_sling=$(( $(log_count "$GC_LOG_A" 'sling') + $(log_count "$GC_LOG_B" 'sling') ))
total_close=$(( $(log_count "$GC_LOG_A" 'bd close wd-bead220 .*superseded') + $(log_count "$GC_LOG_B" 'bd close wd-bead220 .*superseded') ))

assert_eq "1" "$total_create" "exactly ONE fallback bead is minted across both concurrent runs, not two"
assert_eq "1" "$total_sling" "exactly ONE re-dispatch sling across both concurrent runs, not two"
assert_eq "1" "$total_close" "the never-claimed bead is superseded exactly once, not twice"

if grep -q 'locked by a concurrent watchdog run' "$OUT_A" "$OUT_B"; then
  pass "one of the two concurrent runs logs a lock-contention SKIP for the shared dedup_key"
else
  fail "expected one of the two concurrent runs to log a lock-contention SKIP"
fi

assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-220" "attempt_count")" "attempt_count advances by exactly 1 across both concurrent runs, not 2"

# ===========================================================================
# CASE 23 — review fk-uxj98 BLOCKING-1: the stale-lock STEAL itself must be
#   atomic. CASE 22 only proves mutual exclusion for a lock a live holder just
#   created (it starts with no lock at all, so no steal is ever exercised).
#   This case pre-creates an ALREADY-stale lock — as a crashed/frozen holder
#   would leave behind (CV_LOCK_STALE_SECONDS default 300s; this lock's mtime
#   is forced to epoch 0) — and launches several real concurrent invocations
#   that all observe the same stale lock and race to steal it. Against the
#   pre-fix `rm -rf` + `mkdir` steal this is a genuine race, not a guaranteed
#   failure: code-review's own reproduction measured a ~55% double-acquire
#   rate across 60 trials of 8 concurrent stealers on one stale lock, so any
#   SINGLE trial can pass clean by luck. This case therefore repeats the
#   8-way race across several independent trials (fresh sandbox each time)
#   and fails immediately if ANY trial produces more than one winner — the
#   atomic rename-based claim is not probabilistic; every trial must show
#   exactly one winner.
# ===========================================================================
N23=8
TRIALS23=5
for ((t = 1; t <= TRIALS23; t++)); do
  start_case "23.${t}: BLOCKING-1 — concurrent stale-lock steal produces ONE lineage, not ${N23} (trial ${t}/${TRIALS23})"
  setup_case_env "23-${t}"
  write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-230" \
    "" "wd-bead230" "blocked" "kriscoleman" "vandoor/gc.implementation-worker" \
    "kriscoleman/foundry" "230" "fix/thing" "0" "0"
  STALE_TS_230="$(iso_ago 5000)"

  LOCK_230="${STATE_DIR}/.locks/cv-ci-repair-kriscoleman-foundry-230.lock"
  mkdir -p "$LOCK_230"
  printf '99999\n' > "${LOCK_230}/pid"
  python3 -c "import os; os.utime('${LOCK_230}', (0, 0))"

  PIDS_230=()
  for ((i = 1; i <= N23; i++)); do
    env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
      CV_STATE_DIR="$STATE_DIR" STUB_GC_LOG="${SANDBOX}/gc-23-${t}-${i}.log" \
      "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="wd-bead230|open|${STALE_TS_230}" \
      STUB_BD_CREATE_ID="wd-bead230-${t}-${i}" \
      bash "$SCRIPT" > "${SANDBOX}/out-23-${t}-${i}.log" 2>&1 &
    PIDS_230+=("$!")
  done

  fail_count=0
  for pid in "${PIDS_230[@]}"; do
    wait "$pid" || fail_count=$((fail_count + 1))
  done
  assert_eq "0" "$fail_count" "all $N23 concurrent invocations exit 0"

  total_create=0; total_sling=0; total_close=0; total_lock_skip=0
  for ((i = 1; i <= N23; i++)); do
    total_create=$((total_create + $(log_count "${SANDBOX}/gc-23-${t}-${i}.log" 'bd create')))
    total_sling=$((total_sling + $(log_count "${SANDBOX}/gc-23-${t}-${i}.log" 'sling')))
    total_close=$((total_close + $(log_count "${SANDBOX}/gc-23-${t}-${i}.log" 'bd close wd-bead230 .*superseded')))
    total_lock_skip=$((total_lock_skip + $(log_count "${SANDBOX}/out-23-${t}-${i}.log" 'locked by a concurrent watchdog run')))
  done

  assert_eq "1" "$total_create" "exactly ONE fallback bead is minted across $N23 concurrent stale-lock stealers, not $N23"
  assert_eq "1" "$total_sling" "exactly ONE re-dispatch sling across $N23 concurrent stale-lock stealers"
  assert_eq "1" "$total_close" "the never-claimed bead is superseded exactly once, not $N23 times"
  assert_eq "$((N23 - 1))" "$total_lock_skip" "the other $((N23 - 1)) invocations each yield a lock-contention SKIP, none silently double-acquire"
  assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-230" "attempt_count")" "attempt_count advances by exactly 1 across all $N23 concurrent stealers, not $N23"
  # 0 or 1, never more: a race where the eventual sole winner happens to take
  # the plain top-level `mkdir` branch (because it landed in the momentary gap
  # of some other contender's losing steal attempt) legitimately logs no
  # NOTICE at all — still exactly one winner overall (checked above) — while
  # 2+ would mean two processes both believed they completed the steal.
  notice_count_230="$(grep -l 'NOTICE: stole stale lock' "${SANDBOX}"/out-23-"${t}"-*.log 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$notice_count_230" -le 1 ]; then
    pass "at most one run logs the stale-lock steal NOTICE (=${notice_count_230})"
  else
    fail "at most one run logs the stale-lock steal NOTICE (expected <=1, got ${notice_count_230})"
  fi
done

# ===========================================================================
# Summary
# ===========================================================================
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
