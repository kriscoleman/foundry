#!/usr/bin/env bash
# con-voyage-build-phase.test.sh — hermetic, offline contract tests for the
# con-voyage build phase (fk-9aunv: "implement-then-escort — one-sling
# journey"). con-voyage used to be REVIEW-ONLY: its first step assumed a
# pre-built branch already existed, so delivering a fresh bead needed a
# clunky two-step (`gc sling ... --on do-work` THEN `gc sling ... --on
# con-voyage --force`). This suite proves the new build phase is actually
# wired into the graph (not just described in prose a worker never sees) and
# that both journeys it must support — a FRESH bead (build then review) and
# an ALREADY-PRE-BUILT branch (short-circuit straight to review) — are
# reachable from the formula and workflow text.
#
# These are static/contract tests against the real formula TOML and workflow
# markdown, the same style as agents-contract.test.sh and
# con-voyage-orchestration-dispatch-posture.test.sh: they prove the wiring a
# worker actually receives, not a hand-maintained description of it. A live
# end-to-end gc run is exercised by dogfooding this very change through the
# pack (see the con-voyage-gascity CLAUDE.md prime directive), not by this
# offline suite.
#
# Run:  bash tests/con-voyage-build-phase.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
FORMULA="${MOLD_DIR}/pack/formulas/con-voyage.formula.toml"
PREPARE_BUILD_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/{target}.prepare-build.md"
BUILD_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/{target}.build.md"
SETUP_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/{target}.setup-con-voyage-review.md"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
WT_PREP="${MOLD_DIR}/pack/assets/scripts/cv-worktree-prep.sh"

for f in "$FORMULA" "$PREPARE_BUILD_MD" "$BUILD_MD" "$SETUP_MD" "$LIB" "$WT_PREP"; do
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

# ---------------------------------------------------------------------------
# Formula wiring: the two new nodes exist, are ordered before the review
# context step, and the build node carries the same artifact-gate shape
# do-work's own implement step uses (mirrors, does not invent, the contract).
# ---------------------------------------------------------------------------
start_case "formula: prepare-build node exists, routed to gc.run-operator, no needs (first node)"
assert_contains "$FORMULA" 'id = "{target}.prepare-build"' "prepare-build node is declared"
assert_contains "$FORMULA" '"gc.run_target" = "gc.run-operator"' "gc.run-operator route exists in the formula"

start_case "formula: build node exists, needs prepare-build, routed to {implementation_target}"
assert_contains "$FORMULA" 'id = "{target}.build"' "build node is declared"
assert_contains "$FORMULA" 'needs = ["{target}.prepare-build"]' "build node depends on prepare-build"
assert_contains "$FORMULA" '"gc.run_target" = "{implementation_target}"' "build node routes to {implementation_target}"

start_case "formula: build node carries the implementation-summary artifact gate (mirrors do-work's implement step)"
assert_contains "$FORMULA" '"gc.build.artifact_schema" = "gc.build.implementation-summary.v1"' "build node declares the implementation-summary schema"
assert_contains "$FORMULA" '.gc/scripts/checks/build-artifact-valid.sh' "build node's check gate points at build-artifact-valid.sh"

start_case "formula: setup-con-voyage-review now runs AFTER the build phase, not first"
assert_contains "$FORMULA" 'needs = ["{target}.build"]' "setup-con-voyage-review depends on {target}.build"

start_case "formula: description_file paths for both new nodes resolve to real files on disk"
prep_rel="$(grep -A3 'id = "{target}.prepare-build"' "$FORMULA" | grep -oE 'description_file *= *"[^"]+"' | sed -E 's/description_file *= *"([^"]+)"/\1/')"
build_rel="$(grep -A6 'id = "{target}.build"' "$FORMULA" | grep -oE 'description_file *= *"[^"]+"' | sed -E 's/description_file *= *"([^"]+)"/\1/')"
formula_dir="$(dirname "$FORMULA")"
if [ -n "$prep_rel" ] && [ -f "${formula_dir}/${prep_rel}" ]; then
  echo "  PASS: prepare-build description_file resolves (${prep_rel})"
else
  echo "  FAIL: prepare-build description_file missing or unresolved (${prep_rel})" >&2
  FAILURES=$((FAILURES+1))
fi
if [ -n "$build_rel" ] && [ -f "${formula_dir}/${build_rel}" ]; then
  echo "  PASS: build description_file resolves (${build_rel})"
else
  echo "  FAIL: build description_file missing or unresolved (${build_rel})" >&2
  FAILURES=$((FAILURES+1))
fi

