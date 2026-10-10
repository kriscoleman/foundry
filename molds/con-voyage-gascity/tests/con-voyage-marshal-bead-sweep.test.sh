#!/usr/bin/env bash
# con-voyage-marshal-bead-sweep.test.sh — hermetic test for con-voyage-
# marshal-bead-sweep.sh (fk-d0ioj2): city-wide, unconditional bead liveness
# classification (orphan/stuck-READY/stranded-teardown/escalation), gated by
# the marshal assistant flag.
#
# Run:  bash tests/con-voyage-marshal-bead-sweep.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-marshal-bead-sweep.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}
assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (not found in output)"; fi
}
assert_not_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3 (unexpectedly found in output)"; else pass "$3"; fi
}

start_case "con-voyage-marshal-bead-sweep.sh is committed executable"
mode="$(git -C "$MOLD_DIR" ls-files -s -- "pack/assets/scripts/con-voyage-marshal-bead-sweep.sh" | awk '{print $1}')"
assert_eq "100755" "$mode" "git-tracked file mode is 100755"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-marshal-bead-sweep-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
RIG_ROOT="${SANDBOX}/rig"
mkdir -p "$STUBDIR" "$RIG_ROOT/.gc"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }

cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG:-/dev/null}"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }

args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"
case "$sub" in
  bd)
    bdsub="${args[$((i+1))]:-}"
    case "$bdsub" in
      list)
        printf '%s' "${STUB_BDLIST_JSON:-[]}"
        ;;
      show)
        bead_id="${args[$((i+2))]:-}"
        var="STUB_BDSHOW_JSON_$(sanitize "$bead_id")"
        printf '%s' "${!var:-{\}}"
        ;;
      *) exit 0 ;;
    esac
    ;;
  mail)
    mailsub="${args[$((i+1))]:-}"
    case "$mailsub" in
      count)
        printf '%s\n' "${STUB_MAIL_COUNT_OUTPUT:-0 unread}"
        ;;
      send)
        [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ] && exit 1
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
GC_STUB
chmod +x "${STUBDIR}/gc"

cat > "${RIG_ROOT}/.gc/con-voyage-assistants.toml" <<'TOML'
[con_voyage.assistants]
marshal = true
TOML

run_script() {
  local log="${SANDBOX}/gc.log"
  rm -f "$log"
  (
    export PATH="${STUBDIR}:${PATH}"
    export STUB_GC_LOG="$log"
    export GC_RIG_ROOT="$RIG_ROOT"
    export CV_STATE_DIR="${SANDBOX}/state"
    export CV_MARSHAL_READY_STALE_MINUTES=20
    export CV_MARSHAL_TEARDOWN_STALE_MINUTES=15
    export CV_LENS_STORE_TIMEOUT_SECONDS=5
    bash "$SCRIPT"
  )
  LAST_RC=$?
  LAST_LOG="$(cat "$log" 2>/dev/null || true)"
}

old_ts() { date -u -v-"${1}M" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${1} minutes" +%Y-%m-%dT%H:%M:%SZ; }
recent_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
start_case "disabled by default (marshal flag false): no gc bd/mail calls at all"
rm -f "${RIG_ROOT}/.gc/con-voyage-assistants.toml"
out="$( (
  export PATH="${STUBDIR}:${PATH}"
  export STUB_GC_LOG="${SANDBOX}/gc.log"
  export GC_RIG_ROOT="$RIG_ROOT"
  export CV_STATE_DIR="${SANDBOX}/state-disabled"
  rm -f "${SANDBOX}/gc.log"
  bash "$SCRIPT"
) 2>&1 )"
rc=$?
assert_eq "0" "$rc" "exits 0 when disabled"
assert_contains "$out" "disabled" "reports disabled in output"
assert_eq "" "$(cat "${SANDBOX}/gc.log" 2>/dev/null || true)" "no gc calls made while disabled"

