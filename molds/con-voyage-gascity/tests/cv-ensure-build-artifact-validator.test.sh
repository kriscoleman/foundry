#!/usr/bin/env bash
# cv-ensure-build-artifact-validator.test.sh — hermetic, offline test for the
# self-healing build-artifact-validator seeder (fk-ohoy).
#
# WHY: build-artifact-valid.sh (shipped + self-seeded by cv-ensure-gate-
# scripts.sh, fk-6i53) itself depends on a validate_build_artifact.py
# validator at <rig-root>/.gc/scripts/validate_build_artifact.py and a
# schemas/build/*.yaml schema set at <rig-root>/schemas/build/ — neither of
# which the pack shipped or seeded. They existed only as uncommitted local
# scratch files in some rigs (foundry-kc), so a freshly-seeded rig had the
# gate script but not what it needs to actually run, failing the
# workflow-finalize gate with a "validator not found" error. This closes
# that gap the same way fk-6i53 closed it for the check scripts themselves.
#
# Contract under test:
#   cv-ensure-build-artifact-validator.sh <rig-root>
#   - Seeds a MISSING <rig-root>/.gc/scripts/validate_build_artifact.py from
#     this script's own sibling validate_build_artifact.py asset, setting the
#     exec bit.
#   - Seeds any MISSING <rig-root>/schemas/build/<name>.yaml from this
#     script's own sibling ../schemas/build/ assets directory.
#   - NEVER overwrites a file that already exists at the destination — same
#     local-override policy as cv-ensure-gate-scripts.sh.
#   - Fails loudly (exit 1, no partial writes) if the source assets are
#     missing/empty (a broken pack) or <rig-root> is not a directory.
#
# HOW IT WORKS: real temp directories under a sandbox — pure filesystem
# operations, no gc/bd/network involved, so this is hermetic by construction.
#
# Run:  bash tests/cv-ensure-build-artifact-validator.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-ensure-build-artifact-validator.sh"
SOURCE_VALIDATOR="${MOLD_DIR}/pack/assets/scripts/validate_build_artifact.py"
SOURCE_SCHEMAS_DIR="${MOLD_DIR}/pack/assets/schemas/build"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-ensure-build-artifact-validator-test.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

run_script() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

OUT=""
RC=0

