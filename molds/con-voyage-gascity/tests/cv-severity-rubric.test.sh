#!/usr/bin/env bash
# cv-severity-rubric.test.sh — hermetic, offline test that the shared BLOCKING
# vs. LOW severity rubric reaches every con-voyage review lane, and that the
# synthesizer carries the no-downgrade instruction.
#
# THE BUG (fk-qbdta / foundry#158, landed on main): on replicatedhq/vandoor#10589
# (sc-139247 slice 4), the security lane graded a collision-safety issue LOW
# because "the sole current caller passes zero-value options" (safety resting
# on an unenforced precondition, with a local, cheap fix), and the acceptance
# lane graded a "no warnings when unused" criterion LOW even though it was
# vacuously true (the wiring that would exercise it lands in another, unmerged
# slice). Both should have been BLOCKING. #158's fix: a shared
# CV_SEVERITY_RUBRIC_REMINDER carried verbatim by the security and acceptance
# review lanes, and a synthesizer instruction not to downgrade a lane's
# BLOCKING to LOW on "intentional per plan" grounds.
#
# THE WIDER BUG (fk-z1hpp4 / foundry#161): reviewers kept grading real
# correctness/safety problems as LOW on other lenses too (kriscoleman/foundry#160:
# over-matching that dropped human comments). The operator's fix (foundry#160
# comment, 2026-10-03T20:17:14Z): review with the lens "what could go wrong" —
# anything that breaks or misrepresents the intent of the system, the issue, or
# the user is BLOCKING; LOW is reserved for the trivial/cosmetic/opinionated.
# When unsure, it's BLOCKING. This rubric is a superset of fk-qbdta's three
# rules and must live ONCE in a shared template fragment every lens includes
# by reference (not pasted per-lens) — same DRY convention
# cv-code-lens-hardening.test.sh already asserts for the hardening checklist.
#
# This file asserts: the shared fragment's content and that it is a superset
# of fk-qbdta's three BLOCKING rules; that every cv-* lens and the facilitator
# fragment include it by reference; that CV_SEVERITY_RUBRIC_REMINDER (the
# #158 mechanism, still carried verbatim by the acceptance lane, which has no
# cv-* persona template of its own to include the fragment) still states all
# three rules and reaches that lane; that the synthesizer is told never to
# downgrade a lane's BLOCKING to LOW, under either PR's rationale
# ("intentional per plan" from #158, "no longer load-bearing for correctness"
# from fk-6os73y); and that no lens prompt invites a downgrade.
#
# Run:  bash tests/cv-severity-rubric.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
AGENTS_DIR="${MOLD_DIR}/pack/agents"
FRAGMENTS_DIR="${MOLD_DIR}/pack/template-fragments"
WORKFLOWS_DIR="${MOLD_DIR}/pack/assets/workflows/con-voyage"
FRAGMENT="${FRAGMENTS_DIR}/cv-severity-rubric.template.md"
ORCHESTRATION_FRAGMENT="${FRAGMENTS_DIR}/con-voyage-orchestration.template.md"
ACCEPTANCE_LANE="${WORKFLOWS_DIR}/main.acceptance-review.md"
SYNTHESIZER="${WORKFLOWS_DIR}/main.synthesize-review.md"
INCLUDE_TOKEN='{{ template "cv-severity-rubric" . }}'

if [ ! -f "$LIB" ]; then
  echo "FATAL: shared lib not found at ${LIB}" >&2
  exit 2
fi

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $label ($file does not exist)" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  if grep -qF -- "$needle" "$file"; then
    echo "  FAIL: $label (still found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: $label"
  fi
}

start_case "the shared fragment exists and defines the named template"
assert_contains "$FRAGMENT" '{{ define "cv-severity-rubric" }}' \
  "fragment defines the cv-severity-rubric named template"

start_case "the fragment carries the operator's framing verbatim"
assert_contains "$FRAGMENT" "what could go wrong" \
  "fragment states the 'what could go wrong' review lens"
assert_contains "$FRAGMENT" "When unsure, it's BLOCKING" \
  "fragment states the unsure-defaults-to-BLOCKING rule"