# ---------------------------------------------------------------------------
# Both journeys are reachable from the workflow text: FRESH (build runs a TDD
# round) and PRE-BUILT (build short-circuits). Grepped from the real files a
# worker receives as its bead description, same as agents-contract.test.sh.
# ---------------------------------------------------------------------------
start_case "prepare-build.md: detects a pre-built branch via cv_bead_work_dir + cv-worktree-prep.sh built"
assert_contains "$PREPARE_BUILD_MD" "cv_bead_work_dir" "reads the existing work_dir via the shared lib helper"
assert_contains "$PREPARE_BUILD_MD" '"$CV_WT_PREP" built' "checks the existing worktree with cv-worktree-prep.sh built"

start_case "prepare-build.md: fresh-bead path creates the worktree the same way do-work does"
assert_contains "$PREPARE_BUILD_MD" 'git worktree add "$WORKTREE" --detach HEAD' "creates the worktree with the do-work convention"
assert_contains "$PREPARE_BUILD_MD" 'gc bd update "$CONVOY_ID" --set-metadata "work_dir=' "persists work_dir on the source anchor the same key do-work uses"

start_case "prepare-build.md: records the resolution on the workflow root for downstream steps"
assert_contains "$PREPARE_BUILD_MD" "gc.build.source_anchor_id=" "records source_anchor_id on the workflow root"
assert_contains "$PREPARE_BUILD_MD" "gc.build.source_anchor_work_dir=" "records source_anchor_work_dir on the workflow root"
assert_contains "$PREPARE_BUILD_MD" "gc.build.short_circuited=" "records short_circuited on the workflow root"

start_case "build.md: branches on short_circuited instead of unconditionally rebuilding"
assert_contains "$BUILD_MD" "SHORT_CIRCUIT" "reads short_circuited off the workflow root"
assert_contains "$BUILD_MD" "Short-circuit: a pre-built branch already exists" "documents the short-circuit path"
assert_contains "$BUILD_MD" "Fresh bead: run the first TDD implementation round" "documents the fresh-build path"

start_case "build.md: implementation-summary artifact section is NOT nested under 'Fresh bead' (regression guard for a heading-nesting defect)"
if grep -qE '^## Write the implementation summary artifact[[:space:]]*$' "$BUILD_MD"; then
  echo "  PASS: artifact-schema heading is a top-level '## ' section, not nested"
else
  echo "  FAIL: artifact-schema heading is missing or still nested under a '###' subsection in $BUILD_MD" >&2
  FAILURES=$((FAILURES+1))
fi
if grep -qE '^### Write the implementation summary artifact[[:space:]]*$' "$BUILD_MD"; then
  echo "  FAIL: artifact-schema heading is still a nested '###' subsection in $BUILD_MD (short-circuit path is told to skip the section that holds it)" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: artifact-schema heading is not a nested '###' subsection"
fi

start_case "build.md: fresh-build path resolves the REAL work bead, not the source anchor's own (empty) description"
assert_contains "$BUILD_MD" "cv_resolve_work_bead" "resolves the real work bead via the shared lib helper"

start_case "build.md: fresh-build path is TDD (failing test first), matching the pack's SDLC contract"
assert_contains "$BUILD_MD" "TDD: a failing test first, then the code to pass it, then refactor" "instructs TDD explicitly"

start_case "build.md: never pushes or opens a PR (that is publish's job only)"
assert_contains "$BUILD_MD" "Do not push or open a PR from this step" "explicitly defers push/PR to the publish step"

start_case "setup-con-voyage-review.md: reads the build phase's resolution instead of assuming a branch already exists"
assert_contains "$SETUP_MD" "gc.build.source_anchor_id" "reads source_anchor_id from the workflow root"
assert_contains "$SETUP_MD" "gc.build.source_anchor_work_dir" "reads source_anchor_work_dir from the workflow root"
assert_contains "$SETUP_MD" "refusing to start a review with nothing to review" "fails loud instead of silently reviewing nothing"

# ---------------------------------------------------------------------------
# The pack's own contract: every formula-dispatched node (agents-contract.
# test.sh already enforces this globally by discovering description_file
# entries from the formula, so the two new nodes are automatically in scope
# there too) — this case just pins that expectation locally for anyone
# reading this suite in isolation.
# ---------------------------------------------------------------------------
start_case "the two new workflow nodes carry the pack's communal-duty and shell-safety reminders"
# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"
assert_contains "$PREPARE_BUILD_MD" "$CV_COMMUNAL_DUTY_REMINDER" "prepare-build.md carries the communal-duty reminder"
assert_contains "$PREPARE_BUILD_MD" "$CV_SHELL_SAFETY_REMINDER" "prepare-build.md carries the shell-safety reminder"
assert_contains "$BUILD_MD" "$CV_COMMUNAL_DUTY_REMINDER" "build.md carries the communal-duty reminder"
assert_contains "$BUILD_MD" "$CV_SHELL_SAFETY_REMINDER" "build.md carries the shell-safety reminder"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
