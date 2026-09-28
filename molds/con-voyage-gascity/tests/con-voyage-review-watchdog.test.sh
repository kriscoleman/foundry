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
      if [ "${STUB_RIG_LIST_FAIL:-0}" = "1" ]; then
        exit 1
      fi
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
      if [ -n "$stub_rig" ] && [ -n "${STUB_RIG_LIST_HANG_FOR:-}" ] && [ "$stub_rig" = "${STUB_RIG_LIST_HANG_FOR}" ]; then
        sleep "${STUB_HANG_SECONDS:-20}"
      fi
      if [ -z "$stub_rig" ] && [ "${STUB_CITY_LIST_HANG:-0}" = "1" ]; then
        sleep "${STUB_HANG_SECONDS:-20}"
      fi
      if [ -n "$stub_rig" ] && [ -n "${STUB_DB_DIR:-}" ]; then
        cat "${STUB_DB_DIR}/${stub_rig}.json" 2>/dev/null || printf '[]'
      else
        cat "${STUB_DB_FILE}" 2>/dev/null || printf '[]'
      fi
      exit 0
    fi
    if [ "$bdsub" = "show" ]; then
      target_id="${args[$((i+2))]:-}"
      python3 - "$STUB_DB_FILE" "$target_id" "${STUB_DB_DIR:-}" <<'PYEOF'
import json, os, sys
db_file, target_id, db_dir = sys.argv[1], sys.argv[2], sys.argv[3]
found = None
try:
    with open(db_file) as f:
        db = json.load(f)
except Exception:
    db = []
for d in db:
    if d.get('id') == target_id:
        found = d
        break
if found is None and db_dir and os.path.isdir(db_dir):
    for fn in sorted(os.listdir(db_dir)):
        try:
            with open(os.path.join(db_dir, fn)) as f:
                rig_db = json.load(f)
        except Exception:
            continue
        for d in rig_db:
            if d.get('id') == target_id:
                found = d
                break
        if found is not None:
            break
print(json.dumps([found] if found is not None else []))
PYEOF
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
    if [ "$sessub" = "peek" ]; then
      peek_id="${args[$((i+2))]:-}"
      var="STUB_SESSION_PEEK_OUTPUT_${peek_id//-/_}"
      python3 -c "
import json, sys
print(json.dumps({'ok': True, 'output': sys.argv[1], 'line_count': 1, 'lines': 1, 'session_id': sys.argv[2]}))
" "${!var:-}" "$peek_id"
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

# lane ID STATUS ASSIGNEE UPDATED_AT ROUTED_TO ATTEMPT_COUNT ESCALATED TITLE [DEPS_JSON] —
# build one review-lane bead JSON object (default title is a real floor-lane
# title so the ralph_step_id/scope_role/title filters all pass by default).
# DEPS_JSON (default "[]", built with deps() below) is embedded verbatim as
# the bead's own `dependencies` array — this is what a `bd show <id> --json`
# on this SAME lane returns via the stub's new `bd show` case, mirroring the
# real nested-dependency shape (fk-7ba34 readiness gate).
lane() {
  python3 -c "
import json, sys
_id, status, assignee, updated_at, routed_to, attempt_count, escalated, title = sys.argv[1:9]
deps_json = sys.argv[9] if len(sys.argv) > 9 and sys.argv[9] else '[]'
try:
    deps = json.loads(deps_json)
except Exception:
    deps = []
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
    'title': title, 'metadata': meta, 'dependencies': deps,
}))
" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-Con-voyage: test evidence}" "${9:-[]}"
}