cat > "${RIG_ROOT}/.gc/con-voyage-assistants.toml" <<'TOML'
[con_voyage.assistants]
marshal = true
TOML

# ---------------------------------------------------------------------------
start_case "ORPHAN: a bead under an already-closed root is flagged, not closed"
export STUB_BDLIST_JSON='[{"id":"fk-orphan1","status":"open","updated_at":"'"$(recent_ts)"'","metadata":{"gc.root_bead_id":"fk-rootclosed"}}]'
export STUB_BDSHOW_JSON_fk_rootclosed='{"id":"fk-rootclosed","status":"closed"}'
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent"
assert_not_contains "$LAST_LOG" "bd close" "never calls bd close on the orphaned bead (classify-only)"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootclosed

# ---------------------------------------------------------------------------
start_case "STUCK-READY: an open bead stale under a still-open root is flagged"
export STUB_BDLIST_JSON='[{"id":"fk-ready1","status":"open","updated_at":"'"$(old_ts 30)"'","metadata":{"gc.root_bead_id":"fk-rootopen"}}]'
export STUB_BDSHOW_JSON_fk_rootopen='{"id":"fk-rootopen","status":"in_progress"}'
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootopen

# ---------------------------------------------------------------------------
# fk-i1yas2 BLOCKING-1: the dedup key must use a stable class token, not one
# with the volatile ${age} embedded — otherwise a bead that stays in the same
# STUCK-READY class forever gets re-mailed on every tick as age keeps growing.
start_case "STUCK-READY: an unchanged-class bead is NOT re-flagged as age keeps growing"
export STUB_BDLIST_JSON='[{"id":"fk-ready2","status":"open","updated_at":"'"$(old_ts 25)"'","metadata":{"gc.root_bead_id":"fk-rootopen1b"}}]'
export STUB_BDSHOW_JSON_fk_rootopen1b='{"id":"fk-rootopen1b","status":"in_progress"}'
run_script
assert_eq "0" "$LAST_RC" "tick 1 exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "tick 1: first sighting of STUCK-READY is flagged"

export STUB_BDLIST_JSON='[{"id":"fk-ready2","status":"open","updated_at":"'"$(old_ts 30)"'","metadata":{"gc.root_bead_id":"fk-rootopen1b"}}]'
run_script
assert_eq "0" "$LAST_RC" "tick 2 exits 0"
assert_not_contains "$LAST_LOG" "mail send" "tick 2: same still-stuck bead, just older, sends no mail"

export STUB_BDLIST_JSON='[{"id":"fk-ready2","status":"open","updated_at":"'"$(old_ts 35)"'","metadata":{"gc.root_bead_id":"fk-rootopen1b"}}]'
run_script
assert_eq "0" "$LAST_RC" "tick 3 exits 0"
assert_not_contains "$LAST_LOG" "mail send" "tick 3: still unchanged class, still no mail"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootopen1b

# ---------------------------------------------------------------------------
# fk-i1yas2 BLOCKING-4: a failed digest-mail send must not retire the
# persisted state for the flagged bead it was reporting, or the next tick
# sees an unchanged `cur` and silently drops the signal forever.
start_case "a failed digest mail does not retire a flagged bead's state"
export STUB_BDLIST_JSON='[{"id":"fk-failmail1","status":"open","updated_at":"'"$(old_ts 25)"'","metadata":{"gc.root_bead_id":"fk-rootfailmail"}}]'
export STUB_BDSHOW_JSON_fk_rootfailmail='{"id":"fk-rootfailmail","status":"in_progress"}'
export STUB_MAIL_SEND_FAIL=1
run_script
assert_eq "0" "$LAST_RC" "tick 1 (mail fails) still exits 0"
unset STUB_MAIL_SEND_FAIL

run_script
assert_contains "$LAST_LOG" "mail send mayor" "tick 2: the still-unreported condition is re-flagged after the earlier mail failure"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootfailmail

