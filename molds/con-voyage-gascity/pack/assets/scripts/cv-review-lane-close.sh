#!/usr/bin/env bash
# cv-review-lane-close.sh — deterministic close-time enforcement of
# gc.outcome=pass for every con-voyage review-lane and synthesize-review step
# (fk-7w9y6).
#
# WHY: every review-lane close instruction already told the agent, in prose,
# that gc.outcome must stay "pass" regardless of its own verdict — but a bare
# `bd update --set-metadata` is still just more agent-authored text, and an
# agent under load can stamp gc.outcome with its own verdict value instead
# (design-ux lane fk-jvr9z: gc.outcome=iterate) or omit the key entirely
# (synthesize-review bead fk-xyz7gb: no gc.outcome key at all; a THIRD
# recurrence hit the same bug on fk-2l3c8i). Either mistake trips the
# engine's scope-control abort_scope path and skips synthesis/apply-review-
# findings, silently re-reviewing an unchanged commit next iteration. The
# engine's own scope-control logic lives out-of-repo and cannot be hardened
# directly from here, so this script is the deterministic enforcement point
# this repo CAN own: gc.outcome=pass is hardcoded in the script body, never
# read from a caller argument, so no review-lane or synthesize-review close
# path can ever stamp anything else — a wrong or missing verdict value no
# longer depends on the dispatched agent remembering the rule (the mayor's
# own diagnosis of why the prose-only version of this fix was insufficient).
#
# Usage:
#   cv-review-lane-close.sh <bead-id> <close-reason> [--set-metadata 'key=value']...
#
# Every --set-metadata is applied in addition to the hardcoded
# gc.outcome=pass. A caller-supplied `gc.outcome=...` key is NOT treated as a
# usage error (an agent that still copies the old bare bd-update shape should
# not get a harder failure than before) — it is logged and silently
# overridden, so the final stamped value is always "pass" no matter what a
# caller passes.
#
# Exit codes:
#   0 — bead updated with gc.outcome=pass (plus any extra metadata) and
#       closed.
#   1 — usage error, the bead could not be read, or a `bd update`/`bd close`
#       call failed. This script never silently swallows a genuine failure
#       as a pass, unlike cv_bead_close's own fail-safe no-op contract
#       elsewhere in this pack — a scope-control step that genuinely cannot
#       run must still be seen as a genuine failure, so it still aborts
#       (fk-7w9y6 widened acceptance: "a genuine step failure... must still
#       abort").
#
# Requires: bash, the `gc` CLI (GC env var, default: gc).

set -uo pipefail

GC="${GC:-gc}"

die() {
  echo "cv-review-lane-close: ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  cv-review-lane-close.sh <bead-id> <close-reason> [--set-metadata 'key=value']...
USAGE
}

[ $# -ge 2 ] || { usage; die "bead-id and close-reason are required"; }

BEAD_ID="$1"; shift
CLOSE_REASON="$1"; shift
[ -n "${BEAD_ID// /}" ] || { usage; die "bead-id is required"; }
[ -n "${CLOSE_REASON// /}" ] || { usage; die "close-reason is required"; }

EXTRA_METADATA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --set-metadata)
      [ $# -ge 2 ] || die "--set-metadata requires a value"
      case "$2" in
        gc.outcome=*)
          echo "cv-review-lane-close: WARNING: ignoring caller-supplied '$2' — gc.outcome=pass is hardcoded by this script for every review-lane/synthesis close" >&2
          ;;
        *)
          EXTRA_METADATA+=("$2")
          ;;
      esac
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# A genuine lookup failure (bead unknown, gc/bd unreachable, ...) must abort
# this script rather than proceed to a close that would otherwise succeed
# against a nonexistent or wrong bead.
"$GC" bd show "$BEAD_ID" >/dev/null 2>&1 \
  || die "bead ${BEAD_ID} could not be read — refusing to close"

UPDATE_ARGS=("$BEAD_ID" --set-metadata 'gc.outcome=pass')
if [ "${#EXTRA_METADATA[@]}" -gt 0 ]; then
  for kv in "${EXTRA_METADATA[@]}"; do
    UPDATE_ARGS+=(--set-metadata "$kv")
  done
fi

"$GC" bd update "${UPDATE_ARGS[@]}" \
  || die "bd update failed for ${BEAD_ID} — refusing to close with unapplied metadata"

"$GC" bd close "$BEAD_ID" --reason "$CLOSE_REASON" \
  || die "bd close failed for ${BEAD_ID}"

echo "cv-review-lane-close: closed ${BEAD_ID} with gc.outcome=pass (${#EXTRA_METADATA[@]} additional metadata key(s))"