start_case "the fragment reserves LOW for the trivial/cosmetic only"
assert_contains "$FRAGMENT" "trivial" \
  "fragment names trivial findings as LOW"
assert_contains "$FRAGMENT" "cosmetic" \
  "fragment names cosmetic findings as LOW"

start_case "the fragment is a superset of fk-qbdta's three BLOCKING rules (landed foundry#158, narrower security+acceptance-only version)"
assert_contains "$FRAGMENT" "unenforced precondition" \
  "fragment names the unenforced-precondition rule (fk-qbdta rule a)"
assert_contains "$FRAGMENT" "vacuously" \
  "fragment names the vacuous-acceptance rule (fk-qbdta rule b)"
assert_contains "$FRAGMENT" "unmerged" \
  "fragment names the unstacked-dependency rule (fk-qbdta rule c)"

start_case "fk-qbdta's three rules sit inside the fragment's BLOCKING-includes block, not just somewhere in the file"
BLOCKING_BLOCK="$(awk '/^BLOCKING includes:/{flag=1} flag{print} /^LOW is ONLY/{exit}' "$FRAGMENT")"
if [ -z "$BLOCKING_BLOCK" ]; then
  echo "  FAIL: could not locate a 'BLOCKING includes:' ... 'LOW is ONLY' block in $FRAGMENT" >&2
  FAILURES=$((FAILURES+1))
else
  case "$BLOCKING_BLOCK" in
    *"unenforced precondition"*)
      echo "  PASS: unenforced-precondition rule is listed as a BLOCKING example" ;;
    *)
      echo "  FAIL: unenforced-precondition rule is not inside the BLOCKING-includes block" >&2
      FAILURES=$((FAILURES+1)) ;;
  esac
  case "$BLOCKING_BLOCK" in
    *"vacuously"*)
      echo "  PASS: vacuous-acceptance rule is listed as a BLOCKING example" ;;
    *)
      echo "  FAIL: vacuous-acceptance rule is not inside the BLOCKING-includes block" >&2
      FAILURES=$((FAILURES+1)) ;;
  esac
  case "$BLOCKING_BLOCK" in
    *"unmerged"*)
      echo "  PASS: unstacked-dependency rule is listed as a BLOCKING example" ;;
    *)
      echo "  FAIL: unstacked-dependency rule is not inside the BLOCKING-includes block" >&2
      FAILURES=$((FAILURES+1)) ;;
  esac
fi

start_case "the fragment keeps the pre-existing reporting/identity plumbing"
assert_contains "$FRAGMENT" "Report a verdict" \
  "fragment keeps the verdict-reporting bullet"

start_case "the fragment prohibits review lenses from posting to the PR themselves (review fk-lp1pj8 BLOCKING-1)"
assert_contains "$FRAGMENT" "Do NOT call \`cv-pr-comment.sh\`" \
  "fragment explicitly prohibits calling cv-pr-comment.sh"
assert_contains "$FRAGMENT" "report only via your" \
  "fragment points lenses back to their own verdict metadata as the only report channel"
assert_not_contains "$FRAGMENT" "MUST lead with \`[<rig>/<agent> — <lens>]\`" \
  "fragment no longer carries the unscoped banner-format permission line"

start_case "every cv-* lens includes the shared rubric by reference (DRY, not pasted)"
for lens in "${LENSES[@]}"; do
  assert_contains "${AGENTS_DIR}/${lens}/prompt.template.md" "$INCLUDE_TOKEN" \
    "${lens} includes the shared severity rubric"
done

start_case "no cv-* lens still pastes its own hardcoded Reporting & identity bullets"
for lens in "${LENSES[@]}"; do
  assert_not_contains "${AGENTS_DIR}/${lens}/prompt.template.md" \
    "- Tag every finding BLOCKING or LOW, with file:line and a concrete fix." \
    "${lens} no longer duplicates the rubric bullet inline"
done

start_case "no cv-* lens prompt contains wording that invites downgrading a real finding to LOW"
DOWNGRADE_PHRASES=(
  "non-blocking unless"
  "intentional per plan"
  "no longer load-bearing"
)
for lens in "${LENSES[@]}"; do
  lens_file="${AGENTS_DIR}/${lens}/prompt.template.md"
  for phrase in "${DOWNGRADE_PHRASES[@]}"; do
    assert_not_contains "$lens_file" "$phrase" \
      "${lens} does not contain downgrade phrase '${phrase}'"
  done
