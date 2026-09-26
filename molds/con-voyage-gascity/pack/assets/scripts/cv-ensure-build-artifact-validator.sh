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
# "Ensure" means present AND current (fk-6z17l): a rig seeded once used to
# keep that exact copy forever, so a pack upgrade to the validator or a
# schema never reached it. If a destination file's content differs from the
# pack's current copy, this script backs the old content up alongside it
# (`<name>.prev`) and replaces it atomically (write to a temp file in the
# same directory, then rename). A destination whose content already matches
# is left untouched (and gets no backup file) — this is what makes
# re-running this script a true no-op on an already-current rig.
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
#   0 — the validator and every shipped schema file are now present AND
#       current at their destinations (freshly seeded, already current,
#       updated from a stale copy, or a mix of these).
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
updated=0
present=0

if [ -e "$DEST_VALIDATOR" ]; then
  if cmp -s "$SOURCE_VALIDATOR" "$DEST_VALIDATOR"; then
    echo "cv-ensure-build-artifact-validator: validate_build_artifact.py already present and current at ${DEST_VALIDATOR} — left untouched"
    present=$((present+1))
  else
    cp "$DEST_VALIDATOR" "${DEST_VALIDATOR}.prev" || die "could not back up stale ${DEST_VALIDATOR} to ${DEST_VALIDATOR}.prev"
    tmp="${DEST_VALIDATOR}.tmp.$$"
    cp "$SOURCE_VALIDATOR" "$tmp" || die "could not stage ${SOURCE_VALIDATOR} to ${tmp}"
    chmod +x "$tmp" || die "could not set the exec bit on ${tmp}"
    mv -f "$tmp" "$DEST_VALIDATOR" || die "could not move ${tmp} to ${DEST_VALIDATOR}"
    echo "cv-ensure-build-artifact-validator: validate_build_artifact.py was stale — replaced at ${DEST_VALIDATOR} (previous copy backed up to ${DEST_VALIDATOR}.prev)"
    updated=$((updated+1))
  fi
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
    if cmp -s "$src" "$dest"; then
      echo "cv-ensure-build-artifact-validator: ${name} already present and current at ${dest} — left untouched"
      present=$((present+1))
      continue
    fi
    cp "$dest" "${dest}.prev" || die "could not back up stale ${dest} to ${dest}.prev"
    tmp="${dest}.tmp.$$"
    cp "$src" "$tmp" || die "could not stage ${src} to ${tmp}"
    mv -f "$tmp" "$dest" || die "could not move ${tmp} to ${dest}"
    echo "cv-ensure-build-artifact-validator: ${name} was stale — replaced at ${dest} (previous copy backed up to ${dest}.prev)"
    updated=$((updated+1))
    continue
  fi
  cp "$src" "$dest" || die "could not copy ${src} to ${dest}"
  echo "cv-ensure-build-artifact-validator: seeded ${name} -> ${dest}"
  seeded=$((seeded+1))
done

total=$((1 + ${#SOURCE_SCHEMA_FILES[@]}))
echo "cv-ensure-build-artifact-validator: done (${seeded} seeded, ${updated} updated, ${present} already present and current, ${total} total)"
