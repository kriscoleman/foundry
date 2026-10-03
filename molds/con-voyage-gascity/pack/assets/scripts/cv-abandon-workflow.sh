#!/usr/bin/env bash
# cv-abandon-workflow.sh — manual one-call teardown of a graph.v2 workflow
# root and every other still-OPEN bead tagged with its gc.root_bead_id
# (fk-jg6rm).
#
# WHY: a con-voyage whose build fails or whose review loop stalls used to
# need `bd close --force` bead-by-bead to clean up (13 beads by hand on root
# fk-viqoe/fk-zoedy, 2026-10-03) because cv_close_workflow_root — the
# descendant-sweep-then-root teardown primitive — only ever ran from inside
# con-voyage-finalize.sh on a confirmed PR land. This exposes that same
# primitive as a standalone CLI so a human or the mayor can abandon a whole
# workflow tree in one call instead.
#
# Usage:
#   cv-abandon-workflow.sh ROOT_BEAD_ID [REASON]
#
# Exit codes:
#   0 — the root bead itself is now closed (freshly closed, or already was).
#   1 — the root bead's own close failed (see con-voyage-lib.sh's
#       close_if_open for the refusal shapes this can mean: a pin, an
#       unsatisfied gate, or an assignee mismatch a --force retry could not
#       clear). A descendant sweep failure alone never causes this exit —
#       that is logged to stderr and otherwise best-effort, same contract as
#       cv_close_workflow_root itself.
#   2 — usage error (missing ROOT_BEAD_ID).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CV_LIB="${SCRIPT_DIR}/con-voyage-lib.sh"
if [ ! -f "$CV_LIB" ]; then
  echo "cv-abandon-workflow.sh: con-voyage-lib.sh not found next to this script (${CV_LIB})" >&2
  exit 1
fi
# shellcheck source=./con-voyage-lib.sh
source "$CV_LIB"

ROOT_ID="${1:-}"
REASON="${2:-manual abandon via cv-abandon-workflow.sh}"

if [ -z "${ROOT_ID// /}" ]; then
  echo "usage: cv-abandon-workflow.sh ROOT_BEAD_ID [REASON]" >&2
  exit 2
fi

cv_close_workflow_root "$ROOT_ID" "$REASON"
exit "$CV_CLOSE_RC"
