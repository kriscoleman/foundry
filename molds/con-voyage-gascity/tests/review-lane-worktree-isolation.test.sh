#!/usr/bin/env bash
# review-lane-worktree-isolation.test.sh — hermetic, offline test that the
# per-lane worktree isolation contract (fk-q659) actually reaches every
# con-voyage review lane, and that the isolation script it depends on ships
# alongside them.
#
# THE BUG: every con-voyage review lane for a work item shares ONE mutable
# worktree (the source-anchor work_dir recorded in the review context). A
# lane doing mutate-run-revert verification races another lane's concurrent
# build/test in the same directory, producing a false BLOCKING or
# false-negative finding.
#
# THE FIX: cv-review-lane-worktree.sh (tested directly in
# cv-review-lane-worktree.test.sh) gives each lane its own throwaway linked
# worktree. This suite asserts the reminder that sends a lane to that script
# instead of the shared work_dir (con-voyage-lib.sh's
# CV_REVIEW_LANE_WORKTREE_REMINDER) is present, verbatim, on every review
# lane's description_file:
#
#   (a) driven by the con-voyage-review-loop's OWN `[[template.children]]`
#       list in con-voyage.formula.toml, not a hand-maintained lane list, so
#       a new lane added later without the reminder fails this test instead
#       of silently shipping the same race;
#   (b) two children of that same loop are deliberately excluded because they
#       are not review lanes and do not execute against the source tree:
#       synthesize-review (reads lane REPORTS, not the implementation) and
#       apply-review-findings (routed to the implementor, which legitimately
#       owns the real shared worktree once review lanes are done with it).
#
# Run:  bash tests/review-lane-worktree-isolation.test.sh   (exit 0 => pass)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
FORMULA="${MOLD_DIR}/pack/formulas/con-voyage.formula.toml"
ISOLATION_SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-review-lane-worktree.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: shared lib not found at ${LIB}" >&2
  exit 2
fi
if [ ! -f "$FORMULA" ]; then
  echo "FATAL: formula not found at ${FORMULA}" >&2
  exit 2
fi

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

if [ -z "${CV_REVIEW_LANE_WORKTREE_REMINDER:-}" ]; then
  echo "FATAL: CV_REVIEW_LANE_WORKTREE_REMINDER is not defined by ${LIB}" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $label ($file does not exist)" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  if grep -qF -- "$needle" "$file"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (reminder not found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

start_case "the isolation script itself ships in the pack"
if [ -f "$ISOLATION_SCRIPT" ]; then
  echo "  PASS: cv-review-lane-worktree.sh present at ${ISOLATION_SCRIPT}"
else
  echo "  FAIL: cv-review-lane-worktree.sh missing at ${ISOLATION_SCRIPT}" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "every con-voyage review lane carries the worktree-isolation reminder"
# Discover the con-voyage-review-loop's own [[template.children]] block: the
# region from its OWN description_file line (exclusive, via the later
# grep -v) to the next top-level [[template]] header (the publish step).
# Every node in that region is a lane EXCEPT synthesize-review and
# apply-review-findings, excluded above for the reasons documented at the top
# of this file.
mapfile -t lane_rel_paths < <(
  sed -n '/^description_file = ".*con-voyage-review-loop\.md"$/,/^\[\[template\]\]$/p' "$FORMULA" \
    | grep -oE 'description_file *= *"[^"]+"' \
    | sed -E 's/description_file *= *"([^"]+)"/\1/' \
    | grep -v -E 'con-voyage-review-loop\.md$|synthesize-review\.md$|apply-review-findings\.md$'
)

if [ "${#lane_rel_paths[@]}" -eq 0 ]; then
  echo "FATAL: discovered zero review-lane description_file entries — formula structure changed? parser broken?" >&2
  exit 2
fi

formula_dir="$(dirname "$FORMULA")"
for rel_path in "${lane_rel_paths[@]}"; do
  assert_contains "${formula_dir}/${rel_path}" "$CV_REVIEW_LANE_WORKTREE_REMINDER" \
    "$(basename "$rel_path")"
done
echo "  (checked ${#lane_rel_paths[@]} review-lane workflow nodes)"

start_case "synthesize-review and apply-review-findings are correctly excluded from lane discovery"
for excluded in "synthesize-review" "apply-review-findings"; do
  case " ${lane_rel_paths[*]} " in
    *"${excluded}.md"*)
      echo "  FAIL: ${excluded}.md was discovered as a lane — exclusion filter is broken" >&2
      FAILURES=$((FAILURES+1))
      ;;
    *)
      echo "  PASS: ${excluded}.md correctly excluded from lane discovery"
      ;;
  esac
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
