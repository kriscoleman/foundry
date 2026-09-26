#!/usr/bin/env bash
# con-voyage-lib.test.sh — hermetic unit tests for the shared work-bead
# lifecycle helpers in con-voyage-lib.sh (fk-p7j9 / fk-hsca).
#
# The finalize monitor exercises finalize_read/_write, cv_close_reason_for_pr,
# and pr_finalize_state end-to-end (con-voyage-finalize.test.sh). This suite
# adds DIRECT coverage for cv_resolve_work_bead — the bead-id-chain resolver
# that maps a con-voyage `{convoy_id}` (a synthetic input convoy) to the REAL
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
# printing nothing and the lib falls back). For `bd close <id>` it exits 1
# when STUB_BDCLOSE_FAIL_<id>=1 (used by the close_if_open exit-status tests,
# fk-7v3r) — unset/0 behaves like every other no-op subcommand (exit 0).
# Other subcommands no-op. EVERY invocation (including `bd show`) is also
# appended to STUB_GC_LOG, one space-joined argv per line, so
# cv_bead_mark_in_progress/cv_bead_close tests can assert exactly which
# `bd update`/`bd close` calls (if any) fired.
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
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "close" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_BDCLOSE_FAIL_${id//-/_}"
  if [ "${!var:-0}" = "1" ]; then
    exit 1
  fi
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
# cv_bead_work_dir (fk-9aunv: fold the do-work build into con-voyage as its
# own first phase). do-work's prepare-worktree step persists the resolved
# worktree path as a bare `work_dir` metadata key (NOT `gc.`-namespaced) on
# the source anchor bead — see do-work/prepare-worktree.md step 5. The new
# con-voyage build phase reads it back the same way to detect a pre-built
# branch and short-circuit its own initial TDD round.
# ---------------------------------------------------------------------------
start_case "cv_bead_work_dir: bead with work_dir metadata -> the path"
export STUB_BDSHOW_JSON_fk_876om='{"id":"fk-876om","metadata":{"gc.synthetic":"true","work_dir":"/rig/worktrees/fk-876om"}}'
assert_eq "/rig/worktrees/fk-876om" "$(cv_bead_work_dir "fk-876om")" "reads the bare work_dir metadata key"

start_case "cv_bead_work_dir: bead with no work_dir metadata -> empty (never built yet)"
export STUB_BDSHOW_JSON_fk_fresh='{"id":"fk-fresh","metadata":{"gc.synthetic":"true"}}'
assert_eq "" "$(cv_bead_work_dir "fk-fresh")" "no work_dir set yet resolves empty, not an error"

start_case "cv_bead_work_dir: bd show returns nothing -> empty (fail-safe)"
assert_eq "" "$(cv_bead_work_dir "fk-unknown")" "unknown/failed bd show resolves empty"

start_case "cv_bead_work_dir: empty input -> empty, no bd call"
: > "$GC_LOG"
assert_eq "" "$(cv_bead_work_dir "")" "empty bead id resolves empty"
assert_log_count 'bd show' 0 "empty bead id never calls bd show"

start_case "cv_bead_work_dir: unparseable JSON -> empty (fail-safe, never aborts)"
export STUB_BDSHOW_JSON_fk_bad='not json'
assert_eq "" "$(cv_bead_work_dir "fk-bad")" "unparseable bd show output resolves empty"

# ---------------------------------------------------------------------------
# cv_dependency_outcome (fk-03g4s: a `needs` edge in graph.v2 is satisfied on
# CLOSURE alone, regardless of outcome — prepare-build closing gc.outcome=fail
# still let the build step be routed and claimed. build.md/setup-con-voyage-
# review.md fail-fast by checking their own direct dependency's gc.outcome
# BEFORE doing any real investigation. Matched by `title`, not `gc.step_ref`/
# `gc.control_for` — those gain a per-attempt `iteration.N` suffix on
# ralph-wrapped (checked) steps but title is the formula's static `title =
# "..."` string, stable across every attempt and every step type.
# ---------------------------------------------------------------------------
start_case "cv_dependency_outcome: matching dependency title with gc.outcome=fail -> fail"
export STUB_BDSHOW_JSON_fk_bld1='{"id":"fk-bld1","dependencies":[{"id":"fk-prep1","title":"Prepare con-voyage build worktree","metadata":{"gc.outcome":"fail"}}]}'
assert_eq "fail" "$(cv_dependency_outcome "fk-bld1" "Prepare con-voyage build worktree")" "reads gc.outcome off the title-matched dependency"

start_case "cv_dependency_outcome: matching dependency title with gc.outcome=pass -> pass"
export STUB_BDSHOW_JSON_fk_bld2='{"id":"fk-bld2","dependencies":[{"id":"fk-prep2","title":"Prepare con-voyage build worktree","metadata":{"gc.outcome":"pass"}}]}'
assert_eq "pass" "$(cv_dependency_outcome "fk-bld2" "Prepare con-voyage build worktree")" "a passed dependency reads back pass"

start_case "cv_dependency_outcome: no dependency matches the title -> empty (unknown, not a false pass/fail)"
export STUB_BDSHOW_JSON_fk_bld3='{"id":"fk-bld3","dependencies":[{"id":"fk-other","title":"con-voyage","metadata":{}}]}'
assert_eq "" "$(cv_dependency_outcome "fk-bld3" "Prepare con-voyage build worktree")" "an unmatched title resolves empty, never a guess"

start_case "cv_dependency_outcome: matched dependency has no gc.outcome yet -> empty"
export STUB_BDSHOW_JSON_fk_bld4='{"id":"fk-bld4","dependencies":[{"id":"fk-prep4","title":"Prepare con-voyage build worktree","metadata":{}}]}'
assert_eq "" "$(cv_dependency_outcome "fk-bld4" "Prepare con-voyage build worktree")" "a dependency with no recorded outcome resolves empty"

start_case "cv_dependency_outcome: bd show returns nothing -> empty (fail-safe)"
assert_eq "" "$(cv_dependency_outcome "fk-unknown" "Prepare con-voyage build worktree")" "unknown/failed bd show resolves empty"

start_case "cv_dependency_outcome: empty bead id -> empty, no bd call"
: > "$GC_LOG"
assert_eq "" "$(cv_dependency_outcome "" "Prepare con-voyage build worktree")" "empty bead id resolves empty"
assert_log_count 'bd show' 0 "empty bead id never calls bd show"

start_case "cv_dependency_outcome: unparseable JSON -> empty (fail-safe, never aborts)"
export STUB_BDSHOW_JSON_fk_bld5='not json'
assert_eq "" "$(cv_dependency_outcome "fk-bld5" "Prepare con-voyage build worktree")" "unparseable bd show output resolves empty"

start_case "cv_dependency_outcome (fk-2yhob review BLOCKING-1 self-defense): still resolves correctly when \$GC is unset in the caller shell"
# The two fail-fast blocks in build.md/setup-con-voyage-review.md are each the
# first bash block in their file, so nothing upstream has set $GC yet — an
# agent shell only ever exports GC_BIN/GC_CITY/GC_*, never bare GC. This
# proves the lib's own ": ${GC:=gc}" self-defense actually resolves a real
# "gc bd show" call correctly even when GC starts unset, not just the
# caller-side default in the two workflow files (covered separately in
# con-voyage-build-phase.test.sh).
export STUB_BDSHOW_JSON_fk_bld6='{"id":"fk-bld6","dependencies":[{"id":"fk-prep6","title":"Prepare con-voyage build worktree","metadata":{"gc.outcome":"fail"}}]}'
gc_unset_result="$(
  unset GC
  PATH="${STUBDIR}:${PATH}"
  source "$LIB"
  cv_dependency_outcome "fk-bld6" "Prepare con-voyage build worktree"
)"
assert_eq "fail" "$gc_unset_result" "cv_dependency_outcome resolves via bare 'gc' on PATH when \$GC was never set"

# ---------------------------------------------------------------------------
# cv_bead_metadata / cv_root_bead_id (fk-4q6ib: a `{convoy_id}`-style token in
# any description_file too large for gc to inline is a permanent no-op — the
# worker reads the raw, never-rendered file off disk, so nothing ever
# substitutes it. Workflow steps must resolve per-instance values like
# convoy_id dynamically instead of trusting template substitution; these two
# helpers are the shared primitive for that, generalizing the single-key
# readers above.)
# ---------------------------------------------------------------------------
start_case "cv_bead_metadata: known string metadata key -> its value"
export STUB_BDSHOW_JSON_fk_meta1='{"id":"fk-meta1","metadata":{"gc.var.convoy_id":"fk-hd0xv"}}'
assert_eq "fk-hd0xv" "$(cv_bead_metadata "fk-meta1" "gc.var.convoy_id")" "reads a namespaced metadata key"

