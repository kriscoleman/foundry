#!/usr/bin/env bash
# cv-pack-script-resolution-workflows.test.sh — hermetic, offline regression
# guard that no workflow markdown asset (or the shared lib) resorts to the
# nondeterministic command-v/find pack-script resolution idiom fk-q2pon
# removed. Direct unit coverage of the replacement (cv_pack_root /
# cv_pack_script, including the required decoy-copy scenario) lives in
# cv-pack-root-resolution.test.sh; this suite is the static/contract half —
# same style as con-voyage-build-phase.test.sh and agents-contract.test.sh —
# proving the fix actually reached every asset a worker receives, not just
# the one repro file (fk-8dfxt).
#
# Run:  bash tests/cv-pack-script-resolution-workflows.test.sh   (exit 0 => pass)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
ASSETS_DIR="${MOLD_DIR}/pack/assets"

if [ ! -d "$ASSETS_DIR" ]; then
  echo "FATAL: pack assets dir not found at ${ASSETS_DIR}" >&2
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
    echo "  FAIL: $label (not found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

# ===========================================================================
# CASE 1 — blanket regression guard: the old idiom (either shape — with or
# without a `command -v` fast path) must not exist anywhere under
# pack/assets/ any more, including any file added after this test was
# written. This is the primary guard fk-q2pon asked for ("remove the find
# $GC_CITY fallbacks"), covering the whole tree rather than a hand-maintained
# file list.
# ===========================================================================
start_case "no asset file resolves a pack script via 'find \"\${GC_CITY' any more"
mapfile -t offenders < <(grep -rlF 'find "${GC_CITY' "$ASSETS_DIR" 2>/dev/null || true)
if [ "${#offenders[@]}" -eq 0 ]; then
  echo "  PASS: zero matches under ${ASSETS_DIR}"
else
  for f in "${offenders[@]}"; do
    echo "  FAIL: still uses the old find-\$GC_CITY idiom: ${f#${MOLD_DIR}/}" >&2
  done
  FAILURES=$((FAILURES+${#offenders[@]}))
fi

# ===========================================================================
# CASE 2 — spot-check: representative files from each formula actually carry
# the new deterministic resolution (proves the fix was substantively applied
# — CASE 1 passing on its own would also be true if the resolution step had
# simply been deleted instead of replaced).
# ===========================================================================
start_case "representative workflow files carry the new git-toplevel-first resolution"
WORKFLOWS="${ASSETS_DIR}/workflows"
NEW_MARKER='git rev-parse --show-toplevel'
assert_contains "${WORKFLOWS}/con-voyage/{target}.build.md" "$NEW_MARKER" \
  "build.md (con-voyage main build phase)"
assert_contains "${WORKFLOWS}/con-voyage/{target}.prepare-build.md" "$NEW_MARKER" \
  "prepare-build.md"
assert_contains "${WORKFLOWS}/con-voyage/{target}.setup-con-voyage-review.md" "$NEW_MARKER" \
  "setup-con-voyage-review.md"
assert_contains "${WORKFLOWS}/con-voyage/{target}.publish.md" "$NEW_MARKER" \
  "publish.md"
assert_contains "${WORKFLOWS}/con-voyage/{target}.security-review.md" "$NEW_MARKER" \
  "security-review.md (floor review lane)"
assert_contains "${WORKFLOWS}/con-voyage/{target}.acceptance-review.md" "$NEW_MARKER" \
  "acceptance-review.md (floor review lane)"
assert_contains "${WORKFLOWS}/con-voyage-ci-repair/{target}.ci-repair.md" "$NEW_MARKER" \
  "ci-repair.md (separate con-voyage-ci-repair formula)"

# ===========================================================================
# CASE 3 — the shared lib's own internal resolution (inside
# cv_worktree_prep_resolve_base) goes through cv_pack_script now, not a
# hand-rolled duplicate of the old idiom.
# ===========================================================================
start_case "con-voyage-lib.sh's own internal resolver uses cv_pack_script, not a duplicate idiom"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
assert_contains "$LIB" 'prep_script="$(cv_pack_script cv-worktree-prep.sh)"' \
  "cv_worktree_prep_resolve_base delegates to cv_pack_script"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
