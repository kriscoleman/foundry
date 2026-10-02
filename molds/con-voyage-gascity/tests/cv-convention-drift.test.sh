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
# The check is owned by the two frontend-focused lenses and must stay DRY in
# one shared template fragment, not pasted into each lens file — this suite
# asserts the fragment's content AND that each lens includes it by reference
# (`{{ template "cv-convention-drift" . }}`), the same way
# cv-code-lens-hardening.test.sh asserts against its own shared fragment
# instead of a paraphrase of it.
#
# Run:  bash tests/cv-convention-drift.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
AGENTS_DIR="${MOLD_DIR}/pack/agents"
SKILL_FILE="${MOLD_DIR}/skills/con-voyage/SKILL.md"
FRAGMENT="${MOLD_DIR}/pack/template-fragments/cv-convention-drift.template.md"
INCLUDE_TOKEN='{{ template "cv-convention-drift" . }}'

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

start_case "the shared fragment exists and defines the named template"
assert_contains "$FRAGMENT" '{{ define "cv-convention-drift" }}' \
  "fragment defines the cv-convention-drift named template"

start_case "the fragment carries the convention-drift check section"
assert_contains "$FRAGMENT" "## Convention-drift check" \
  "fragment has a Convention-drift check section"
assert_contains "$FRAGMENT" "nearest siblings" \
  "fragment requires comparing against nearest siblings, not just itself"

start_case "the fragment covers class tokens (radius, border, color, spacing, typography)"
assert_contains "$FRAGMENT" "**Class tokens**" \
  "fragment names class tokens as a checked category"
assert_contains "$FRAGMENT" "radius, border, color, spacing, and typography" \
  "fragment enumerates the specific token categories"

start_case "the fragment covers component reuse vs. a duplicated one-off"
assert_contains "$FRAGMENT" "**Component reuse**" \
  "fragment names component reuse as a checked category"
assert_contains "$FRAGMENT" "is drift, not a style choice" \
  "fragment flags duplicating a shared component instead of reusing it"

start_case "the fragment covers copy/verb consistency"
assert_contains "$FRAGMENT" "**Copy and verb consistency**" \
  "fragment names copy/verb consistency as a checked category"

start_case "the fragment requires file:line citation of both the drift and the convention it breaks"
assert_contains "$FRAGMENT" "cite the sibling's" \
  "fragment requires citing the sibling's file:line as proof of the established convention"

start_case "the fragment sets severity: visible or shared-component drift is at least LOW"
assert_contains "$FRAGMENT" "**LOW**" \
  "fragment names a LOW severity level for visible/shared-component drift"
assert_contains "$FRAGMENT" "shared" \
  "fragment ties the LOW severity level to shared-component drift"

start_case "the fragment documents a concrete BLOCKING rule instead of leaving severity ambiguous"
assert_contains "$FRAGMENT" "**BLOCKING**" \
  "fragment names a BLOCKING severity level"
assert_contains "$FRAGMENT" "forks an existing" \
  "fragment states the BLOCKING rule: forking a shared component instead of reusing it"

start_case "both frontend-focused lenses include the shared fragment by reference (DRY, not pasted)"
for lens in cv-frontend-principal-engineer cv-design-ux; do
  assert_contains "${AGENTS_DIR}/${lens}/prompt.template.md" "$INCLUDE_TOKEN" \
    "${lens} includes the shared convention-drift fragment"
done

start_case "the con-voyage skill's design-ux roster row documents the drift check"
DESIGN_UX_ROW="$(grep -F 'enable_design_ux=true' "$SKILL_FILE")"
if [ -z "$DESIGN_UX_ROW" ]; then
  echo "  FAIL: enable_design_ux roster row not found in $SKILL_FILE" >&2
  FAILURES=$((FAILURES+1))
elif [[ "$DESIGN_UX_ROW" == *"drift"* ]]; then
  echo "  PASS: enable_design_ux roster row mentions convention drift"
else
  echo "  FAIL: enable_design_ux roster row does not mention drift" >&2
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