start_case "cv_bead_metadata: missing key -> empty"
export STUB_BDSHOW_JSON_fk_meta2='{"id":"fk-meta2","metadata":{"other.key":"x"}}'
assert_eq "" "$(cv_bead_metadata "fk-meta2" "gc.var.convoy_id")" "an absent key resolves empty, not an error"

start_case "cv_bead_metadata: bd show returns nothing -> empty (fail-safe)"
assert_eq "" "$(cv_bead_metadata "fk-unknownmeta" "gc.var.convoy_id")" "unknown/failed bd show resolves empty"

start_case "cv_bead_metadata: empty bead id -> empty, no bd call"
: > "$GC_LOG"
assert_eq "" "$(cv_bead_metadata "" "gc.var.convoy_id")" "empty bead id resolves empty"
assert_log_count 'bd show' 0 "empty bead id never calls bd show"

start_case "cv_bead_metadata: unparseable JSON -> empty (fail-safe, never aborts)"
export STUB_BDSHOW_JSON_fk_badmeta='not json'
assert_eq "" "$(cv_bead_metadata "fk-badmeta" "gc.var.convoy_id")" "unparseable bd show output resolves empty"

start_case "cv_bead_metadata: non-string metadata value -> JSON-encoded"
export STUB_BDSHOW_JSON_fk_meta3='{"id":"fk-meta3","metadata":{"gc.flag":true}}'
assert_eq "true" "$(cv_bead_metadata "fk-meta3" "gc.flag")" "a non-string value is still returned (JSON-encoded)"

start_case "cv_root_bead_id: bead carries gc.root_bead_id -> that root id"
export STUB_BDSHOW_JSON_fk_step1='{"id":"fk-step1","metadata":{"gc.root_bead_id":"fk-root1"}}'
assert_eq "fk-root1" "$(cv_root_bead_id "fk-step1")" "reads the workflow root off a step bead"

start_case "cv_root_bead_id: bead has no gc.root_bead_id -> itself (it IS the root)"
export STUB_BDSHOW_JSON_fk_root2='{"id":"fk-root2","metadata":{"gc.kind":"workflow"}}'
assert_eq "fk-root2" "$(cv_root_bead_id "fk-root2")" "a rootless bead falls back to itself"

start_case "cv_root_bead_id: bd show returns nothing -> input id (fail-safe)"
assert_eq "fk-unknownroot" "$(cv_root_bead_id "fk-unknownroot")" "unknown/failed bd show falls back to the input id"

start_case "cv_root_bead_id: empty input -> empty, no bd call"
: > "$GC_LOG"
assert_eq "" "$(cv_root_bead_id "")" "empty bead id resolves empty"
assert_log_count 'bd show' 0 "empty bead id never calls bd show"

# ---------------------------------------------------------------------------
# cv_close_reason_for_pr
# ---------------------------------------------------------------------------
start_case "cv_close_reason_for_pr: canonical reasons"
assert_eq "landed: PR #29 merged" "$(cv_close_reason_for_pr MERGED 29)" "MERGED -> landed reason"
assert_eq "landed: PR #29 merged" "$(cv_close_reason_for_pr merged 29)" "case-insensitive merged -> landed"
assert_eq "abandoned: PR #27 closed without merge" "$(cv_close_reason_for_pr CLOSED 27)" "CLOSED -> abandoned reason"

# ---------------------------------------------------------------------------
# cv_repair_close_reason_for_pr (fk-f1vp FIX-B)
# ---------------------------------------------------------------------------
start_case "cv_repair_close_reason_for_pr: canonical reasons (no outcome prefix)"
assert_eq "PR #83 merged" "$(cv_repair_close_reason_for_pr MERGED 83)" "MERGED -> 'PR #N merged'"
assert_eq "PR #83 merged" "$(cv_repair_close_reason_for_pr merged 83)" "case-insensitive merged -> 'PR #N merged'"
assert_eq "PR #84 closed" "$(cv_repair_close_reason_for_pr CLOSED 84)" "CLOSED -> 'PR #N closed' (not 'closed without merge')"
start_case "cv_repair_close_reason_for_pr: composes with cv_bead_close into the full 'superseded: ...' reason"
: > "$GC_LOG"
export STUB_BDSHOW_JSON_rb_repair='{"id":"rb-repair","status":"open","assignee":""}'
cv_bead_close "rb-repair" "superseded" "$(cv_repair_close_reason_for_pr MERGED 83)" 2>/dev/null
assert_log_count 'bd close rb-repair --reason superseded: PR #83 merged' 1 "composes into 'superseded: PR #83 merged'"

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
# cv_bead_claim_non_routable / CV_WORK_BEAD_OWNER (fk-9f2n — the WORK_BEAD
# claim re-hand loop): setup-con-voyage-review's WORK_BEAD lifecycle block
# used to run `bd update $WORK_BEAD --claim`, which assigns the work bead to
# the CALLING run-operator session. Because the work bead carries no graph.v2
# step metadata (empty gc.root_bead_id/gc.routed_to/gc.continuation_group),
# that same session's NEXT `gc hook --claim` immediately re-surfaced the
# identical bead as fresh routed work -- a live dispatch loop confirmed
# recurring across three separate con-voyage runs (see fk-9f2n notes).
# Assigning to the fixed CV_WORK_BEAD_OWNER identity instead means no
# session's resume-my-own-in-progress-work claim fallback ever matches it.
# ---------------------------------------------------------------------------
start_case "CV_WORK_BEAD_OWNER: defined and non-empty"
if [ -n "${CV_WORK_BEAD_OWNER:-}" ]; then
  echo "  PASS: CV_WORK_BEAD_OWNER is defined (=${CV_WORK_BEAD_OWNER})"
else
  echo "  FAIL: CV_WORK_BEAD_OWNER is not defined by ${LIB}" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "cv_bead_claim_non_routable: empty bead id -> no-op, no bd call"
: > "$GC_LOG"
cv_bead_claim_non_routable "" 2>/dev/null
assert_log_count 'bd update' 0 "empty id never calls bd update"

start_case "cv_bead_claim_non_routable: unknown bead -> no-op, no bd call (fail-safe)"
: > "$GC_LOG"
cv_bead_claim_non_routable "rb-unknown" 2>/dev/null
assert_log_count 'bd update' 0 "unknown bead never calls bd update"

start_case "cv_bead_claim_non_routable: already-closed bead -> no-op, no bd call (fail-safe)"
: > "$GC_LOG"
cv_bead_claim_non_routable "rb-closed" 2>/dev/null
assert_log_count 'bd update' 0 "already-closed bead never calls bd update"

start_case "cv_bead_claim_non_routable: open bead -> assigns to CV_WORK_BEAD_OWNER, in_progress, exactly once"
: > "$GC_LOG"
cv_bead_claim_non_routable "rb-open" 2>/dev/null
assert_log_count "bd update rb-open --assignee ${CV_WORK_BEAD_OWNER} --status in_progress" 1 "claims under the non-routable owner identity (never --claim)"
assert_log_count '--claim( |$)' 0 "never uses --claim (that is exactly what assigns to the caller's own session)"

start_case "cv_bead_claim_non_routable: fail-safe paths never abort the caller"
rc=0
cv_bead_claim_non_routable "rb-unknown" 2>/dev/null || rc=$?
assert_eq "0" "$rc" "unknown-bead call still returns 0 (never aborts the step)"

start_case "setup-con-voyage-review.md: WORK_BEAD claim uses the non-routable owner identity, not --claim"
SETUP_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.setup-con-voyage-review.md"
if [ -f "$SETUP_MD" ]; then
  if grep -qF -- "--assignee \"${CV_WORK_BEAD_OWNER}\"" "$SETUP_MD"; then
    echo "  PASS: workflow block assigns the work bead to CV_WORK_BEAD_OWNER"
  else
    echo "  FAIL: workflow block does not assign the work bead to CV_WORK_BEAD_OWNER (drifted from ${LIB}?)" >&2
    FAILURES=$((FAILURES+1))
  fi
  if grep -qE -- '\$\{?WORK_BEAD\}? --claim\b' "$SETUP_MD"; then
    echo "  FAIL: workflow block still claims WORK_BEAD under the caller's own identity (--claim regressed)" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: workflow block no longer claims WORK_BEAD under the caller's own identity"
  fi