# deps ID:STATUS[:TYPE] ... — build a dependencies-array JSON fragment for
# lane()'s optional 9th argument. TYPE defaults to "blocks" (the only type the
# readiness gate inspects); STATUS defaults to "closed".
deps() {
  python3 -c "
import json, sys
out = []
for item in sys.argv[1:]:
    parts = item.split(':')
    dep_id = parts[0]
    status = parts[1] if len(parts) > 1 else 'closed'
    dtype = parts[2] if len(parts) > 2 else 'blocks'
    out.append({'id': dep_id, 'status': status, 'dependency_type': dtype})
print(json.dumps(out))
" "$@"
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

DEFAULT_ENV=(CV_LENS_STALL_SECONDS="600" CV_LENS_MAX_ATTEMPTS="3" CV_LENS_ESCALATE_TARGET="human" CV_LENS_STORE_TIMEOUT_SECONDS="5")

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
if grep -q '{cv_lens_claim_seconds}' "$REVIEW_LOOP_MD" && grep -q '{cv_lens_max_redispatch}' "$REVIEW_LOOP_MD" && grep -q '{cv_lens_escalate_target}' "$REVIEW_LOOP_MD"; then
  pass "references all three cv_lens_* formula vars"
else
  fail "expected {cv_lens_claim_seconds}, {cv_lens_max_redispatch}, and {cv_lens_escalate_target} all present"
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
# CASE 19 — fk-rri7q LOW-A (security, fk-ivure): a bead field containing an
#   embedded newline+separator payload must never smuggle a second,
#   attacker-controlled synthetic lane row into the TSV. Reproduces the exact
#   chain the finding describes: a poisoned `assignee` field forges a
#   complete phantom row (open+unassigned+stale, attacker-chosen lane id and
#   route) that — if fields were not sanitized before SEP.join — causes a
#   REAL `gc sling` call naming the attacker's own id and route.
# ===========================================================================
start_case "19: a forged newline+separator payload in a bead field cannot smuggle a phantom lane row"
setup_case_env "19"
STALE_TS="$(iso_ago 5000)"
POISON_SEP=$'\x1f'
POISON_ASSIGNEE="realassignee"$'\n'"fk-evil99${POISON_SEP}open${POISON_SEP}${POISON_SEP}${STALE_TS}${POISON_SEP}evil/route${POISON_SEP}0${POISON_SEP}0"
write_db "$DB_FILE" "$(lane "fk-lane15" "open" "$POISON_ASSIGNEE" "$(iso_ago 5)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0 despite the poisoned field"
assert_log_count "$GC_LOG" 'evil/route' 0 "the attacker-chosen route never reaches a gc call"
assert_log_count "$GC_LOG" 'fk-evil99' 0 "the forged lane id never reaches a gc call"
assert_log_count "$GC_LOG" 'sling' 0 "no phantom re-route fires from a poisoned field"

# ===========================================================================
# CASE 20 — fk-rri7q LOW-B (code-review, fk-yr4gj): the per-rig query-failure
#   WARNING must name the command that actually failed (bd list --rig
#   <name>), not the unrelated `gc rig list` enumeration call that already
#   succeeded.
# ===========================================================================
start_case "20: the per-rig query-failure WARNING names bd list, not rig list"
setup_case_env "20"
STUB_RIGS_JSON='{"rigs":[{"name":"repl-city","hq":true},{"name":"vandoor","hq":false}]}'
run_script "${DEFAULT_ENV[@]}" STUB_RIGS_JSON="$STUB_RIGS_JSON" STUB_RIG_LIST_FAIL_FOR="vandoor" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
if printf '%s' "$OUT" | grep -q "WARNING: review-lane query (bd list --rig vandoor) returned nothing for rig 'vandoor'"; then
  pass "the WARNING names the actual failing command (bd list --rig vandoor)"
else
  fail "expected the WARNING to name 'bd list --rig vandoor', not 'rig list query'"
fi
if printf '%s' "$OUT" | grep -q "rig list query returned nothing"; then
  fail "the old, misleading wording ('rig list query returned nothing') must not reappear"
else
  pass "the old misleading wording is gone"
fi

# ===========================================================================
# CASE 21 — fk-rri7q LOW-C (SRE reliability, fk-hdma1): `gc rig list --json`
#   returning unparseable JSON must log a WARNING distinguishing this from a
#   legitimate zero-rig city, and must not abort the pass — city-store lanes
#   are still processed.
# ===========================================================================
start_case "21: unparseable 'gc rig list --json' output logs a WARNING, city lanes still processed"
setup_case_env "21"
write_db "$DB_FILE" "$(lane "fk-lane16" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" STUB_RIGS_JSON='not-valid-json-at-all' STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0 despite unparseable rig list output"
if printf '%s' "$OUT" | grep -q "WARNING: 'gc rig list --json' returned nothing/unparseable"; then
  pass "logs the rig-enumeration-failure WARNING"
else
  fail "expected a WARNING distinguishing unparseable rig list output from a legitimate zero-rig city"
fi
assert_log_count "$GC_LOG" 'sling foundry-kc/gc.gap-analyst fk-lane16 --nudge' 1 "the city-store lane is still discovered and acted on despite the rig-enumeration failure"

# ===========================================================================
# CASE 22 — fk-rri7q LOW-C: `gc rig list --json` failing outright (nothing on
#   stdout) hits the SAME WARNING+fail-safe path as unparseable output (CASE
#   21) — the two distinct code paths (empty output vs. parse failure) both
#   surface the operator-facing signal.
# ===========================================================================
start_case "22: 'gc rig list --json' failing outright (empty output) also logs the WARNING"
setup_case_env "22"
run_script "${DEFAULT_ENV[@]}" STUB_RIG_LIST_FAIL=1 STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0 despite the rig-list call failing outright"
if printf '%s' "$OUT" | grep -q "WARNING: 'gc rig list --json' returned nothing/unparseable"; then
  pass "logs the rig-enumeration-failure WARNING on an outright empty/failed call too"
else
  fail "expected the same rig-enumeration-failure WARNING when the call produces no output at all"
fi

# ===========================================================================
# CASE 23 — fk-rri7q LOW-C negative control: a VALID `{"rigs":[]}` response (a
#   genuinely single-rig/no-peer city) must NOT trigger the new WARNING —
#   only a failed/unparseable enumeration should.
# ===========================================================================
start_case "23: a valid, legitimately empty rig list is not treated as a failure"
setup_case_env "23"
run_script "${DEFAULT_ENV[@]}" STUB_RIGS_JSON='{"rigs":[]}' STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
if printf '%s' "$OUT" | grep -q "WARNING: 'gc rig list --json' returned"; then
  fail "a legitimately empty rig list must not log the enumeration-failure WARNING"
else
  pass "no false-alarm WARNING for a genuinely empty (but validly parsed) rig list"
fi

# ===========================================================================
# CASE 24 — fk-rri7q LOW-D (SRE reliability, fk-hdma1): a hung per-rig store
#   read is bounded by CV_LENS_STORE_TIMEOUT_SECONDS instead of stalling the
#   whole cycle, and does not blind discovery of a DIFFERENT rig's stalled
#   lane. The stub hangs for 20s; the test configures a 1s timeout and
#   asserts the whole run finishes in well under 20s — proving a real kill
#   happened, not just that the logic looks right on paper.
# ===========================================================================
start_case "24: a hung per-rig store read is bounded and does not blind other rigs"
setup_case_env "24"
STUB_RIGS_JSON='{"rigs":[{"name":"repl-city","hq":true},{"name":"vandoor","hq":false},{"name":"replicated-docs","hq":false}]}'
write_rig_db "replicated-docs" \
  "$(lane "rd-lane3" "open" "" "$(iso_ago 5000)" "replicated-docs/con-voyage.cv-documentation" "0" "0" "Con-voyage: documentation review")"
START_TS=$(date +%s)
run_script CV_LENS_STALL_SECONDS="600" CV_LENS_MAX_ATTEMPTS="3" CV_LENS_ESCALATE_TARGET="human" CV_LENS_STORE_TIMEOUT_SECONDS="1" \
  STUB_RIGS_JSON="$STUB_RIGS_JSON" STUB_RIG_LIST_HANG_FOR="vandoor" STUB_HANG_SECONDS="20" STUB_SESSION_LIST_JSON='{"sessions":[]}'
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
assert_eq "0" "$RC" "script exits 0 despite a hung rig store"
if [ "$ELAPSED" -lt 10 ]; then pass "the hung store was killed well before its own 20s hang finished (elapsed ${ELAPSED}s)"; else fail "the run took ${ELAPSED}s — the timeout did not actually bound the hung call"; fi
assert_log_count "$GC_LOG" 'sling replicated-docs/con-voyage.cv-documentation rd-lane3 --nudge' 1 "the OTHER rig's stalled lane is still discovered and re-routed despite vandoor hanging"

# ===========================================================================
# CASE 25 — fk-rri7q LOW-D: a hung CITY store read is likewise bounded, and a
#   per-rig lane is still discovered even though the city query itself hung.
# ===========================================================================
start_case "25: a hung CITY store read is bounded and per-rig discovery still proceeds"
setup_case_env "25"
STUB_RIGS_JSON='{"rigs":[{"name":"repl-city","hq":true},{"name":"replicated-docs","hq":false}]}'
write_rig_db "replicated-docs" \
  "$(lane "rd-lane4" "open" "" "$(iso_ago 5000)" "replicated-docs/con-voyage.cv-documentation" "0" "0" "Con-voyage: documentation review")"
START_TS=$(date +%s)
run_script CV_LENS_STALL_SECONDS="600" CV_LENS_MAX_ATTEMPTS="3" CV_LENS_ESCALATE_TARGET="human" CV_LENS_STORE_TIMEOUT_SECONDS="1" \
  STUB_RIGS_JSON="$STUB_RIGS_JSON" STUB_CITY_LIST_HANG="1" STUB_HANG_SECONDS="20" STUB_SESSION_LIST_JSON='{"sessions":[]}'
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
assert_eq "0" "$RC" "script exits 0 despite a hung city store"
if [ "$ELAPSED" -lt 10 ]; then pass "the hung city query was killed well before its own 20s hang finished (elapsed ${ELAPSED}s)"; else fail "the run took ${ELAPSED}s — the timeout did not bound the city call"; fi
assert_log_count "$GC_LOG" 'sling replicated-docs/con-voyage.cv-documentation rd-lane4 --nudge' 1 "the rig-store lane is still discovered even though the city query hung"

# ===========================================================================
# CASE 26 — fk-7ba34 DEFECT 1: a lane with an OPEN blocking dependency is not
#   ready yet — its stall clock must never start, no matter how stale its own
#   updated_at is or how obviously "dead" its pool looks. Never counted:
#   no sling/nudge/mail, no attempt_count write.
# ===========================================================================
start_case "26: a lane with an open blocking dependency is never counted (not ready)"
setup_case_env "26"
write_db "$DB_FILE" "$(lane "fk-notready" "open" "" "$(iso_ago 99999)" "foundry-kc/gc.gap-analyst" "0" "0" "Con-voyage: test evidence" "$(deps "fk-buildstep:open")")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling|session nudge|mail send' 0 "a not-ready lane is never acted on despite looking dead+ancient"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-notready" "gc.review_watchdog.attempt_count")" "attempt_count stays at its seeded 0 — the stall clock never started"
if printf '%s' "$OUT" | grep -q "NOT READY fk-notready"; then pass "logs a NOT READY line for the blocked lane"; else fail "expected a NOT READY line naming fk-notready"; fi

