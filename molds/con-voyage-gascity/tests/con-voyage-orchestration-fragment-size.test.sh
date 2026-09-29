#!/usr/bin/env bash
# con-voyage-orchestration-fragment-size.test.sh — hermetic, offline test
# pinning the mayor context-budget cut (fk-lx8ze, operator plan
# .claude/plans/mayor-context-budget-2026-09-28.md item 6).
#
# The `con-voyage-orchestration` fragment is appended verbatim into every
# mayor's SessionStart context (README.md's `[mayor] append_fragments =
# ["con-voyage-orchestration"]`, flux.yaml's pack output is `process: false`
# — no templating rewrite). At 14.2KB it pushed the mayor's total prime to
# 18.8KB, over Claude Code's SessionStart inline cap — the mayor either
# starts without its operating contract or pays ~5K tokens to Read it.
#
# The fix keeps only what must be resident every session (facilitator
# contract, dispatch posture, condensed red flags, one-line phase pointers)
# in the fragment, and moves full phase-by-phase detail plus the model-tier /
# all-opencode fallback protocol into the on-demand `con-voyage` skill, which
# only loads when a journey actually runs.
#
# Run:  bash tests/con-voyage-orchestration-fragment-size.test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
FRAGMENT="${MOLD_DIR}/pack/template-fragments/con-voyage-orchestration.template.md"
SKILL="${MOLD_DIR}/skills/con-voyage/SKILL.md"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

bytes_of() { wc -c < "$1" | tr -d ' '; }

# ---------------------------------------------------------------------------
start_case "the fragment fits the SessionStart inline budget"
# ---------------------------------------------------------------------------
# Cap set well under the 9KB total-prime target from the budget plan, leaving
# headroom for the rest of the mayor prime (AGENTS.md contract copy, other
# appended fragments) that this fragment doesn't control.
FRAGMENT_CAP=4500
if [ ! -f "$FRAGMENT" ]; then
  fail "fragment not found at $FRAGMENT"
else
  size="$(bytes_of "$FRAGMENT")"
  if [ "$size" -le "$FRAGMENT_CAP" ]; then
    pass "fragment is ${size} bytes (<= ${FRAGMENT_CAP})"
  else
    fail "fragment is ${size} bytes, over the ${FRAGMENT_CAP}-byte cap"
  fi
fi

# ---------------------------------------------------------------------------
start_case "the fragment still carries the always-resident facilitator contract"
# ---------------------------------------------------------------------------
for needle in "chief-of-staff facilitator" "Dispatch posture" "Do not serialize by habit" "same-file overlap" "stacked PR" "last resort" "I'll queue them to be safe" "Reporting & identity"; do
  if grep -qF -- "$needle" "$FRAGMENT" 2>/dev/null; then
    pass "fragment retains: $needle"
  else
    fail "fragment missing always-resident content: $needle"
  fi
done

# ---------------------------------------------------------------------------
start_case "the fragment no longer carries the full model-tier / opencode detail"
# ---------------------------------------------------------------------------
for needle in "kimi-k3" "glm-5p3-flash" "minimax-m3" "CV_LOOKOUT_AUTO_FLIP"; do
  if grep -qF -- "$needle" "$FRAGMENT" 2>/dev/null; then
    fail "fragment still carries model-tier detail that should live in the skill: $needle"
  else
    pass "fragment no longer carries: $needle"
  fi
done

# ---------------------------------------------------------------------------
start_case "the on-demand skill carries the full phase and model-tier detail instead"
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL" ]; then
  fail "skill not found at $SKILL"
else
  for needle in "kimi-k3" "glm-5p3-flash" "minimax-m3" "claude limit circuit breaker OPEN" "lockstep" "FIXES PUSHED"; do
    if grep -qF -- "$needle" "$SKILL" 2>/dev/null; then
      pass "skill carries: $needle"
    else
      fail "skill missing detail moved from the fragment: $needle"
    fi
  done
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