else
  echo "  FAIL: setup-con-voyage-review.md not found at ${SETUP_MD}" >&2
  FAILURES=$((FAILURES+1))
fi

# ---------------------------------------------------------------------------
# cv_text_has_interactive_prompt_stall (fk-6kvnt item 2/3: a fixture pane
# frame carrying the AskUserQuestion prompt footer must be detected, and a
# normal frame must not).
# ---------------------------------------------------------------------------
start_case "cv_text_has_interactive_prompt_stall: detects the AskUserQuestion footer in a captured pane fixture"
# Real footer text/order verified against the installed claude binary
# (v2.1.282): "to navigate" always precedes "Enter to select" — the reverse
# of this fixture's previous (buggy-matcher-derived) order.
PANE_FIXTURE_STALLED=$'? Proceed now?\n\n  1. Yes\n  2. No\n\n↑/↓ to navigate · Enter to select · Esc to close'
if cv_text_has_interactive_prompt_stall "$PANE_FIXTURE_STALLED"; then
  echo "  PASS: stalled pane fixture is detected"
else
  echo "  FAIL: stalled pane fixture was NOT detected" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "cv_text_has_interactive_prompt_stall: a normal pane frame is never a false positive"
PANE_FIXTURE_NORMAL=$'Running tests...\n5 passed, 0 failed\n$ '
if cv_text_has_interactive_prompt_stall "$PANE_FIXTURE_NORMAL"; then
  echo "  FAIL: normal pane fixture was incorrectly detected as stalled" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: normal pane fixture is not detected"
fi

# ---------------------------------------------------------------------------
# cv_text_has_usage_limit_stall (fk-7ba34: a captured pane frame carrying the
# real provider usage-limit banner must be detected, in both its initial and
# repeat-after-continue forms; a normal frame must not).
# ---------------------------------------------------------------------------
start_case "cv_text_has_usage_limit_stall: detects the initial usage-limit banner in a captured pane fixture"
PANE_FIXTURE_USAGE_LIMIT=$'Usage limit reached · continuing automatically at 6:10am · esc or type to cancel'
if cv_text_has_usage_limit_stall "$PANE_FIXTURE_USAGE_LIMIT"; then
  echo "  PASS: initial usage-limit banner fixture is detected"
else
  echo "  FAIL: initial usage-limit banner fixture was NOT detected" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "cv_text_has_usage_limit_stall: detects the repeat-after-continue banner variant"
PANE_FIXTURE_USAGE_LIMIT_AGAIN=$'Usage limit reached again after you continued · continuing automatically at 4:30pm · the automatic-continue setting no longer ends the session'
if cv_text_has_usage_limit_stall "$PANE_FIXTURE_USAGE_LIMIT_AGAIN"; then
  echo "  PASS: repeat usage-limit banner fixture is detected"
else
  echo "  FAIL: repeat usage-limit banner fixture was NOT detected" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "cv_text_has_usage_limit_stall: a normal pane frame is never a false positive"
if cv_text_has_usage_limit_stall "$PANE_FIXTURE_NORMAL"; then
  echo "  FAIL: normal pane fixture was incorrectly detected as a usage-limit stall" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: normal pane fixture is not detected"
fi

# ---------------------------------------------------------------------------
# cv_lane_has_open_blocking_dependency (fk-7ba34 DEFECT 1: a review-lane bead
# with an open "blocks" dependency is not ready, regardless of any other
# dependency type or status).
# ---------------------------------------------------------------------------
start_case "cv_lane_has_open_blocking_dependency: an open 'blocks' dependency is not ready"
export STUB_BDSHOW_JSON_fk_notready1='[{"id":"fk-notready1","dependencies":[{"id":"fk-build","dependency_type":"blocks","status":"open"}]}]'
if cv_lane_has_open_blocking_dependency "fk-notready1"; then
  echo "  PASS: an open blocking dependency is detected"
else
  echo "  FAIL: expected an open blocking dependency to be detected" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "cv_lane_has_open_blocking_dependency: every 'blocks' dependency closed -> ready"
export STUB_BDSHOW_JSON_fk_ready1='[{"id":"fk-ready1","dependencies":[{"id":"fk-build","dependency_type":"blocks","status":"closed"}]}]'
if cv_lane_has_open_blocking_dependency "fk-ready1"; then
  echo "  FAIL: a fully-closed blocking dependency was incorrectly treated as not ready" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: a closed blocking dependency is ready"
fi

start_case "cv_lane_has_open_blocking_dependency: no dependencies at all -> ready"
export STUB_BDSHOW_JSON_fk_ready2='[{"id":"fk-ready2","dependencies":[]}]'
if cv_lane_has_open_blocking_dependency "fk-ready2"; then
  echo "  FAIL: a lane with no dependencies was incorrectly treated as not ready" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: no dependencies at all is ready"
fi

start_case "cv_lane_has_open_blocking_dependency: an open 'tracks' (non-blocks) dependency is ignored"
export STUB_BDSHOW_JSON_fk_ready3='[{"id":"fk-ready3","dependencies":[{"id":"fk-other","dependency_type":"tracks","status":"open"}]}]'
if cv_lane_has_open_blocking_dependency "fk-ready3"; then
  echo "  FAIL: a non-blocks dependency type must never gate readiness" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: an open non-blocks dependency does not affect readiness"
fi

start_case "cv_lane_has_open_blocking_dependency: fail-safe — unknown bead treated as NOT ready"
# No STUB_BDSHOW_JSON_* for this id => empty `bd show` output => fail-safe.
if cv_lane_has_open_blocking_dependency "fk-unknown-lane"; then
  echo "  PASS: an unresolvable lane fails safe to 'not ready' (no action taken)"
else
  echo "  FAIL: expected a bd-show lookup failure to fail safe to 'not ready'" >&2
  FAILURES=$((FAILURES+1))
fi

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
# cv_default_state_dir (fk-mr07): the default CV_STATE_DIR base every caller
# falls back to when it does not set CV_STATE_DIR explicitly. GC_CITY is the
# multi-rig CITY root, not any one rig's own root -- defaulting to it (the
# pre-fix behavior) let con-voyage's publish step and the finalize/pr-watch/
# repair-watchdog monitors independently compute two disagreeing paths
# whenever one happened to run in a context that did not have CV_STATE_DIR
# pre-scoped to the rig (confirmed live: PR #59's finalize record landed at
# the city root this way and sat orphaned until moved by hand).
# ---------------------------------------------------------------------------
start_case "cv_default_state_dir: prefers GC_RIG_ROOT when set"
GC_RIG_ROOT_SAVE="${GC_RIG_ROOT:-}"
GC_RIG_ROOT="${SANDBOX}/rig-root"
result="$(cv_default_state_dir)"
assert_eq "${SANDBOX}/rig-root/.gc/cv-pr-watch" "$result" "GC_RIG_ROOT wins over GC_CITY"

start_case "cv_default_state_dir: falls back to walking up from cwd for a .beads marker when GC_RIG_ROOT is unset"
unset GC_RIG_ROOT
mkdir -p "${SANDBOX}/walkup-rig/.beads" "${SANDBOX}/walkup-rig/worktrees/nested/deep"
# Resolve RIGDIR through a real cd+pwd round-trip so it is normalized the
# same way $PWD is inside cv_default_state_dir itself — SANDBOX (built from
# $TMPDIR) can carry a redundant "//" that only one side would otherwise
# collapse, producing a false mismatch.
RIGDIR="$(cd "${SANDBOX}/walkup-rig" && pwd)"
result="$(cd "${RIGDIR}/worktrees/nested/deep" && cv_default_state_dir)"
assert_eq "${RIGDIR}/.gc/cv-pr-watch" "$result" "walks up to the nearest .beads-marked rig root"

start_case "cv_default_state_dir: falls back to GC_CITY when neither signal is available"
NOMARKERDIR="${SANDBOX}/no-marker-zone"
mkdir -p "$NOMARKERDIR"
result="$(cd "$NOMARKERDIR" && cv_default_state_dir)"
assert_eq "${GC_CITY}/.gc/cv-pr-watch" "$result" "last-resort fallback to GC_CITY preserves prior behavior"

if [ -n "$GC_RIG_ROOT_SAVE" ]; then
  GC_RIG_ROOT="$GC_RIG_ROOT_SAVE"
else
  unset GC_RIG_ROOT
fi

