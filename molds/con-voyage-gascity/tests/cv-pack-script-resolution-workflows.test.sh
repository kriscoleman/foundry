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

# Unlike assert_contains (whole-file search), this scopes the check to a
# single function's body — so a needle present in some other function of the
# same file does not mask that function's own copy being wrong or missing.
assert_function_delegates() {
  local file="$1" fn="$2" needle="$3" label="$4"
  local start end
  start="$(grep -n "^${fn}() {" "$file" | head -1 | cut -d: -f1)"
  if [ -z "$start" ]; then
    echo "  FAIL: $label (function ${fn} not found in $file)" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  end="$(awk -v start="$start" 'NR>start && /^}/{print NR; exit}' "$file")"
  if [ -z "$end" ]; then
    echo "  FAIL: $label (could not find closing brace for ${fn})" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  if sed -n "${start},${end}p" "$file" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (${fn} body, lines ${start}-${end}, does not contain the delegation line)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

# ===========================================================================
# CASE 1 — blanket regression guard: the old idiom must not exist anywhere
# under pack/assets/ any more, including any file added after this test was
# written. This is the primary guard fk-q2pon asked for ("remove the find
# $GC_CITY fallbacks"), covering the whole tree rather than a hand-maintained
# file list. Catches three shapes: a braced `find "${GC_CITY` fallback, an
# unbraced `find "$GC_CITY` fallback, and a bare `command -v foo.sh` fast
# path with no find fallback at all (the grep for the find text alone would
# miss that last shape).
# ===========================================================================
start_case "no asset file resolves a pack script via find/command-v any more"
mapfile -t offenders < <(grep -rlE 'find "\$\{?GC_CITY|command -v [A-Za-z0-9_-]+\.sh' "$ASSETS_DIR" 2>/dev/null || true)
if [ "${#offenders[@]}" -eq 0 ]; then
  echo "  PASS: zero matches under ${ASSETS_DIR}"
else
  for f in "${offenders[@]}"; do
    echo "  FAIL: still uses the old find/command-v idiom: ${f#${MOLD_DIR}/}" >&2
  done
  FAILURES=$((FAILURES+${#offenders[@]}))
fi

# ===========================================================================
# CASE 2 — every workflow file that resolves a pack script (not just a
# hand-picked sample) actually carries the new deterministic resolution
# (proves the fix was substantively applied — CASE 1 passing on its own
# would also be true if the resolution step had simply been deleted instead
# of replaced). The file set is discovered from a structural filter so a
# file added later is covered automatically instead of needing a new
# assert_contains line.
# ===========================================================================
start_case "every workflow file that resolves a pack script carries the new git-toplevel-first resolution"
WORKFLOWS="${ASSETS_DIR}/workflows"
NEW_MARKER='git rev-parse --show-toplevel'
mapfile -t resolver_files < <(grep -rlF 'assets/scripts/' \
  "${WORKFLOWS}/con-voyage" "${WORKFLOWS}/con-voyage-ci-repair" 2>/dev/null | sort)
if [ "${#resolver_files[@]}" -eq 0 ]; then
  echo "  FAIL: no workflow files matched the 'resolves a pack script' filter — filter or path is broken" >&2
  FAILURES=$((FAILURES+1))
else
  for f in "${resolver_files[@]}"; do
    assert_contains "$f" "$NEW_MARKER" "${f#${MOLD_DIR}/}"
  done
  echo "  (checked ${#resolver_files[@]} files that resolve a pack script)"
fi

# ===========================================================================
# CASE 3 — the shared lib's own internal resolvers (cv_worktree_prep_resolve_base
# and cv_find_prior_built_anchor) each go through cv_pack_script now, not a
# hand-rolled duplicate of the old idiom. Checked per-function (not a
# whole-file search) so one function's correct copy can't mask the other
# function's copy being wrong or missing — there are two call sites, not one.
# ===========================================================================
start_case "con-voyage-lib.sh's own internal resolvers use cv_pack_script, not a duplicate idiom"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
DELEGATION='prep_script="$(cv_pack_script cv-worktree-prep.sh)"'
assert_function_delegates "$LIB" "cv_worktree_prep_resolve_base" "$DELEGATION" \
  "cv_worktree_prep_resolve_base delegates to cv_pack_script"
assert_function_delegates "$LIB" "cv_find_prior_built_anchor" "$DELEGATION" \
  "cv_find_prior_built_anchor delegates to cv_pack_script"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
