#!/usr/bin/env bash
# cv-review-lane-close.test.sh — hermetic, offline test for
# cv-review-lane-close.sh, the deterministic close-time enforcement point for
# gc.outcome=pass on every con-voyage review-lane and synthesize-review step
# (fk-7w9y6, mayor's widened 10-08 11:00Z acceptance criteria).
#
# HOW IT WORKS (no network, no real gc/bd): a recording STUB `gc` binary is
# built in a temp dir (same idiom as tests/cv-reopen-findings.test.sh) and
# prepended to PATH. The stub answers `bd show`, `bd update`, and `bd close`
# with configurable success/failure and logs every call's argv (one line per
# call) to a log file so assertions can inspect exactly what was sent.
#
# Fixtures (mayor's widened GWT, 10-08 11:00Z):
#   1. missing gc.outcome key — caller passes no gc.outcome at all; the
#      script must still stamp gc.outcome=pass.
#   2. a verdict-valued gc.outcome (e.g. iterate) — caller passes it anyway
#      (mimicking an agent that still copies the old bare bd-update shape);
#      the script must override it so the only gc.outcome value ever sent to
#      `bd update` is pass.
#   3. a genuine step failure — the underlying `bd update`/`bd close` call
#      itself fails; the script must propagate that failure (nonzero exit,
#      no close) rather than silently treating it as a pass.
#
# Run:  bash tests/cv-review-lane-close.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-review-lane-close.sh"

[ -f "$SCRIPT" ] || { echo "FATAL: script under test not found: $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-close-test.XXXXXX")"
export SANDBOX
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

# shellcheck disable=SC2329
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

case "${1:-}" in
  bd)
    case "${2:-}" in
      show)
        [ "${STUB_BDSHOW_FAIL:-0}" = "1" ] && exit 1
        echo '{"id":"'"${3:-}"'","status":"open"}'
        exit 0
        ;;
      update)
        [ "${STUB_BDUPDATE_FAIL:-0}" = "1" ] && { echo "bd update: simulated failure" >&2; exit 1; }
        exit 0
        ;;
      close)
        [ "${STUB_BDCLOSE_FAIL:-0}" = "1" ] && { echo "bd close: simulated failure" >&2; exit 1; }
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

export GC="${STUBDIR}/gc"
export PATH="${STUBDIR}:${PATH}"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

run_script() {
  STUB_GC_LOG="${SANDBOX}/gc.log"
  : > "$STUB_GC_LOG"
  export STUB_GC_LOG
  "$SCRIPT" "$@"
}

start_case "fixture 1: missing gc.outcome — caller passes none, script stamps it anyway"
STUB_BDSHOW_FAIL=0 STUB_BDUPDATE_FAIL=0 STUB_BDCLOSE_FAIL=0 \
  run_script "fk-test1" "no-op pass" --set-metadata 'code_review.code_verdict=approve'
rc=$?
if [ "$rc" -eq 0 ] && grep -qE "^bd update fk-test1 --set-metadata gc\.outcome=pass " "$STUB_GC_LOG"; then
  echo "  PASS: bd update stamped gc.outcome=pass with no caller-supplied gc.outcome"
else
  echo "  FAIL: expected a successful bd update with gc.outcome=pass stamped (rc=${rc})" >&2
  FAILURES=$((FAILURES+1))
fi
if grep -q "bd close fk-test1" "$STUB_GC_LOG"; then
  echo "  PASS: bd close was called"
else
  echo "  FAIL: bd close was never called" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "fixture 2: verdict-valued gc.outcome supplied by caller is overridden to pass"
STUB_BDSHOW_FAIL=0 STUB_BDUPDATE_FAIL=0 STUB_BDCLOSE_FAIL=0 \
  run_script "fk-test2" "iterate" --set-metadata 'gc.outcome=iterate' --set-metadata 'code_review.code_verdict=iterate' >/tmp/cv-rlc-out2.$$ 2>&1
rc=$?
OUT2="$(cat /tmp/cv-rlc-out2.$$)"; rm -f /tmp/cv-rlc-out2.$$
if [ "$rc" -eq 0 ] && grep -q "gc.outcome=pass" "$STUB_GC_LOG" && ! grep -q "gc.outcome=iterate" "$STUB_GC_LOG"; then
  echo "  PASS: bd update never received gc.outcome=iterate — only gc.outcome=pass"