# ---------------------------------------------------------------------------
# cv_extra_rig_state_dirs (fk-2c937 review, LOW-A/C/D/E): direct unit coverage
# for the helper con-voyage-finalize.sh uses to learn about every registered
# rig's ".gc/cv-pr-watch" directory from "${GC_CITY}/.gc/site.toml". Previously
# only exercised end-to-end (con-voyage-finalize.test.sh CASE 29/30), each with
# exactly one registered rig never equal to the primary dir — leaving
# multi-rig scanning and skip-primary dedup untested in isolation (the
# reviewers' own LOW-1/LOW findings). GC_CITY is swapped to a private
# sandbox dir for these cases and restored after, so no fixture here leaks
# into the "cv_default_state_dir" cases above or the zsh cases below.
# ---------------------------------------------------------------------------
GC_CITY_SAVE="$GC_CITY"
GC_CITY="${SANDBOX}/cv-extra-rig-city"
mkdir -p "${GC_CITY}/.gc"

start_case "cv_extra_rig_state_dirs: multi-rig site.toml yields every registered rig's dir except the primary"
RIG_A="${SANDBOX}/multi-rig-a"
RIG_B="${SANDBOX}/multi-rig-b"
RIG_C="${SANDBOX}/multi-rig-c"
cat > "${GC_CITY}/.gc/site.toml" <<SITE_TOML
workspace_name = "test-city"

[[rig]]
name = "rig-a"
path = "${RIG_A}"

[[rig]]
name = "rig-b"
path = "${RIG_B}"

[[rig]]
name = "rig-c"
path = "${RIG_C}"
SITE_TOML
result="$(cv_extra_rig_state_dirs "${RIG_C}/.gc/cv-pr-watch" 2>/dev/null | sort)"
expected="$(printf '%s\n%s' "${RIG_A}/.gc/cv-pr-watch" "${RIG_B}/.gc/cv-pr-watch" | sort)"
assert_eq "$expected" "$result" "multi-rig scanning + skip-primary dedup in one pass (rig-c's dir equals the passed-in primary)"

start_case "cv_extra_rig_state_dirs: missing site.toml -> nothing, fail-soft, no warning"
rm -f "${GC_CITY}/.gc/site.toml"
result="$(cv_extra_rig_state_dirs "${SANDBOX}/whatever/.gc/cv-pr-watch" 2>/dev/null)"
assert_eq "" "$result" "no site.toml at all prints nothing"
stderr_out="$(cv_extra_rig_state_dirs "${SANDBOX}/whatever/.gc/cv-pr-watch" 2>&1 >/dev/null)"
assert_eq "" "$stderr_out" "a missing site.toml is the ordinary/expected case, not degradation -- no warning"

start_case "cv_extra_rig_state_dirs: site.toml present but zero [[rig]] blocks -> nothing, warns on stderr (LOW-E)"
cat > "${GC_CITY}/.gc/site.toml" <<SITE_TOML
workspace_name = "test-city"
SITE_TOML
result="$(cv_extra_rig_state_dirs "${SANDBOX}/whatever/.gc/cv-pr-watch" 2>/dev/null)"
assert_eq "" "$result" "zero [[rig]] blocks prints nothing"
stderr_out="$(cv_extra_rig_state_dirs "${SANDBOX}/whatever/.gc/cv-pr-watch" 2>&1 >/dev/null)"
case "$stderr_out" in
  *WARNING*) echo "  PASS: warns on stderr so a silently-degraded parse is distinguishable from a missing file" ;;
  *) echo "  FAIL: expected a stderr WARNING when site.toml exists but yields zero rig paths (got: '$stderr_out')" >&2; FAILURES=$((FAILURES+1)) ;;
esac

start_case "cv_extra_rig_state_dirs: single-quoted TOML path value is parsed like the double-quoted form (LOW-D)"
RIG_Q="${SANDBOX}/single-quoted-rig"
cat > "${GC_CITY}/.gc/site.toml" <<SITE_TOML
[[rig]]
name = "quoted"
path = '${RIG_Q}'
SITE_TOML
result="$(cv_extra_rig_state_dirs "${SANDBOX}/other/.gc/cv-pr-watch" 2>/dev/null)"
assert_eq "${RIG_Q}/.gc/cv-pr-watch" "$result" "single-quoted path = '...' is parsed, not silently dropped"

start_case "cv_extra_rig_state_dirs: a bare/unquoted path value is skipped, not emitted as garbage"
cat > "${GC_CITY}/.gc/site.toml" <<SITE_TOML
[[rig]]
name = "bare"
path = /no/quotes/here
SITE_TOML
result="$(cv_extra_rig_state_dirs "${SANDBOX}/other/.gc/cv-pr-watch" 2>/dev/null)"
assert_eq "" "$result" "an unquoted value is dropped rather than turned into a bogus directory entry"

GC_CITY="$GC_CITY_SAVE"

# ---------------------------------------------------------------------------
# pr_finalize_state: CV_GH_TIMEOUT_SECONDS bounds a hung `gh pr view` (fk-2c937
# review, SRE LOW-2) — previously unbounded, so one stalled poll (GitHub
# partition, gh auth re-prompt, rate-limit stall) blocked this monitor's
# entire sweep with no cap, and the fk-2c937 diff now runs that same poll
# once per registered rig in a single pass, amplifying the blast radius. A
# missing `timeout`/`gtimeout` binary degrades to the prior unwrapped
# behavior (fail soft, matching this file's posture) rather than a hard
# dependency -- the enforcement case below is skipped, not failed, on a host
# with neither installed.
# ---------------------------------------------------------------------------
GH_SAVE="$GH"
HANG_GH="${STUBDIR}/gh-hang"
cat > "$HANG_GH" <<'HANG_STUB'
#!/usr/bin/env bash
sleep 6
printf '{"state":"MERGED","mergedAt":"2026-01-01T00:00:00Z","closedAt":null}\n'
HANG_STUB
chmod +x "$HANG_GH"

if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  echo
  echo "SKIP: no timeout/gtimeout binary on this host, skipping the timeout-enforcement case" >&2
else
  start_case "pr_finalize_state: a hung gh pr view is bounded by CV_GH_TIMEOUT_SECONDS, not left to hang"
  GH="$HANG_GH"
  CV_GH_TIMEOUT_SECONDS=1
  start_ts=$(date +%s)
  result="$(pr_finalize_state "kriscoleman/foundry" "42")"
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  assert_eq "$(printf '\x1f\x1f')" "$result" "a killed gh call yields the SEP-only unresolved-state fallback, not the eventual MERGED body"
  if [ "$elapsed" -lt 4 ]; then
    echo "  PASS: returned in ${elapsed}s -- bounded by the 1s timeout, not the 6s hang"
  else
    echo "  FAIL: took ${elapsed}s -- the timeout was not enforced" >&2
    FAILURES=$((FAILURES+1))
  fi
  unset CV_GH_TIMEOUT_SECONDS
  GH="$GH_SAVE"
fi

start_case "pr_finalize_state: a fast/normal gh call is unaffected by the timeout wrapping (happy path)"
FAST_GH="${STUBDIR}/gh-fast"
cat > "$FAST_GH" <<'FAST_STUB'
#!/usr/bin/env bash
printf '{"state":"MERGED","mergedAt":"2026-01-01T00:00:00Z","closedAt":null}\n'
FAST_STUB
chmod +x "$FAST_GH"
GH="$FAST_GH"
result="$(pr_finalize_state "kriscoleman/foundry" "42")"
GH="$GH_SAVE"
IFS=$'\x1f' read -r fast_state _fast_merged _fast_closed <<< "$result"
assert_eq "MERGED" "$fast_state" "a normal, fast gh response still parses correctly whether or not it ran under a timeout wrapper"

# cv_default_rig_root (fk-4jdeh): the bare rig-root resolver cv_default_state_dir
# itself now builds on. A caller that needs the rig root ITSELF as an argument
# -- not a "<root>/.gc/cv-pr-watch" state-dir path -- must call this directly
# rather than stripping the suffix back off cv_default_state_dir's output or
# hand-copying the GC_RIG_ROOT/.beads-walkup/GC_CITY algorithm a third time.
# setup-con-voyage-review previously passed ${GC_CITY:-.} -- the multi-rig
# CITY root -- as the <rig-root> argument to cv-ensure-gate-scripts.sh and
# cv-ensure-build-artifact-validator.sh, both of which write to
# <rig-root>/.gc/...; harmless on a rig with those paths already hand-seeded
# under its city root by coincidence, but silently seeding the wrong
# directory on any rig without that lucky prior seeding.
# ---------------------------------------------------------------------------
start_case "cv_default_rig_root: prefers GC_RIG_ROOT when set"
GC_RIG_ROOT_SAVE="${GC_RIG_ROOT:-}"
GC_RIG_ROOT="${SANDBOX}/rig-root-bare"
result="$(cv_default_rig_root)"
assert_eq "${SANDBOX}/rig-root-bare" "$result" "GC_RIG_ROOT wins over GC_CITY, returned bare (no /.gc/cv-pr-watch suffix)"