# ===========================================================================
# CASE 27 — sanity/negative control for CASE 26: a lane whose only blocking
#   dependency is CLOSED is ready, and behaves exactly like a dependency-free
#   lane (unchanged existing behavior).
# ===========================================================================
start_case "27: a lane with only CLOSED blocking dependencies is ready (unaffected)"
setup_case_env "27"
write_db "$DB_FILE" "$(lane "fk-ready" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "0" "0" "Con-voyage: test evidence" "$(deps "fk-buildstep:closed")")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-ready","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session nudge rc-ready ' 1 "a lane with only closed blocking deps is treated as ready and nudged normally"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-ready" "gc.review_watchdog.attempt_count")" "attempt_count advances normally once ready"

# ===========================================================================
# CASE 28 — fk-7ba34 DEFECT 2 (global percent rule): many watched lanes
#   crossing the stall threshold in the same cycle, across DIFFERENT routes
#   (so the per-lens rule cannot explain it), is a suspected provider freeze:
#   no re-dispatch of any kind, exactly ONE freeze-suspected mail (not one per
#   lane), and every attempt_count stays unchanged.
# ===========================================================================
start_case "28: many lanes stalled in one cycle across different routes -> freeze suspected, one mail, no re-dispatch"
setup_case_env "28"
write_db "$DB_FILE" \
  "$(lane "fk-freeze1" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "0" "0")" \
  "$(lane "fk-freeze2" "open" "" "$(iso_ago 5000)" "foundry-kc/con-voyage.cv-security-reviewer" "0" "0" "Con-voyage: security review")" \
  "$(lane "fk-freeze3" "open" "" "$(iso_ago 5000)" "foundry-kc/con-voyage.cv-simplicity-reviewer" "0" "0" "Con-voyage: simplicity review")" \
  "$(lane "fk-freeze4" "open" "" "$(iso_ago 5000)" "foundry-kc/con-voyage.cv-sre-reliability" "0" "0" "Con-voyage: sre review")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling|session nudge' 0 "no re-dispatch of any kind while a freeze is suspected"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "exactly one freeze-suspected mail, not one per stalled lane"
