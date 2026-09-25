#!/usr/bin/env bash
# con-voyage-review-watchdog.test.sh — hermetic, offline test for the con-voyage
# review-lane liveness watchdog (fk-loo1 FIX-F, DEFENSE-IN-DEPTH half of the
# review-lens liveness guard).
#
# BACKGROUND: review lens sessions are pool-managed and their only task
# delivery is a core nudge-on-route mechanism. On a slow-startup (large) repo
# a lens can take minutes to wake; if the pool restarts its still-starting
# run-operator in that window, the review-lane bead it would have claimed is
# left open+unassigned forever and the review loop can never fan in (see the
# fk-loo1 bead description for the full dogfooding root-cause writeup). The
# PRIMARY fix is an in-loop claim-verification/re-dispatch block added to
# {target}.con-voyage-review-loop.md; this script is the periodic,
# independent safety net that catches a stalled lane even when the review
# loop's own run-operator is the thing that died.
#
# DESIGN NOTE (why this looks different from con-voyage-repair-watchdog.sh):
# that watchdog needs an external CV_STATE_DIR state file because a GitHub PR
# has no durable bd-bead representation spanning its whole repair lifecycle.
# A review-lane bead has no such gap — it IS the durable, queryable record —
# so this watchdog persists its own attempt_count/escalated bookkeeping
# directly on the lane bead's metadata (gc.review_watchdog.*) instead of a
# side-channel file, and discovers candidates with a single `bd list`
# metadata-field query instead of globbing state records.
#
# HOW IT WORKS (no network, no real gc): a recording STUB `gc` is built in a
# temp dir, backed by a small JSON "database" file that `bd list` reads and
# `bd update --set-metadata` mutates in place — this is what lets a multi-cycle
# test (CASE 15) observe attempt_count actually persisting across independent
# invocations of the script, exactly like the real bead metadata would. The
# script under test honors GC= (default gc) so we point it at the stub.
#
# CASES 17-18 additionally exercise multi-store discovery (fk-jsdw2): the
# stub also answers `rig list --json` (from STUB_RIGS_JSON, default
# '{"rigs":[]}' so every pre-existing case above is unaffected) and, when a
# `bd list` call carries `--rig <name>`, serves that rig's OWN fixture from
# `${STUB_DB_DIR}/<name>.json` instead of the shared STUB_DB_FILE — so a lane
# that exists ONLY in one rig's store can be proven discoverable independent
# of the city store.
#
# CASE 16 additionally content-checks the PRIMARY half of this same fix — the
# in-loop claim-verification/re-dispatch block added directly to
# {target}.con-voyage-review-loop.md. That block runs inside the review-loop's
# own run-operator session (not as a standalone script), so it has no
# separate executable test target; pinning its required shape here follows
# the same convention as con-voyage-ci-repair-guard.test.sh's content checks
# against {target}.ci-repair.md.
#
# Run:  bash tests/con-voyage-review-watchdog.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-review-watchdog.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-watchdog-test.XXXXXX")"
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
# The `gc` stub. Records argv, and backs `bd list`/`bd update --set-metadata`
# with a small JSON "database" file (STUB_DB_FILE) so state genuinely
# persists across independent invocations within one test case (CASE 15).
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

args=("$@")
i=0
stub_rig=""
while :; do
  case "${args[$i]:-}" in
    --city) i=$((i+2)) ;;
    --rig)  stub_rig="${args[$((i+1))]:-}"; i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"

