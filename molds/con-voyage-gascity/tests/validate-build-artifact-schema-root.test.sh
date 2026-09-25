#!/usr/bin/env bash
# validate-build-artifact-schema-root.test.sh — hermetic, offline test for
# validate_build_artifact.py's SCHEMA_ROOT resolution (fk-vrvxl).
#
# WHY: validate_build_artifact.py is deployed at two different relative
# depths from its schemas/build/ directory, and the SAME file (copied
# byte-for-byte, per cv-ensure-build-artifact-validator.sh) must resolve
# SCHEMA_ROOT correctly from either one:
#
#   - shipped/cast-pack layout: <root>/assets/scripts/validate_build_artifact.py
#     with schemas at <root>/assets/schemas/build/ (mold source, and any
#     `ailloy cast` copy under a rig's packs/<name>/ cache) — one directory
#     up from "scripts" (parents[1]).
#   - seeded gate layout: <rig-root>/.gc/scripts/validate_build_artifact.py
#     with schemas at <rig-root>/schemas/build/ (self-seeded by
#     cv-ensure-build-artifact-validator.sh, fk-ohoy) — two directories up
#     from "scripts" (parents[2]).
#
# A single hardcoded parents[N] can only ever be correct for one of these.
# fk-ohoy shipped parents[2], which is correct for the seeded gate layout but
# breaks the shipped/cast-pack layout (fk-vrvxl's reported bug: "unknown
# build artifact schema"). Naively "fixing" it to parents[1] would repair the
# shipped-layout case while silently reintroducing the exact
# "validator can't find schemas" failure fk-ohoy fixed for the seeded gate —
# the one every live workflow-finalize gate actually depends on. This test
# pins BOTH layouts so neither regresses again.
#
# HOW IT WORKS: real temp directories under a sandbox, each populated with
# only ONE of the two layouts (so a wrong resolution can't accidentally find
# the other layout's schemas sitting nearby) — pure filesystem operations, no
# gc/bd/network involved, so this is hermetic by construction.
#
# Run:  bash tests/validate-build-artifact-schema-root.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SOURCE_VALIDATOR="${MOLD_DIR}/pack/assets/scripts/validate_build_artifact.py"
SOURCE_SCHEMAS_DIR="${MOLD_DIR}/pack/assets/schemas/build"

if [ ! -f "$SOURCE_VALIDATOR" ]; then
  echo "FATAL: validator under test not found at ${SOURCE_VALIDATOR}" >&2
  exit 2
fi
if [ ! -d "$SOURCE_SCHEMAS_DIR" ]; then
  echo "FATAL: source schemas dir not found at ${SOURCE_SCHEMAS_DIR}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/validate-build-artifact-schema-root-test.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

# A minimal, fully schema-conformant gc.build.implementation-summary.v1
# artifact — valid regardless of which layout resolves SCHEMA_ROOT, so a
# failure can only mean the schema file itself wasn't found/loaded.
FIXTURE="${SANDBOX}/fixture.md"
cat > "$FIXTURE" <<'EOF'
---
schema: gc.build.implementation-summary.v1
workflow: {id: test-root, formula: test-formula}
methodology: {pack: gascity, name: build-basic}
producer: {formula: do-work, stage: implement, attempt: 1}
status: approved
trace:
  upstream:
    - path: beads/test-anchor
      hash: bead:test-anchor
      ids: [REQ-001]
  coverage:
    - id: REQ-001
      status: covered
---

## Summary

Test fixture for SCHEMA_ROOT resolution.

## Intended Behavior

N/A — this artifact only exercises schema loading.

## Changed Files

N/A

## Verification

N/A

## Remaining Risks

None.

| ID | Status |
| --- | --- |
| REQ-001 | covered |
EOF

assert_schema_resolves() {
  local validator="$1"
  local out rc
  out="$(python3 "$validator" --schema gc.build.implementation-summary.v1 --path "$FIXTURE" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"ok": true'; then
    pass "validator resolved the schema and validated the fixture (${out})"
  else
    fail "validator did not validate the fixture (exit ${rc}): ${out}"
  fi
}

# ===========================================================================
# CASE 1 — shipped / cast-pack layout: assets/scripts + assets/schemas/build
# ===========================================================================
start_case "1: shipped/cast-pack layout (assets/scripts + assets/schemas/build)"
SHIPPED_SCRIPTS="${SANDBOX}/shipped/pack/assets/scripts"
SHIPPED_SCHEMAS="${SANDBOX}/shipped/pack/assets/schemas/build"
mkdir -p "$SHIPPED_SCRIPTS" "$SHIPPED_SCHEMAS"
cp "$SOURCE_VALIDATOR" "${SHIPPED_SCRIPTS}/validate_build_artifact.py"
cp "${SOURCE_SCHEMAS_DIR}"/*.yaml "$SHIPPED_SCHEMAS"/
assert_schema_resolves "${SHIPPED_SCRIPTS}/validate_build_artifact.py"

# ===========================================================================
# CASE 2 — seeded gate layout: .gc/scripts + <rig-root>/schemas/build
# (regression guard for fk-ohoy: must keep working)
# ===========================================================================
start_case "2: seeded gate layout (.gc/scripts + rig-root schemas/build)"
SEEDED_SCRIPTS="${SANDBOX}/seeded/.gc/scripts"
SEEDED_SCHEMAS="${SANDBOX}/seeded/schemas/build"
mkdir -p "$SEEDED_SCRIPTS" "$SEEDED_SCHEMAS"
cp "$SOURCE_VALIDATOR" "${SEEDED_SCRIPTS}/validate_build_artifact.py"
cp "${SOURCE_SCHEMAS_DIR}"/*.yaml "$SEEDED_SCHEMAS"/
assert_schema_resolves "${SEEDED_SCRIPTS}/validate_build_artifact.py"

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