if printf '%s' "$OUT" | grep -q "FREEZE SUSPECTED"; then pass "logs a FREEZE SUSPECTED line"; else fail "expected a FREEZE SUSPECTED line"; fi
for id in fk-freeze1 fk-freeze2 fk-freeze3 fk-freeze4; do
  assert_eq "0" "$(db_metadata_field "$DB_FILE" "$id" "gc.review_watchdog.attempt_count")" "${id}: attempt_count unchanged during a suspected freeze"
done

# ===========================================================================
# CASE 29 — fk-7ba34 DEFECT 2 (per-lens rule): ALL lanes of one lens (route)
#   are stalled while the city-wide percentage stays well under the default
#   50% threshold (2 stalled out of 5 watched = 40%) — still a suspected
#   freeze via the per-lens rule alone.
# ===========================================================================
start_case "29: all lanes of one lens stalled -> freeze suspected via the per-lens rule alone"
setup_case_env "29"
write_db "$DB_FILE" \
  "$(lane "fk-lensA1" "open" "" "$(iso_ago 5000)" "foundry-kc/con-voyage.cv-documentation" "0" "0" "Con-voyage: documentation review")" \
  "$(lane "fk-lensA2" "in_progress" "gc__documentation-rc-9" "$(iso_ago 5000)" "foundry-kc/con-voyage.cv-documentation" "0" "0" "Con-voyage: documentation review")" \
  "$(lane "fk-fresh1" "open" "" "$(iso_ago 5)" "foundry-kc/gc.gap-analyst" "0" "0")" \
  "$(lane "fk-fresh2" "open" "" "$(iso_ago 5)" "foundry-kc/con-voyage.cv-security-reviewer" "0" "0" "Con-voyage: security review")" \
  "$(lane "fk-fresh3" "open" "" "$(iso_ago 5)" "foundry-kc/con-voyage.cv-simplicity-reviewer" "0" "0" "Con-voyage: simplicity review")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-9","session_name":"gc__documentation-rc-9","state":"active"},{"id":"rc-lensA","template":"foundry-kc/con-voyage.cv-documentation","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling|session nudge' 0 "no re-dispatch — the fully-stalled lens alone is enough to suspect a freeze"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "exactly one freeze-suspected mail"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-lensA1" "gc.review_watchdog.attempt_count")" "fk-lensA1: attempt_count unchanged"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-lensA2" "gc.review_watchdog.attempt_count")" "fk-lensA2: attempt_count unchanged"