# ---------------------------------------------------------------------------
start_case "STRANDED-TEARDOWN: a stale open teardown bead is flagged"
export STUB_BDLIST_JSON='[{"id":"fk-td1","status":"open","updated_at":"'"$(old_ts 20)"'","metadata":{"gc.root_bead_id":"fk-rootopen2","gc.scope_role":"teardown"}}]'
export STUB_BDSHOW_JSON_fk_rootopen2='{"id":"fk-rootopen2","status":"in_progress"}'
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootopen2

# ---------------------------------------------------------------------------
start_case "ESCALATION: a failed-outcome bead is flagged on first sight"
export STUB_BDLIST_JSON='[{"id":"fk-fail1","status":"open","updated_at":"'"$(recent_ts)"'","metadata":{"gc.root_bead_id":"fk-rootopen3","gc.outcome":"fail","gc.failure_class":"boom"}}]'
export STUB_BDSHOW_JSON_fk_rootopen3='{"id":"fk-rootopen3","status":"in_progress"}'
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootopen3

# ---------------------------------------------------------------------------
start_case "no flagged conditions: quiet tick sends no mail"
export STUB_BDLIST_JSON='[{"id":"fk-fine1","status":"in_progress","updated_at":"'"$(recent_ts)"'","metadata":{"gc.root_bead_id":"fk-rootopen4","gc.outcome":"pass"}}]'
export STUB_BDSHOW_JSON_fk_rootopen4='{"id":"fk-rootopen4","status":"in_progress"}'
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_not_contains "$LAST_LOG" "mail send" "no digest mail sent on a quiet tick"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootopen4

# ---------------------------------------------------------------------------
start_case "mayor mail count rising is flagged"
export STUB_BDLIST_JSON='[]'
export STUB_MAIL_COUNT_OUTPUT="5 unread"
rm -rf "${SANDBOX}/state"
mkdir -p "${SANDBOX}/state"
printf '%s' "2" > "${SANDBOX}/state/_mail"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent for rising unread count"
unset STUB_BDLIST_JSON STUB_MAIL_COUNT_OUTPUT

# ---------------------------------------------------------------------------
# fk-9oigyg review LOW-1: a bead id containing a path separator (or a
# traversal sequence) must never let the per-bead state file resolve outside
# CV_STATE_DIR.
start_case "LOW-1: a bead id containing a path separator never escapes CV_STATE_DIR"
export STUB_BDLIST_JSON='[{"id":"fk-evil/../../escape","status":"open","updated_at":"'"$(recent_ts)"'","metadata":{"gc.root_bead_id":"fk-rootevil","gc.outcome":"fail","gc.failure_class":"boom"}}]'
export STUB_BDSHOW_JSON_fk_rootevil='{"id":"fk-rootevil","status":"in_progress"}'
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent for the malicious-id escalation"
[ -e "${SANDBOX}/escape" ] \
  && fail "a state file escaped CV_STATE_DIR via the path-separator id" \
  || pass "no file was written outside CV_STATE_DIR"
state_file_count="$(find "${SANDBOX}/state" -type f ! -name '_mail' | grep -c .)"
assert_eq "1" "$state_file_count" "exactly one sanitized bead state file was written, inside CV_STATE_DIR"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootevil

# ---------------------------------------------------------------------------
# fk-9oigyg review LOW-2: a bounded, age-based prune keeps CV_STATE_DIR from
# growing unbounded as beads/roots disappear.
start_case "LOW-2: an ancient state file is pruned from CV_STATE_DIR on the next tick"
rm -rf "${SANDBOX}/state"
mkdir -p "${SANDBOX}/state"
touch -t 202001010000 "${SANDBOX}/state/fk-long-gone"
export STUB_BDLIST_JSON='[]'
run_script
assert_eq "0" "$LAST_RC" "exits 0"
[ -f "${SANDBOX}/state/fk-long-gone" ] \
  && fail "an ancient state file for a long-gone bead was not pruned" \
  || pass "the ancient state file was pruned"
unset STUB_BDLIST_JSON

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
