#!/usr/bin/env bash
# cv-code-lens-hardening.test.sh — hermetic, offline test that the con-voyage
# review lens PROMPTS carry the #10494-class regression hardening (fk-7fego).
#
# Con-voyage's own review lenses waved through failure modes that later
# surfaced in replicatedhq/vandoor#10494 (request-scoped Helm namespace prop):
# an "intentionally unthreaded" code path whose "no live caller" claim was
# never independently verified, and a cache-key-delimiter-ambiguity bug that
# a different reviewer (not our lenses) had to catch. This asserts the
# hardening actually landed in the prompt files the lenses read — not a doc a
# reviewer never sees — the same way con-voyage-orchestration-dispatch-posture
# .test.sh asserts against the mayor's fragment instead of a paraphrase of it.
#
# Items 1-4 (path coverage, exported-signature break, silent fallback,
# cache-key completeness) are owned by the three code-lens variants and must
# stay DRY in one shared template fragment, not pasted into each lens file —
# this suite asserts the fragment's content AND that each variant includes it
# by reference (`{{ template "cv-code-lens-hardening" . }}`), so a lens that
# silently drops the include still fails here even if the fragment itself
# looks correct.
#
# Run:  bash tests/cv-code-lens-hardening.test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
AGENTS_DIR="${MOLD_DIR}/pack/agents"
FRAGMENT="${MOLD_DIR}/pack/template-fragments/cv-code-lens-hardening.template.md"
INCLUDE_TOKEN='{{ template "cv-code-lens-hardening" . }}'

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
assert_contains "$FRAGMENT" '{{ define "cv-code-lens-hardening" }}' \
  "fragment defines the cv-code-lens-hardening named template"

start_case "the fragment states failure mode 1 (path coverage) and demands independent verification, not trust in a comment"
assert_contains "$FRAGMENT" "Path coverage" \
  "fragment names path coverage"
assert_contains "$FRAGMENT" "not itself proof" \
  "fragment requires independently confirming no live caller, not trusting the diff's own claim"

start_case "the fragment states failure mode 2 (exported-signature break)"
assert_contains "$FRAGMENT" "Exported-signature break" \
  "fragment names exported-signature break"
assert_contains "$FRAGMENT" "optional parameters/options" \
  "fragment requires new behavior to thread via optional params, never a changed signature"

start_case "the fragment states failure mode 3 (silent fallback)"
assert_contains "$FRAGMENT" "Silent fallback" \
  "fragment names silent fallback"
assert_contains "$FRAGMENT" "fail loud" \
  "fragment demands failing loud instead of a silent degraded output"

start_case "the fragment states failure mode 4 (cache-key completeness)"
assert_contains "$FRAGMENT" "Cache-key completeness" \
  "fragment names cache-key completeness"
assert_contains "$FRAGMENT" "missing an output-affecting input produces" \
  "fragment explains the consequence of an incomplete cache key"

start_case "all three code-lens variants include the shared fragment by reference (DRY, not pasted)"
for lens in cv-go-principal-engineer cv-frontend-principal-engineer cv-code-reviewer; do
  assert_contains "${AGENTS_DIR}/${lens}/prompt.template.md" "$INCLUDE_TOKEN" \
    "${lens} includes the shared hardening fragment"
done

start_case "cv-api-platform-contract explicitly verifies exported-signature break (failure mode 2)"
assert_contains "${AGENTS_DIR}/cv-api-platform-contract/prompt.template.md" "Exported-signature break" \
  "cv-api-platform-contract names exported-signature break explicitly"

start_case "cv-standards-janitor explicitly verifies comment bloat (failure mode 5, LOW unless egregious)"
assert_contains "${AGENTS_DIR}/cv-standards-janitor/prompt.template.md" "Comment bloat" \
  "cv-standards-janitor names comment bloat explicitly"
assert_contains "${AGENTS_DIR}/cv-standards-janitor/prompt.template.md" "egregious" \
  "cv-standards-janitor keeps comment bloat LOW unless egregious"

start_case "cv-security-reviewer explicitly verifies secret leak across the full diff, fixtures, and re-added code (failure mode 6)"
assert_contains "${AGENTS_DIR}/cv-security-reviewer/prompt.template.md" "test fixtures" \
  "cv-security-reviewer's secret-leak check names test fixtures"
assert_contains "${AGENTS_DIR}/cv-security-reviewer/prompt.template.md" "removed and then re-added" \
  "cv-security-reviewer's secret-leak check names removed-then-re-added code"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
