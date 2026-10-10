#!/usr/bin/env bash
# cv-rereview-seed-fallback.sh ROOT_ID CLAIMED_BEAD_ID BRANCH SEED_FAIL
#   — the CV_LIB-unresolved sweep for main.rereview-seed.md's seed-failure
#     path (review fk-xfewni BLOCKING LOW-6).
#
# WHY A STANDALONE SCRIPT: this logic only runs when con-voyage-lib.sh could
# NOT be resolved, so it is necessarily self-contained — it cannot call into
# cv_close_workflow_root or any other lib function. Before this extraction it
# lived inline in main.rereview-seed.md's prose, where the only coverage was
# textual (grep/line-order against the markdown source): a regression in the
# invocation itself (wrong flag, wrong id variable, wrong reason content)
# would pass undetected as long as the literal substring and line order
# stayed intact. Extracting it here (mirroring cv-worktree-prep.sh's own
# free-branch extraction) gives it real, stub-bd/gc executable coverage
# instead (tests/cv-rereview-seed-fallback.test.sh).
#
# WHAT IT DOES, in order (mirrors cv_close_workflow_root's own contract: the
# root bead is closed LAST, after every descendant):
#   1. best-effort mail to the mayor (never fatal — a failed/timed-out mail
#      is logged to stderr and the sweep continues)
#   2. find every open/in_progress descendant of ROOT_ID and close each one
#   3. close ROOT_ID itself
#
# Every bd/gc call is bounded via cv-timeout.sh (review fk-xfewni BLOCKING
# LOW-7) — resolved by direct sibling path, same convention
# main.rereview-seed.md already uses for CV_GUARD (cv-worktree-prep.sh): a
# standalone script in this same assets/scripts/ directory is found
# independently of whether con-voyage-lib.sh itself resolved.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CV_TIMEOUT="${SELF_DIR}/cv-timeout.sh"
if [ ! -x "$CV_TIMEOUT" ]; then
  echo "cv-rereview-seed-fallback: cv-timeout.sh not found or not executable at ${CV_TIMEOUT} — cannot run bounded calls" >&2
  exit 1
fi

ROOT_ID="${1:-}"
CLAIMED_BEAD_ID="${2:-}"
BRANCH="${3:-}"
SEED_FAIL="${4:-}"

if [ -z "$ROOT_ID" ] || [ -z "$CLAIMED_BEAD_ID" ] || [ -z "$SEED_FAIL" ]; then
  echo "cv-rereview-seed-fallback: usage: $0 ROOT_ID CLAIMED_BEAD_ID BRANCH SEED_FAIL" >&2
  exit 2
fi

echo "cv-rereview-seed-fallback: con-voyage-lib.sh was unresolved — falling back to a direct bd close sweep of open workflow-root descendants, with a best-effort direct mayor mail alongside it" >&2

MAIL_ERR_FILE="$(mktemp)"
"$CV_TIMEOUT" 30 gc mail send mayor -s "con-voyage rereview-seed failed: ${ROOT_ID}" -m "con-voyage rereview-seed (${CLAIMED_BEAD_ID}) could not attach a worktree for ${BRANCH}: ${SEED_FAIL}. con-voyage-lib.sh was unresolved on this path, so cv_close_workflow_root was unavailable — falling back to a direct descendant sweep instead." --json >/dev/null 2>"$MAIL_ERR_FILE"
MAIL_RC=$?
MAIL_ERR_TEXT="$(cat "$MAIL_ERR_FILE" 2>/dev/null)"
rm -f "$MAIL_ERR_FILE"
[ "$MAIL_RC" -eq 0 ] || echo "cv-rereview-seed-fallback: mail to mayor on seed failure failed/timed out: ${MAIL_ERR_TEXT} — mayor NOT confirmed notified" >&2

BD_LIST_ERR_FILE="$(mktemp)"
DESC_IDS="$("$CV_TIMEOUT" 30 bd list --metadata-field "gc.root_bead_id=${ROOT_ID}" --status open,in_progress --json 2>"$BD_LIST_ERR_FILE" | python3 -c "
import json, sys
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
for it in items:
    bid = it.get('id')
    if bid:
        print(bid)
")"
BD_LIST_ERR_TEXT="$(cat "$BD_LIST_ERR_FILE" 2>/dev/null)"
rm -f "$BD_LIST_ERR_FILE"
[ -z "$BD_LIST_ERR_TEXT" ] || echo "cv-rereview-seed-fallback: bd list during fallback sweep reported: ${BD_LIST_ERR_TEXT}" >&2
if [ -n "$DESC_IDS" ]; then
  while IFS= read -r DESC_ID; do
    [ -n "$DESC_ID" ] || continue
    "$CV_TIMEOUT" 30 bd close "$DESC_ID" --reason "con-voyage rereview-seed failed (${CLAIMED_BEAD_ID}): ${SEED_FAIL}; sweeping descendant (con-voyage-lib.sh unresolved, cv_close_workflow_root unavailable)" \
      || echo "cv-rereview-seed-fallback: WARNING: could not close descendant ${DESC_ID} during fallback sweep" >&2
  done <<< "$DESC_IDS"
fi

# Close the root LAST, after every descendant — mirrors cv_close_workflow_root's
# own ordering (review fk-pwbxc7 BLOCKING-1), tolerant of an already-closed root.
"$CV_TIMEOUT" 30 bd close "$ROOT_ID" --reason "con-voyage rereview-seed failed (${CLAIMED_BEAD_ID}): ${SEED_FAIL}; closing workflow root (con-voyage-lib.sh unresolved, cv_close_workflow_root unavailable)" \
  || echo "cv-rereview-seed-fallback: WARNING: could not close workflow root ${ROOT_ID} during fallback sweep" >&2

exit 0