case "$sub" in
  rig)
    rigsub="${args[$((i+1))]:-}"
    if [ "$rigsub" = "list" ]; then
      if [ -n "${STUB_RIGS_JSON:-}" ]; then
        printf '%s' "$STUB_RIGS_JSON"
      else
        printf '{"rigs":[]}'
      fi
      exit 0
    fi
    exit 0
    ;;
  bd)
    bdsub="${args[$((i+1))]:-}"
    if [ "$bdsub" = "list" ]; then
      if [ -n "$stub_rig" ] && [ "$stub_rig" = "${STUB_RIG_LIST_FAIL_FOR:-}" ]; then
        exit 1
      fi
      if [ -n "$stub_rig" ] && [ -n "${STUB_DB_DIR:-}" ]; then
        cat "${STUB_DB_DIR}/${stub_rig}.json" 2>/dev/null || printf '[]'
      else
        cat "${STUB_DB_FILE}" 2>/dev/null || printf '[]'
      fi
      exit 0
    fi
    if [ "$bdsub" = "update" ]; then
      if [ "${STUB_BDUPDATE_FAIL:-0}" = "1" ]; then
        exit 1
      fi
      target_id="${args[$((i+2))]:-}"
      # Collect every "--set-metadata key=value" pair that follows.
      pairs=()
      j=$((i+3))
      while [ "$j" -lt "${#args[@]}" ]; do
        if [ "${args[$j]}" = "--set-metadata" ]; then
          pairs+=("${args[$((j+1))]}")
          j=$((j+2))
        else
          j=$((j+1))
        fi
      done
      python3 - "$STUB_DB_FILE" "$target_id" "${pairs[@]}" <<'PYEOF'
import sys, json
db_file, target_id = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
try:
    with open(db_file) as f:
        db = json.load(f)
except Exception:
    db = []
for d in db:
    if d.get('id') == target_id:
        meta = d.setdefault('metadata', {})
        for p in pairs:
            k, _, v = p.partition('=')
            meta[k] = v
with open(db_file, 'w') as f:
    json.dump(db, f)
PYEOF
      exit 0
    fi
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
      if [ -n "${STUB_SESSION_LIST_JSON:-}" ]; then
        printf '%s' "$STUB_SESSION_LIST_JSON"
      else
        printf '{"sessions":[]}'
      fi
      exit 0
    fi
    if [ "$sessub" = "nudge" ]; then
      if [ "${STUB_SESSION_NUDGE_FAIL:-0}" = "1" ]; then
        echo "gc session nudge: failed to deliver (simulated)" >&2
        exit 1
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
# Test harness bookkeeping (same idioms as con-voyage-repair-watchdog.test.sh).
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

db_metadata_field() {
  # db_metadata_field ID FIELD — current value of metadata[FIELD] for bead ID
  # in the live STUB_DB_FILE, or empty if absent/bead unknown.
  python3 -c "
import json, sys
db_file, bead_id, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(db_file) as f:
        db = json.load(f)
except Exception:
    print(''); raise SystemExit(0)
for d in db:
    if d.get('id') == bead_id:
        print((d.get('metadata') or {}).get(field, '') or '')
        raise SystemExit(0)
print('')
" "$1" "$2" "$3"
}

# lane ID STATUS ASSIGNEE UPDATED_AT ROUTED_TO ATTEMPT_COUNT ESCALATED TITLE —
# build one review-lane bead JSON object (default title is a real floor-lane
# title so the ralph_step_id/scope_role/title filters all pass by default).
lane() {
  python3 -c "
import json, sys
_id, status, assignee, updated_at, routed_to, attempt_count, escalated, title = sys.argv[1:9]
meta = {
    'gc.ralph_step_id': 'main.con-voyage-review-loop',
    'gc.scope_role': 'member',
    'gc.routed_to': routed_to,
}
if attempt_count != '__ABSENT__':
    meta['gc.review_watchdog.attempt_count'] = attempt_count
if escalated != '__ABSENT__':
    meta['gc.review_watchdog.escalated'] = escalated
print(json.dumps({
    'id': _id, 'status': status, 'assignee': assignee, 'updated_at': updated_at,
    'title': title, 'metadata': meta,
}))
" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-Con-voyage: test evidence}"
}

write_db() {
  # write_db FILE LANE_JSON... — assemble a JSON array fixture.
  local file="$1"; shift
  python3 -c "
import json, sys
print(json.dumps([json.loads(x) for x in sys.argv[1:]]))
" "$@" > "$file"
}

CITY_DIR=""
DB_FILE=""
DB_DIR=""
GC_LOG=""
OUT=""
RC=0

setup_case_env() {
  CITY_DIR="${SANDBOX}/city-${1}"
  DB_FILE="${SANDBOX}/db-${1}.json"
  DB_DIR="${SANDBOX}/db-dir-${1}"
  GC_LOG="${SANDBOX}/gc-${1}.log"
  mkdir -p "$CITY_DIR" "$DB_DIR"
  printf '[]' > "$DB_FILE"
  : > "$GC_LOG"
}