done

start_case "the facilitator (mayor) fragment includes the same shared rubric, not its own copy"
assert_contains "$ORCHESTRATION_FRAGMENT" "$INCLUDE_TOKEN" \
  "con-voyage-orchestration fragment includes the shared severity rubric"
assert_not_contains "$ORCHESTRATION_FRAGMENT" \
  "- Tag every finding BLOCKING or LOW, with file:line and a concrete fix." \
  "con-voyage-orchestration fragment no longer duplicates the rubric bullet inline"

start_case "cv-security-reviewer's own LOW example no longer invites the vandoor#10589-class downgrade"
assert_not_contains "${AGENTS_DIR}/cv-security-reviewer/prompt.template.md" \
  "LOW\` (hardening, defense-in-depth)" \
  "cv-security-reviewer's Findings line no longer bare-lists defense-in-depth as LOW"
assert_contains "${AGENTS_DIR}/cv-security-reviewer/prompt.template.md" \
  "unenforced precondition" \
  "cv-security-reviewer's Findings line now excludes unenforced-precondition safety from the LOW example"

start_case "the shared severity rubric constant (fk-qbdta / #158) is still defined for lanes with no cv-* persona template"
if [ -z "${CV_SEVERITY_RUBRIC_REMINDER:-}" ]; then
  echo "  FAIL: CV_SEVERITY_RUBRIC_REMINDER is not defined by ${LIB}" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: CV_SEVERITY_RUBRIC_REMINDER is defined"
fi

start_case "the #158 constant states the same three BLOCKING rules as the fragment"
if [ -n "${CV_SEVERITY_RUBRIC_REMINDER:-}" ]; then
  case "$CV_SEVERITY_RUBRIC_REMINDER" in
    *"unenforced precondition"*"current caller behavior"*"fix is local"*)
      echo "  PASS: constant names the unenforced-precondition BLOCKING condition"
      ;;
    *)
      echo "  FAIL: constant text missing the unenforced-precondition BLOCKING condition" >&2
      FAILURES=$((FAILURES+1))
      ;;
  esac
  case "$CV_SEVERITY_RUBRIC_REMINDER" in
    *"vacuously"*)
      echo "  PASS: constant names the vacuous-acceptance BLOCKING condition"
      ;;
    *)
      echo "  FAIL: constant text missing the vacuous-acceptance BLOCKING condition" >&2
      FAILURES=$((FAILURES+1))
      ;;
  esac
  case "$CV_SEVERITY_RUBRIC_REMINDER" in
    *"unmerged"*"stacked"*)
      echo "  PASS: constant names the unstacked-dependency BLOCKING condition"
      ;;
    *)
      echo "  FAIL: constant text missing the unstacked-dependency BLOCKING condition" >&2
      FAILURES=$((FAILURES+1))
      ;;
  esac
fi

start_case "the acceptance lane (no cv-* persona template of its own) still carries the #158 constant verbatim"
if [ -n "${CV_SEVERITY_RUBRIC_REMINDER:-}" ]; then
  assert_contains "$ACCEPTANCE_LANE" "$CV_SEVERITY_RUBRIC_REMINDER" \
    "main.acceptance-review.md carries the shared severity rubric"
fi

start_case "the synthesizer is told never to downgrade a lane's own BLOCKING verdict, under either PR's rationale"
assert_contains "$SYNTHESIZER" "Never downgrade" \
  "synthesizer states the never-downgrade rule"
assert_contains "$SYNTHESIZER" "intentional per plan" \
  "synthesizer names 'intentional per plan' (fk-qbdta/#158) as an invalid downgrade justification"
assert_contains "$SYNTHESIZER" "no longer load-bearing for correctness" \
  "synthesizer names fk-6os73y's 'no longer load-bearing for correctness' as an invalid downgrade justification"
assert_contains "$SYNTHESIZER" "fk-6os73y" \
  "synthesizer cites the fk-6os73y evidence for the no-downgrade rule"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