start_case "cv_default_rig_root: falls back to walking up from cwd for a .beads marker when GC_RIG_ROOT is unset"
unset GC_RIG_ROOT
mkdir -p "${SANDBOX}/walkup-rig-bare/.beads" "${SANDBOX}/walkup-rig-bare/worktrees/nested/deep"
RIGDIR_BARE="$(cd "${SANDBOX}/walkup-rig-bare" && pwd)"
result="$(cd "${RIGDIR_BARE}/worktrees/nested/deep" && cv_default_rig_root)"
assert_eq "$RIGDIR_BARE" "$result" "walks up to the nearest .beads-marked rig root, returned bare"

start_case "cv_default_rig_root: falls back to GC_CITY when neither signal is available"
NOMARKERDIR_BARE="${SANDBOX}/no-marker-zone-bare"
mkdir -p "$NOMARKERDIR_BARE"
result="$(cd "$NOMARKERDIR_BARE" && cv_default_rig_root)"
assert_eq "${GC_CITY}" "$result" "last-resort fallback to GC_CITY, returned bare"

if [ -n "$GC_RIG_ROOT_SAVE" ]; then
  GC_RIG_ROOT="$GC_RIG_ROOT_SAVE"
else
  unset GC_RIG_ROOT
fi

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

# ---------------------------------------------------------------------------
# --city omission (fk-7v3r): bead_status/close_if_open/cv_bead_mark_in_progress/
# cv_bead_close/cv_resolve_work_bead/cv_bead_claim_non_routable must NOT pass
# --city on their bd calls — passing --city alone routed an already-rig-
# prefixed bead id to the CITY store instead of its owning rig's store, so bd
# show/close/update silently no-op'd against the wrong store ("Issue not
# found", swallowed by each helper's own fail-safe posture) and the bead
# never actually advanced. Omitting --city/--rig entirely lets gc's own
# cwd-based store auto-detection resolve the correct store instead (confirmed
# working in practice).
#
# fk-t2fsa: cv_bead_claim_non_routable (added by the parallel fk-9f2n fix)
# missed this file's own contract and shipped with --city still attached —
# the exact same bug class recurring in code added after fk-mr07's sweep,
# proving the contract needs a standing test per helper, not just a one-time
# audit.
# ---------------------------------------------------------------------------
start_case "bead_status: omits --city"
: > "$GC_LOG"
bead_status "rb-open" assignee >/dev/null 2>/dev/null
assert_log_count '--city' 0 "bead_status never passes --city"

start_case "close_if_open: omits --city on the underlying bd close"
: > "$GC_LOG"
close_if_open "rb-open" "landed: fix pushed" 2>/dev/null
assert_log_count '--city' 0 "close_if_open never passes --city"

start_case "cv_bead_mark_in_progress: omits --city"
: > "$GC_LOG"
cv_bead_mark_in_progress "rb-open" 2>/dev/null
assert_log_count '--city' 0 "cv_bead_mark_in_progress never passes --city"

start_case "cv_bead_close: omits --city"
: > "$GC_LOG"
cv_bead_close "rb-open" "landed" "fix pushed" 2>/dev/null
assert_log_count '--city' 0 "cv_bead_close never passes --city"

start_case "cv_resolve_work_bead: omits --city"
: > "$GC_LOG"
cv_resolve_work_bead "fk-2co" >/dev/null 2>/dev/null
assert_log_count '--city' 0 "cv_resolve_work_bead never passes --city"

start_case "cv_bead_work_dir: omits --city"
: > "$GC_LOG"
cv_bead_work_dir "fk-876om" >/dev/null 2>/dev/null
assert_log_count '--city' 0 "cv_bead_work_dir never passes --city"

start_case "cv_bead_claim_non_routable: omits --city"
: > "$GC_LOG"
cv_bead_claim_non_routable "rb-open" 2>/dev/null
assert_log_count '--city' 0 "cv_bead_claim_non_routable never passes --city"

# ---------------------------------------------------------------------------
# $GC unset -> defaults to "gc" on PATH, never a silent no-op (fk-v8hqr:
# follow-on from fk-4q6ib BLOCKING-2, which fixed this same bare-"$GC" pattern
# for cv_bead_metadata alone — con-voyage-lib.sh had ~11 more call sites doing
# the same thing, so any caller that forgot to set $GC before sourcing this
# file silently no-op'd instead of falling through to a real "gc" on PATH).
#
# Each case unsets $GC in a fresh subshell, puts the stub directory on PATH so
# a bare "gc" resolves to it, sources the lib there, and proves the call still
# reaches the stub. Before the fix, `"$GC" ...` with $GC empty tries to run a
# command literally named "" — that never touches PATH or the stub, so
# STUB_GC_LOG stays empty for that call instead of recording it.
# ---------------------------------------------------------------------------
start_case "cv_convoy_target: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; cv_convoy_target 'fk-gcuconvoy'" >/dev/null 2>/dev/null
assert_log_count 'convoy status fk-gcuconvoy --json' 1 "a caller that forgets to set \$GC still reaches gc convoy status"

start_case "bead_status: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; bead_status 'rb-open' assignee" >/dev/null 2>/dev/null
assert_log_count 'bd show rb-open --json' 1 "a caller that forgets to set \$GC still reaches gc bd show"

start_case "implementor_alive: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" GC_CITY="$GC_CITY" bash -c "unset GC; source '$LIB'; implementor_alive 'gc__gap-analyst-rc-1'" >/dev/null 2>/dev/null
assert_log_count 'session list --json' 1 "a caller that forgets to set \$GC still reaches gc session list"

start_case "session_id_for_ident: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" GC_CITY="$GC_CITY" bash -c "unset GC; source '$LIB'; session_id_for_ident 'gc__gap-analyst-rc-1'" >/dev/null 2>/dev/null
assert_log_count 'session list --json' 1 "a caller that forgets to set \$GC still reaches gc session list"

start_case "first_alive_session_id_for_route: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" GC_CITY="$GC_CITY" bash -c "unset GC; source '$LIB'; first_alive_session_id_for_route 'foundry-kc/gc.gap-analyst'" >/dev/null 2>/dev/null
assert_log_count 'session list --json' 1 "a caller that forgets to set \$GC still reaches gc session list"

start_case "close_if_open: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; close_if_open 'rb-open' 'landed: x'" >/dev/null 2>/dev/null
assert_log_count 'bd close rb-open' 1 "a caller that forgets to set \$GC still reaches gc bd close"

start_case "cv_bead_mark_in_progress: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; cv_bead_mark_in_progress 'rb-open'" >/dev/null 2>/dev/null
assert_log_count 'bd update rb-open --claim' 1 "a caller that forgets to set \$GC still claims the bead"

start_case "cv_bead_close: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; cv_bead_close 'rb-open' 'landed' 'fix pushed'" >/dev/null 2>/dev/null
assert_log_count 'bd close rb-open --reason landed: fix pushed' 1 "a caller that forgets to set \$GC still closes the bead"

start_case "cv_resolve_work_bead: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), resolves the tracked work bead instead of a silent fail-safe to the input"
export STUB_BDSHOW_JSON_fk_gcuwb='{"id":"fk-gcuwb","issue_type":"convoy","metadata":{"gc.synthetic":"true"},"dependencies":[{"id":"fk-gcuwb-real","dependency_type":"tracks"}]}'
result="$(PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; cv_resolve_work_bead 'fk-gcuwb'" 2>/dev/null)"
assert_eq "fk-gcuwb-real" "$result" "a caller that forgets to set \$GC still resolves the tracked work bead"

start_case "cv_bead_work_dir: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), reads the real work_dir instead of a silent empty"
export STUB_BDSHOW_JSON_fk_gcuwd='{"id":"fk-gcuwd","metadata":{"work_dir":"/rig/worktrees/fk-gcuwd"}}'
result="$(PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; cv_bead_work_dir 'fk-gcuwd'" 2>/dev/null)"
assert_eq "/rig/worktrees/fk-gcuwd" "$result" "a caller that forgets to set \$GC still reads the real work_dir"