# write_rig_db RIG_NAME LANE_JSON... — a rig-scoped fixture at
# ${DB_DIR}/<rig-name>.json, served when the script queries `bd list --rig
# <rig-name>` (as opposed to the shared city-level DB_FILE).
write_rig_db() {
  local rig_name="$1"; shift
  write_db "${DB_DIR}/${rig_name}.json" "$@"
}

# run_script — invoke the script under test with the stub wired in.
run_script() {
  OUT="$(
    env \
      GC="${STUBDIR}/gc" \
      GC_CITY="$CITY_DIR" \
      STUB_GC_LOG="$GC_LOG" \
      STUB_DB_FILE="$DB_FILE" \
      STUB_DB_DIR="$DB_DIR" \
      "$@" \
      bash "$SCRIPT" 2>&1
  )"
  RC=$?
}

DEFAULT_ENV=(CV_LENS_STALL_SECONDS="600" CV_LENS_MAX_ATTEMPTS="3" CV_LENS_ESCALATE_TARGET="human")

# ===========================================================================
# CASE 1 — Empty candidate set: nothing to do, exits 0.
# ===========================================================================
start_case "1: no active review lanes is a clean no-op"
setup_case_env "1"
run_script "${DEFAULT_ENV[@]}"
assert_eq "0" "$RC" "script exits 0 with no candidate lanes"
assert_log_count "$GC_LOG" 'session list|sling|mail send' 0 "no follow-up gc calls when nothing was found"

