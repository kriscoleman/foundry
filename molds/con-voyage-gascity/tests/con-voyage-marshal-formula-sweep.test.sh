#!/usr/bin/env bash
# con-voyage-marshal-formula-sweep.test.sh — hermetic test for con-voyage-
# marshal-formula-sweep.sh (fk-d0ioj2): city-wide, unconditional con-voyage
# run step-progress diff + source-anchor health check, gated by the marshal
# assistant flag.
#
# Run:  bash tests/con-voyage-marshal-formula-sweep.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-marshal-formula-sweep.sh"

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

start_case "con-voyage-marshal-formula-sweep.sh is committed executable"
mode="$(git -C "$MOLD_DIR" ls-files -s -- "pack/assets/scripts/con-voyage-marshal-formula-sweep.sh" | awk '{print $1}')"
assert_eq "100755" "$mode" "git-tracked file mode is 100755"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-marshal-formula-sweep-test.XXXXXX")"
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
        is_root_query=0
        for a in "${args[@]}"; do
          case "$a" in "gc.kind=workflow") is_root_query=1 ;; esac
        done
        if [ "$is_root_query" = "1" ]; then
          printf '%s' "${STUB_ROOTS_JSON:-[]}"
        else
          printf '%s' "${STUB_STEPS_JSON:-[]}"
        fi
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
    export CV_LENS_STORE_TIMEOUT_SECONDS=5
    bash "$SCRIPT"
  )
  LAST_RC=$?
  LAST_LOG="$(cat "$log" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
start_case "disabled by default (marshal flag false): no gc calls at all"
rm -f "${RIG_ROOT}/.gc/con-voyage-assistants.toml"
rm -f "${SANDBOX}/gc.log"
out="$( (
  export PATH="${STUBDIR}:${PATH}"
  export STUB_GC_LOG="${SANDBOX}/gc.log"
  export GC_RIG_ROOT="$RIG_ROOT"
  export CV_STATE_DIR="${SANDBOX}/state-disabled"
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
start_case "no open workflow roots: quiet tick, no mail"
export STUB_ROOTS_JSON='[]'
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_not_contains "$LAST_LOG" "mail send" "no digest mail sent when no roots are open"
unset STUB_ROOTS_JSON

# ---------------------------------------------------------------------------
start_case "RUN: a step bead escalation (outcome=fail) is flagged"
export STUB_ROOTS_JSON='[{"id":"fk-root1"}]'
export STUB_STEPS_JSON='[{"id":"fk-step1","status":"open","assignee":"","metadata":{"gc.root_bead_id":"fk-root1","gc.outcome":"fail","gc.failure_class":"boom"},"title":"Some step"}]'
export STUB_BDSHOW_JSON_fk_root1='{"id":"fk-root1","metadata":{}}'
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent for the step escalation"
unset STUB_ROOTS_JSON STUB_STEPS_JSON STUB_BDSHOW_JSON_fk_root1

# ---------------------------------------------------------------------------
start_case "RUN: routine step progress (outcome=pass) is logged, not mailed"
export STUB_ROOTS_JSON='[{"id":"fk-root2"}]'
export STUB_STEPS_JSON='[{"id":"fk-step2","status":"closed","assignee":"bob","metadata":{"gc.root_bead_id":"fk-root2","gc.outcome":"pass"},"title":"Some other step"}]'
export STUB_BDSHOW_JSON_fk_root2='{"id":"fk-root2","metadata":{}}'
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_not_contains "$LAST_LOG" "mail send" "no digest mail sent for routine step progress"
assert_contains "$LAST_LOG" "" "ran without error"
unset STUB_ROOTS_JSON STUB_STEPS_JSON STUB_BDSHOW_JSON_fk_root2

# ---------------------------------------------------------------------------
start_case "ANCHOR: a detached-HEAD source anchor ahead of main is flagged once"
GIT_WT="${SANDBOX}/anchor-wt"
GIT_REMOTE="${SANDBOX}/anchor-remote.git"
git init --bare -q "$GIT_REMOTE"
git clone -q "$GIT_REMOTE" "$GIT_WT"
git -C "$GIT_WT" config user.email "test@example.com"
git -C "$GIT_WT" config user.name "Test"
echo "hello" > "$GIT_WT/file.txt"
git -C "$GIT_WT" add file.txt
git -C "$GIT_WT" commit -q -m "initial"
git -C "$GIT_WT" push -q origin HEAD:main
echo "change" >> "$GIT_WT/file.txt"
git -C "$GIT_WT" commit -q -am "anchor commit"
git -C "$GIT_WT" checkout -q --detach HEAD

export STUB_ROOTS_JSON='[{"id":"fk-root3"}]'
export STUB_STEPS_JSON='[]'
export STUB_BDSHOW_JSON_fk_root3='{"id":"fk-root3","metadata":{"gc.build.source_anchor_work_dir":"'"$GIT_WT"'"}}'
rm -rf "${SANDBOX}/state"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_contains "$LAST_LOG" "mail send mayor" "a digest mail was sent for the detached-HEAD anchor"
FIRST_LOG="$LAST_LOG"

start_case "ANCHOR: a root already checked is never re-flagged (one-shot-per-root)"
run_script
assert_eq "0" "$LAST_RC" "exits 0"
assert_not_contains "$LAST_LOG" "mail send" "second tick sends no mail for an already-checked anchor"
unset STUB_ROOTS_JSON STUB_STEPS_JSON STUB_BDSHOW_JSON_fk_root3

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