# ===========================================================================
# CASE 30 — fk-7ba34 DEFECT 2 (session-peek signature): a single stalled lane
#   — nowhere near the percent or per-lens thresholds on its own — still
#   suspects a freeze when a sampled peek of its target session's pane shows
#   the real captured provider usage-limit banner.
# ===========================================================================
start_case "30: a sampled session peek showing the usage-limit banner suspects a freeze"
setup_case_env "30"
write_db "$DB_FILE" "$(lane "fk-peek1" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-peek","template":"foundry-kc/gc.gap-analyst","state":"active"}]}' \
  STUB_SESSION_PEEK_OUTPUT_rc_peek='Some prior output...

Usage limit reached · continuing automatically at 6:10am · esc or type to cancel'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session nudge' 0 "no nudge — the peeked banner alone is enough to suspect a freeze"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "exactly one freeze-suspected mail"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-peek1" "gc.review_watchdog.attempt_count")" "attempt_count unchanged"

# ===========================================================================
# CASE 31 — negative control for CASE 30: the SAME single-stalled-lane shape,
#   but the sampled peek shows ordinary, unrelated pane text. Must NOT
#   suspect a freeze — proves the peek call itself does not regress the
#   existing single-stalled-lane re-dispatch behavior (CASE 4).
# ===========================================================================
start_case "31: a normal (non-usage-limit) peek does not falsely suspect a freeze"
setup_case_env "31"
write_db "$DB_FILE" "$(lane "fk-peek2" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "0" "0")"
run_script "${DEFAULT_ENV[@]}" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-peek2","template":"foundry-kc/gc.gap-analyst","state":"active"}]}' \
  STUB_SESSION_PEEK_OUTPUT_rc_peek2='Running tests...
