#!/usr/bin/env bash
# cv-json-parse-stderr-guard.test.sh — lint guard (fk-pu523 acceptance #3):
# every place in the con-voyage-gascity mold's pack scripts that calls
# `gc`/`bd` (or any command) with --json must never also merge stderr into
# that same call with `2>&1` — a stray warning line on stderr (for example
# ".gc/site.toml declares a binding for unknown rig ...") then lands ahead of
# the JSON on the merged stream and corrupts the parse, exactly the bug
# cv-synthesis-low-mail.sh had (see cv-synthesis-low-mail.test.sh CASE 19 for
# the concrete runtime repro).
#
# This is a static text check, not a runtime test: it joins
# backslash-continued lines into one logical statement per iteration, then
# flags any logical line containing both `--json` and `2>&1`. If a `2>&1` is
# ever reintroduced on a `--json` call, this test fails immediately instead
# of waiting for it to surface as a silent JSON-parse failure in the field.
#
# Run:  bash tests/cv-json-parse-stderr-guard.test.sh   (exit 0 => guard holds)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPTS_DIR="${MOLD_DIR}/pack/assets/scripts"

FAILURES=0

# check_file FILE — join backslash-continued lines into logical statements
# and flag any logical line that combines --json with 2>&1.
check_file() {
  local f="$1"
  local logical=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == *'\' ]]; then
      logical="${logical}${line%\\} "
      continue
    fi
    logical="${logical}${line}"
    if [[ "$logical" == *'--json'* && "$logical" == *'2>&1'* ]]; then
      echo "FAIL: ${f#"${MOLD_DIR}/"}: --json call merges stderr via 2>&1: ${logical}" >&2
      FAILURES=$((FAILURES + 1))
    fi
    logical=""
  done < "$f"
}

while IFS= read -r -d '' f; do
  check_file "$f"
done < <(find "$SCRIPTS_DIR" -name '*.sh' -print0)

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} violation(s) found"
  exit 1
fi
