#!/usr/bin/env bash
# cv-ensure-gate-scripts.sh — self-healing seed for con-voyage's graph.v2 gate
# check scripts (fk-6i53).
#
# WHY: the con-voyage-review-loop and finalize steps are graph.v2 `mode =
# "exec"` gates that reference `.gc/scripts/checks/*.sh` BY PATH, resolved
# relative to the rig root. Those scripts were never shipped by the pack —
# they only ever existed as hand-placed copies in some rigs (foundry-kc,
# embedded-cluster) and not others (vandoor, kots, knuckles). A rig missing
# `.gc/scripts/checks/` hits a controller-level path-resolution error
# ("resolving gate condition path: lstat ... no such file or directory") and
# the whole review loop goes gc.control_quarantined — worse, the quarantined
# node can close with gc.outcome=fail while the dependency graph still treats
# it as satisfied, letting a downstream publish step run as if review had
# actually passed (see cv-verify-review-approved.sh for the other half of
# this fix). Seeding the scripts before the gate is ever evaluated closes the
# root cause: the path always resolves.
#
# `.gc/` is a local, non-committed, rig-specific runtime directory (documented
# elsewhere in this pack as the override point for rig-local behavior), so
# this script NEVER overwrites a script that already exists at the
# destination — a rig may have deliberately customized its local copy.
#
# Usage:
#   cv-ensure-gate-scripts.sh <rig-root>
#
# Source of truth: this script's own sibling `checks/` directory
# (pack/assets/scripts/checks/*.sh), resolved from its own path so it works
# identically whether run from the mold source or a cast pack copy.
#
# Exit codes:
#   0 — every shipped check script is now present at
#       <rig-root>/.gc/scripts/checks/ (freshly seeded, already present, or a
#       mix of both), each executable.
#   1 — usage error (missing/invalid rig-root), or the pack itself ships no
#       check scripts (source checks/ dir missing or empty) — fails loud with
#       NO partial writes, rather than silently leaving a gate to fail later
#       with a confusing controller error.
#
# Requires: bash 4+.

set -uo pipefail

die() {
  echo "cv-ensure-gate-scripts: ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  cv-ensure-gate-scripts.sh <rig-root>
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/checks"

RIG_ROOT="${1:-}"
[ -n "$RIG_ROOT" ] || { usage; die "a rig-root directory argument is required"; }
[ -d "$RIG_ROOT" ] || die "'${RIG_ROOT}' is not a directory"

[ -d "$SOURCE_DIR" ] || die "no source check scripts shipped beside this script (expected ${SOURCE_DIR}) — the pack is incomplete"

shopt -s nullglob
SOURCE_SCRIPTS=("${SOURCE_DIR}"/*.sh)
shopt -u nullglob
[ "${#SOURCE_SCRIPTS[@]}" -gt 0 ] || die "${SOURCE_DIR} ships no *.sh check scripts — the pack is incomplete"

DEST_DIR="${RIG_ROOT}/.gc/scripts/checks"
mkdir -p "$DEST_DIR" || die "could not create ${DEST_DIR}"

seeded=0
present=0
for src in "${SOURCE_SCRIPTS[@]}"; do
  name="$(basename "$src")"
  dest="${DEST_DIR}/${name}"
  if [ -e "$dest" ]; then
    echo "cv-ensure-gate-scripts: ${name} already present at ${dest} — left untouched"
    present=$((present+1))
    continue
  fi
  cp "$src" "$dest" || die "could not copy ${src} to ${dest}"
  chmod +x "$dest" || die "could not set the exec bit on ${dest}"
  echo "cv-ensure-gate-scripts: seeded ${name} -> ${dest}"
  seeded=$((seeded+1))
done

echo "cv-ensure-gate-scripts: done (${seeded} seeded, ${present} already present, ${#SOURCE_SCRIPTS[@]} total)"