5 passed, 0 failed
$ '
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'session nudge rc-peek2 ' 1 "a benign peek leaves the existing single-stalled-lane nudge behavior unchanged"
assert_log_count "$GC_LOG" 'mail send mayor' 0 "no freeze mail for a benign peek"
assert_eq "1" "$(db_metadata_field "$DB_FILE" "fk-peek2" "gc.review_watchdog.attempt_count")" "attempt_count advances normally — this was not a freeze"

# ===========================================================================
# CASE 32 — a suspected freeze suppresses escalation too, not just re-dispatch:
#   a lane that already exhausted CV_LENS_MAX_ATTEMPTS would normally escalate
#   via mail this cycle, but a concurrent city-wide freeze must hold that back
#   as well — exactly the one freeze mail fires, no escalation mail, escalated
#   flag left unset.
# ===========================================================================
start_case "32: a suspected freeze also suppresses a lane that would otherwise escalate"
setup_case_env "32"
write_db "$DB_FILE" \
  "$(lane "fk-capped" "open" "" "$(iso_ago 5000)" "foundry-kc/gc.gap-analyst" "3" "0")" \
  "$(lane "fk-freezeB2" "open" "" "$(iso_ago 5000)" "foundry-kc/con-voyage.cv-security-reviewer" "0" "0" "Con-voyage: security review")" \
  "$(lane "fk-freezeB3" "open" "" "$(iso_ago 5000)" "foundry-kc/con-voyage.cv-simplicity-reviewer" "0" "0" "Con-voyage: simplicity review")"
run_script "${DEFAULT_ENV[@]}" STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send human' 0 "the normally-due escalation is suppressed by the suspected freeze"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "exactly one freeze-suspected mail covers the whole cycle"
assert_eq "0" "$(db_metadata_field "$DB_FILE" "fk-capped" "gc.review_watchdog.escalated")" "the capped lane is NOT escalated while a freeze is suspected"
assert_eq "3" "$(db_metadata_field "$DB_FILE" "fk-capped" "gc.review_watchdog.attempt_count")" "attempt_count stays exactly as it was"

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
