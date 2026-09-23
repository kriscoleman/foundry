#!/usr/bin/env bash
# cv-ensure-build-artifact-validator.sh — self-healing seed for the
# build-artifact-valid.sh gate's own dependency (fk-ohoy).
#
# WHY: build-artifact-valid.sh (shipped + self-seeded into
# <rig-root>/.gc/scripts/checks/ by cv-ensure-gate-scripts.sh, fk-6i53) does
# not validate build artifacts itself — it shells out to a
# validate_build_artifact.py validator at
# <rig-root>/.gc/scripts/validate_build_artifact.py, which in turn loads
# schema definitions from <rig-root>/schemas/build/*.yaml. Neither of those
# was ever shipped or seeded by the pack; they only existed as uncommitted
# local scratch files in some rigs (foundry-kc). A freshly-seeded rig would
# get the gate script but not what it needs to run, failing the
# workflow-finalize gate with a "validator not found" error instead of
# actually validating anything. This closes that gap the same way fk-6i53
# closed it for the check scripts themselves.
#
# `.gc/` and the rig-root `schemas/` directory are both local, non-committed
# rig state (documented elsewhere in this pack as override points for
# rig-local behavior), so this script NEVER overwrites a file that already
# exists at its destination — a rig may have deliberately customized its
# local copy.
#
# Usage:
#   cv-ensure-build-artifact-validator.sh <rig-root>
#
# Source of truth: this script's own sibling validate_build_artifact.py file
# (pack/assets/scripts/validate_build_artifact.py) and sibling schemas
# directory (pack/assets/schemas/build/*.yaml), resolved from its own path so
# it works identically whether run from the mold source or a cast pack copy.
#
# Destination layout mirrors validate_build_artifact.py's own fixed
# SCHEMA_ROOT resolution (two parents up from its own file location):
#   <rig-root>/.gc/scripts/validate_build_artifact.py
#   <rig-root>/schemas/build/*.yaml
#
# Exit codes:
#   0 — the validator and every shipped schema file are now present at their
#       destinations (freshly seeded, already present, or a mix of both).
#   1 — usage error (missing/invalid rig-root), or the pack itself ships no
#       validator or no schema files (source assets missing/empty) — fails
#       loud with NO partial writes, rather than silently leaving the gate to
#       fail later with a confusing "validator not found" error.
#
# Requires: bash 4+.

set -uo pipefail

die() {
  echo "cv-ensure-build-artifact-validator: ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  cv-ensure-build-artifact-validator.sh <rig-root>
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_VALIDATOR="${SCRIPT_DIR}/validate_build_artifact.py"
SOURCE_SCHEMAS_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd)/schemas/build"

RIG_ROOT="${1:-}"
[ -n "$RIG_ROOT" ] || { usage; die "a rig-root directory argument is required"; }
[ -d "$RIG_ROOT" ] || die "'${RIG_ROOT}' is not a directory"

[ -f "$SOURCE_VALIDATOR" ] || die "no source validator shipped beside this script (expected ${SOURCE_VALIDATOR}) — the pack is incomplete"

shopt -s nullglob
SOURCE_SCHEMA_FILES=("${SOURCE_SCHEMAS_DIR}"/*.yaml)
shopt -u nullglob
[ -d "$SOURCE_SCHEMAS_DIR" ] && [ "${#SOURCE_SCHEMA_FILES[@]}" -gt 0 ] || die "${SOURCE_SCHEMAS_DIR} ships no *.yaml schema files — the pack is incomplete"

DEST_VALIDATOR_DIR="${RIG_ROOT}/.gc/scripts"
DEST_VALIDATOR="${DEST_VALIDATOR_DIR}/validate_build_artifact.py"
DEST_SCHEMAS_DIR="${RIG_ROOT}/schemas/build"

seeded=0
present=0

if [ -e "$DEST_VALIDATOR" ]; then
  echo "cv-ensure-build-artifact-validator: validate_build_artifact.py already present at ${DEST_VALIDATOR} — left untouched"
  present=$((present+1))
else
  mkdir -p "$DEST_VALIDATOR_DIR" || die "could not create ${DEST_VALIDATOR_DIR}"
  cp "$SOURCE_VALIDATOR" "$DEST_VALIDATOR" || die "could not copy ${SOURCE_VALIDATOR} to ${DEST_VALIDATOR}"
  chmod +x "$DEST_VALIDATOR" || die "could not set the exec bit on ${DEST_VALIDATOR}"
  echo "cv-ensure-build-artifact-validator: seeded validate_build_artifact.py -> ${DEST_VALIDATOR}"
  seeded=$((seeded+1))
fi

mkdir -p "$DEST_SCHEMAS_DIR" || die "could not create ${DEST_SCHEMAS_DIR}"
for src in "${SOURCE_SCHEMA_FILES[@]}"; do
  name="$(basename "$src")"
  dest="${DEST_SCHEMAS_DIR}/${name}"
  if [ -e "$dest" ]; then
    echo "cv-ensure-build-artifact-validator: ${name} already present at ${dest} — left untouched"
    present=$((present+1))
    continue
  fi
  cp "$src" "$dest" || die "could not copy ${src} to ${dest}"
  echo "cv-ensure-build-artifact-validator: seeded ${name} -> ${dest}"
  seeded=$((seeded+1))
done

total=$((1 + ${#SOURCE_SCHEMA_FILES[@]}))
echo "cv-ensure-build-artifact-validator: done (${seeded} seeded, ${present} already present, ${total} total)"
