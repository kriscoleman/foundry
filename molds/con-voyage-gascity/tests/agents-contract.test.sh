#!/usr/bin/env bash
# agents-contract.test.sh — hermetic, offline test that the pack's
# communal-duty / mail-the-mayor contract actually reaches every worker the
# pack dispatches (PR #45 human review, fk-doh9).
#
# The prior version of this test grepped molds/con-voyage-gascity/AGENTS.md
# for keywords and was rightly rejected as testing nothing: AGENTS.md lives
# at the mold root, a sibling of pack/, and `ailloy cast` only ever
# materializes pack/'s contents into a target rig (verified against this
# rig's own packs/con-voyage/ — no AGENTS.md, no CLAUDE.md there). A worker
# dispatched into a real target rig never has that file on disk; grepping it
# proves only that the file's author typed the right words, not that any
# worker ever sees them.
#
# What actually reaches a worker is the bead it claims. Every graph.v2
# formula node's task text is a description_file template, and the one place
# this pack free-texts a bead body outside the formula graph is
# con-voyage-pr-watch.sh's human-comment router (cv_build_pr_feedback_body in
# con-voyage-lib.sh). This suite asserts the shared communal-duty reminder
# (con-voyage-lib.sh's CV_COMMUNAL_DUTY_REMINDER) is present on every one of
# those surfaces:
#
#   (a) driven by the formulas' OWN description_file lists, not a
#       hand-maintained list, so a new workflow node added later without the
#       reminder fails this test instead of silently shipping a blind spot;
#   (b) by calling the real cv_build_pr_feedback_body function with sample
#       inputs and inspecting its actual output, not by grepping the script
#       source for an identifier.
#
# Run:  bash tests/agents-contract.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: shared lib not found at ${LIB}" >&2
  exit 2
fi

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

if [ -z "${CV_COMMUNAL_DUTY_REMINDER:-}" ]; then
  echo "FATAL: CV_COMMUNAL_DUTY_REMINDER is not defined by ${LIB}" >&2
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

start_case "every formula-dispatched workflow node carries the communal-duty reminder"
# Discover every description_file a formula references — the real dispatch
# graph, not a hand-maintained list — so a new node added later without the
# reminder fails here instead of shipping a blind spot.
node_count=0
for formula in "${MOLD_DIR}"/pack/formulas/*.toml; do
  formula_dir="$(dirname "$formula")"
  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    node_count=$((node_count+1))
    assert_contains "${formula_dir}/${rel_path}" "$CV_COMMUNAL_DUTY_REMINDER" \
      "$(basename "$formula"): $(basename "$rel_path")"
  done < <(grep -oE 'description_file *= *"[^"]+"' "$formula" | sed -E 's/description_file *= *"([^"]+)"/\1/')
done

if [ "$node_count" -eq 0 ]; then
  echo "FATAL: discovered zero description_file entries across pack/formulas/*.toml — parser broken?" >&2
  exit 2
fi
echo "  (checked ${node_count} formula-dispatched workflow nodes)"

start_case "the routed PR-feedback bead body (con-voyage-pr-watch.sh) includes the reminder"
if declare -f cv_build_pr_feedback_body >/dev/null 2>&1; then
  sample_body="$(cv_build_pr_feedback_body \
    "https://github.com/acme/widgets/pull/1" "fix/example" \
    "  [comment] @reviewer: an example finding  [id:1]" "test-key")"
  case "$sample_body" in
    *"${CV_COMMUNAL_DUTY_REMINDER}"*)
      echo "  PASS: cv_build_pr_feedback_body output includes the reminder" ;;
    *)
      echo "  FAIL: cv_build_pr_feedback_body output is missing the reminder" >&2
      FAILURES=$((FAILURES+1)) ;;
  esac
else
  echo "  FAIL: cv_build_pr_feedback_body is not defined by ${LIB}" >&2
  FAILURES=$((FAILURES+1))
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