shopt -s nullglob
SOURCE_SCHEMA_FILES=("${SOURCE_SCHEMAS_DIR}"/*.yaml)
shopt -u nullglob

# ===========================================================================
# CASE 1 — fresh rig (nothing at all): seeds validator + every schema file.
# ===========================================================================
start_case "1: fresh rig gets validator and all schema files seeded, correct, executable"
RIG1="${SANDBOX}/rig1"
mkdir -p "$RIG1"
run_script "$RIG1"
assert_eq "0" "$RC" "exit 0 on fresh seed"

DEST1_VALIDATOR="${RIG1}/.gc/scripts/validate_build_artifact.py"
if [ -f "$DEST1_VALIDATOR" ]; then pass "validator was seeded"; else fail "validator was NOT seeded"; fi
if [ -x "$DEST1_VALIDATOR" ]; then pass "validator is executable"; else fail "validator is NOT executable"; fi
if diff -q "$SOURCE_VALIDATOR" "$DEST1_VALIDATOR" >/dev/null 2>&1; then
  pass "validator content matches pack source"
else
  fail "validator content does NOT match pack source"
fi

DEST1_SCHEMAS="${RIG1}/schemas/build"
for src in "${SOURCE_SCHEMA_FILES[@]}"; do
  name="$(basename "$src")"
  dest="${DEST1_SCHEMAS}/${name}"
  if [ -f "$dest" ]; then pass "${name} was seeded"; else fail "${name} was NOT seeded"; fi
  if diff -q "$src" "$dest" >/dev/null 2>&1; then
    pass "${name} content matches pack source"
  else
    fail "${name} content does NOT match pack source"
  fi
done

# ===========================================================================
# CASE 2 — rig with a customized validator and one customized schema already
# in place: never overwritten, everything else still seeded.
# ===========================================================================
start_case "2: existing rig-local files are never clobbered (override point)"
RIG2="${SANDBOX}/rig2"
mkdir -p "${RIG2}/.gc/scripts" "${RIG2}/schemas/build"
printf '#!/usr/bin/env python3\nprint("custom override")\n' > "${RIG2}/.gc/scripts/validate_build_artifact.py"
FIRST_SCHEMA_NAME="$(basename "${SOURCE_SCHEMA_FILES[0]}")"
printf 'custom: true\n' > "${RIG2}/schemas/build/${FIRST_SCHEMA_NAME}"
run_script "$RIG2"
assert_eq "0" "$RC" "exit 0 when customized files already exist"

VALIDATOR_CONTENT="$(cat "${RIG2}/.gc/scripts/validate_build_artifact.py")"
if printf '%s' "$VALIDATOR_CONTENT" | grep -q "custom override"; then
  pass "customized validate_build_artifact.py was left untouched"
else
  fail "customized validate_build_artifact.py was overwritten"
fi
SCHEMA_CONTENT="$(cat "${RIG2}/schemas/build/${FIRST_SCHEMA_NAME}")"
assert_eq "custom: true" "$SCHEMA_CONTENT" "customized ${FIRST_SCHEMA_NAME} left untouched"

MISSING_COUNT=0
for src in "${SOURCE_SCHEMA_FILES[@]}"; do
  name="$(basename "$src")"
  [ "$name" = "$FIRST_SCHEMA_NAME" ] && continue
  if [ ! -f "${RIG2}/schemas/build/${name}" ]; then MISSING_COUNT=$((MISSING_COUNT+1)); fi
done
assert_eq "0" "$MISSING_COUNT" "every other schema file was still seeded alongside the customized one"

# ===========================================================================
# CASE 3 — partial seed: only the missing pieces are added.
# ===========================================================================
start_case "3: partial seed — only missing files are added"
RIG3="${SANDBOX}/rig3"
mkdir -p "${RIG3}/.gc/scripts"
printf 'placeholder\n' > "${RIG3}/.gc/scripts/validate_build_artifact.py"
run_script "$RIG3"
assert_eq "0" "$RC" "exit 0 on partial seed"
PLACEHOLDER="$(cat "${RIG3}/.gc/scripts/validate_build_artifact.py")"
assert_eq "placeholder" "$PLACEHOLDER" "pre-existing validate_build_artifact.py left untouched"
ALL_SEEDED=1
for src in "${SOURCE_SCHEMA_FILES[@]}"; do
  name="$(basename "$src")"
  diff -q "$src" "${RIG3}/schemas/build/${name}" >/dev/null 2>&1 || ALL_SEEDED=0
done
assert_eq "1" "$ALL_SEEDED" "all schema files were seeded from pack source even though only schemas/ was missing"

# ===========================================================================
# CASE 4 — second run against a fully seeded rig is a clean no-op.
# ===========================================================================
start_case "4: idempotent — re-running against a fully seeded rig changes nothing"
run_script "$RIG1"
assert_eq "0" "$RC" "exit 0 on idempotent re-run"
if diff -q "$SOURCE_VALIDATOR" "$DEST1_VALIDATOR" >/dev/null 2>&1; then
  pass "validator still matches pack source after re-run"
else
  fail "validator drifted from pack source after re-run"
fi
for src in "${SOURCE_SCHEMA_FILES[@]}"; do
  name="$(basename "$src")"
  if diff -q "$src" "${DEST1_SCHEMAS}/${name}" >/dev/null 2>&1; then
    pass "${name} still matches pack source after re-run"
  else
    fail "${name} drifted from pack source after re-run"
  fi
done

# ===========================================================================
# CASE 5 — missing rig-root argument / not a directory: fails safe, no writes.
# ===========================================================================
start_case "5: usage error on missing/invalid rig-root argument"
run_script
if [ "$RC" -ne 0 ]; then pass "no-args exits non-zero"; else fail "no-args should fail, got exit 0"; fi

NOTADIR="${SANDBOX}/does-not-exist"
run_script "$NOTADIR"
if [ "$RC" -ne 0 ]; then
  pass "non-existent rig-root exits non-zero"
else
  fail "non-existent rig-root should fail, got exit 0"
fi
if [ -e "$NOTADIR" ]; then fail "script created something at a rig-root that should have been rejected"; else pass "no writes happened for an invalid rig-root"; fi

# ===========================================================================
# CASE 6 — broken pack (no source validator, no source schemas): fails loud,
# no partial write.
# ===========================================================================
start_case "6: fails loud when the pack itself ships no validator/schemas"
EMPTY_PACK_SCRIPTS="${SANDBOX}/empty-pack/pack/assets/scripts"
mkdir -p "${EMPTY_PACK_SCRIPTS}"
# Deliberately do NOT create a sibling validate_build_artifact.py or a
# ../schemas/build dir, and copy the script under test into this fake pack
# layout so it resolves missing/empty sources relative to itself.
cp "$SCRIPT" "${EMPTY_PACK_SCRIPTS}/cv-ensure-build-artifact-validator.sh"
RIG6="${SANDBOX}/rig6"
mkdir -p "$RIG6"
OUT="$(bash "${EMPTY_PACK_SCRIPTS}/cv-ensure-build-artifact-validator.sh" "$RIG6" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then pass "missing source validator/schemas exits non-zero"; else fail "missing source validator/schemas should fail, got exit 0"; fi
if [ -e "${RIG6}/.gc" ]; then fail "partial .gc/ directory was created despite the failure"; else pass "no partial .gc/ directory was created"; fi
if [ -e "${RIG6}/schemas" ]; then fail "partial schemas/ directory was created despite the failure"; else pass "no partial schemas/ directory was created"; fi

# ===========================================================================
# Summary
# ===========================================================================
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
