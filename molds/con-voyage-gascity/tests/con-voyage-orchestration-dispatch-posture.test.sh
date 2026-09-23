#!/usr/bin/env bash
# con-voyage-orchestration-dispatch-posture.test.sh — hermetic, offline test
# that the parallel-PRs-by-default dispatch norm (fk-7ve4, operator
# correction 2026-09-22) actually reaches the mayor.
#
# The mayor defaulted to serializing independent foundry PRs that merely
# shared a file (three con-voyage-lib.sh fixes chained #61 -> fk-cy2z ->
# fk-mr07) out of "dirty-conflict" caution, even though con-voyage gives
# every do-work its own worktree so builds never collide. This asserts the
# fix against the real wiring, not against a doc a worker never sees:
# README.md's `[mayor] append_fragments = ["con-voyage-orchestration"]`
# city.toml snippet appends pack/template-fragments/con-voyage-orchestration
# .template.md verbatim into the mayor's own context (flux.yaml's pack
# output is `process: false` — a raw pass-through, no templating rewrite).
# So a grep against that fragment is a grep against what the mayor actually
# reads, unlike the AGENTS.md contract copy (see agents-contract.test.sh).
#
# Run:  bash tests/con-voyage-orchestration-dispatch-posture.test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
FRAGMENT="${MOLD_DIR}/pack/template-fragments/con-voyage-orchestration.template.md"

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
    echo "  FAIL: $label (not found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

start_case "the fragment wired into the mayor states parallel dispatch is the default"
assert_contains "$FRAGMENT" "Do not serialize by habit" \
  "orchestration fragment tells the mayor not to serialize independent work by habit"

start_case "the fragment says same-file overlap is not a dependency"
assert_contains "$FRAGMENT" "same-file overlap" \
  "orchestration fragment names same-file overlap explicitly"

start_case "the fragment prefers stacked PRs for genuinely dependent changes"
assert_contains "$FRAGMENT" "stacked PR" \
  "orchestration fragment recommends stacked PRs over a serial land-chain"

start_case "the fragment frames serial queueing as a last resort"
assert_contains "$FRAGMENT" "last resort" \
  "orchestration fragment frames serial queueing as a last resort"

start_case "the red-flags table reinforces the norm"
assert_contains "$FRAGMENT" "I'll queue them to be safe" \
  "red-flags table catches the habitual serialize-by-default instinct"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
