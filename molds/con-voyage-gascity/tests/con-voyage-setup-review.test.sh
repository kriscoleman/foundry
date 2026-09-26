#!/usr/bin/env bash
# con-voyage-setup-review.test.sh — hermetic, offline structural test for
# {target}.setup-con-voyage-review.md's gate-script/validator seeding blocks
# (fk-4jdeh).
#
# WHY: both blocks call an "ensure" script (cv-ensure-gate-scripts.sh /
# cv-ensure-build-artifact-validator.sh) that takes a positional <rig-root>
# and writes to <rig-root>/.gc/... itself. Before this fix they passed
# "${GC_CITY:-.}" -- the multi-rig CITY root, not any one rig's own root --
# as that argument. Harmless on a rig that happened to have those paths
# already hand-seeded under its city root (foundry-kc, per fk-6i53
# 2026-09-15), but on any rig without that lucky prior seeding this silently
# "succeeds" into the wrong directory: the review-loop/finalize gate stays
# unresolved and reproduces the exact quarantine failure fk-6i53/fk-ohoy
# closed (confirmed live: blocked the P1 replicated-docs PR, root fk-tbs0h/
# fk-czkvb).
#
# Mirrors the existing pattern for structurally verifying embedded bash in a
# workflow .md file (con-voyage-publish.test.sh's CV_STATE_DIR block, itself
# mirroring con-voyage-review-watchdog.test.sh CASE 16) rather than
# extracting and executing the fenced block -- the resolution logic itself
# (cv_default_rig_root) already has direct unit coverage in
# con-voyage-lib.test.sh.
#
# Run:  bash tests/con-voyage-setup-review.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SETUP_REVIEW_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/{target}.setup-con-voyage-review.md"

if [ ! -f "$SETUP_REVIEW_MD" ]; then
  echo "FATAL: workflow file under test not found at ${SETUP_REVIEW_MD}" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$SETUP_REVIEW_MD"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (not found verbatim in ${SETUP_REVIEW_MD})" >&2
    FAILURES=$((FAILURES+1))
  fi
}

assert_not_contains() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$SETUP_REVIEW_MD"; then
    echo "  FAIL: $label (found verbatim in ${SETUP_REVIEW_MD}, should not be)" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: $label"
  fi
}

line_of() {
  grep -nF -- "$1" "$SETUP_REVIEW_MD" | head -1 | cut -d: -f1
}

count_of() {
  grep -cF -- "$1" "$SETUP_REVIEW_MD"
}

# Counts occurrences of $1 on a line immediately followed by a line equal to
# $2. Used instead of a bare whole-file count_of for the CV_LIB lookup idiom:
# fk-qppb4's base-branch resolution block (unrelated to RIG_ROOT) reuses the
# exact same command-v/find idiom for its own CV_LIB lookup, so a raw
# occurrence count drifts upward as other blocks adopt it. Pairing with the
# RIG_ROOT="" line that only this fix's two blocks emit keeps the assertion
# scoped to what CASE 2 actually verifies.
count_of_adjacent_pair() {
  local first="$1" second="$2" prev="" line count=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$prev" = "$first" ] && [ "$line" = "$second" ]; then
      count=$((count+1))
    fi
    prev="$line"
  done < "$SETUP_REVIEW_MD"
  printf '%s' "$count"
}

# ===========================================================================
# CASE 1 — Neither ensure-script invocation still passes the CITY root where
#   a rig root is required. This is the actual bug: ${GC_CITY:-.} is a
#   legitimate *search root* for locating a not-yet-seeded script via `find`
#   (kept, see CASE 2), but never the value passed AS <rig-root> to a script
#   that writes rig-scoped output.
# ===========================================================================
start_case "1: neither ensure-script call still receives \${GC_CITY:-.} as its <rig-root> argument"
assert_not_contains '"$CV_ENSURE_GATE_SCRIPTS" "${GC_CITY:-.}"' "cv-ensure-gate-scripts.sh no longer invoked with the CITY root as <rig-root>"
assert_not_contains '"$CV_ENSURE_VALIDATOR" "${GC_CITY:-.}"' "cv-ensure-build-artifact-validator.sh no longer invoked with the CITY root as <rig-root>"

