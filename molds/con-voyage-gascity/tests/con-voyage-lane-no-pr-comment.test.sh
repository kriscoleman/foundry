#!/usr/bin/env bash
# con-voyage-lane-no-pr-comment.test.sh — hermetic, offline contract tests
# for fk-mmrf7t (PR noise reduction, slice A).
#
# WHY: every review-lane prompt carried a formatting rule — "Every PR
# comment MUST lead with [<rig>/<agent> -- <lens>]" — with no accompanying
# prohibition on posting at all. No lane prompt anywhere stated the
# negative ("you never comment on the PR yourself; synthesis/publish does").
# An LLM reading only the formatting rule can infer implicit license to
# post, which is exactly what happened on replicatedhq/vandoor#10603
# (standards-janitor and qa-test-engineer both posted standalone verdict
# comments, bypassing the one-aggregate-per-round rule). This suite proves
# every review-lane prompt now carries an explicit prohibition instead, and
# that the roles actually allowed to post (publish, synthesis/finalize)
# still carry their own banner-format rule unchanged.
#
# Run:  bash tests/con-voyage-lane-no-pr-comment.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WORKFLOWS_DIR="${MOLD_DIR}/pack/assets/workflows/con-voyage"
PUBLISH_MD="${WORKFLOWS_DIR}/main.publish.md"

# Every review-lane prompt that (before this fix) carried the unscoped
# banner-format line, discovered by its lens suffix.
LANE_FILES=(
  "main.api-platform-review.md"
  "main.compliance-review.md"
  "main.data-db-review.md"
  "main.design-ux-review.md"
  "main.dev-ex-review.md"
  "main.documentation-review.md"
  "main.founder-cto-review.md"
  "main.marketing-review.md"
  "main.product-owner-review.md"
  "main.qa-test-review.md"
  "main.sre-review.md"
  "main.standards-janitor-review.md"
)

for f in "${LANE_FILES[@]}" "main.publish.md"; do
  if [ ! -f "${WORKFLOWS_DIR}/${f}" ]; then
    echo "FATAL: expected file not found: ${WORKFLOWS_DIR}/${f}" >&2
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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "  FAIL: $label (still found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: $label"
  fi
}

# ---------------------------------------------------------------------------
# AC1: every review lane explicitly prohibits posting, and the old unscoped
# banner-format line (which read as implicit permission) is gone.
# ---------------------------------------------------------------------------
for f in "${LANE_FILES[@]}"; do
  path="${WORKFLOWS_DIR}/${f}"
  start_case "${f} (AC1): no longer carries the unscoped banner-format permission line"
  assert_not_contains "$path" "Every PR comment MUST lead with" "unscoped banner-format line removed"

  start_case "${f} (AC1): explicitly prohibits calling cv-pr-comment.sh or posting to the PR"
  assert_contains "$path" "Do NOT call cv-pr-comment.sh" "explicit prohibition present"
  assert_contains "$path" "report only via" "points the lane back to verdict metadata as the only report channel"
done

# ---------------------------------------------------------------------------
# AC2 regression guard: publish.md (the role actually allowed to post) still
# carries its own banner-format rule and the comment-aggregate call,
# unaffected by the lane-prompt rewording.
# ---------------------------------------------------------------------------
start_case "main.publish.md (AC2 regression guard): still owns the banner-format rule and the one-aggregate-per-round call"
assert_contains "$PUBLISH_MD" "it MUST lead with the" "publish.md keeps its own banner-format rule"
assert_contains "$PUBLISH_MD" "cv-pr-comment.sh comment-aggregate" "publish.md still posts the single aggregated round comment"
assert_contains "$PUBLISH_MD" "never a separate comment per lane" "publish.md still documents the one-aggregate rule every lane's findings flow through"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