# ===========================================================================
# CASE 2 — Discovery excludes non-lane beads sharing the same loop scope
#   (apply-findings/synthesize/control beads) even though they are open.
# ===========================================================================
start_case "2: non-lane beads in the same review-loop scope are never candidates"
setup_case_env "2"
write_db "$DB_FILE" \
  "$(lane "fk-apply" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.implementation-worker" "0" "0" "Apply con-voyage review findings")" \
  "$(lane "fk-synth" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.review-synthesizer" "0" "0" "Synthesize con-voyage review")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling|mail send|session nudge' 0 "non-lane titles are filtered out before any action is considered"

# ===========================================================================
# CASE 3 — Acceptance: fast repo, lens claims immediately -> unchanged
#   behavior. Open+unassigned but FRESH, and the route has a live session.
# ===========================================================================
start_case "3: open+unassigned, route alive, fresh updated_at -> no action"
setup_case_env "3"
write_db "$DB_FILE" "$(lane "fk-lane1" "open" "" "$(iso_ago 5)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling|mail send|session nudge fk-lane1|session nudge rc-1' 0 "a freshly-created, still-unclaimed lane with a live pool is left alone"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-lane1" "gc.review_watchdog.attempt_count")" "attempt_count stays 0"

# ===========================================================================
# CASE 4 — Open+unassigned, route session alive, but STALE past
#   CV_LENS_STALL_SECONDS -> touch (persist attempt_count) + nudge that
#   session directly.
# ===========================================================================
start_case "4: open+unassigned, route alive, stale -> nudge the live pool session"
setup_case_env "4"
write_db "$DB_FILE" "$(lane "fk-lane2" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-2","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session nudge rc-2 ' 1 "the live pool session is nudged directly"
assert_log_count "$GC_LOG" 'sling' 0 "no re-route while the pool still has a live session"
assert_log_count "$GC_LOG" '^bd update fk-lane2 ' 1 "fk-mr07: the attempt_count update omits --city (fk-lane2 is an existing, already-rig-prefixed lane bead — --city alone routes it to the CITY store and 'Issue not found's every cycle, the fk-7v3r bug class); relies on cwd auto-detection like every other already-fixed bd call in this pack"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-lane2" "gc.review_watchdog.attempt_count")" "attempt_count advances to 1"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-lane2" "gc.review_watchdog.escalated")" "not escalated after one attempt"

# ===========================================================================
# CASE 5 — Open+unassigned, NO live session anywhere for the route (pool
#   drained) -> immediate re-route via `gc sling ... --nudge`, no staleness
#   gate (mirrors con-voyage-repair-watchdog's "confirmed-dead is unambiguous
#   on its own"). Proven here with a FRESH updated_at.
# ===========================================================================
start_case "5: open+unassigned, pool fully drained -> immediate re-route (no staleness gate)"
setup_case_env "5"
write_db "$DB_FILE" "$(lane "fk-lane3" "open" "" "$(iso_ago 5)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling foundry-kc/gc.gap-analyst fk-lane3 --nudge' 1 "the lane is re-routed to its own target with an immediate nudge"
assert_log_count "$GC_LOG" 'session nudge' 0 "no direct session nudge — there is nobody alive to nudge"
assert_log_count "$GC_LOG" '^bd update fk-lane3 ' 1 "fk-mr07: the re-route branch's attempt_count update omits --city (fk-lane3 is an existing, already-rig-prefixed lane bead — same fk-7v3r bug class as CASE 4's nudge-branch update); relies on cwd auto-detection like every other already-fixed bd call in this pack"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-lane3" "gc.review_watchdog.attempt_count")" "attempt_count advances to 1 even though the lane was still fresh"

# ===========================================================================
# CASE 6 — Missing gc.routed_to metadata: never guess at a re-dispatch
#   target. Logs a WARNING, takes no action, leaves attempt_count untouched.
# ===========================================================================
start_case "6: open+unassigned with no gc.routed_to -> WARNING, no guess"
setup_case_env "6"
write_db "$DB_FILE" "$(lane "fk-lane4" "open" "" "$(iso_ago 5000)" "" "__ABSENT__" "__ABSENT__")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling|session nudge|mail send' 0 "no action taken without a routed_to target"
if printf '%s' "$OUT" | grep -q 'WARNING'; then pass "logs a WARNING for the missing route"; else fail "expected a WARNING for the missing route"; fi
assert_eq "" "$(db_metadata_field "$DB_FILE" "fk-lane4" "gc.review_watchdog.attempt_count")" "attempt_count is never written — this was not a real attempt"

# ===========================================================================
# CASE 7 — Acceptance: claimed + alive + progressing (fresh) -> no action.
# ===========================================================================
start_case "7: in_progress, assignee alive, fresh updated_at -> no action"
setup_case_env "7"
write_db "$DB_FILE" "$(lane "fk-lane5" "in_progress" "gc__gap-analyst-rc-5" "$(iso_ago 5)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-5","session_name":"gc__gap-analyst-rc-5","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session nudge|sling|mail send' 0 "a progressing, claimed lane is left alone"

# ===========================================================================
# CASE 8 — Claimed but stalled (assignee alive, updated_at stale) ->
#   re-notify the SAME assignee session directly (no re-route/new bead).
# ===========================================================================
start_case "8: in_progress, assignee alive, stalled -> nudge the same assignee"
setup_case_env "8"
write_db "$DB_FILE" "$(lane "fk-lane6" "in_progress" "gc__gap-analyst-rc-6" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-6","session_name":"gc__gap-analyst-rc-6","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session nudge rc-6 ' 1 "the same claimed lens session is re-notified"
assert_log_count "$GC_LOG" 'sling' 0 "a claimed lane is never re-routed out from under its assignee"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-lane6" "gc.review_watchdog.attempt_count")" "attempt_count advances to 1"

# ===========================================================================
# CASE 9 — Claimed + stalled, but the assignee's own session is no longer
#   alive either: no safe target to nudge. WARNING, no action, no guess.
# ===========================================================================
start_case "9: in_progress, stalled, assignee session also gone -> WARNING, no guess"
setup_case_env "9"
write_db "$DB_FILE" "$(lane "fk-lane7" "in_progress" "gc__gap-analyst-rc-7" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "__ABSENT__" "__ABSENT__")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session nudge|sling|mail send' 0 "no action without a live target to nudge"
if printf '%s' "$OUT" | grep -q 'WARNING'; then pass "logs a WARNING for the unreachable assignee"; else fail "expected a WARNING"; fi
assert_eq "" "$(db_metadata_field "$DB_FILE" "fk-lane7" "gc.review_watchdog.attempt_count")" "attempt_count is never written — this was not a real attempt"

# ===========================================================================
# CASE 10 — Already escalated: no further action of any kind, ever, even
#   though the lane still looks stalled.
# ===========================================================================
start_case "10: already-escalated lane takes no further action"
setup_case_env "10"
write_db "$DB_FILE" "$(lane "fk-lane8" "open" "" "$(iso_ago 99999)" "foundry-kc/gc.gap-analyst" "3" "1")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling|session nudge|mail send' 0 "no repeated action once escalated"

# ===========================================================================
# CASE 11 — Attempt cap already reached: escalate via mail instead of a 4th
#   re-dispatch; sets escalated=1, preserves attempt_count.
# ===========================================================================
start_case "11: attempt cap reached -> escalate instead of re-dispatching"
setup_case_env "11"
write_db "$DB_FILE" "$(lane "fk-lane9" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "3" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling|session nudge' 0 "no 4th re-dispatch once the cap is reached"
assert_log_count "$GC_LOG" 'mail send human' 1 "exactly one escalation mail to the operator"
assert_log_count "$GC_LOG" 'mail send human .*fk-lane9' 1 "the escalation mail names the lane"
assert_log_count "$GC_LOG" '^bd update fk-lane9 ' 1 "fk-mr07: the escalate branch's escalated-flag update omits --city (fk-lane9 is an existing, already-rig-prefixed lane bead — same fk-7v3r bug class as CASE 4's nudge-branch update); relies on cwd auto-detection like every other already-fixed bd call in this pack"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-lane9" "gc.review_watchdog.escalated")" "escalated flag is now set"
assert_eq "3" "$(db_metadata_field "$DB_FILE" "fk-lane9" "gc.review_watchdog.attempt_count")" "attempt_count is preserved through escalation, not incremented further"

start_case "11b: escalation honors a custom CV_LENS_ESCALATE_TARGET"
setup_case_env "11b"
write_db "$DB_FILE" "$(lane "fk-lane9b" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "3" "0")"
run_script CV_LENS_STALL_SECONDS="600" CV_LENS_MAX_ATTEMPTS="3" CV_LENS_ESCALATE_TARGET="oncall-lead" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send oncall-lead' 1 "escalation goes to the configured target"

# ===========================================================================
# CASE 12 — A failed escalation mail must NOT set escalated=1, so a transient
#   mail outage is retried next cycle instead of silently going permanently
#   quiet on a lane the operator was never actually told about.
# ===========================================================================
start_case "12: a failed escalation mail is retried next cycle (no false escalated=1)"
setup_case_env "12"
write_db "$DB_FILE" "$(lane "fk-lane10" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "3" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}' STUB_MAIL_SEND_FAIL=1
assert_eq "0" "$RC" "script exits 0 (a failed escalation is non-fatal to the whole run)"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-lane10" "gc.review_watchdog.escalated")" "escalated stays 0 when the mail itself failed to send"
if printf '%s' "$OUT" | grep -q 'WARNING'; then pass "logs a WARNING for the failed escalation mail"; else fail "expected a WARNING"; fi

# ===========================================================================
# CASE 13 — Multiple independent lanes in one run: each judged solely on its
#   own fields.
# ===========================================================================
start_case "13: multiple lanes are each judged independently"
setup_case_env "13"
write_db "$DB_FILE" \
  "$(lane "fk-lane11" "open" "" "$(iso_ago 5)" "foundry-kc/gc.gap-analyst" "0" "0")" \
  "$(lane "fk-lane12" "open" "" "$(iso_ago 5000)" "foundry-kc/con-voyage.cv-security-reviewer" "0" "0" "Con-voyage: security review")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-11","template":"foundry-kc/gc.gap-analyst","state":"active"},{"id":"rc-12","template":"foundry-kc/con-voyage.cv-security-reviewer","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session nudge rc-11 ' 0 "the fresh lane is untouched"
assert_log_count "$GC_LOG" 'session nudge rc-12 ' 1 "the stalled lane's live pool session is nudged"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-lane11" "gc.review_watchdog.attempt_count")" "lane 11 untouched"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-lane12" "gc.review_watchdog.attempt_count")" "lane 12 re-dispatched"

# ===========================================================================
# CASE 14 — Robustness: a malformed attempt_count metadata value must never
#   abort the pass or block a legitimate re-dispatch — coerced to 0 (same
#   fail-safe posture as every other malformed-field guard in this pack).
# ===========================================================================
start_case "14: a malformed attempt_count is coerced to 0, not fatal"
setup_case_env "14"
write_db "$DB_FILE" "$(lane "fk-lane13" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "not-a-number" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-13","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0 (a malformed attempt_count does not crash the whole pass)"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-lane13" "gc.review_watchdog.attempt_count")" "a non-numeric attempt_count is treated as 0 and increments to 1"

# ===========================================================================
# CASE 15 — End-to-end, multi-cycle: a persistently stalled, pool-alive lane
#   is re-dispatched on three consecutive watchdog cycles (attempt_count
#   climbs 1, 2, 3), the FOURTH consecutive detection escalates and stops,
#   and a FIFTH cycle sends no further mail (no escalation spam). Each
#   invocation reads back the PRIOR invocation's persisted attempt_count from
#   the shared STUB_DB_FILE, exactly like real bead metadata would.
# ===========================================================================
start_case "15: 3 stalled cycles then escalation on the 4th, silence on the 5th (end-to-end)"
setup_case_env "15"
STALE_TS="$(iso_ago 5000)"
write_db "$DB_FILE" "$(lane "fk-lane14" "open" "" "$STALE_TS" "foundry-kc/gc.gap-analyst" "0" "0")"

for n in 1 2 3; do
  GC_LOG="${SANDBOX}/gc-15-${n}.log"; : > "$GC_LOG"
  run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-14","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
  assert_eq "0" "$RC" "cycle ${n} exits 0"
  assert_log_count "$GC_LOG" 'session nudge rc-14 ' 1 "cycle ${n} nudges the pool session"
  assert_eq "$n" "$(db_metadata_field "$DB_FILE" "fk-lane14" "gc.review_watchdog.attempt_count")" "cycle ${n} advances attempt_count to ${n}"
  assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-lane14" "gc.review_watchdog.escalated")" "cycle ${n} has not escalated yet"
done

GC_LOG="${SANDBOX}/gc-15-4.log"; : > "$GC_LOG"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-14","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "0" "$RC" "cycle 4 exits 0"
assert_log_count "$GC_LOG" 'session nudge' 0 "cycle 4 does not nudge again — it escalates instead"
assert_log_count "$GC_LOG" 'mail send human' 1 "cycle 4 escalates to the operator"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-lane14" "gc.review_watchdog.escalated")" "cycle 4 sets escalated=1"

GC_LOG="${SANDBOX}/gc-15-5.log"; : > "$GC_LOG"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-14","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "0" "$RC" "cycle 5 exits 0"
assert_log_count "$GC_LOG" 'mail send' 0 "cycle 5 sends no mail of any kind — already escalated, no repeated spam"

# ===========================================================================
# CASE 16 — Content checks: the PRIMARY half of fk-loo1 FIX-F is an in-loop
#   claim-verification/re-dispatch block added directly to
#   {target}.con-voyage-review-loop.md (it runs inside the review-loop's own
#   run-operator session, not as a standalone script, so it has no separate
#   executable test target — pin its required shape here instead, same
#   convention as con-voyage-ci-repair-guard.test.sh's content checks against
#   {target}.ci-repair.md).
# ===========================================================================
start_case "16: {target}.con-voyage-review-loop.md carries the claim-verification/re-dispatch block"
REVIEW_LOOP_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/{target}.con-voyage-review-loop.md"
if [ -f "$REVIEW_LOOP_MD" ]; then pass "review-loop workflow file exists"; else fail "review-loop workflow file not found at ${REVIEW_LOOP_MD}"; fi

if grep -q '## Verify review-lane claims and re-dispatch stalled lenses' "$REVIEW_LOOP_MD"; then
  pass "carries the claim-verification section heading"
else
  fail "expected a '## Verify review-lane claims and re-dispatch stalled lenses' section"
fi
if grep -q '{{cv_lens_claim_seconds}}' "$REVIEW_LOOP_MD" && grep -q '{{cv_lens_max_redispatch}}' "$REVIEW_LOOP_MD" && grep -q '{{cv_lens_escalate_target}}' "$REVIEW_LOOP_MD"; then
  pass "references all three cv_lens_* formula vars"
else
  fail "expected {{cv_lens_claim_seconds}}, {{cv_lens_max_redispatch}}, and {{cv_lens_escalate_target}} all present"
fi
if grep -q -- '--include-dependents' "$REVIEW_LOOP_MD" && grep -q 'dependency_type.*tracks' "$REVIEW_LOOP_MD"; then
  pass "discovers active lanes from the claimed step bead's own tracks-dependents (not guessed)"
else
  fail "expected lane discovery via bd show \$GC_BEAD_ID --include-dependents filtered on dependency_type=tracks"
fi
if grep -q "startswith('Con-voyage: ')" "$REVIEW_LOOP_MD"; then
  pass "filters lanes by the 'Con-voyage: ' title prefix (excludes apply-findings/synthesize)"
else
  fail "expected a title prefix filter excluding non-lane scope siblings"
fi
if grep -q 'CV_LENS_MAX_REDISPATCH' "$REVIEW_LOOP_MD" && grep -q 'gc mail send' "$REVIEW_LOOP_MD"; then
  pass "bounds re-dispatch attempts and escalates via mail"
else
  fail "expected a bounded attempt counter and a gc mail send escalation path"
fi
if grep -q 'gc sling' "$REVIEW_LOOP_MD"; then
  pass "re-routes via gc sling when the routed pool has no live session"
else
  fail "expected a gc sling re-route path for a drained pool"
fi
if grep -q 'gc session nudge' "$REVIEW_LOOP_MD"; then
  pass "nudges a live pool session directly"
else
  fail "expected a gc session nudge path for an alive pool"
fi

start_case "16b: con-voyage.formula.toml declares the three cv_lens_* vars with documented defaults"
FORMULA_TOML="${MOLD_DIR}/pack/formulas/con-voyage.formula.toml"
if grep -q '\[vars.cv_lens_claim_seconds\]' "$FORMULA_TOML" && grep -A15 '\[vars.cv_lens_claim_seconds\]' "$FORMULA_TOML" | grep -q 'default = "300"'; then
  pass "cv_lens_claim_seconds defaults to 300"
else
  fail "expected [vars.cv_lens_claim_seconds] default = \"300\""
fi
if grep -q '\[vars.cv_lens_max_redispatch\]' "$FORMULA_TOML" && grep -A15 '\[vars.cv_lens_max_redispatch\]' "$FORMULA_TOML" | grep -q 'default = "3"'; then
  pass "cv_lens_max_redispatch defaults to 3"
else
  fail "expected [vars.cv_lens_max_redispatch] default = \"3\""
fi
if grep -q '\[vars.cv_lens_escalate_target\]' "$FORMULA_TOML" && grep -A15 '\[vars.cv_lens_escalate_target\]' "$FORMULA_TOML" | grep -q 'default = "human"'; then
  pass "cv_lens_escalate_target defaults to the reserved human alias"
else
  fail "expected [vars.cv_lens_escalate_target] default = \"human\""
fi

start_case "16c: review-loop.md integer-coerces CV_LENS_CLAIM_SECONDS/CV_LENS_MAX_REDISPATCH (FIX-F security LOW follow-up)"
# shellcheck disable=SC2016 # intentionally matching the literal $VAR text in the markdown source, not expanding it
if grep -A3 'case "\$CV_LENS_CLAIM_SECONDS" in' "$REVIEW_LOOP_MD" | grep -q '\*\[!0-9\]\*' \
   && grep -A3 'case "\$CV_LENS_CLAIM_SECONDS" in' "$REVIEW_LOOP_MD" | grep -q 'CV_LENS_CLAIM_SECONDS="300"'; then
  pass "a non-numeric CV_LENS_CLAIM_SECONDS falls back to the documented default (300)"
else
  fail "expected a case \"\$CV_LENS_CLAIM_SECONDS\" in *[!0-9]*|'') CV_LENS_CLAIM_SECONDS=\"300\" ;; esac guard, mirroring con-voyage-review-watchdog.sh:95-97"
fi
# shellcheck disable=SC2016 # intentionally matching the literal $VAR text in the markdown source, not expanding it
if grep -A3 'case "\$CV_LENS_MAX_REDISPATCH" in' "$REVIEW_LOOP_MD" | grep -q '\*\[!0-9\]\*' \
   && grep -A3 'case "\$CV_LENS_MAX_REDISPATCH" in' "$REVIEW_LOOP_MD" | grep -q 'CV_LENS_MAX_REDISPATCH="3"'; then
  pass "a non-numeric CV_LENS_MAX_REDISPATCH falls back to the documented default (3)"
else
  fail "expected a case \"\$CV_LENS_MAX_REDISPATCH\" in *[!0-9]*|'') CV_LENS_MAX_REDISPATCH=\"3\" ;; esac guard, mirroring con-voyage-review-watchdog.sh:98-100"
fi

# ===========================================================================
# CASE 17 — fk-jsdw2: a stalled lane that exists ONLY in a non-HQ rig's own
#   store (the city-level DB_FILE is empty) is still discovered and acted on.
#   Reproduces the real 2026-09-25 replicated-docs incident: a lane routed to
#   a rig-scoped review lens, pool fully drained -> immediate re-route. Also
#   pins that the HQ rig entry is never queried a second time via --rig (its
#   store is already covered by the plain --city query).
# ===========================================================================
start_case "17: a lane that lives only in a non-HQ rig's store is discovered and re-routed"
setup_case_env "17"
STUB_RIGS_JSON='{"rigs":[{"name":"repl-city","hq":true},{"name":"replicated-docs","hq":false}]}'
write_rig_db "replicated-docs" \
  "$(lane "rd-vfx" "open" "" "$(iso_ago 5000)" "replicated-docs/con-voyage.cv-documentation" "0" "0" "Con-voyage: documentation review")"
run_script "${DEFAULT_ENV[@]}" STUB_RIGS_JSON="$STUB_RIGS_JSON" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'rig list --json' 1 "the watchdog enumerates registered rigs exactly once"
assert_log_count "$GC_LOG" 'rig replicated-docs bd list' 1 "the non-HQ rig's own store is queried"
assert_log_count "$GC_LOG" 'rig repl-city bd list' 0 "the HQ rig is never queried a second time via --rig — its store is already the plain --city query"
assert_log_count "$GC_LOG" 'sling replicated-docs/con-voyage.cv-documentation rd-vfx --nudge' 1 "the rig-only lane is discovered and re-routed (pool fully drained)"
assert_log_count "$GC_LOG" '^bd update rd-vfx ' 1 "fk-mr07/fk-7v3r: the attempt_count update for a rig-discovered lane still omits --city/--rig (rd-vfx is an existing, already-rig-prefixed lane bead); relies on cwd/prefix auto-detection like every other already-fixed bd call in this pack"

# ===========================================================================
# CASE 18 — fail-safe: one rig's `bd list` query fails outright (simulated),
#   but that must never blind the watchdog to a stalled lane living in a
#   DIFFERENT rig's store, nor abort the whole pass.
# ===========================================================================
start_case "18: one rig's failed list query does not blind discovery of another rig's stalled lane"
setup_case_env "18"
STUB_RIGS_JSON='{"rigs":[{"name":"repl-city","hq":true},{"name":"vandoor","hq":false},{"name":"replicated-docs","hq":false}]}'
write_rig_db "replicated-docs" \
  "$(lane "rd-lane2" "open" "" "$(iso_ago 5000)" "replicated-docs/con-voyage.cv-documentation" "0" "0" "Con-voyage: documentation review")"
run_script "${DEFAULT_ENV[@]}" STUB_RIGS_JSON="$STUB_RIGS_JSON" STUB_RIG_LIST_FAIL_FOR="vandoor" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0 (one rig's failed query is non-fatal to the whole pass)"
if printf '%s' "$OUT" | grep -q "WARNING.*vandoor"; then pass "logs a WARNING naming the unreachable rig"; else fail "expected a WARNING mentioning 'vandoor'"; fi
assert_log_count "$GC_LOG" 'sling replicated-docs/con-voyage.cv-documentation rd-lane2 --nudge' 1 "the OTHER rig's stalled lane is still discovered and re-routed"
assert_log_count "$GC_LOG" 'sling' 1 "exactly one re-route happened — the failed rig produced no phantom action"

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
