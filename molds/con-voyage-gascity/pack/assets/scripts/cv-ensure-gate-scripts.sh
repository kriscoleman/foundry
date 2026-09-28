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
# "Ensure" means present AND current (fk-6z17l): a rig seeded once used to
# keep that exact copy forever, so a pack upgrade (e.g. fk-w31l7's rewrite of
# implementation-review-approved.sh) never reached it. If a destination
# script's content differs from the pack's current copy, this script backs
# the old content up alongside it (`<name>.sh.prev`) and replaces it
# atomically (write to a temp file in the same directory, then rename). A
# destination whose content already matches is left untouched (and gets no
# backup file) — this is what makes re-running this script a true no-op on
# an already-current rig.
#
# Usage:
#   cv-ensure-gate-scripts.sh <rig-root>
#
# Source of truth: this script's own sibling `checks/` directory
# (pack/assets/scripts/checks/*.sh), resolved from its own path so it works
# identically whether run from the mold source or a cast pack copy.
#
# Exit codes:
#   0 — every shipped check script is now present AND current at
#       <rig-root>/.gc/scripts/checks/ (freshly seeded, already current,
#       updated from a stale copy, or a mix of these), each executable.
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
# shellcheck source=con-voyage-lib.sh
source "${SCRIPT_DIR}/con-voyage-lib.sh"
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
updated=0
present=0
for src in "${SOURCE_SCRIPTS[@]}"; do
  name="$(basename "$src")"
  dest="${DEST_DIR}/${name}"
  copy_status="$(cv_ensure_current_copy "$src" "$dest" --exec)" || die "could not ensure ${dest} from ${src}"
  case "$copy_status" in
    current)
      echo "cv-ensure-gate-scripts: ${name} already present and current at ${dest} — left untouched"
      present=$((present+1))
      ;;
    updated)
      echo "cv-ensure-gate-scripts: ${name} was stale — replaced at ${dest} (previous copy backed up to ${dest}.prev)"
      updated=$((updated+1))
      ;;
    seeded)
      echo "cv-ensure-gate-scripts: seeded ${name} -> ${dest}"
      seeded=$((seeded+1))
      ;;
    *)
      die "unexpected status '${copy_status}' ensuring ${dest}"
      ;;
  esac
done

echo "cv-ensure-gate-scripts: done (${seeded} seeded, ${updated} updated, ${present} already present and current, ${#SOURCE_SCRIPTS[@]} total)"
