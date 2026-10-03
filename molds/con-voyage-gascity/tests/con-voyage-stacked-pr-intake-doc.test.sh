#!/usr/bin/env bash
# con-voyage-stacked-pr-intake-doc.test.sh — hermetic, offline doc test
# (fk-jdhtq).
#
# fk-qppb4 built the full engine-side stacked-PR primitive — `gc convoy
# target <convoy-id> <base-branch>`, `cv_resolve_base_branch`,
# `cv_ensure_branch_based_on` — and documented it in README.md. But the
# facilitator-facing runbook (skills/con-voyage/SKILL.md, the file actually
# loaded when a human or the mayor runs `/con-voyage`) never mentioned it:
# a facilitator following the skill at intake has no way to discover that
# declaring a dependent slice is one `gc convoy target` call, so dependent
# slices keep shipping as independent PRs off main (sc-139247 wave 2: s3/s4
# both depend on slice 2, each PR opened against main anyway).
#
# This test pins that the skill's Phase 0 (Intake) actually tells the
# facilitator how and when to declare a dependency, using the real
# `gc convoy target` primitive — not a reinvented formula var — and flags
# the known CI-repair boundary (base_branches in city.toml) so a stacked
# PR's own CI failures don't silently go unrepaired.
#
# Run:  bash tests/con-voyage-stacked-pr-intake-doc.test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SKILL_FILE="${MOLD_DIR}/skills/con-voyage/SKILL.md"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $label ($file does not exist)" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  if grep -qF -- "$needle" "$file"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (not found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

start_case "SKILL.md documents the gc convoy target primitive for a dependent slice"
assert_contains "$SKILL_FILE" 'gc convoy target <convoy-id> <base-branch>' \
  "SKILL.md shows the worked gc convoy target invocation"

start_case "SKILL.md tells the facilitator WHEN to declare it (intake, before sling)"
assert_contains "$SKILL_FILE" 'declare it now, before the sling below' \
  "SKILL.md intake step calls out declaring the dependency before slinging"

start_case "SKILL.md names this as GitHub stacked PRs, not a bespoke mechanism"
assert_contains "$SKILL_FILE" 'GitHub stacked PR' \
  "SKILL.md ties the convoy-target step to GitHub stacked PRs"

start_case "SKILL.md flags the CI-repair base_branches boundary (fk-qppb4 known gap)"
assert_contains "$SKILL_FILE" 'base_branches' \
  "SKILL.md warns that the stacked base must be added to city.toml base_branches for CI repair to see it"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
