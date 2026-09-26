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
#   - "Ensure" means present AND current (fk-6z17l): a STALE destination file
#     (content differs from the pack's current copy) is replaced atomically,
#     with the previous content backed up to `<name>.prev` — same policy as
#     cv-ensure-gate-scripts.sh. A destination whose content already matches
#     the pack is left untouched and gets no backup file.
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
# CASE 2 — rig with a STALE validator and one stale schema already in place:
# both replaced (with a .prev backup each), everything else still seeded
# (fk-6z17l: "ensure" means present AND current, not stuck at first-seed
# version forever).
# ===========================================================================
start_case "2: a stale validator and a stale schema are replaced, previous content backed up"
RIG2="${SANDBOX}/rig2"
mkdir -p "${RIG2}/.gc/scripts" "${RIG2}/schemas/build"
STALE_VALIDATOR='#!/usr/bin/env python3
print("stale pre-upgrade validator")
'
printf '%s' "$STALE_VALIDATOR" > "${RIG2}/.gc/scripts/validate_build_artifact.py"
FIRST_SCHEMA_NAME="$(basename "${SOURCE_SCHEMA_FILES[0]}")"
printf 'stale: true\n' > "${RIG2}/schemas/build/${FIRST_SCHEMA_NAME}"
run_script "$RIG2"
assert_eq "0" "$RC" "exit 0 when stale files already exist"

if diff -q "$SOURCE_VALIDATOR" "${RIG2}/.gc/scripts/validate_build_artifact.py" >/dev/null 2>&1; then
  pass "stale validate_build_artifact.py was replaced with the current pack content"
else
  fail "stale validate_build_artifact.py was NOT replaced"
fi
if [ -x "${RIG2}/.gc/scripts/validate_build_artifact.py" ]; then
  pass "replaced validate_build_artifact.py is executable"
else
  fail "replaced validate_build_artifact.py is NOT executable"
fi
VALIDATOR_BACKUP="${RIG2}/.gc/scripts/validate_build_artifact.py.prev"
if [ -f "$VALIDATOR_BACKUP" ] && printf '%s' "$STALE_VALIDATOR" | cmp -s - "$VALIDATOR_BACKUP"; then
  pass "the stale validator content was backed up to validate_build_artifact.py.prev"
else
  fail "no correct .prev backup of the stale validator was kept"
fi

if diff -q "${SOURCE_SCHEMAS_DIR}/${FIRST_SCHEMA_NAME}" "${RIG2}/schemas/build/${FIRST_SCHEMA_NAME}" >/dev/null 2>&1; then
  pass "stale ${FIRST_SCHEMA_NAME} was replaced with the current pack content"
else
  fail "stale ${FIRST_SCHEMA_NAME} was NOT replaced"
fi
SCHEMA_BACKUP="${RIG2}/schemas/build/${FIRST_SCHEMA_NAME}.prev"
assert_eq "stale: true" "$(cat "$SCHEMA_BACKUP" 2>/dev/null)" "the stale ${FIRST_SCHEMA_NAME} content was backed up to ${FIRST_SCHEMA_NAME}.prev"

MISSING_COUNT=0
for src in "${SOURCE_SCHEMA_FILES[@]}"; do
  name="$(basename "$src")"
  [ "$name" = "$FIRST_SCHEMA_NAME" ] && continue
  if [ ! -f "${RIG2}/schemas/build/${name}" ]; then MISSING_COUNT=$((MISSING_COUNT+1)); fi
done
assert_eq "0" "$MISSING_COUNT" "every other schema file was still seeded alongside the stale-replaced one"

# ===========================================================================
# CASE 3 — partial seed: a stale validator is replaced, missing schemas are
# added, neither disturbs the other.
# ===========================================================================
start_case "3: partial seed — a stale validator is replaced, missing schemas are added"
RIG3="${SANDBOX}/rig3"
mkdir -p "${RIG3}/.gc/scripts"
printf 'placeholder\n' > "${RIG3}/.gc/scripts/validate_build_artifact.py"
run_script "$RIG3"
assert_eq "0" "$RC" "exit 0 on partial seed"
if diff -q "$SOURCE_VALIDATOR" "${RIG3}/.gc/scripts/validate_build_artifact.py" >/dev/null 2>&1; then
  pass "stale validate_build_artifact.py was replaced with the current pack content"
else
  fail "stale validate_build_artifact.py was NOT replaced"
fi
assert_eq "placeholder" "$(cat "${RIG3}/.gc/scripts/validate_build_artifact.py.prev" 2>/dev/null)" "the stale placeholder was backed up to validate_build_artifact.py.prev"
ALL_SEEDED=1
for src in "${SOURCE_SCHEMA_FILES[@]}"; do
  name="$(basename "$src")"
  diff -q "$src" "${RIG3}/schemas/build/${name}" >/dev/null 2>&1 || ALL_SEEDED=0
done
assert_eq "1" "$ALL_SEEDED" "all schema files were seeded from pack source even though only schemas/ was missing"

# ===========================================================================
# CASE 4 — second run against a fully seeded, up-to-date rig is a clean
# no-op: nothing replaced, no .prev backup files created.
# ===========================================================================
start_case "4: idempotent — re-running against an up-to-date rig changes nothing, writes no backup"
run_script "$RIG1"
assert_eq "0" "$RC" "exit 0 on idempotent re-run"
if diff -q "$SOURCE_VALIDATOR" "$DEST1_VALIDATOR" >/dev/null 2>&1; then
  pass "validator still matches pack source after re-run"
else
  fail "validator drifted from pack source after re-run"
fi
if [ -e "${DEST1_VALIDATOR}.prev" ]; then
  fail "validate_build_artifact.py.prev backup should not exist when content already matched"
else
  pass "no validate_build_artifact.py.prev backup was created for an already-current file"
fi
for src in "${SOURCE_SCHEMA_FILES[@]}"; do
  name="$(basename "$src")"
  if diff -q "$src" "${DEST1_SCHEMAS}/${name}" >/dev/null 2>&1; then
    pass "${name} still matches pack source after re-run"
  else
    fail "${name} drifted from pack source after re-run"
  fi
  if [ -e "${DEST1_SCHEMAS}/${name}.prev" ]; then
    fail "${name}.prev backup should not exist when content already matched"
  else
    pass "no ${name}.prev backup was created for an already-current file"
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
