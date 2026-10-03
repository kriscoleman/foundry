#!/usr/bin/env bash
# cv-sling-doc-form.test.sh — hermetic, offline test that every doc surface
# documenting the con-voyage sling invocation uses the real gc flag (fk-81o4o).
#
# The con-voyage skill (mold source for .claude/skills/con-voyage/SKILL.md),
# the mayor orchestration fragment, and this README all documented
# `gc sling <target> <work-bead> --formula --var ...`. On the live gc,
# `-f/--formula` means "the second positional arg is a FORMULA NAME", so
# following the doc literally fails with "formula \"<bead-id>\" not found in
# search paths" — the working form is
# `gc sling <target> <work-bead> --on <formula> --var ...`.
#
# This greps every doc surface that shows the sling invocation and fails if
# the broken `<bead> ... --formula` form reappears, so a future edit can't
# silently reintroduce it.
#
# Run:  bash tests/cv-sling-doc-form.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"

README="${MOLD_DIR}/README.md"
SKILL_FILE="${MOLD_DIR}/skills/con-voyage/SKILL.md"
ORCHESTRATION_FRAGMENT="${MOLD_DIR}/pack/template-fragments/con-voyage-orchestration.template.md"

# Every doc surface that shows a worked `gc sling` invocation example.
DOC_FILES=("$README" "$SKILL_FILE" "$ORCHESTRATION_FRAGMENT")

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

# Matches the broken form: `gc sling <two positional args> --formula`, e.g.
# `gc sling <target> <bead> --formula` or `gc sling foo/bar fk-123 --formula`.
# The correct form puts the formula name as `--on <formula>`, never a bare
# `--formula` flag after the target/bead positionals.
BROKEN_PATTERN='gc sling [^ ]+ [^ ]+ --formula'

assert_no_broken_sling_form() {
  local file="$1" label="$2"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $label ($file does not exist)" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  if grep -qE -- "$BROKEN_PATTERN" "$file"; then
    echo "  FAIL: $label (found broken 'gc sling <target> <bead> --formula' form in $file)" >&2
    grep -nE -- "$BROKEN_PATTERN" "$file" | sed 's/^/    /' >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: $label"
  fi
}

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

start_case "no doc surface shows the broken 'gc sling <target> <bead> --formula' form"
for f in "${DOC_FILES[@]}"; do
  assert_no_broken_sling_form "$f" "$(basename "$f") has no broken sling invocation form"
done

start_case "README documents the working --on form"
assert_contains "$README" 'gc sling <target> <bead> --on con-voyage' \
  "README sling example uses --on con-voyage"

start_case "SKILL.md documents the working --on form"
assert_contains "$SKILL_FILE" 'gc sling <target> <work-bead> --on con-voyage' \
  "SKILL.md sling example uses --on con-voyage"

start_case "mayor orchestration fragment documents the working --on form"
assert_contains "$ORCHESTRATION_FRAGMENT" 'gc sling <target> <work-bead> --on con-voyage' \
  "orchestration fragment sling example uses --on con-voyage"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
