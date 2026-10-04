#!/usr/bin/env bash
# con-voyage-apply-review-findings-pause.test.sh — hermetic, offline contract
# tests for the LOW-only mayor-reopen pause added to main.apply-review-
# findings.md (fk-9iqxnx (a): "LOW-only verdicts PAUSE before publish for a
# bounded window waiting for [a real re-open command]"). Mirrors the static/
# contract-grep style of con-voyage-build-phase.test.sh: these prove the
# wiring a worker actually receives from the real workflow file, not a
# hand-maintained description of it.
#
# Run:  bash tests/con-voyage-apply-review-findings-pause.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
APPLY_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.apply-review-findings.md"

[ -f "$APPLY_MD" ] || { echo "FATAL: expected file not found: $APPLY_MD" >&2; exit 2; }

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$APPLY_MD"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (not found verbatim in $APPLY_MD)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

line_of() {
  grep -nF -- "$1" "$APPLY_MD" | head -1 | cut -d: -f1
}

start_case "the LOW-only path defers the done decision to the new pause section instead of setting done directly"
assert_contains 'LOW-only verdict" below BEFORE deciding the verdict' "LOW-only path routes through the pause section before deciding done"
assert_contains "LOW count is 0, write a no-op review summary and set" "a genuine zero-finding approval still sets done directly, no pause needed"

start_case "the pause window is a rig/city env var with a digit-guarded default, not a sling flag"
assert_contains 'CV_LOW_REOPEN_WINDOW_SECONDS="${CV_LOW_REOPEN_WINDOW_SECONDS:-1200}"' "reads CV_LOW_REOPEN_WINDOW_SECONDS with a 1200s (20min) default"
assert_contains '*[!0-9]*|'"'"''"'"') CV_LOW_REOPEN_WINDOW_SECONDS="1200" ;;' "a non-numeric override coerces back to the default instead of breaking the loop"

start_case "the pause polls gc.build.mayor_reopen_requested on the workflow root, cheaply (no LLM calls)"
assert_contains ".get('gc.build.mayor_reopen_requested')" "reads the reopen flag cv-reopen-findings.sh sets"
assert_contains 'sleep 30' "polls on a plain sleep interval, not an LLM call"

start_case "a detected reopen reads the recorded findings and is distinguishable from a timeout"
assert_contains ".get('gc.build.mayor_reopen_findings')" "reads the recorded findings text"
assert_contains 'mayor reopen detected on ${ROOT_ID} — treating the recorded findings as BLOCKING for this pass' "logs the reopen distinctly from the no-reopen timeout path"
assert_contains 'no mayor reopen within ${CV_LOW_REOPEN_WINDOW_SECONDS}s — proceeding to publish with the LOW findings on the PR, as designed' "logs the timeout path distinctly from a detected reopen"

start_case "a consumed reopen clears the flag so a later pass never re-consumes the same request"
assert_contains "gc bd update \"\$ROOT_ID\" --set-metadata 'gc.build.mayor_reopen_requested=false'" "clears gc.build.mayor_reopen_requested after consuming it"

start_case "a reopen forces verdict=iterate, never done, in the same pass that consumed it"
assert_contains 'OR the mayor reopened this pass with new' "verdict=iterate condition lists the mayor-reopen case"
assert_contains 'set code_review.verdict=iterate instead, even if you believe every finding' "the mayor-reopen case falls into the same iterate branch as any other fix"
assert_contains 'Never set done in the same pass that' "the never-done-same-pass rule is stated"
assert_contains 'before, or consumed a mayor reopen.' "the never-done-same-pass rule explicitly includes a consumed mayor reopen"

start_case "a reopen with no actionable code change still carries forward, never silently dropped"
assert_contains 'still set verdict=iterate and record' "a non-actionable reopen (a question, a scope decision) still forces iterate"
assert_contains 'never silently drop a reopen that produced no code change' "explicitly rules out silently dropping an unactionable reopen"

start_case "ordering: the pause section precedes the verdict-setting section it feeds"
pause_line="$(line_of '### Pause for a mayor reopen on a LOW-only verdict')"
verdict_line="$(line_of '### Setting code_review.verdict')"
if [ -n "$pause_line" ] && [ -n "$verdict_line" ] && [ "$pause_line" -lt "$verdict_line" ]; then
  echo "  PASS: pause section (line ${pause_line}) precedes the verdict section (line ${verdict_line})"
else
  echo "  FAIL: expected the pause section to precede the verdict section" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "the pause section resolves WORK_BEAD itself (self-contained, does not assume an earlier block's variable survives)"
assert_contains 'cv_resolve_work_bead "$CONVOY_ID"' "resolves the real work bead via the shared lib helper, same as every other step"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
