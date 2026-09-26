#!/usr/bin/env bash
# cv-pack-root-resolution.test.sh — hermetic unit tests for cv_pack_root /
# cv_pack_script in con-voyage-lib.sh (fk-q2pon).
#
# THE BUG: every pack workflow step located its helper scripts with
# `command -v X || find "${GC_CITY:-.}" -maxdepth 6 -name X | head -1` —
# whichever copy that bounded, unordered filesystem search happened to hit
# first. Real con-voyage cities carry multiple real copies under $GC_CITY at
# once (the live pack cast, each rig's git-tracked mold source, and every
# build/review worktree's own checkout of that mold source), so which copy
# actually ran depended on filesystem layout and search depth, not on which
# copy the running step was cooked from. A build/review step running INSIDE
# a worktree could silently load the city's cast copy of con-voyage-lib.sh
# instead of the very copy it was there to test (fk-8dfxt).
#
# THE FIX: cv_pack_root resolves deterministically, never by search:
#   1. `git rev-parse --show-toplevel` (shell-agnostic, not a
#      ${BASH_SOURCE[0]} introspection — see the fk-qppb4 B2 doc comment on
#      cv_worktree_prep_resolve_base for why that matters under zsh) — if
#      that toplevel carries its own molds/con-voyage-gascity/pack copy, a
#      dogfooding run under a worktree/rig checkout uses THAT copy.
#   2. Otherwise, the city's live pack cast at $GC_CITY/packs/con-voyage —
#      the path an ordinary (non-dogfooding) cast rig actually runs from.
# No candidate list, no depth-bounded search, no "whichever sorts first".
#
# Run:  bash tests/cv-pack-root-resolution.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: lib under test not found at ${LIB}" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$LIB"

if ! command -v cv_pack_root >/dev/null 2>&1; then
  echo "FATAL: cv_pack_root is not defined by ${LIB} (fk-q2pon fix not implemented yet)" >&2
  exit 2
fi
if ! command -v cv_pack_script >/dev/null 2>&1; then
  echo "FATAL: cv_pack_script is not defined by ${LIB} (fk-q2pon fix not implemented yet)" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-pack-root-test.XXXXXX")"
# Canonicalize (macOS: /tmp and $TMPDIR resolve through /private) so paths
# built from $SANDBOX compare equal to git's own resolved --show-toplevel
# output, which is already fully symlink-resolved.
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (expected '${expected}', got '${actual}')" >&2
    FAILURES=$((FAILURES+1))
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders. Neither fixture ever commits anything — cv_pack_root only
# needs `git rev-parse --show-toplevel`, which resolves from a bare `git
# init` alone, so these fixtures stay hermetic without needing a fixture
# git identity (unlike con-voyage-stacked-pr-base.test.sh's mk_repo, which
# needs real commits for a rebase).
# ---------------------------------------------------------------------------

# A "worktree" fixture: a real git repo carrying its own
# molds/con-voyage-gascity/pack/assets/scripts/<name> copy — deeper in the
# tree than the city cast copy below, and the one that must win.
mk_worktree_fixture() {
  local dir="$1"; shift
  mkdir -p "${dir}/molds/con-voyage-gascity/pack/assets/scripts"
  git -C "$dir" init -q -b main
  for name in "$@"; do
    printf '# worktree copy of %s\n' "$name" > "${dir}/molds/con-voyage-gascity/pack/assets/scripts/${name}"
  done
}

# A "city cast" fixture: NOT a mold checkout at all, just
# packs/con-voyage/assets/scripts/<name> — the shallower fallback location.
mk_city_fixture() {
  local dir="$1"; shift
  mkdir -p "${dir}/packs/con-voyage/assets/scripts"
  for name in "$@"; do
    printf '# city cast copy of %s\n' "$name" > "${dir}/packs/con-voyage/assets/scripts/${name}"
  done
}

