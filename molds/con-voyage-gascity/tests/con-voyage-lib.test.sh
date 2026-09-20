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
# printing nothing and the lib falls back). Other subcommands no-op. EVERY
# invocation (including `bd show`) is also appended to STUB_GC_LOG, one
# space-joined argv per line, so cv_bead_mark_in_progress/cv_bead_close tests
# can assert exactly which `bd update`/`bd close` calls (if any) fired.
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG:-/dev/null}"
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
if [ "${args[$i]:-}" = "session" ] && [ "${args[$((i+1))]:-}" = "list" ]; then
  printf '%s' "${STUB_SESSION_LIST_JSON:-{\"sessions\":[]\}}"
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

# Call log for the `gc` stub (cv_bead_mark_in_progress/cv_bead_close cases
# assert on this — see the stub's logging line above). Exported so the
# separately-exec'd stub process inherits it.
GC_LOG="${SANDBOX}/gc.log"
: > "$GC_LOG"
export STUB_GC_LOG="$GC_LOG"

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

FAILURES=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3 (=$1)"; else echo "  FAIL: $3 (expected '$1', got '$2')" >&2; FAILURES=$((FAILURES+1)); fi
}
start_case() { echo; echo "=== CASE: $1 ==="; }

# assert_log_count PATTERN EXPECTED MESSAGE — counts lines in $GC_LOG matching
# an extended regex (mirrors tests/con-voyage-pr-watch.test.sh's helper).
assert_log_count() {
  local pattern="$1" expected="$2" msg="$3" n
  n="$(grep -E -c -- "$pattern" "$GC_LOG")"
  assert_eq "$expected" "${n:-0}" "$msg"
}

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
# cv_bead_mark_in_progress / cv_bead_close (fk-7mw7 FIX-A — the shared
# bead-state-event helpers: a step/work bead goes in_progress the moment a
# step starts it, and closes on ANY terminal outcome, never left orphaned).
# ---------------------------------------------------------------------------
export STUB_BDSHOW_JSON_rb_open='{"id":"rb-open","status":"open","assignee":""}'
export STUB_BDSHOW_JSON_rb_closed='{"id":"rb-closed","status":"closed","assignee":"someone"}'

start_case "cv_bead_mark_in_progress: empty bead id -> no-op, no bd call"
: > "$GC_LOG"
cv_bead_mark_in_progress "" 2>/dev/null
assert_log_count 'bd update' 0 "empty id never calls bd update"

start_case "cv_bead_mark_in_progress: unknown bead -> no-op, no bd call (fail-safe)"
: > "$GC_LOG"
cv_bead_mark_in_progress "rb-unknown" 2>/dev/null
assert_log_count 'bd update' 0 "unknown bead never calls bd update"

start_case "cv_bead_mark_in_progress: already-closed bead -> no-op, no bd call (fail-safe)"
: > "$GC_LOG"
cv_bead_mark_in_progress "rb-closed" 2>/dev/null
assert_log_count 'bd update' 0 "already-closed bead never calls bd update"

start_case "cv_bead_mark_in_progress: open bead -> claims it exactly once"
: > "$GC_LOG"
cv_bead_mark_in_progress "rb-open" 2>/dev/null
assert_log_count 'bd update rb-open --claim' 1 "claims the open bead"

start_case "cv_bead_mark_in_progress: fail-safe paths never abort the caller"
rc=0
cv_bead_mark_in_progress "rb-unknown" 2>/dev/null || rc=$?
assert_eq "0" "$rc" "unknown-bead call still returns 0 (never aborts the step)"

start_case "cv_bead_close: empty bead id -> no-op, no bd call"
: > "$GC_LOG"
cv_bead_close "" "landed" "fix pushed" 2>/dev/null
assert_log_count 'bd close' 0 "empty id never calls bd close"

