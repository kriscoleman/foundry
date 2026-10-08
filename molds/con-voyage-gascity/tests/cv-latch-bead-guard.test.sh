#!/usr/bin/env bash
# cv-latch-bead-guard.test.sh — hermetic, offline test that every con-voyage
# review lens refuses a workflow-control latch bead instead of working it.
#
# THE BUG (fk-79odi, widened by mayor note 2026-10-08T01:30Z): `gc hook
# --claim --json` handed `gc.implementation-worker` sessions con-voyage ROOT
# beads (gc.kind=workflow) to work as normal task content, RECURRING 4x on
# foundry-kc — fk-2v5tdv (claimed by TWO sessions at once), fk-qj2s9r,
# fk-2pw0n1. The vendored gc-role-worker.template.md fragment (GC-METH-012,
# byte-identical to the gascity-packs upstream — see
# cv-lens-gc-claim-protocol.test.sh) already DOCUMENTS the rule in its own
# "## Notes" section ("gc.kind=workflow and gc.kind=scope are latch beads.
# You should not receive them as normal work.") but never enforces it: the
# claim loop verifies id/status/assignee/route and stops there.
#
# This pack cannot edit the vendored fragment (that would break the
# byte-identity contract with upstream), so the real claim-time fix for
# gascity-core routes (implementation-worker, run-operator) must be filed
# upstream with a repro. What con-voyage DOES own is every cv-* lens prompt,
# so this fix adds an explicit post-claim guard fragment those prompts
# include right after the shared claim protocol: refuse to execute a claimed
# bead whose gc.kind is workflow/scope/check/fanout/scope-check/
# workflow-finalize, mail the mayor once per occurrence, and re-run the claim
# loop instead of working it.
#
# Run:  bash tests/cv-latch-bead-guard.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
AGENTS_DIR="${MOLD_DIR}/pack/agents"
FRAGMENTS_DIR="${MOLD_DIR}/pack/template-fragments"
FRAGMENT="${FRAGMENTS_DIR}/cv-latch-bead-guard.template.md"
ROLE_WORKER_FRAGMENT="${FRAGMENTS_DIR}/gc-role-worker.template.md"
ROLE_WORKER_TOKEN='{{ template "gc-role-worker" . }}'
INCLUDE_TOKEN='{{ template "cv-latch-bead-guard" . }}'
FORMULA_TOML="${MOLD_DIR}/pack/formulas/con-voyage.formula.toml"

LENSES=(
  cv-api-platform-contract
  cv-code-reviewer
  cv-compliance-privacy
  cv-data-db-engineer
  cv-design-ux
  cv-dev-ex-reviewer
  cv-documentation
  cv-founder-cto
  cv-frontend-principal-engineer
  cv-go-principal-engineer
  cv-marketing
  cv-product-owner
  cv-qa-test-engineer
  cv-security-reviewer
  cv-sre-reliability
  cv-standards-janitor
)

LATCH_KINDS=(workflow scope check fanout scope-check workflow-finalize)

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

start_case "the shared latch-bead guard fragment exists and defines the named template"
assert_contains "$FRAGMENT" '{{ define "cv-latch-bead-guard" }}' \
  "fragment defines the cv-latch-bead-guard named template"

start_case "the fragment names every latch gc.kind value from the vendored fragment's Notes section"
for kind in "${LATCH_KINDS[@]}"; do
  assert_contains "$FRAGMENT" "\`${kind}\`" \
    "fragment names gc.kind=${kind} as a latch kind to refuse"
done

start_case "the fragment instructs refusing to execute, not just noticing, a claimed latch bead"
assert_contains "$FRAGMENT" "Do NOT execute its description" \
  "fragment tells the worker not to execute a latch bead's description"
assert_contains "$FRAGMENT" "Do NOT close it" \
  "fragment tells the worker not to close/mutate a latch bead"

start_case "the fragment surfaces a recurring routing gap instead of silently working around it (communal duty)"
assert_contains "$FRAGMENT" "Mail the mayor" \
  "fragment tells the worker to mail the mayor on a latch-bead claim"

start_case "the fragment resumes normal operation instead of stalling the session"
assert_contains "$FRAGMENT" "Re-run the Startup Claim Protocol" \
  "fragment tells the worker to re-run the claim loop after refusing"
