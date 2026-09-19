#!/usr/bin/env bash
# con-voyage-lib.test.sh — hermetic unit tests for the shared work-bead
# lifecycle helpers in con-voyage-lib.sh (fk-p7j9 / fk-hsca).
#
# The finalize monitor exercises finalize_read/_write, cv_close_reason_for_pr,
# and pr_finalize_state end-to-end (con-voyage-finalize.test.sh). This suite
# adds DIRECT coverage for cv_resolve_work_bead — the bead-id-chain resolver
# that maps a con-voyage `{{convoy_id}}` (a synthetic input convoy) to the REAL
# work bead (its `tracks` dependency). That mapping is the crux of the whole
# lifecycle and is also mirrored by the inline resolver snippet the workflow
# steps run, so it is unit-tested here against the real bd-show JSON shapes.
#
# The lib is `source`d directly (it defines functions only, no side effects). A
# recording `gc` stub returns canned `bd show --json` bodies keyed by
# STUB_BDSHOW_JSON_<id>.
#
# Run:  bash tests/con-voyage-lib.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: lib under test not found at ${LIB}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-lib-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Recording `gc` stub. For `bd show <id> --json` it echoes the environment
# variable STUB_BDSHOW_JSON_<id> verbatim (empty => `bd show` "fails" by
# printing nothing and the lib falls back). Other subcommands no-op.
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "show" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_BDSHOW_JSON_${id//-/_}"
  printf '%s' "${!var:-}"
  exit 0
fi
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# The lib reads GC/GC_CITY/GH/CV_STATE_DIR as globals at CALL time (inside the
# sourced functions), so shellcheck cannot see the uses when it checks this file
# standalone — hence the SC2034 disables below. They are genuinely consumed.
# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
GC="${STUBDIR}/gc"
# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
GC_CITY="${SANDBOX}/city"
mkdir -p "$GC_CITY"
# GH is referenced by pr_finalize_state (not tested here) — point it somewhere
# harmless so `set -u` never trips on an unbound global if a helper reads it.
# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
GH="${STUBDIR}/gc"
# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
CV_STATE_DIR="${SANDBOX}/state"
mkdir -p "$CV_STATE_DIR"

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

FAILURES=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3 (=$1)"; else echo "  FAIL: $3 (expected '$1', got '$2')" >&2; FAILURES=$((FAILURES+1)); fi
}
start_case() { echo; echo "=== CASE: $1 ==="; }

# ---------------------------------------------------------------------------
# cv_resolve_work_bead
# ---------------------------------------------------------------------------
start_case "cv_resolve_work_bead: synthetic input convoy -> tracks dependency"
export STUB_BDSHOW_JSON_fk_8ba='[{"id":"fk-8ba","issue_type":"convoy","metadata":{"gc.synthetic":"true"},"dependencies":[{"id":"fk-2co","dependency_type":"tracks"}]}]'
assert_eq "fk-2co" "$(cv_resolve_work_bead "fk-8ba")" "resolves synthetic convoy to its tracked work bead"

start_case "cv_resolve_work_bead: issue_type=convoy (non-synthetic) -> tracks dependency"
export STUB_BDSHOW_JSON_cv_1='{"id":"cv-1","issue_type":"convoy","metadata":{},"dependencies":[{"id":"wb-1","dependency_type":"tracks"}]}'
assert_eq "wb-1" "$(cv_resolve_work_bead "cv-1")" "resolves any convoy bead to its tracked work bead"

start_case "cv_resolve_work_bead: plain work bead (not a convoy) -> itself"
export STUB_BDSHOW_JSON_fk_2co='{"id":"fk-2co","issue_type":"task","metadata":{},"dependencies":[]}'
assert_eq "fk-2co" "$(cv_resolve_work_bead "fk-2co")" "a non-convoy id is already the work bead"

start_case "cv_resolve_work_bead: convoy with NO usable dependency -> fail-safe to input"
export STUB_BDSHOW_JSON_cv_empty='{"id":"cv-empty","issue_type":"convoy","metadata":{"gc.synthetic":"true"},"dependencies":[]}'
assert_eq "cv-empty" "$(cv_resolve_work_bead "cv-empty")" "convoy with no dependency falls back to the input id (never empty)"

start_case "cv_resolve_work_bead: bd show returns nothing -> fail-safe to input"
# No STUB_BDSHOW_JSON_* for this id => empty output => fallback.
assert_eq "cv-unknown" "$(cv_resolve_work_bead "cv-unknown")" "unknown/failed bd show falls back to the input id"

start_case "cv_resolve_work_bead: empty input -> empty (echoed unchanged)"
assert_eq "" "$(cv_resolve_work_bead "")" "empty input echoes empty (caller's problem, never invents an id)"

start_case "cv_resolve_work_bead: dependency id equal to convoy id is ignored (no self-loop)"
export STUB_BDSHOW_JSON_cv_self='{"id":"cv-self","issue_type":"convoy","metadata":{"gc.synthetic":"true"},"dependencies":[{"id":"cv-self","dependency_type":"tracks"}]}'
assert_eq "cv-self" "$(cv_resolve_work_bead "cv-self")" "a self-referential dependency is ignored, falls back to input"

start_case "cv_resolve_work_bead: dependency with no type field still resolves (older records)"
export STUB_BDSHOW_JSON_cv_notype='{"id":"cv-notype","issue_type":"convoy","metadata":{},"dependencies":[{"id":"wb-notype"}]}'
assert_eq "wb-notype" "$(cv_resolve_work_bead "cv-notype")" "a dependency with an absent type still resolves (back-compat)"

# ---------------------------------------------------------------------------
# cv_close_reason_for_pr
# ---------------------------------------------------------------------------
start_case "cv_close_reason_for_pr: canonical reasons"
assert_eq "landed: PR #29 merged" "$(cv_close_reason_for_pr MERGED 29)" "MERGED -> landed reason"
assert_eq "landed: PR #29 merged" "$(cv_close_reason_for_pr merged 29)" "case-insensitive merged -> landed"
assert_eq "abandoned: PR #27 closed without merge" "$(cv_close_reason_for_pr CLOSED 27)" "CLOSED -> abandoned reason"

# ---------------------------------------------------------------------------
# finalize_read / finalize_write round-trip
# ---------------------------------------------------------------------------
start_case "finalize_write/read round-trip"
finalize_write "k1" "wb-1" "cv-1" "kriscoleman/foundry" "29" "kriscoleman" "foundry/impl" "awaiting_merge"
finalize_read "k1"
assert_eq "wb-1" "$FS_WORK_BEAD" "work_bead round-trips"
assert_eq "cv-1" "$FS_CONVOY_ID" "convoy_id round-trips"
assert_eq "kriscoleman/foundry" "$FS_REPO_FULL" "repo_full round-trips"
assert_eq "29" "$FS_PR_NUMBER" "pr_number round-trips"
assert_eq "kriscoleman" "$FS_PR_AUTHOR" "pr_author round-trips"
assert_eq "foundry/impl" "$FS_IMPLEMENTOR" "implementor round-trips"
assert_eq "awaiting_merge" "$FS_LAST_PHASE" "last_phase round-trips"

start_case "finalize_read: missing record leaves fields empty (no stale bleed)"
finalize_read "does-not-exist"
assert_eq "" "$FS_WORK_BEAD" "missing record => empty work_bead"
assert_eq "" "$FS_LAST_PHASE" "missing record => empty last_phase"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