start_case "cv_bead_close: unknown bead -> no-op, no bd call (fail-safe)"
: > "$GC_LOG"
cv_bead_close "rb-unknown" "landed" "fix pushed" 2>/dev/null
assert_log_count 'bd close' 0 "unknown bead never calls bd close"

start_case "cv_bead_close: already-closed bead -> no-op, no bd call (idempotent)"
: > "$GC_LOG"
cv_bead_close "rb-closed" "landed" "fix pushed" 2>/dev/null
assert_log_count 'bd close' 0 "already-closed bead never calls bd close again"

start_case "cv_bead_close: open bead -> closes with an outcome-prefixed reason"
: > "$GC_LOG"
cv_bead_close "rb-open" "landed" "fix pushed" 2>/dev/null
assert_log_count 'bd close rb-open --reason landed: fix pushed' 1 "closes with '<outcome>: <reason>'"

start_case "cv_bead_close: fail-safe paths never abort the caller"
rc=0
cv_bead_close "rb-unknown" "abandoned" "dropped" 2>/dev/null || rc=$?
assert_eq "0" "$rc" "unknown-bead call still returns 0 (never aborts the step)"

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

# ---------------------------------------------------------------------------
# session_id_for_ident / first_alive_session_id_for_route (fk-loo1 FIX-F —
# review-lane liveness guard helpers, shared with con-voyage-review-watchdog.sh)
# ---------------------------------------------------------------------------
start_case "session_id_for_ident: matches by session_name form (bead assignee shape) -> canonical id"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","alias":"foundry-kc/gc.gap-analyst-1","name":"gap-analyst-1","session_name":"gc__gap-analyst-rc-1","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "rc-1" "$(session_id_for_ident "gc__gap-analyst-rc-1")" "resolves a session_name-form identity to the canonical id"

start_case "session_id_for_ident: matches by alias form too"
assert_eq "rc-1" "$(session_id_for_ident "foundry-kc/gc.gap-analyst-1")" "resolves an alias-form identity to the canonical id"

start_case "session_id_for_ident: closed session is not alive"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-2","session_name":"gc__gap-analyst-rc-2","template":"foundry-kc/gc.gap-analyst","state":"closed"}]}'
assert_eq "" "$(session_id_for_ident "gc__gap-analyst-rc-2")" "a closed session never resolves"

start_case "session_id_for_ident: no match -> empty"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","session_name":"gc__gap-analyst-rc-1","state":"active"}]}'
assert_eq "" "$(session_id_for_ident "gc__someone-else")" "an unmatched identity resolves empty"

start_case "session_id_for_ident: empty ident -> empty, no gc call"
: > "$GC_LOG"
assert_eq "" "$(session_id_for_ident "")" "empty ident short-circuits"
assert_log_count 'session list' 0 "empty ident never calls gc session list"

start_case "first_alive_session_id_for_route: one live session for the route"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "rc-1" "$(first_alive_session_id_for_route "foundry-kc/gc.gap-analyst")" "finds the live session matching the route template"

start_case "first_alive_session_id_for_route: pool fully drained (no sessions at all) -> empty"
export STUB_SESSION_LIST_JSON='{"sessions":[]}'
assert_eq "" "$(first_alive_session_id_for_route "foundry-kc/gc.gap-analyst")" "an empty session list resolves to no live route session"

start_case "first_alive_session_id_for_route: only a closed session for the route -> empty"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","template":"foundry-kc/gc.gap-analyst","state":"closed"}]}'
assert_eq "" "$(first_alive_session_id_for_route "foundry-kc/gc.gap-analyst")" "a closed-only pool is treated as drained"

start_case "first_alive_session_id_for_route: a session for a DIFFERENT route never matches"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","template":"foundry-kc/con-voyage.cv-security-reviewer","state":"active"}]}'
assert_eq "" "$(first_alive_session_id_for_route "foundry-kc/gc.gap-analyst")" "a live session on an unrelated route template does not match"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