# ===========================================================================
# CASE 1 — decoy at both depths: a worktree copy (deep) and a city-cast copy
# (shallow) both exist. The worktree's own copy must win even though the city
# copy is shallower — this is the exact fk-8dfxt regression (a naive
# depth/search-order pick would take the shallow one).
# ===========================================================================
start_case "1: worktree's own copy wins over a shallower city-cast decoy"
WT1="${SANDBOX}/case1-worktree"
CITY1="${SANDBOX}/case1-city"
mk_worktree_fixture "$WT1" con-voyage-lib.sh cv-worktree-prep.sh
mk_city_fixture "$CITY1" con-voyage-lib.sh cv-worktree-prep.sh

(
  cd "$WT1" || exit 2
  export GC_CITY="$CITY1"
  got_root="$(cv_pack_root)"
  got_lib="$(cv_pack_script con-voyage-lib.sh)"
  got_prep="$(cv_pack_script cv-worktree-prep.sh)"
  printf 'RESOLVED_ROOT=%s\nRESOLVED_LIB=%s\nRESOLVED_PREP=%s\n' "$got_root" "$got_lib" "$got_prep"
) > "${SANDBOX}/case1.out"
# shellcheck disable=SC1090
# Deliberately named RESOLVED_* rather than ROOT/LIB/PREP: this file gets
# `source`d into THIS script's own top-level scope, and a plain `LIB=` here
# would clobber the SUT path this whole file already holds in $LIB (used by
# every later case, including 1b's zsh subprocess) — reproduced first-hand:
# an earlier draft named this field LIB and every case after 1 silently
# sourced the fixture's decoy con-voyage-lib.sh instead of the real one.
source "${SANDBOX}/case1.out"

assert_eq "$RESOLVED_ROOT" "${WT1}/molds/con-voyage-gascity/pack" \
  "cv_pack_root returns the worktree's own pack dir, not the city cast"
assert_eq "$RESOLVED_LIB" "${WT1}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh" \
  "cv_pack_script resolves con-voyage-lib.sh to the worktree copy"
assert_eq "$RESOLVED_PREP" "${WT1}/molds/con-voyage-gascity/pack/assets/scripts/cv-worktree-prep.sh" \
  "cv_pack_script resolves a DIFFERENT script (cv-worktree-prep.sh) the same way, off the same root"

if grep -q "worktree copy" "$RESOLVED_LIB" 2>/dev/null; then
  echo "  PASS: the resolved file's own content confirms it is the worktree copy, not the city-cast decoy"
else
  echo "  FAIL: resolved path ${RESOLVED_LIB} does not contain the worktree fixture's marker text" >&2
  FAILURES=$((FAILURES+1))
fi

# ===========================================================================
# CASE 1b — zsh portability: `path` is a special TIED parameter in zsh (an
# array kept in sync with $PATH, not an ordinary scalar — see zsh's own
# PARAMETERS(1) "tied" list), so `local path` inside a zsh-sourced function
# silently replaces $PATH with an empty value for that function's scope
# (no error is raised, unlike fk-k14n's `local status` read-only-variable
# abort in con-voyage-lib.test.sh — this corruption is silent, which is why
# it survived a bash-only test run undetected). Any command cv_pack_script
# or something it calls needs from $PATH during that window (this file's own
# `git rev-parse --show-toplevel` inside cv_pack_root, called from within
# cv_pack_script) then silently fails, so cv_pack_root falls through to the
# GC_CITY branch even though the correct worktree copy exists — reproduced
# first-hand under zsh 5.9 while validating this exact fix (fk-q2pon).
# These cases source the real lib into an actual zsh subprocess (not bash
# emulating zsh), matching con-voyage-lib.test.sh's zsh-subprocess precedent,
# and assert the ACTUAL resolved path is still correct — not just "no error"
# — since this class of bug does not raise one.
# ===========================================================================
if ! command -v zsh >/dev/null 2>&1; then
  echo
  echo "SKIP: zsh not installed on this host, skipping zsh portability case" >&2
