#!/usr/bin/env bash
# cv-abandon-workflow.test.sh — hermetic test for cv-abandon-workflow.sh
# (fk-jg6rm): the mayor's one-call manual teardown entry point for a graph.v2
# workflow root, wrapping cv_close_workflow_root so manual cleanup of an
# abandoned/stuck con-voyage no longer needs `bd close --force` bead-by-bead
# (the exact cleanup fk-79odi/fk-lhjn3 needed by hand, 13 beads).
#
# Run:  bash tests/cv-abandon-workflow.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-abandon-workflow.sh"

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

start_case "cv-abandon-workflow.sh is committed executable (fk-4gqm0 pattern: a 644 script silently ships non-executable)"
mode="$(git -C "$MOLD_DIR" ls-files -s -- "pack/assets/scripts/cv-abandon-workflow.sh" | awk '{print $1}')"
assert_eq "100755" "$mode" "git-tracked file mode is 100755"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-abandon-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG:-/dev/null}"
args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "show" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_BDSHOW_JSON_${id//-/_}"
  printf '%s' "${!var:-}"
  exit 0
fi
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "close" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_BDCLOSE_FAIL_${id//-/_}"
  if [ "${!var:-0}" = "1" ]; then exit 1; fi
  exit 0
fi
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "blocked" ]; then
  printf '%s' "${STUB_BDBLOCKED_JSON:-[]}"
  exit 0
fi
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "list" ]; then
  printf '%s' "${STUB_BDPINNED_JSON:-[]}"
  exit 0
fi
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

GC_LOG="${SANDBOX}/gc.log"
: > "$GC_LOG"

start_case "cv-abandon-workflow.sh ROOT_ID: sweeps open descendants and closes the root in one call"
export STUB_BDSHOW_JSON_fk_abroot='{"id":"fk-abroot","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDPINNED_JSON='[{"id":"fk-ablane1"},{"id":"fk-ablane2"}]'
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" "fk-abroot" "test manual abandon" 2>&1)"
rc=$?
assert_eq "0" "$rc" "exits 0 when the root bead itself closes cleanly"
if grep -qE 'bd close fk-ablane1 ' "$GC_LOG" && grep -qE 'bd close fk-ablane2 ' "$GC_LOG" && grep -qE 'bd close fk-abroot ' "$GC_LOG"; then
  pass "both descendants and the root were closed in a single invocation"
else
  fail "expected both lane descendants and the root to be closed; log was:
$(cat "$GC_LOG")"
fi
unset STUB_BDPINNED_JSON

start_case "cv-abandon-workflow.sh: missing ROOT_ID argument -> usage error, exit 2, no bd calls"
: > "$GC_LOG"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "2" "$rc" "usage error exits 2"
assert_eq "0" "$(wc -l < "$GC_LOG" | tr -d ' ')" "no bd calls were made without a root id"

start_case "cv-abandon-workflow.sh: propagates CV_CLOSE_RC as its own exit status when the root itself fails to close"
export STUB_BDSHOW_JSON_fk_abfail='{"id":"fk-abfail","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDCLOSE_FAIL_fk_abfail=1
: > "$GC_LOG"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" "fk-abfail" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  pass "a failed root close surfaces as a non-zero exit, not a silent success"
else
  fail "expected a non-zero exit when the root bead's own close fails"
fi
unset STUB_BDCLOSE_FAIL_fk_abfail

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
