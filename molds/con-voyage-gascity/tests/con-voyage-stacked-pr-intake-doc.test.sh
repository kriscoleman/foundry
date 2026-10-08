#!/usr/bin/env bash
# con-voyage-stacked-pr-intake-doc.test.sh — hermetic, offline doc test
# (fk-jdhtq).
#
# fk-qppb4 built the full engine-side stacked-PR primitive — `gc convoy
# target <convoy-id> <base-branch>`, `cv_resolve_base_branch`,
# `cv_ensure_branch_based_on` — and documented it in README.md. The
# facilitator-facing runbook (skills/con-voyage/SKILL.md, the file actually
# loaded when a human or the mayor runs `/con-voyage`) originally told the
# facilitator to call `gc convoy target` on a pre-made convoy before
# slinging — but `gc sling ... --on con-voyage` always mints its own fresh
# input convoy (`convoy_id` is a reserved v2 token), so that pre-made
# convoy's target was silently ignored, and calling `gc convoy target` AFTER
# the sling instead raced prepare-build (fk-wmhr96: confirmed live twice,
# vandoor va-69b17/va-fn5k1 — a build attempt resolved the default base
# before the post-sling target call landed, and the dead workflow still
# minted downstream review lanes).
#
# fk-wmhr96 replaced that two-step, racy recipe with a single sling-time
# `base_branch` formula var, applied deterministically inside prepare-build
# before any worktree exists. This test pins that the skill's Phase 0
# (Intake) documents THAT recipe — not the old pre-sling/post-sling
# `gc convoy target` call — and still flags the known CI-repair boundary
# (base_branches in city.toml) so a stacked PR's own CI failures don't
# silently go unrepaired.
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

start_case "SKILL.md documents the sling-time base_branch var for a dependent slice"
assert_contains "$SKILL_FILE" '--var base_branch=<base-branch>' \
  "SKILL.md shows the worked base_branch sling invocation"

start_case "SKILL.md tells the facilitator WHEN to declare it (at sling time, not before/after)"
assert_contains "$SKILL_FILE" 'declare it **at sling time**' \
  "SKILL.md intake step calls out declaring the dependency at sling time"

start_case "SKILL.md warns against the old pre-sling convoy-target recipe (fk-wmhr96)"
assert_contains "$SKILL_FILE" 'Do **not** pre-create a convoy and call' \
  "SKILL.md explicitly steers the facilitator away from the racy pre/post-sling gc convoy target recipe"

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