else
  echo "  FAIL: expected gc.outcome=pass to win over the caller-supplied iterate value (rc=${rc})" >&2
  FAILURES=$((FAILURES+1))
fi
if printf '%s' "$OUT2" | grep -qi "ignoring caller-supplied"; then
  echo "  PASS: script logged a warning about the ignored caller-supplied gc.outcome"
else
  echo "  FAIL: expected a warning about the ignored caller-supplied gc.outcome" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "fixture 3a: genuine failure — bd update fails, script aborts and never closes"
STUB_BDSHOW_FAIL=0 STUB_BDUPDATE_FAIL=1 STUB_BDCLOSE_FAIL=0 \
  run_script "fk-test3a" "should not close" --set-metadata 'code_review.code_verdict=approve' >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "  PASS: script exited nonzero on a genuine bd update failure"
else
  echo "  FAIL: expected a nonzero exit when bd update fails" >&2
  FAILURES=$((FAILURES+1))
fi
if grep -q "bd close fk-test3a" "$STUB_GC_LOG"; then
  echo "  FAIL: bd close was called despite the earlier bd update failure" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: bd close was never reached after the bd update failure"
fi

start_case "fixture 3b: genuine failure — the bead cannot be read, script aborts before any write"
STUB_BDSHOW_FAIL=1 STUB_BDUPDATE_FAIL=0 STUB_BDCLOSE_FAIL=0 \
  run_script "fk-test3b" "should not close" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q "bd update fk-test3b" "$STUB_GC_LOG" && ! grep -q "bd close fk-test3b" "$STUB_GC_LOG"; then
  echo "  PASS: script exited nonzero and never reached bd update/close when the bead could not be read"
else
  echo "  FAIL: expected a nonzero exit and no bd update/close when bd show fails (rc=${rc})" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "fixture 3c: genuine failure — bd close itself fails, script surfaces it"
STUB_BDSHOW_FAIL=0 STUB_BDUPDATE_FAIL=0 STUB_BDCLOSE_FAIL=1 \
  run_script "fk-test3c" "should fail at close" --set-metadata 'code_review.code_verdict=approve' >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "  PASS: script exited nonzero on a genuine bd close failure"
else
  echo "  FAIL: expected a nonzero exit when bd close fails" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "fixture 4: zero --set-metadata args under /bin/bash (bash 3.2 empty-array regression, fk-7w9y6 iteration 2 BLOCKING-1)"
if [ -x /bin/bash ]; then
  STUB_GC_LOG="${SANDBOX}/gc.log"
  : > "$STUB_GC_LOG"
  STUB_BDSHOW_FAIL=0 STUB_BDUPDATE_FAIL=0 STUB_BDCLOSE_FAIL=0 STUB_GC_LOG="$STUB_GC_LOG" GC="${STUBDIR}/gc" PATH="${STUBDIR}:${PATH}" \
    /bin/bash "$SCRIPT" "fk-test4" "no-op pass, no extra metadata" >/tmp/cv-rlc-out4.$$ 2>&1
  rc=$?
  OUT4="$(cat /tmp/cv-rlc-out4.$$)"; rm -f /tmp/cv-rlc-out4.$$
  if [ "$rc" -eq 0 ] && grep -qE "^bd update fk-test4 --set-metadata gc\.outcome=pass $" "$STUB_GC_LOG"; then
    echo "  PASS: script closed cleanly under /bin/bash with zero --set-metadata args"
  else
    echo "  FAIL: expected a successful bd update/close under /bin/bash with zero extra metadata (rc=${rc})" >&2
    printf '%s\n' "$OUT4" >&2
    FAILURES=$((FAILURES+1))
  fi
  if grep -q "bd close fk-test4" "$STUB_GC_LOG"; then
    echo "  PASS: bd close was called"
  else
    echo "  FAIL: bd close was never called" >&2
    FAILURES=$((FAILURES+1))
  fi
else
  echo "  SKIP: /bin/bash not available on this host"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILURES: $FAILURES"
  exit 1
fi