start_case "cv_bead_claim_non_routable: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; cv_bead_claim_non_routable 'rb-open'" >/dev/null 2>/dev/null
assert_log_count "bd update rb-open --assignee ${CV_WORK_BEAD_OWNER} --status in_progress" 1 "a caller that forgets to set \$GC still claims the bead under the non-routable owner identity"

# ---------------------------------------------------------------------------
# close_if_open: CV_CLOSE_RC / exit-status handling (fk-7v3r COMPOUNDING fix —
# a swallowed `bd close` failure used to let con-voyage-finalize.sh delete its
# own retry record right after, self-destructing the idempotent-retry safety
# net on the very first close failure).
# ---------------------------------------------------------------------------
start_case "close_if_open: empty bead id -> CV_CLOSE_RC=0 (no-op), no bd call"
: > "$GC_LOG"
close_if_open "" "landed: x" 2>/dev/null
assert_eq "0" "$CV_CLOSE_RC" "empty id reports rc=0 (no-op)"
assert_log_count 'bd close' 0 "empty id never calls bd close"

start_case "close_if_open: already-closed bead -> CV_CLOSE_RC=0 (no-op), no bd call"
: > "$GC_LOG"
close_if_open "rb-closed" "landed: x" 2>/dev/null
assert_eq "0" "$CV_CLOSE_RC" "already-closed bead reports rc=0 (no-op)"
assert_log_count 'bd close' 0 "already-closed bead never calls bd close"

start_case "close_if_open: open bead, bd close succeeds -> CV_CLOSE_RC=0"
: > "$GC_LOG"
close_if_open "rb-open" "landed: x" 2>/dev/null
assert_eq "0" "$CV_CLOSE_RC" "a successful close reports rc=0"
assert_log_count 'bd close rb-open' 1 "bd close was attempted"

start_case "close_if_open: open bead, bd close FAILS -> CV_CLOSE_RC is non-zero, exit status not swallowed"
: > "$GC_LOG"
export STUB_BDCLOSE_FAIL_rb_open=1
close_if_open "rb-open" "landed: x" 2>/dev/null
assert_eq "1" "$CV_CLOSE_RC" "a failed close reports the real (non-zero) exit status instead of swallowing it"
unset STUB_BDCLOSE_FAIL_rb_open

start_case "close_if_open: bd close failure still returns 0 from the function itself (never aborts a set -e caller)"
rc=0
export STUB_BDCLOSE_FAIL_rb_open=1
close_if_open "rb-open" "landed: x" 2>/dev/null || rc=$?
unset STUB_BDCLOSE_FAIL_rb_open
assert_eq "0" "$rc" "close_if_open's own return code stays 0 even on a bd close failure (con-voyage-pr-watch.sh calls this under set -e as a bare statement)"

# ---------------------------------------------------------------------------
# cv_with_timeout (fk-rri7q LOW-D): portable poll+kill call bound for hosts
# with no `timeout(1)` binary. CASE "kill" uses a REAL sleep and a REAL
# wall-clock measurement — proving an actual process was actually killed,
# not just that the logic looks right on paper. The hung fixture is a plain
# `sleep` (not `sh -c 'sleep N; ...'`): every real caller in this pack wraps a
# single external binary directly, matching cv_with_timeout's own documented
# grandchild-process limitation, and a shell-wrapped grandchild would still
# outlive the kill regardless of what this test is trying to prove here.
# ---------------------------------------------------------------------------
start_case "cv_with_timeout: a command that finishes within the bound passes through output and exit status"
out="$(cv_with_timeout 5 sh -c 'printf ok; exit 3')"
rc=$?
assert_eq "ok" "$out" "stdout passes through unchanged"
assert_eq "3" "$rc" "the command's own exit status passes through unchanged"

start_case "cv_with_timeout: a hung command is killed at the bound, not left to run to completion"
t0=$(date +%s)
out="$(cv_with_timeout 1 sleep 20)"
rc=$?
t1=$(date +%s)
elapsed=$((t1 - t0))
assert_eq "124" "$rc" "a killed command reports 124 (matching the timeout(1) convention)"
if [ "$elapsed" -lt 10 ]; then
  echo "  PASS: returned in ${elapsed}s — well before the hung command's own 20s sleep (real kill, not just correct-looking logic)"
else
  echo "  FAIL: took ${elapsed}s — the bound did not actually cut the hung command short" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "cv_with_timeout: a malformed SECONDS runs the command with no bound (fail-open on bad config)"
out="$(cv_with_timeout not-a-number echo hi)"
assert_eq "hi" "$out" "a non-numeric bound still runs the command and returns its output"

start_case "cv_with_timeout: an empty SECONDS runs the command with no bound"
out="$(cv_with_timeout '' echo hi)"
assert_eq "hi" "$out" "an empty bound still runs the command and returns its output"

start_case "cv_with_timeout: a zero/negative SECONDS runs the command with no bound"
out="$(cv_with_timeout 0 echo hi)"
assert_eq "hi" "$out" "a zero bound still runs the command and returns its output"

start_case "cv_with_timeout: a fast command returns promptly, not after the full bound"
t0=$(date +%s)
out="$(cv_with_timeout 20 echo fast)"
t1=$(date +%s)
elapsed=$((t1 - t0))
assert_eq "fast" "$out" "output passes through"
if [ "$elapsed" -lt 5 ]; then
  echo "  PASS: returned in ${elapsed}s — did not wait for the full 20s bound"
else
  echo "  FAIL: took ${elapsed}s — a fast command should not be held up by the polling bound" >&2
  FAILURES=$((FAILURES+1))
fi

# ---------------------------------------------------------------------------
# cv_ensure_current_copy (fk-6z17l review hardening, fk-elkyf synthesis LOW
# findings #1/#2/#4 — mktemp over a PID suffix, refuse a symlinked
# destination, and be the ONE shared implementation cv-ensure-gate-scripts.sh
# and cv-ensure-build-artifact-validator.sh both call instead of each
# carrying 3 near-identical copies of this sequence).
# ---------------------------------------------------------------------------
CP_SANDBOX="${SANDBOX}/ensure-current-copy"
mkdir -p "$CP_SANDBOX"

start_case "cv_ensure_current_copy: destination missing -> seeds it, echoes 'seeded'"
printf 'pack content\n' > "${CP_SANDBOX}/src1"
DEST1="${CP_SANDBOX}/dest1"
out="$(cv_ensure_current_copy "${CP_SANDBOX}/src1" "$DEST1")"; rc=$?
assert_eq "0" "$rc" "exit 0 seeding a missing destination"
assert_eq "seeded" "$out" "echoes 'seeded' for a missing destination"
assert_eq "pack content" "$(cat "$DEST1" 2>/dev/null)" "destination content matches source after seeding"
if [ -e "${DEST1}.prev" ]; then
  echo "  FAIL: a fresh seed should never create a .prev backup" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: no .prev backup created for a fresh seed"
fi

start_case "cv_ensure_current_copy: destination already identical -> true no-op, echoes 'current'"
printf 'pack content\n' > "${CP_SANDBOX}/src2"
DEST2="${CP_SANDBOX}/dest2"
printf 'pack content\n' > "$DEST2"
before_mtime="$(cd "$CP_SANDBOX" && stat -f '%m' dest2 2>/dev/null || stat -c '%Y' dest2 2>/dev/null)"
out="$(cv_ensure_current_copy "${CP_SANDBOX}/src2" "$DEST2")"; rc=$?
assert_eq "0" "$rc" "exit 0 when content already matches"
assert_eq "current" "$out" "echoes 'current' when content already matches"
if [ -e "${DEST2}.prev" ]; then
  echo "  FAIL: an already-current destination should never get a .prev backup" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: no .prev backup created for an already-current destination"
fi

start_case "cv_ensure_current_copy: destination stale -> replaced atomically, old content backed up, echoes 'updated'"
printf 'new pack content\n' > "${CP_SANDBOX}/src3"
DEST3="${CP_SANDBOX}/dest3"
printf 'old stale content\n' > "$DEST3"
out="$(cv_ensure_current_copy "${CP_SANDBOX}/src3" "$DEST3")"; rc=$?
assert_eq "0" "$rc" "exit 0 replacing a stale destination"
assert_eq "updated" "$out" "echoes 'updated' when stale content is replaced"
assert_eq "new pack content" "$(cat "$DEST3" 2>/dev/null)" "destination content matches source after replacement"
assert_eq "old stale content" "$(cat "${DEST3}.prev" 2>/dev/null)" "the stale content was backed up to <dest>.prev"

