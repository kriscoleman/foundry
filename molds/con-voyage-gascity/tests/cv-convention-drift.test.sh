#!/usr/bin/env bash
# cv-convention-drift.test.sh — hermetic, offline test that the frontend-
# focused con-voyage review lenses carry an explicit convention-drift
# contract (fk-yhqwj, operator request on replicatedhq/ec#578).
#
# On #578 a new UI card used rounded-lg / border-red-200 while every sibling
# card in the same panel used rounded / border-red-300. It was only caught as
# a LOW finding by the design-ux lens — cv-frontend-principal-engineer (the
# JS/TS code lens) had no explicit instruction to compare a changed element
# against its siblings at all. The operator asked that "no drift from
# established frontend conventions" become an explicit, checked item in both
# frontend-focused lenses' contracts, not an incidental catch.
#
# This asserts the contract landed in the prompt files the lenses actually
# read — not a paraphrase elsewhere — the same way cv-code-lens-hardening
# .test.sh asserts against the shared hardening fragment instead of a
# description of it.
#
# Run:  bash tests/cv-convention-drift.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
AGENTS_DIR="${MOLD_DIR}/pack/agents"
SKILL_FILE="${MOLD_DIR}/skills/con-voyage/SKILL.md"

FRONTEND_PROMPT="${AGENTS_DIR}/cv-frontend-principal-engineer/prompt.template.md"
DESIGN_UX_PROMPT="${AGENTS_DIR}/cv-design-ux/prompt.template.md"

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

for pair in "cv-frontend-principal-engineer:${FRONTEND_PROMPT}" "cv-design-ux:${DESIGN_UX_PROMPT}"; do
  lens="${pair%%:*}"
  file="${pair#*:}"

  start_case "${lens} carries the convention-drift check section"
  assert_contains "$file" "## Convention-drift check" \
    "${lens} has a Convention-drift check section"
  assert_contains "$file" "nearest siblings" \
    "${lens} requires comparing against nearest siblings, not just itself"

  start_case "${lens} covers class tokens (radius, border, color, spacing, typography)"
  assert_contains "$file" "**Class tokens**" \
    "${lens} names class tokens as a checked category"
  assert_contains "$file" "radius, border, color, spacing, and typography" \
    "${lens} enumerates the specific token categories"

  start_case "${lens} covers component reuse vs. a duplicated one-off"
  assert_contains "$file" "**Component reuse**" \
    "${lens} names component reuse as a checked category"
  assert_contains "$file" "is drift, not a style choice" \
    "${lens} flags duplicating a shared component instead of reusing it"

  start_case "${lens} covers copy/verb consistency"
  assert_contains "$file" "**Copy and verb consistency**" \
    "${lens} names copy/verb consistency as a checked category"

  start_case "${lens} requires file:line citation of both the drift and the convention it breaks"
  assert_contains "$file" "cite the sibling's" \
    "${lens} requires citing the sibling's file:line as proof of the established convention"

  start_case "${lens} sets severity: visible or shared-component drift is at least LOW"
  assert_contains "$file" "is at least LOW" \
    "${lens} sets a LOW severity floor for visible/shared-component drift"

  start_case "${lens} documents a concrete BLOCKING rule instead of leaving severity ambiguous"
  assert_contains "$file" "BLOCKING when the diff forks an existing" \
    "${lens} states the BLOCKING rule: forking a shared component instead of reusing it"
done

start_case "the con-voyage skill's roster table documents design-ux's drift check"
assert_contains "$SKILL_FILE" "drift" \
  "SKILL.md's design_ux roster row mentions convention drift"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