else
  start_case "1b: cv_pack_script still resolves the worktree copy under zsh (no silent \$PATH corruption)"
  (
    cd "$WT1" || exit 2
    export GC_CITY="$CITY1"
    zsh -c "source '$LIB'; cv_pack_script con-voyage-lib.sh"
  ) > "${SANDBOX}/case1b.out" 2>"${SANDBOX}/case1b.err"
  CASE1B_LIB="$(cat "${SANDBOX}/case1b.out")"
  assert_eq "$CASE1B_LIB" "${WT1}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh" \
    "cv_pack_script under zsh still resolves the worktree copy, not a GC_CITY fallback caused by \$PATH corruption"
  if [ -s "${SANDBOX}/case1b.err" ]; then
    echo "  FAIL: unexpected zsh stderr: $(cat "${SANDBOX}/case1b.err")" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: no zsh stderr noise"
  fi
fi

# ===========================================================================
# CASE 2 — no worktree mold copy at all (a normal, non-dogfooding cast rig):
# falls back to the city cast.
# ===========================================================================
start_case "2: falls back to the city cast when running outside a mold checkout"
PLAIN2="${SANDBOX}/case2-plain-repo"
CITY2="${SANDBOX}/case2-city"
mkdir -p "$PLAIN2"
git -C "$PLAIN2" init -q -b main
mk_city_fixture "$CITY2" con-voyage-lib.sh

(
  cd "$PLAIN2" || exit 2
  export GC_CITY="$CITY2"
  cv_pack_script con-voyage-lib.sh
) > "${SANDBOX}/case2.out"
CASE2_LIB="$(cat "${SANDBOX}/case2.out")"
assert_eq "$CASE2_LIB" "${CITY2}/packs/con-voyage/assets/scripts/con-voyage-lib.sh" \
  "cv_pack_script falls back to \$GC_CITY/packs/con-voyage when the git toplevel has no mold copy"

# ===========================================================================
# CASE 3 — neither location has the script: fails soft (empty string), same
# contract the old command-v/find idiom had on total miss, so existing
# `[ -n "$VAR" ]` call sites keep working unchanged.
# ===========================================================================
start_case "3: empty result (not a crash) when the script exists nowhere"
PLAIN3="${SANDBOX}/case3-plain-repo"
CITY3="${SANDBOX}/case3-city-empty"
mkdir -p "$PLAIN3" "$CITY3"
git -C "$PLAIN3" init -q -b main

(
  cd "$PLAIN3" || exit 2
  export GC_CITY="$CITY3"
  out="$(cv_pack_script totally-nonexistent-script.sh)"
  printf 'RESULT=[%s]\n' "$out"
) > "${SANDBOX}/case3.out"
CASE3_RESULT="$(cat "${SANDBOX}/case3.out")"
assert_eq "$CASE3_RESULT" "RESULT=[]" \
  "cv_pack_script prints nothing (not an error) when the script is not found anywhere"

# ===========================================================================
# CASE 4 — not inside any git repo at all: must not crash or resolve to a
# bogus filesystem-root path (an earlier draft of this fix concatenated an
# empty `git rev-parse` result directly and could resolve to "/molds/...").
# Still falls back to the city cast cleanly.
# ===========================================================================
start_case "4: outside any git repo — falls back to the city cast, no crash"
NOGIT4="${SANDBOX}/case4-not-a-repo"
CITY4="${SANDBOX}/case4-city"
mkdir -p "$NOGIT4"
mk_city_fixture "$CITY4" con-voyage-lib.sh

(
  cd "$NOGIT4" || exit 2
  export GC_CITY="$CITY4"
  cv_pack_script con-voyage-lib.sh
) > "${SANDBOX}/case4.out" 2>"${SANDBOX}/case4.err"
CASE4_LIB="$(cat "${SANDBOX}/case4.out")"
assert_eq "$CASE4_LIB" "${CITY4}/packs/con-voyage/assets/scripts/con-voyage-lib.sh" \
  "cv_pack_script falls back cleanly to the city cast when cwd is outside any git repo"
if [ -s "${SANDBOX}/case4.err" ]; then
  echo "  FAIL: unexpected stderr output: $(cat "${SANDBOX}/case4.err")" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: no stderr noise when cwd is outside any git repo"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