start_case "cv_ensure_current_copy: --exec sets the executable bit; omitting it does not"
printf '#!/bin/sh\necho hi\n' > "${CP_SANDBOX}/src4"
DEST4_EXEC="${CP_SANDBOX}/dest4-exec"
DEST4_DATA="${CP_SANDBOX}/dest4-data"
cv_ensure_current_copy "${CP_SANDBOX}/src4" "$DEST4_EXEC" --exec >/dev/null
cv_ensure_current_copy "${CP_SANDBOX}/src4" "$DEST4_DATA" >/dev/null
if [ -x "$DEST4_EXEC" ]; then echo "  PASS: --exec sets the executable bit"; else echo "  FAIL: --exec did not set the executable bit" >&2; FAILURES=$((FAILURES+1)); fi
if [ -x "$DEST4_DATA" ]; then echo "  FAIL: omitting --exec should not set the executable bit" >&2; FAILURES=$((FAILURES+1)); else echo "  PASS: omitting --exec leaves the executable bit unset"; fi

start_case "cv_ensure_current_copy: a symlinked destination is refused outright, never read through or replaced through (fk-eqhgl LOW finding #2)"
printf 'src content\n' > "${CP_SANDBOX}/src5"
TARGET5="${CP_SANDBOX}/secret-target5"
printf 'SECRET-TARGET-CONTENT\n' > "$TARGET5"
DEST5="${CP_SANDBOX}/dest5-symlink"
ln -s "$TARGET5" "$DEST5"
out="$(cv_ensure_current_copy "${CP_SANDBOX}/src5" "$DEST5" 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ]; then echo "  PASS: refuses (non-zero exit) when destination is a symlink"; else echo "  FAIL: should refuse a symlinked destination, got exit 0" >&2; FAILURES=$((FAILURES+1)); fi
assert_eq "" "$out" "nothing is echoed to stdout on refusal"
assert_eq "SECRET-TARGET-CONTENT" "$(cat "$TARGET5" 2>/dev/null)" "the symlink target's content is untouched"
if [ -e "${DEST5}.prev" ]; then
  echo "  FAIL: refusing up front must not leak the symlink target's content into a .prev file" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: no .prev file created — the target's content was never duplicated"
fi
if [ -L "$DEST5" ]; then echo "  PASS: the symlink itself is left exactly as it was"; else echo "  FAIL: the symlink should be untouched on refusal" >&2; FAILURES=$((FAILURES+1)); fi

start_case "cv_ensure_current_copy: a leftover .prev from an earlier run does not make a fresh seed misreport as 'updated'"
printf 'pack content\n' > "${CP_SANDBOX}/src6"
DEST6="${CP_SANDBOX}/dest6"
printf 'orphaned backup from a prior run\n' > "${DEST6}.prev"
out="$(cv_ensure_current_copy "${CP_SANDBOX}/src6" "$DEST6")"; rc=$?
assert_eq "0" "$rc" "exit 0 seeding a missing destination that has a stale sibling .prev file"
assert_eq "seeded" "$out" "still echoes 'seeded' (not 'updated') when the destination itself was missing"

# ---------------------------------------------------------------------------
# fk-jjumm review iteration 3 (BLOCKING-1): the taper's poll/waited accounting
# used to run through `awk`'s locale-aware `%.3f` formatting, so under a
# comma-decimal LC_NUMERIC the poll interval came out as e.g. "0,100" — a
# value `sleep` rejects outright. That turned the poll into a busy-spin that
# advanced `waited` on fork speed alone, timing healthy commands out well
# before the real bound. Only run this if the box actually has a
# comma-decimal locale installed; skip (not fail) otherwise, since locale
# availability varies by host/CI image and isn't itself what this case tests.
# ---------------------------------------------------------------------------
if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -i '^de_DE\.utf-\?8$' >/dev/null; then
  # A command that exits INSTANTLY never enters the poll loop at all (the
  # `kill -0` check already fails on the first pass), so it can't exercise
  # the poll/waited accounting this case targets. Wrap a real ~1s `sleep`
  # under a generous 30s bound instead — matching the synthesis's own
  # reproduction (`cv_with_timeout 30 'sleep 1'`) — so at least one full poll
  # iteration (and therefore the locale-sensitive arithmetic) actually runs.
  start_case "cv_with_timeout: a comma-decimal LC_NUMERIC locale does not busy-spin or false-timeout a healthy command"
  t0=$(date +%s)
  out="$(LC_ALL=de_DE.UTF-8 cv_with_timeout 30 sleep 1; echo "rc=$?")"
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  assert_eq "rc=0" "$out" "a healthy ~1s command under a generous 30s bound still succeeds, not falsely timed out (rc=124) by a locale-broken poll"
  if [ "$elapsed" -lt 10 ]; then
    echo "  PASS: returned in ${elapsed}s — not busy-spun to a false early timeout"
  else
    echo "  FAIL: took ${elapsed}s — expected a healthy ~1s command to return promptly, not be held up" >&2
    FAILURES=$((FAILURES+1))
  fi

  start_case "cv_with_timeout: a comma-decimal LC_NUMERIC locale still bounds a genuinely hung command"
  t0=$(date +%s)
  out="$(LC_ALL=de_DE.UTF-8 cv_with_timeout 1 sleep 20)"
  rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  assert_eq "124" "$rc" "a hung command is still killed and reported as a timeout under a comma-decimal locale"
  if [ "$elapsed" -lt 10 ]; then
    echo "  PASS: returned in ${elapsed}s — bounded, not a runaway busy-spin"
  else
    echo "  FAIL: took ${elapsed}s — expected the 1s bound to apply under this locale too" >&2
    FAILURES=$((FAILURES+1))
  fi
else
  echo "  SKIP: de_DE.UTF-8 locale not installed on this host; comma-decimal LC_NUMERIC case not exercised"
fi

# ---------------------------------------------------------------------------
# fk-i7d7b review iteration 4 (BLOCKING-1, qa-test): removing `awk` from the
# poll loop's taper accounting replaced it with bash's native `$(( ))`
# arithmetic, which applies C-style octal parsing to any leading-zero digit
# string — a rule `awk` never had. An operator-supplied "010" silently
# misparsed as octal (decimal 8, not 10), and "08" hard-crashed the
# arithmetic expansion AFTER the command was already backgrounded, orphaning
# it with no supervising poll loop ever entered. Forcing base-10 via `10#`
# fixes both without touching the taper algorithm itself.
# ---------------------------------------------------------------------------
start_case "cv_with_timeout: a leading-zero decimal bound (010) is read as decimal 10, not octal 8"
t0=$(date +%s)
out="$(cv_with_timeout 010 sleep 9; echo "rc=$?")"
t1=$(date +%s)
elapsed=$((t1 - t0))
assert_eq "rc=0" "$out" "a 9s command under a decimal-10s bound succeeds; under the octal bug '010' misreads as 8 and this would instead time out (rc=124) at ~8s"
if [ "$elapsed" -lt 15 ]; then
  echo "  PASS: returned in ${elapsed}s — bound read as decimal 10, not octal 8"
else
  echo "  FAIL: took ${elapsed}s — unexpectedly slow for a 9s command under a 10s bound" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "cv_with_timeout: a leading-zero bound with an 8/9 digit (08) does not crash or orphan the child"
out="$(cv_with_timeout 08 true 2>&1)"
rc=$?
assert_eq "0" "$rc" "no arithmetic error aborts the function before the command completes"
assert_eq "" "$out" "no stderr from a bad octal-literal arithmetic expansion ('08: value too great for base')"

# ---------------------------------------------------------------------------
# zsh portability (fk-k14n REWORK — operator PR comment + new bug report):
# `status` is a special/read-only parameter in zsh (it mirrors `$?`), so
# `local status` followed by an assignment (`status="$x"` or
# `read -r status ...`) throws "read-only variable: status" and ABORTS the
# function before it reaches its `bd update`/`bd close` call. Any agent whose
# configured shell is zsh (the Bash tool runs whichever shell the operator
# has configured — see CV_SHELL_SAFETY_REMINDER above) silently loses the
# bead-state-event update every time these helpers run, unless the caller
# happens to route through an explicit `bash <<EOF` workaround.
#
# These cases source the real lib into an actual zsh subprocess (not bash
# emulating zsh) and call each affected helper end-to-end against the SAME
# stub harness used above, asserting both "did not raise read-only variable"
# AND "the expected bd call actually landed" — a caught-but-swallowed abort
# would still show zero bd calls in the log, so the log assertion is the one
# that would have caught the bug even if zsh's error text ever changes.
# ---------------------------------------------------------------------------
if ! command -v zsh >/dev/null 2>&1; then
  echo
  echo "SKIP: zsh not installed on this host, skipping zsh portability cases" >&2