assert_contains "$FRAGMENT" "drain" \
  "fragment tells the worker to drain rather than spin on a repeated latch-bead claim"

start_case "the fragment cites the evidence this fix is grounded in (fk-79odi)"
assert_contains "$FRAGMENT" "fk-79odi" \
  "fragment cites fk-79odi"

start_case "every cv-* lens includes the shared latch-bead guard by reference (DRY, not pasted)"
for lens in "${LENSES[@]}"; do
  assert_contains "${AGENTS_DIR}/${lens}/prompt.template.md" "$INCLUDE_TOKEN" \
    "${lens} includes the shared latch-bead guard"
done

start_case "every cv-* lens includes the guard after the shared claim protocol, not before it"
for lens in "${LENSES[@]}"; do
  lens_file="${AGENTS_DIR}/${lens}/prompt.template.md"
  if [ ! -f "$lens_file" ]; then
    echo "  FAIL: ${lens} prompt template does not exist" >&2
    FAILURES=$((FAILURES+1))
    continue
  fi
  role_line="$(grep -nF -- "$ROLE_WORKER_TOKEN" "$lens_file" | head -1 | cut -d: -f1)"
  guard_line="$(grep -nF -- "$INCLUDE_TOKEN" "$lens_file" | head -1 | cut -d: -f1)"
  if [ -z "$role_line" ] || [ -z "$guard_line" ]; then
    echo "  FAIL: ${lens} is missing one of the two include tokens" >&2
    FAILURES=$((FAILURES+1))
  elif [ "$guard_line" -gt "$role_line" ]; then
    echo "  PASS: ${lens} includes the latch-bead guard after the claim protocol"
  else
    echo "  FAIL: ${lens} includes the latch-bead guard before the claim protocol (line ${guard_line} <= ${role_line})" >&2
    FAILURES=$((FAILURES+1))
  fi
done

start_case "the vendored gc-role-worker fragment's own Notes still name the same latch kinds (sanity: guard is a superset, not a divergent list)"
for kind in "${LATCH_KINDS[@]}"; do
  assert_contains "$ROLE_WORKER_FRAGMENT" "${kind}" \
    "vendored fragment's Notes section still mentions gc.kind=${kind}"
done

# review fk-hbsmk BLOCKING-1: pin the floor-lane -> gc.run_target mapping so a
# future change that either (a) drops coverage on security/code (the two
# floor lanes this fix actually guards) or (b) silently re-routes
# acceptance/test-evidence/simplicity onto a con-voyage-owned, guardable
# persona without anyone extending the guard to match is caught here instead
# of shipping unnoticed. The 3 "unguarded" floor lanes are a disclosed,
# tracked residual (fk-bzjqn, upstream gc hook --claim fix covers all of
# gc.implementation-worker/run-operator/these 3 lanes at once) — not an
# oversight of this change.
start_case "the floor-lane -> gc.run_target mapping matches what this fix can and cannot guard"
assert_floor_lane_route() {
  local lane_id="$1" expected_target="$2" guarded="$3"
  local actual
  actual="$(awk -v id="\"${lane_id}\"" '
    $0 ~ ("id = " id) { found=1 }
    found && /gc\.run_target/ {
      line = $0
      sub(/.*gc\.run_target" = "/, "", line)
      sub(/".*/, "", line)
      print line
      exit
    }
  ' "$FORMULA_TOML")"
  if [ "$actual" = "$expected_target" ]; then
    echo "  PASS: ${lane_id} routes to ${expected_target} (guarded=${guarded})"
  else
    echo "  FAIL: ${lane_id} routes to '${actual}', expected '${expected_target}' (guarded=${guarded})" >&2
    FAILURES=$((FAILURES+1))
  fi
}
if [ -f "$FORMULA_TOML" ]; then
  assert_floor_lane_route "{target}.acceptance-review" "gc.implementation-reviewer" "no"
  assert_floor_lane_route "{target}.test-evidence-review" "gc.gap-analyst" "no"
  assert_floor_lane_route "{target}.simplicity-review" "gc.design-implementation-reviewer" "no"
  assert_floor_lane_route "{target}.security-review" "con-voyage.cv-security-reviewer" "yes"
  assert_floor_lane_route "{target}.code-review" "{code_lens}" "yes"
else
  echo "  FAIL: formula toml not found at $FORMULA_TOML" >&2
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