# ===========================================================================
# CASE 2 — Both blocks resolve RIG_ROOT via the shared cv_default_rig_root(),
#   not a hand-copied GC_RIG_ROOT/.beads-walkup/GC_CITY algorithm, and the
#   find-based script-discovery idiom (a legitimate city-wide search) is
#   otherwise undisturbed.
# ===========================================================================
start_case "2: RIG_ROOT resolution calls the shared cv_default_rig_root(), not a duplicate"
assert_contains 'CV_LIB="$(command -v con-voyage-lib.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"' "locates con-voyage-lib.sh via the same command-v/find idiom as this file's CV_ENSURE_GATE_SCRIPTS/CV_ENSURE_VALIDATOR"
assert_contains 'RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"' "sources the lib and calls cv_default_rig_root() for the resolved value"
assert_contains '[ -n "${RIG_ROOT:-}" ] || RIG_ROOT="${GC_CITY:-.}"' "falls back to GC_CITY when CV_LIB is empty or the source+call produced nothing"

lib_lookup_count="$(count_of_adjacent_pair 'CV_LIB="$(command -v con-voyage-lib.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"' 'RIG_ROOT=""')"
resolve_count="$(count_of 'RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"')"
if [ "$lib_lookup_count" -eq 2 ] && [ "$resolve_count" -eq 2 ]; then
  echo "  PASS: both the gate-scripts block and the validator block resolve RIG_ROOT independently (each fenced block is self-contained, matching this file's existing per-block re-derivation idiom)"
else
  echo "  FAIL: expected 2 independent RIG_ROOT resolutions (one per block), found lib-lookup=${lib_lookup_count} resolve=${resolve_count}" >&2
  FAILURES=$((FAILURES+1))
fi

# ===========================================================================
# CASE 3 — Both ensure-script invocations now pass the resolved $RIG_ROOT.
# ===========================================================================
start_case "3: both ensure-script calls now pass the resolved \$RIG_ROOT"
assert_contains '"$CV_ENSURE_GATE_SCRIPTS" "$RIG_ROOT" || { echo "gate check script seeding failed — refusing to start a review loop that would quarantine" >&2; exit 1; }' "cv-ensure-gate-scripts.sh invoked with the resolved rig root"
assert_contains '"$CV_ENSURE_VALIDATOR" "$RIG_ROOT" || { echo "build-artifact validator seeding failed — refusing to proceed toward a workflow-finalize gate that would fail confusingly" >&2; exit 1; }' "cv-ensure-build-artifact-validator.sh invoked with the resolved rig root"

# ===========================================================================
# CASE 4 — Ordering: RIG_ROOT must be fully resolved before each ensure
#   script runs, within its own block.
# ===========================================================================
start_case "4: RIG_ROOT resolution precedes each ensure-script invocation"
gate_resolve_line="$(grep -nF 'RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"' "$SETUP_REVIEW_MD" | sed -n '1p' | cut -d: -f1)"
gate_call_line="$(line_of '"$CV_ENSURE_GATE_SCRIPTS" "$RIG_ROOT"')"
validator_resolve_line="$(grep -nF 'RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"' "$SETUP_REVIEW_MD" | sed -n '2p' | cut -d: -f1)"
validator_call_line="$(line_of '"$CV_ENSURE_VALIDATOR" "$RIG_ROOT"')"

if [ -n "$gate_resolve_line" ] && [ -n "$gate_call_line" ] && [ "$gate_resolve_line" -lt "$gate_call_line" ]; then
  echo "  PASS: gate-scripts block resolves RIG_ROOT (line ${gate_resolve_line}) before invoking CV_ENSURE_GATE_SCRIPTS (line ${gate_call_line})"
else
  echo "  FAIL: expected RIG_ROOT resolution to precede the cv-ensure-gate-scripts.sh call" >&2
  FAILURES=$((FAILURES+1))
fi

if [ -n "$validator_resolve_line" ] && [ -n "$validator_call_line" ] && [ "$validator_resolve_line" -lt "$validator_call_line" ]; then
  echo "  PASS: validator block resolves RIG_ROOT (line ${validator_resolve_line}) before invoking CV_ENSURE_VALIDATOR (line ${validator_call_line})"
else
  echo "  FAIL: expected RIG_ROOT resolution to precede the cv-ensure-build-artifact-validator.sh call" >&2
  FAILURES=$((FAILURES+1))
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