else
  start_case "cv_bead_mark_in_progress under zsh: open bead -> claims it (no read-only-variable abort)"
  : > "$GC_LOG"
  zsh_err="$(GC="$GC" GC_CITY="$GC_CITY" GH="$GH" CV_STATE_DIR="$CV_STATE_DIR" \
    zsh -c "source '$LIB'; cv_bead_mark_in_progress 'rb-open'" 2>&1 >/dev/null)"
  case "$zsh_err" in
    *"read-only variable"*)
      echo "  FAIL: cv_bead_mark_in_progress aborts under zsh: $zsh_err" >&2
      FAILURES=$((FAILURES+1)) ;;
    *)
      echo "  PASS: cv_bead_mark_in_progress raises no read-only-variable error under zsh" ;;
  esac
  assert_log_count 'bd update rb-open --claim' 1 "cv_bead_mark_in_progress under zsh still reaches bd update"

  start_case "cv_bead_close under zsh: open bead -> closes it (no read-only-variable abort)"
  : > "$GC_LOG"
  zsh_err="$(GC="$GC" GC_CITY="$GC_CITY" GH="$GH" CV_STATE_DIR="$CV_STATE_DIR" \
    zsh -c "source '$LIB'; cv_bead_close 'rb-open' 'landed' 'fix pushed'" 2>&1 >/dev/null)"
  case "$zsh_err" in
    *"read-only variable"*)
      echo "  FAIL: cv_bead_close aborts under zsh: $zsh_err" >&2
      FAILURES=$((FAILURES+1)) ;;
    *)
      echo "  PASS: cv_bead_close raises no read-only-variable error under zsh" ;;
  esac
  assert_log_count 'bd close rb-open --reason landed: fix pushed' 1 "cv_bead_close under zsh still reaches bd close"

  start_case "close_if_open under zsh: open bead -> closes it (no read-only-variable abort)"
  : > "$GC_LOG"
  zsh_err="$(GC="$GC" GC_CITY="$GC_CITY" GH="$GH" CV_STATE_DIR="$CV_STATE_DIR" \
    zsh -c "source '$LIB'; close_if_open 'rb-open' 'landed: x'" 2>&1 >/dev/null)"
  case "$zsh_err" in
    *"read-only variable"*)
      echo "  FAIL: close_if_open aborts under zsh: $zsh_err" >&2
      FAILURES=$((FAILURES+1)) ;;
    *)
      echo "  PASS: close_if_open raises no read-only-variable error under zsh" ;;
  esac
  assert_log_count 'bd close rb-open' 1 "close_if_open under zsh still reaches bd close"

  start_case "cv_extra_rig_state_dirs under zsh: multi-rig parsing + skip-primary dedup (fk-2c937 review — no word-splitting/quoting divergence)"
  ZSH_CITY="${SANDBOX}/cv-extra-rig-zsh-city"
  mkdir -p "${ZSH_CITY}/.gc"
  ZRIG_A="${SANDBOX}/zsh-rig-a"
  ZRIG_B="${SANDBOX}/zsh-rig-b"
  cat > "${ZSH_CITY}/.gc/site.toml" <<SITE_TOML
[[rig]]
name = "rig-a"
path = "${ZRIG_A}"

[[rig]]
name = "rig-b"
path = "${ZRIG_B}"
SITE_TOML
  zsh_result="$(GC_CITY="$ZSH_CITY" zsh -c "source '$LIB'; cv_extra_rig_state_dirs '${ZRIG_B}/.gc/cv-pr-watch'" 2>/dev/null | sort)"
  assert_eq "${ZRIG_A}/.gc/cv-pr-watch" "$zsh_result" "under zsh: rig-a's dir is printed, rig-b's is skipped as the passed-in primary"

  start_case "cv_with_timeout under zsh: passes through output/status and actually kills a hung command"
  zsh_out="$(zsh -c "source '$LIB'; cv_with_timeout 5 sh -c 'printf ok; exit 3'")"
  zsh_rc=$?
  assert_eq "ok" "$zsh_out" "cv_with_timeout under zsh passes through stdout"
  assert_eq "3" "$zsh_rc" "cv_with_timeout under zsh passes through the command's exit status"
  zsh_t0=$(date +%s)
  zsh -c "source '$LIB'; cv_with_timeout 1 sleep 20" >/dev/null 2>&1
  zsh_rc2=$?
  zsh_t1=$(date +%s)
  zsh_elapsed=$((zsh_t1 - zsh_t0))
  assert_eq "124" "$zsh_rc2" "cv_with_timeout under zsh reports 124 on a real kill"
  if [ "$zsh_elapsed" -lt 10 ]; then
    echo "  PASS: cv_with_timeout under zsh returned in ${zsh_elapsed}s, not the hung command's full 20s"
  else
    echo "  FAIL: cv_with_timeout under zsh took ${zsh_elapsed}s — the bound did not actually apply" >&2
    FAILURES=$((FAILURES+1))
  fi

  # acquire_lock/release_lock (fk-8b5fl): newly lifted into this file from
  # con-voyage-repair-watchdog.sh so con-voyage-pr-watch.sh can share the same
  # lock instead of duplicating it. Neither function's local variable names
  # collide with a zsh special parameter (unlike the `status` bug above), so
  # no abort is expected here — this case exists to prove that going forward,
  # not to hunt for one, per the same "any newly live-shell-sourced helper
  # gets the zsh treatment" precedent the other cases in this block follow.
  start_case "acquire_lock/release_lock under zsh: acquire creates the lock dir, release removes it (no read-only-variable abort)"
  ZSH_LOCK_DEDUP="zsh-lock-test-1"
  ZSH_LOCK_DIR="${CV_STATE_DIR}/.locks/${ZSH_LOCK_DEDUP}.lock"
  rm -rf "$ZSH_LOCK_DIR"
  zsh_err="$(CV_STATE_DIR="$CV_STATE_DIR" zsh -c "source '$LIB'; acquire_lock '${ZSH_LOCK_DEDUP}'" 2>&1 >/dev/null)"
  case "$zsh_err" in
    *"read-only"*)
      echo "  FAIL: acquire_lock aborts under zsh: $zsh_err" >&2
      FAILURES=$((FAILURES+1))
      ;;
    *)
      echo "  PASS: acquire_lock raises no read-only-variable error under zsh" ;;
  esac
  if [ -d "$ZSH_LOCK_DIR" ]; then
    echo "  PASS: acquire_lock under zsh actually created the lock directory on disk"
  else
    echo "  FAIL: acquire_lock under zsh did not create the expected lock directory" >&2
    FAILURES=$((FAILURES+1))
  fi

  CV_STATE_DIR="$CV_STATE_DIR" zsh -c "source '$LIB'; release_lock '${ZSH_LOCK_DEDUP}'"
  if [ -d "$ZSH_LOCK_DIR" ]; then
    echo "  FAIL: release_lock under zsh did not remove the lock directory" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: release_lock under zsh removed the lock directory"
  fi

  start_case "acquire_lock under zsh steals an already-stale lock instead of wedging forever"
  mkdir -p "$ZSH_LOCK_DIR"
  python3 -c "import os; os.utime('${ZSH_LOCK_DIR}', (0, 0))"
  zsh_steal_err="$(CV_STATE_DIR="$CV_STATE_DIR" CV_LOCK_STALE_SECONDS="300" zsh -c "source '$LIB'; acquire_lock '${ZSH_LOCK_DEDUP}'" 2>&1 >/dev/null)"
  zsh_steal_rc=$?
  assert_eq "0" "$zsh_steal_rc" "acquire_lock under zsh returns success after stealing an already-stale lock"
  case "$zsh_steal_err" in
    *"NOTICE: stole stale lock"*)
      echo "  PASS: acquire_lock under zsh logs the stale-lock steal NOTICE" ;;
    *)
      echo "  FAIL: expected a stale-lock steal NOTICE under zsh, got: $zsh_steal_err" >&2
      FAILURES=$((FAILURES+1))
      ;;
  esac
  rm -rf "$ZSH_LOCK_DIR" "${ZSH_LOCK_DIR}.stealing"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
