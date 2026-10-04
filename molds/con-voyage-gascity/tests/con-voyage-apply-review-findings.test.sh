#!/usr/bin/env bash
# con-voyage-apply-review-findings.test.sh — hermetic, offline contract tests
# for the $WORK_BRANCH_NAME resolution-with-fallback logic added to
# main.apply-review-findings.md and main.synthesize-review.md (fk-6os73y:
# con-voyage/<bead-id>-<topic-slug> branch naming). Neither file had any test
# coverage before this change, unlike the equivalent call sites in
# main.build.md and main.publish.md, which con-voyage-build-phase.test.sh and
# con-voyage-publish.test.sh already assert against.
#
# These are static/contract tests against the real workflow markdown, the
# same style as con-voyage-build-phase.test.sh: they prove the wiring a
# worker actually receives, not a hand-maintained description of it.
#
# Run:  bash tests/con-voyage-apply-review-findings.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
APPLY_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.apply-review-findings.md"
SYNTH_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.synthesize-review.md"

for f in "$APPLY_MD" "$SYNTH_MD"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: expected file not found: $f" >&2
    exit 2
  fi
done

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (not found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

line_of() {
  local file="$1" needle="$2"
  grep -nF -- "$needle" "$file" | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# apply-review-findings.md: reads gc.build.work_branch_name off the workflow
# root alongside the existing source-anchor metadata, with the same
# bare-con-voyage/<bead-id> fallback build.md/publish.md use for a root that
# predates fk-6os73y.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: reads gc.build.work_branch_name off the workflow root"
assert_contains "$APPLY_MD" "meta.get('gc.build.work_branch_name') or ''" "reads the stored work_branch_name alongside source_anchor metadata"

start_case "apply-review-findings.md: falls back to the bare con-voyage/<convoy-id> name when unset"
assert_contains "$APPLY_MD" '[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"' "falls back to the pre-fk-6os73y bare branch name"

start_case "apply-review-findings.md: the fallback runs after WORK_BRANCH_NAME is read, not before"
read_line="$(line_of "$APPLY_MD" "meta.get('gc.build.work_branch_name') or ''")"
fallback_line="$(line_of "$APPLY_MD" '[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"')"
if [ -n "$read_line" ] && [ -n "$fallback_line" ] && [ "$read_line" -lt "$fallback_line" ]; then
  echo "  PASS: WORK_BRANCH_NAME read (line ${read_line}) precedes the fallback check (line ${fallback_line})"
else
  echo "  FAIL: expected the WORK_BRANCH_NAME read to precede its fallback check" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "apply-review-findings.md: the resolved \$WORK_BRANCH_NAME, not a recomputed name, reaches cv_sync_worktree_to_base"
assert_contains "$APPLY_MD" 'cv_sync_worktree_to_base "$WORKTREE" "$WORK_BRANCH_NAME"' "syncs the worktree using the stored \$WORK_BRANCH_NAME"

# ---------------------------------------------------------------------------
# synthesize-review.md: the same resolve-with-fallback pattern feeds the
# LOW-only mail's branch argument.
# ---------------------------------------------------------------------------
start_case "synthesize-review.md: reads gc.build.work_branch_name off the workflow root"
assert_contains "$SYNTH_MD" "meta.get('gc.build.work_branch_name') or ''" "reads the stored work_branch_name"

start_case "synthesize-review.md: falls back to the bare con-voyage/<convoy-id> name when unset"
assert_contains "$SYNTH_MD" '[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"' "falls back to the pre-fk-6os73y bare branch name"

start_case "synthesize-review.md: the resolved \$WORK_BRANCH_NAME reaches the LOW-only mail script, not a recomputed name"
assert_contains "$SYNTH_MD" '"<synthesis path just written above>" "$ROOT_ID" "$WORK_BEAD" "$WORK_BRANCH_NAME"' "passes \$WORK_BRANCH_NAME as the mail script's branch argument"

start_case "synthesize-review.md: the fallback runs after WORK_BRANCH_NAME is read and before the mail script call"
read_line="$(line_of "$SYNTH_MD" "meta.get('gc.build.work_branch_name') or ''")"
fallback_line="$(line_of "$SYNTH_MD" '[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"')"
mail_line="$(line_of "$SYNTH_MD" '"<synthesis path just written above>" "$ROOT_ID" "$WORK_BEAD" "$WORK_BRANCH_NAME"')"
if [ -n "$read_line" ] && [ -n "$fallback_line" ] && [ "$read_line" -lt "$fallback_line" ]; then
  echo "  PASS: WORK_BRANCH_NAME read (line ${read_line}) precedes the fallback check (line ${fallback_line})"
else
  echo "  FAIL: expected the WORK_BRANCH_NAME read to precede its fallback check" >&2
  FAILURES=$((FAILURES+1))
fi
if [ -n "$fallback_line" ] && [ -n "$mail_line" ] && [ "$fallback_line" -lt "$mail_line" ]; then
  echo "  PASS: the fallback check (line ${fallback_line}) precedes the mail script call (line ${mail_line})"
else
  echo "  FAIL: expected the fallback check to precede the mail script call" >&2
  FAILURES=$((FAILURES+1))
fi

# ---------------------------------------------------------------------------
# apply-review-findings.md: fk-bcyt7v — stamp gc.build.reviewed_head_sha on
# the workflow root at the exact moment of a genuine no-op approval (HEAD at
# that point is the commit every active lane actually reviewed), so publish
# can later record the TRUE reviewed SHA instead of whatever HEAD happens to
# be when publish runs.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: stamps gc.build.reviewed_head_sha on the workflow root"
assert_contains "$APPLY_MD" 'gc bd update "$ROOT_ID" --set-metadata "gc.build.reviewed_head_sha=${REVIEWED_HEAD_SHA}"' "stamps the reviewed HEAD sha onto \$ROOT_ID"

start_case "apply-review-findings.md: the reviewed-sha stamp precedes the verdict=done close"
stamp_line="$(line_of "$APPLY_MD" 'gc bd update "$ROOT_ID" --set-metadata "gc.build.reviewed_head_sha=${REVIEWED_HEAD_SHA}"')"
done_line="$(line_of "$APPLY_MD" "--set-metadata 'code_review.verdict=done' \\")"
if [ -n "$stamp_line" ] && [ -n "$done_line" ] && [ "$stamp_line" -lt "$done_line" ]; then
  echo "  PASS: the reviewed-sha stamp (line ${stamp_line}) precedes the verdict=done close example (line ${done_line})"
else
  echo "  FAIL: expected the reviewed-sha stamp to precede the verdict=done close example" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "apply-review-findings.md: warns explicitly against stamping on a fix pass"
assert_contains "$APPLY_MD" 'Do NOT run this on a fix pass' "documents that the stamp only applies to a genuine no-op approval"

# ---------------------------------------------------------------------------
# apply-review-findings.md: review fk-qj2s9r BLOCKING-1 (fk-1fwe34/fk-0bkrzd/
# fk-qzn6vu) — the reviewed-sha stamp's guard was gated on an unused $CV_LIB
# (copy-pasted from the neighboring implementor_session block, which actually
# needs $CV_LIB for its cv_session_route_handle call; this stamp is a bare
# `gc bd update` with no cv_* dependency at all). If $CV_LIB failed to
# resolve for any unrelated reason, the stamp silently never wrote, quietly
# resurrecting the exact pre-fix bug fk-bcyt7v exists to close. Assert the
# guard is gated only on the inputs it actually uses ($REVIEWED_HEAD_SHA,
# $ROOT_ID), not on $CV_LIB, so a future copy-paste can't reintroduce the
# dead gate silently.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: the reviewed-sha stamp's guard does not gate on the unused \$CV_LIB"
assert_not_contains_near() {
  local file="$1" anchor="$2" needle="$3" label="$4"
  local anchor_line
  anchor_line="$(line_of "$file" "$anchor")"
  if [ -z "$anchor_line" ]; then
    echo "  FAIL: ${label} (anchor not found: ${anchor})" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  local window
  window="$(sed -n "${anchor_line},$((anchor_line + 6))p" "$file")"
  case "$window" in
    *"$needle"*) echo "  FAIL: ${label} (found '${needle}' within 6 lines of the stamp)" >&2; FAILURES=$((FAILURES+1)) ;;
    *) echo "  PASS: ${label}" ;;
  esac
}
assert_not_contains_near "$APPLY_MD" \
  'REVIEWED_HEAD_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "")"' \
  '[ -n "$CV_LIB" ]' \
  "stamp guard no longer conjuncts on \$CV_LIB"

start_case "apply-review-findings.md: the reviewed-sha stamp resolves HEAD via \$WORKTREE, not ambient cwd"
assert_contains "$APPLY_MD" 'REVIEWED_HEAD_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "")"' "resolves HEAD against \$WORKTREE explicitly"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
