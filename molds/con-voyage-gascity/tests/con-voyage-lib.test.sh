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
# fk-16zsa iter-4: close_if_open's FORCE path is now behavior-based (it
# inspects bd's own refusal text rather than a status field), so three more
# vars simulate the real `bd close` refusal shapes it must tell apart:
#   STUB_BDCLOSE_ASSIGNEE_MISMATCH_<id>=1 — a plain (non-forced) close fails
#     with the real assignee-guard message ("...reclaim or use --force to
#     override"); a --force retry succeeds. This is the one refusal FORCE
#     is meant to override.
#   STUB_BDCLOSE_PIN_REFUSAL_<id>=1 / STUB_BDCLOSE_GATE_REFUSAL_<id>=1 — a
#     plain close fails with a refusal message that does NOT match the
#     assignee-guard text (a real pin or gate hold), so close_if_open must
#     never retry with --force.
# fk-16zsa iter-5: real `bd` returns the assignee-guard message FIRST even
# when a bead is ALSO pinned/gate-blocked, masking the pin/gate refusal
# entirely — so close_if_open now calls bead_pinned_or_blocked (`bd blocked
# --json` / `bd list --pinned --json`) as a second, independent check before
# trusting the assignee-guard text. STUB_BDBLOCKED_JSON / STUB_BDPINNED_JSON
# stand in for those two calls' JSON bodies (default `[]`, i.e. neither).
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
if [ "${args[$i]:-}" = "convoy" ] && [ "${args[$((i+1))]:-}" = "status" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_CONVOY_STATUS_JSON_${id//-/_}"
  printf '%s' "${!var:-}"
  exit 0
fi
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "close" ]; then
  id="${args[$((i+2))]:-}"
  has_force=0
  for a in "${args[@]:$((i+2))}"; do
    [ "$a" = "--force" ] && has_force=1
  done
  var="STUB_BDCLOSE_FAIL_${id//-/_}"
  if [ "${!var:-0}" = "1" ]; then
    exit 1
  fi
  # fk-0ks7ui (review fk-sku8km BLOCKING-1): simulates a hung `bd close` call
  # so a test can assert close_if_open's own cv_with_timeout wrap actually
  # bounds it, mirroring STUB_BDLIST_SWEEP_HANG_SECONDS below for the sweep's
  # `bd list` call.
  if [ -n "${STUB_BDCLOSE_HANG_SECONDS:-}" ]; then
    sleep "$STUB_BDCLOSE_HANG_SECONDS"
  fi
  var="STUB_BDCLOSE_ASSIGNEE_MISMATCH_${id//-/_}"
  if [ "${!var:-0}" = "1" ] && [ "$has_force" = "0" ]; then
    echo "Error: cannot close ${id}: assignee is \"someone\", actor is \"mayor\"; reclaim or use --force to override" >&2
    exit 1
  fi
  var="STUB_BDCLOSE_PIN_REFUSAL_${id//-/_}"
  if [ "${!var:-0}" = "1" ]; then
    echo "Error: cannot close ${id}: issue is pinned" >&2
    exit 1
  fi
  var="STUB_BDCLOSE_GATE_REFUSAL_${id//-/_}"
  if [ "${!var:-0}" = "1" ]; then
    echo "Error: cannot close ${id}: unsatisfied gate blocks closure" >&2
    exit 1
  fi
  # fk-dgia1g: STUB_BDCLOSE_FAIL_FIRST_N_<id>=N simulates a descendant
  # blocked by a SIBLING this same sweep hasn't closed yet — the first N
  # close attempts for this id fail, the (N+1)th succeeds, so
  # cv_close_workflow_root's multi-pass sweep has something real to
  # converge on (unlike STUB_BDCLOSE_FAIL_<id>, which fails every attempt
  # forever). Requires STUB_BDCLOSE_COUNTER_DIR for the per-id attempt count.
  var="STUB_BDCLOSE_FAIL_FIRST_N_${id//-/_}"
  fail_first_n="${!var:-0}"
  if [ "$fail_first_n" -gt 0 ] 2>/dev/null; then
    attempt=1
    if [ -n "${STUB_BDCLOSE_COUNTER_DIR:-}" ]; then
      mkdir -p "$STUB_BDCLOSE_COUNTER_DIR"
      counter_file="${STUB_BDCLOSE_COUNTER_DIR}/${id}"
      attempt=0
      [ -f "$counter_file" ] && attempt="$(cat "$counter_file")"
      attempt=$((attempt+1))
      echo "$attempt" > "$counter_file"
    fi
    if [ "$attempt" -le "$fail_first_n" ]; then
      echo "Error: cannot close ${id}: blocked by another issue in this tree" >&2
      exit 1
    fi
  fi
  exit 0
fi
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "blocked" ]; then
  printf '%s' "${STUB_BDBLOCKED_JSON:-[]}"
  exit 0
fi
if [ "${args[$i]:-}" = "rig" ] && [ "${args[$((i+1))]:-}" = "list" ]; then
  printf '%s' "${STUB_RIGLIST_JSON:-{\"rigs\":[]\}}"
  exit 0
fi
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "list" ]; then
  is_sweep=0
  for a in "${args[@]:$((i+2))}"; do
    [ "$a" = "--metadata-field" ] && is_sweep=1
  done
  if [ "$is_sweep" = "1" ]; then
    counter_file="${STUB_SWEEP_COUNTER_FILE:-/dev/null}"
    n=0
    if [ "$counter_file" != "/dev/null" ]; then
      [ -f "$counter_file" ] && n="$(cat "$counter_file")"
      n=$((n+1))
      echo "$n" > "$counter_file"
    fi
    # fk-tj3bih BLOCKING-2: simulates the sweep's bd list call itself
    # failing/timing out on pass $n (exit 1, nothing on stdout) — distinct
    # from STUB_BDLIST_SWEEP_JSON_<n>='[]', which is the call SUCCEEDING with
    # genuinely zero descendants.
    var="STUB_BDLIST_SWEEP_FAIL_${n}"
    if [ "${!var:-0}" = "1" ]; then
      exit 1
    fi
    # fk-tj3bih BLOCKING-3: simulates a hung sweep bd list call so a test can
    # assert cv_with_timeout actually bounds it instead of letting it run to
    # completion.
    if [ -n "${STUB_BDLIST_SWEEP_HANG_SECONDS:-}" ]; then
      sleep "$STUB_BDLIST_SWEEP_HANG_SECONDS"
    fi
    var="STUB_BDLIST_SWEEP_JSON_${n}"
    if [ -n "${!var+x}" ]; then
      printf '%s' "${!var}"
    else
      printf '%s' "${STUB_BDLIST_SWEEP_JSON_LAST:-[]}"
    fi
    exit 0
  fi
  printf '%s' "${STUB_BDPINNED_JSON:-[]}"
  exit 0
fi
if [ "${args[$i]:-}" = "session" ] && [ "${args[$((i+1))]:-}" = "list" ]; then
  printf '%s' "${STUB_SESSION_LIST_JSON:-{\"sessions\":[]\}}"
  exit 0
fi
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "update" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_BDUPDATE_FAIL_${id//-/_}"
  if [ "${!var:-0}" = "1" ]; then
    exit 1
  fi
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

# Default rig registry for cv_rig_for_bead_id (fk-dgia1g): every bead id this
# suite uses is fk-*, resolving to a single "foundry-kc" rig, so cases that
# don't care about rig resolution get it for free without per-case setup.
export STUB_RIGLIST_JSON='{"rigs":[{"name":"foundry-kc","prefix":"fk"}]}'

# Per-pass descendant-listing counter for cv_close_workflow_root's sweep
# (fk-dgia1g): each "bd list --metadata-field ..." call increments this file
# and the stub serves STUB_BDLIST_SWEEP_JSON_<n> for that pass, falling back
# to STUB_BDLIST_SWEEP_JSON_LAST (default "[]", i.e. "nothing left open") once
# a case stops defining later-pass vars — a static single-pass case only ever
# needs to set _1. Reset (rm -f) at the top of every case that exercises the
# sweep so pass numbering starts fresh.
export STUB_SWEEP_COUNTER_FILE="${SANDBOX}/sweep_count"

# Per-id close-attempt counter directory for STUB_BDCLOSE_FAIL_FIRST_N_<id>
# (fk-dgia1g) — see the stub's "bd close" handler above.
export STUB_BDCLOSE_COUNTER_DIR="${SANDBOX}/close_counts"

# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}
assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (not found in output)"; fi
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

# fk-9f2n loop variant (fk-hua0vl.ci-repair bead-id placeholder; actual bug
# bead fk-tvefk0): main.rereview-seed.md stamps gc.build.source_anchor_id to
# ITS OWN graph.v2 step bead (it has gc.step_ref/gc.routed_to/gc.root_bead_id,
# never gc.synthetic or issue_type=convoy). Before this fix, that bead fell
# through to "not a convoy: echo input", so the caller (setup-con-voyage-
# review.md) claimed/reassigned the closed step bead itself and re-triggered
# the dispatch loop. A graph.v2 step bead must resolve via the PR's finalize
# record instead (keyed by the workflow root's gc.var.finalize_key).
start_case "cv_resolve_work_bead: graph.v2 step bead (re-review seed) -> resolves via finalize record"
export STUB_BDSHOW_JSON_step_1='{"id":"step-1","issue_type":"task","metadata":{"gc.step_ref":"con-voyage.rereview-seed","gc.routed_to":"foundry-kc/gc.implementation-worker","gc.root_bead_id":"root-1"}}'
export STUB_BDSHOW_JSON_root_1='{"id":"root-1","issue_type":"task","metadata":{"gc.var.finalize_key":"cv-finalize-owner-repo-170"}}'
finalize_write "cv-finalize-owner-repo-170" "real-wb-1" "orig-convoy-1" "owner/repo" "170" "kriscoleman" "" ""
assert_eq "real-wb-1" "$(cv_resolve_work_bead "step-1")" "a graph.v2 step bead resolves to the finalize record's real work_bead, never itself"

start_case "cv_resolve_work_bead: graph.v2 step bead with no resolvable finalize record -> fail-safe to input"
export STUB_BDSHOW_JSON_step_2='{"id":"step-2","issue_type":"task","metadata":{"gc.step_ref":"con-voyage.rereview-seed","gc.root_bead_id":"root-2"}}'
# No STUB_BDSHOW_JSON_root_2 -> root bd show "fails" -> no finalize_key resolvable.
assert_eq "step-2" "$(cv_resolve_work_bead "step-2")" "a step bead whose finalize record cannot be resolved fails safe to the input id (never guesses)"

# review fk-up9s4z BLOCKING-1 (QA lane): gc.step_ref/gc.routed_to/gc.root_bead_id
# are leftover breadcrumbs a dispatched task can carry from an EARLIER,
# unrelated graph.v2 run even after it's an ordinary work bead again. Before
# this fix, the step-bead branch above triggered on gc.routed_to OR
# gc.root_bead_id alone, so a stale gc.root_bead_id pointing at a different
# root that itself has a resolvable gc.var.finalize_key would silently
# resolve this bead to that UNRELATED root's work_bead instead of leaving it
# alone. Only gc.step_ref is stamped exclusively on an actual graph.v2
# workflow step bead, so the heuristic must require it specifically.
start_case "cv_resolve_work_bead: ordinary task bead with stale gc.root_bead_id (no gc.step_ref) -> itself, never the unrelated root's work_bead"
export STUB_BDSHOW_JSON_fk_stale='{"id":"fk-stale","issue_type":"task","metadata":{"gc.root_bead_id":"root-unrelated"}}'
export STUB_BDSHOW_JSON_root_unrelated='{"id":"root-unrelated","issue_type":"task","metadata":{"gc.var.finalize_key":"cv-finalize-owner-repo-999"}}'
finalize_write "cv-finalize-owner-repo-999" "unrelated-wb" "orig-convoy-999" "owner/repo" "999" "kriscoleman" "" ""
assert_eq "fk-stale" "$(cv_resolve_work_bead "fk-stale")" "a stale gc.root_bead_id with no gc.step_ref must not resolve through an unrelated root's finalize record"

# fk-gnb3m6 (review fk-hbsmk BLOCKING-1): the step-bead branch above reads the
# finalize record through finalize_read, which reads
# "${CV_STATE_DIR}/<dedup_key>.finalize". Every other finalize_read caller
# defaults CV_STATE_DIR via cv_default_state_dir before calling it; this test
# unsets CV_STATE_DIR entirely (unlike every case above, which runs under the
# sandbox's exported CV_STATE_DIR) to prove cv_resolve_work_bead defaults it
# itself instead of relying on an ambient global happening to be set.
start_case "cv_resolve_work_bead: graph.v2 step bead resolves via finalize record even with CV_STATE_DIR unset"
export STUB_BDSHOW_JSON_step_3='{"id":"step-3","issue_type":"task","metadata":{"gc.step_ref":"con-voyage.rereview-seed","gc.routed_to":"foundry-kc/gc.implementation-worker","gc.root_bead_id":"root-3"}}'
export STUB_BDSHOW_JSON_root_3='{"id":"root-3","issue_type":"task","metadata":{"gc.var.finalize_key":"cv-finalize-owner-repo-171"}}'
UNSET_STATE_DIR_RIG="${SANDBOX}/unset-state-dir-rig"
mkdir -p "${UNSET_STATE_DIR_RIG}/.gc/cv-pr-watch"
CV_STATE_DIR="${UNSET_STATE_DIR_RIG}/.gc/cv-pr-watch" \
  finalize_write "cv-finalize-owner-repo-171" "real-wb-3" "orig-convoy-3" "owner/repo" "171" "kriscoleman" "" ""
result="$(PATH="${STUBDIR}:${PATH}" GC_RIG_ROOT="$UNSET_STATE_DIR_RIG" bash -c "
unset GC CV_STATE_DIR
source '$LIB'
cv_resolve_work_bead 'step-3'
" 2>/dev/null)"
assert_eq "real-wb-3" "$result" "a graph.v2 step bead resolves via the finalize record even when the caller never set CV_STATE_DIR"

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

start_case "cv_bead_metadata: \$GC unset -> defaults to literal \"gc\" on PATH, not a silent no-op (fk-4q6ib BLOCKING-2: main.publish.md called this helper without setting \$GC first)"
export STUB_BDSHOW_JSON_fk_metagc='{"id":"fk-metagc","metadata":{"gc.var.convoy_id":"fk-hd0xv"}}'
gc_unset_result="$(PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; cv_bead_metadata 'fk-metagc' 'gc.var.convoy_id'")"
assert_eq "fk-hd0xv" "$gc_unset_result" "a caller that forgets to set \$GC still resolves via the default, not empty"

# ---------------------------------------------------------------------------
# cv_flatten_roster_vars_from_json / cv_flatten_roster_vars (fk-pubvq roster
# replay; review fk-n74o9 BLOCKING-2 — this logic used to be duplicated
# near-identically in main.publish.md's inline python and
# con-voyage-rereview-watch.sh's own flatten_roster_vars, and had already
# drifted cosmetically between the two copies).
# ---------------------------------------------------------------------------
start_case "cv_flatten_roster_vars_from_json: keeps enable_*/exact keys, drops everything else, sorted"
assert_eq "code_lens=con-voyage.cv-go-principal-engineer,enable_qa_test=true,enable_sre=false,implementation_target=gc.implementation-worker" \
  "$(cv_flatten_roster_vars_from_json '{"code_lens":"con-voyage.cv-go-principal-engineer","implementation_target":"gc.implementation-worker","enable_sre":"false","enable_qa_test":"true","some_other_var":"x"}')" \
  "only the roster-relevant keys survive, alphabetically sorted"

start_case "cv_flatten_roster_vars_from_json: empty input -> empty"
assert_eq "" "$(cv_flatten_roster_vars_from_json "")" "empty raw JSON resolves empty, not an error"

start_case "cv_flatten_roster_vars_from_json: unparseable JSON -> empty (fail-safe)"
assert_eq "" "$(cv_flatten_roster_vars_from_json "not json")" "unparseable input resolves empty"

start_case "cv_flatten_roster_vars_from_json: JSON that isn't an object -> empty"
assert_eq "" "$(cv_flatten_roster_vars_from_json '["enable_sre"]')" "a JSON array (not an object) resolves empty"

start_case "cv_flatten_roster_vars: reads gc.graphv2_vars.v1 off the root bead and flattens it"
export STUB_BDSHOW_JSON_fk_roster1='{"id":"fk-roster1","metadata":{"gc.graphv2_vars.v1":"{\"enable_sre\":\"true\",\"code_lens\":\"con-voyage.cv-go-principal-engineer\",\"noise\":\"1\"}"}}'
assert_eq "code_lens=con-voyage.cv-go-principal-engineer,enable_sre=true" \
  "$(cv_flatten_roster_vars "fk-roster1")" "flattens the real metadata field end to end"

start_case "cv_flatten_roster_vars: bead has no gc.graphv2_vars.v1 -> empty"
export STUB_BDSHOW_JSON_fk_roster2='{"id":"fk-roster2","metadata":{}}'
assert_eq "" "$(cv_flatten_roster_vars "fk-roster2")" "a root bead with no roster metadata resolves empty"

start_case "cv_flatten_roster_vars: empty bead id -> empty, no bd call"
: > "$GC_LOG"
assert_eq "" "$(cv_flatten_roster_vars "")" "empty bead id resolves empty"
assert_log_count 'bd show' 0 "empty bead id never calls bd show"

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
# cv_convoy_target (fk-zl42t iteration-2 BLOCKING-1: cv_resolve_base_branch's
# first line calls this, and main.publish.md / main.setup-con-voyage-review.md
# both reach it with no `GC=` set in scope — the same unguarded-`$GC` defect
# cv_bead_metadata was just fixed for above, one function away.)
# ---------------------------------------------------------------------------
start_case "cv_convoy_target: convoy has a target -> that value"
export STUB_CONVOY_STATUS_JSON_fk_convoy1='{"convoy":{"fields":{"target":"main"}}}'
assert_eq "main" "$(cv_convoy_target "fk-convoy1")" "reads the configured stacked-PR target"

start_case "cv_convoy_target: empty convoy id -> empty, no gc call"
: > "$GC_LOG"
assert_eq "" "$(cv_convoy_target "")" "empty convoy id resolves empty"
assert_log_count 'convoy status' 0 "empty convoy id never calls gc convoy status"

start_case "cv_convoy_target: \$GC unset -> defaults to literal \"gc\" on PATH, not a silent no-op (fk-zl42t iteration-2 BLOCKING-1: main.publish.md/main.setup-con-voyage-review.md call cv_resolve_base_branch -> cv_convoy_target with no \$GC in scope)"
export STUB_CONVOY_STATUS_JSON_fk_convoygc='{"convoy":{"fields":{"target":"release/9.0"}}}'
gc_unset_convoy_result="$(PATH="${STUBDIR}:${PATH}" bash -c "unset GC; source '$LIB'; cv_convoy_target 'fk-convoygc'")"
assert_eq "release/9.0" "$gc_unset_convoy_result" "a caller that forgets to set \$GC still resolves the stacked-PR target, not empty"

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
# fk-16zsa iter-4: real `bd` never sets status="pinned"/"blocked" for these
# cases (pin is an orthogonal flag, a dependency/gate block leaves status
# "open") — these fixtures now use the real shape; the refusal signal comes
# from the STUB_BDCLOSE_*_REFUSAL_* vars on the `bd close` stub instead.
export STUB_BDSHOW_JSON_rb_pinned='{"id":"rb-pinned","status":"open","assignee":"someone"}'
export STUB_BDSHOW_JSON_rb_blocked='{"id":"rb-blocked","status":"open","assignee":"someone"}'
# fk-16zsa iter-5: an open bead that is ALSO pinned/gate-blocked — bd's own
# close refusal text can't tell this apart from rb-open (see the FORCE case
# further below), so bead_pinned_or_blocked must positively confirm the hold.
export STUB_BDSHOW_JSON_rb_masked='{"id":"rb-masked","status":"open","assignee":"someone"}'
export STUB_BDSHOW_JSON_rb_masked2='{"id":"rb-masked2","status":"open","assignee":"someone"}'

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
assert_eq "" "$FS_ROOT_BEAD_ID" "root_bead_id omitted -> empty (backward compat, fk-bkz94)"

start_case "finalize_write/read round-trip: root_bead_id (fk-bkz94)"
finalize_write "k2" "wb-2" "cv-2" "kriscoleman/foundry" "30" "kriscoleman" "foundry/impl" "awaiting_merge" "fk-root2"
finalize_read "k2"
assert_eq "fk-root2" "$FS_ROOT_BEAD_ID" "root_bead_id round-trips"

start_case "finalize_read: missing record leaves fields empty (no stale bleed)"
finalize_read "does-not-exist"
assert_eq "" "$FS_WORK_BEAD" "missing record => empty work_bead"
assert_eq "" "$FS_LAST_PHASE" "missing record => empty last_phase"
assert_eq "" "$FS_ROOT_BEAD_ID" "missing record => empty root_bead_id"

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

# ---------------------------------------------------------------------------
# cv_session_route_handle (review fk-pbadx BLOCKING-1 / fk-hbsmk BLOCKING-1 —
# the rig-scoped name/alias handle usable for implementor_alive, gc sling, AND
# gc mail send simultaneously; see con-voyage-lib.sh for the full rationale)
# ---------------------------------------------------------------------------
start_case "cv_session_route_handle: matches by session_name form, resolves to rig-scoped name"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","alias":"foundry-kc/gc.gap-analyst-1","name":"foundry-kc/gc.gap-analyst-1","session_name":"gc__gap-analyst-rc-1","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "foundry-kc/gc.gap-analyst-1" "$(cv_session_route_handle "gc__gap-analyst-rc-1")" "resolves a session_name-form identity to the rig-scoped name"

start_case "cv_session_route_handle: matches by alias form too"
assert_eq "foundry-kc/gc.gap-analyst-1" "$(cv_session_route_handle "foundry-kc/gc.gap-analyst-1")" "resolves an alias-form identity to the rig-scoped name"

start_case "cv_session_route_handle: name absent -> falls back to alias"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","alias":"foundry-kc/gc.gap-analyst-1","session_name":"gc__gap-analyst-rc-1","template":"foundry-kc/gc.gap-analyst","state":"active"}]}'
assert_eq "foundry-kc/gc.gap-analyst-1" "$(cv_session_route_handle "gc__gap-analyst-rc-1")" "falls back to alias when name is absent"

start_case "cv_session_route_handle: closed session is not alive"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-2","name":"foundry-kc/gc.gap-analyst-2","session_name":"gc__gap-analyst-rc-2","template":"foundry-kc/gc.gap-analyst","state":"closed"}]}'
assert_eq "" "$(cv_session_route_handle "gc__gap-analyst-rc-2")" "a closed session never resolves"

start_case "cv_session_route_handle: no match -> empty"
export STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","name":"foundry-kc/gc.gap-analyst-1","session_name":"gc__gap-analyst-rc-1","state":"active"}]}'
assert_eq "" "$(cv_session_route_handle "gc__someone-else")" "an unmatched identity resolves empty"

start_case "cv_session_route_handle: empty ident -> empty, no gc call"
: > "$GC_LOG"
assert_eq "" "$(cv_session_route_handle "")" "empty ident short-circuits"
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

start_case "cv_session_route_handle: \$GC unset -> still invokes gc (defaults to \"gc\" on PATH), not a silent no-op"
: > "$GC_LOG"
PATH="${STUBDIR}:${PATH}" GC_CITY="$GC_CITY" bash -c "unset GC; source '$LIB'; cv_session_route_handle 'gc__gap-analyst-rc-1'" >/dev/null 2>/dev/null
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
# close_if_open FORCE: behavior-based pin/gate detection (fk-16zsa iter-2/3
# BLOCKING — a `status`-field compare against "pinned"/"blocked"/is_blocked
# is always dead code, because real `bd show --json` never sets any of
# those for a genuinely pinned or dependency/gate-blocked bead. fk-16zsa
# iter-4: detect the refusal from bd's own close output instead — only a
# plain close's failure text matching the assignee-guard message is safe to
# retry with --force; any other refusal (pin, gate, anything else) must
# leave the bead open.
# ---------------------------------------------------------------------------
start_case "close_if_open: FORCE on a pinned bead -> plain close refused for a non-assignee reason, refuses to force, CV_CLOSE_RC=1"
: > "$GC_LOG"
export STUB_BDCLOSE_PIN_REFUSAL_rb_pinned=1
close_if_open "rb-pinned" "landed: x" "" "" FORCE 2>/dev/null
unset STUB_BDCLOSE_PIN_REFUSAL_rb_pinned
assert_eq "1" "$CV_CLOSE_RC" "a pinned bead's non-assignee refusal is never retried with --force"
assert_log_count 'bd close rb-pinned' 1 "only the plain close was attempted"
assert_log_count 'bd close rb-pinned.*--force' 0 "the refuse-branch never retries with --force"

start_case "close_if_open: FORCE on a gate-blocked bead -> plain close refused for a non-assignee reason, refuses to force, CV_CLOSE_RC=1"
: > "$GC_LOG"
export STUB_BDCLOSE_GATE_REFUSAL_rb_blocked=1
close_if_open "rb-blocked" "landed: x" "" "" FORCE 2>/dev/null
unset STUB_BDCLOSE_GATE_REFUSAL_rb_blocked
assert_eq "1" "$CV_CLOSE_RC" "a gate-blocked bead's non-assignee refusal is never retried with --force"
assert_log_count 'bd close rb-blocked' 1 "only the plain close was attempted"
assert_log_count 'bd close rb-blocked.*--force' 0 "the refuse-branch never retries with --force"

start_case "close_if_open: FORCE on a plain assignee-mismatch bead -> plain close refused for the assignee reason, retries and succeeds with --force"
: > "$GC_LOG"
export STUB_BDCLOSE_ASSIGNEE_MISMATCH_rb_open=1
close_if_open "rb-open" "landed: x" "" "" FORCE 2>/dev/null
unset STUB_BDCLOSE_ASSIGNEE_MISMATCH_rb_open
assert_eq "0" "$CV_CLOSE_RC" "a plain assignee-guard case still forces through"
assert_log_count 'bd close rb-open --reason .*--force' 1 "bd close was retried with --force"

# fk-16zsa iter-5 BLOCKING: a bead that is BOTH assignee-mismatched AND
# gate-blocked/pinned. Real `bd` emits only the assignee-guard text in this
# case (the earlier iter-4 cases above only ever exercise ONE refusal reason
# in isolation), so a text-only check on bd's refusal output cannot tell
# this apart from the safe plain-assignee-mismatch case above. close_if_open
# must independently confirm via bead_pinned_or_blocked before forcing.
start_case "close_if_open: FORCE on a bead that is assignee-mismatched AND gate-blocked -> the masking assignee refusal text is not trusted alone, bd blocked confirms the hold, never forces"
: > "$GC_LOG"
export STUB_BDCLOSE_ASSIGNEE_MISMATCH_rb_masked=1
export STUB_BDBLOCKED_JSON='[{"id":"rb-masked"}]'
close_if_open "rb-masked" "landed: x" "" "" FORCE 2>/dev/null
unset STUB_BDCLOSE_ASSIGNEE_MISMATCH_rb_masked
unset STUB_BDBLOCKED_JSON
assert_eq "1" "$CV_CLOSE_RC" "an assignee-refusal-masked gate hold is never overridden with --force"
assert_log_count 'bd close rb-masked --reason .*--force' 0 "the masked gate hold is never forced"

start_case "close_if_open: FORCE on a bead that is assignee-mismatched AND pinned -> the masking assignee refusal text is not trusted alone, bd list --pinned confirms the hold, never forces"
: > "$GC_LOG"
export STUB_BDCLOSE_ASSIGNEE_MISMATCH_rb_masked2=1
export STUB_BDPINNED_JSON='[{"id":"rb-masked2"}]'
close_if_open "rb-masked2" "landed: x" "" "" FORCE 2>/dev/null
unset STUB_BDCLOSE_ASSIGNEE_MISMATCH_rb_masked2
unset STUB_BDPINNED_JSON
assert_eq "1" "$CV_CLOSE_RC" "an assignee-refusal-masked pin is never overridden with --force"
assert_log_count 'bd close rb-masked2 --reason .*--force' 0 "the masked pin is never forced"

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
# cv_close_workflow_root (fk-jg6rm, reworked for fk-dgia1g): direct unit
# coverage. This is the teardown primitive every "root closed -> abandon,
# mint nothing" guard this fix adds to the build/setup-review/review-loop/
# synthesize/apply-findings workflow steps calls, and is now also exposed to
# the mayor as a standalone CLI (cv-abandon-workflow.sh). close_if_open
# already has its own direct coverage above (force-close refusal shapes);
# these cases cover the root-first, multi-pass, rig-routed descendant-sweep
# orchestration cv_close_workflow_root adds on top. The stub's "bd list"
# handler serves the metadata-field sweep query from
# STUB_BDLIST_SWEEP_JSON_<pass-number> (via STUB_SWEEP_COUNTER_FILE, reset
# per case below), distinct from STUB_BDPINNED_JSON (the unrelated "bd list
# --pinned" call bead_pinned_or_blocked makes).
# ---------------------------------------------------------------------------
start_case "cv_close_workflow_root: closes the root FIRST, then sweeps open descendants (fk-dgia1g: a loop-control bead closing before its root could re-mint mid-sweep)"
export STUB_BDSHOW_JSON_fk_root1='{"id":"fk-root1","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDLIST_SWEEP_JSON_1='[{"id":"fk-lane1","metadata":{}},{"id":"fk-lane2","metadata":{}}]'
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
cv_close_workflow_root "fk-root1" "test teardown"
assert_eq "0" "$CV_CLOSE_RC" "root bead closes cleanly -> CV_CLOSE_RC=0"
assert_eq "0" "$CV_CLOSE_OPEN_DESCENDANTS" "sweep converges to zero open descendants"
assert_log_count 'bd close fk-lane1 ' 1 "descendant fk-lane1 was closed"
assert_log_count 'bd close fk-lane2 ' 1 "descendant fk-lane2 was closed"
assert_log_count 'bd close fk-root1 ' 1 "root fk-root1 was closed"
root_line="$(grep -nE 'bd close fk-root1 ' "$GC_LOG" | head -1 | cut -d: -f1)"
descendant_line="$(grep -nE 'bd close fk-lane[12] ' "$GC_LOG" | head -1 | cut -d: -f1)"
if [ -n "$root_line" ] && [ -n "$descendant_line" ] && [ "$root_line" -lt "$descendant_line" ]; then
  echo "  PASS: the root closes before any descendant, arming every step's \"root already closed\" guard before the sweep can trigger a re-mint"
else
  echo "  FAIL: expected the root's own close to precede every descendant close (root=${root_line:-<missing>}, descendant=${descendant_line:-<missing>})" >&2
  FAILURES=$((FAILURES+1))
fi
unset STUB_BDLIST_SWEEP_JSON_1

start_case "cv_close_workflow_root: resolves --rig from the root id's own prefix for the descendant-listing query (fk-dgia1g case 1: a city-root cwd silently queried the wrong store)"
export STUB_BDSHOW_JSON_fk_root1b='{"id":"fk-root1b","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDLIST_SWEEP_JSON_1='[]'
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
cv_close_workflow_root "fk-root1b" "test teardown"
assert_log_count '\-\-rig foundry-kc bd list' 1 "the descendant sweep's bd list call carries --rig, resolved from the fk- prefix, not left to cwd-based auto-discovery"
unset STUB_BDLIST_SWEEP_JSON_1

start_case "cv_close_workflow_root: a descendant blocked by a sibling on pass 1 closes on pass 2 once that sibling is gone (fk-dgia1g case 2: one-shot sweep order isn't dependency order)"
export STUB_BDSHOW_JSON_fk_root4='{"id":"fk-root4","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDCLOSE_FAIL_FIRST_N_fk_blocked=1
export STUB_BDLIST_SWEEP_JSON_1='[{"id":"fk-blocked","metadata":{}},{"id":"fk-blocker","metadata":{}}]'
export STUB_BDLIST_SWEEP_JSON_2='[{"id":"fk-blocked","metadata":{}}]'
rm -f "$STUB_SWEEP_COUNTER_FILE"
rm -rf "$STUB_BDCLOSE_COUNTER_DIR"
: > "$GC_LOG"
cv_close_workflow_root "fk-root4" "test teardown"
assert_eq "0" "$CV_CLOSE_OPEN_DESCENDANTS" "the previously-blocked descendant is closed by the second pass, not permanently stuck"
assert_log_count 'bd close fk-blocked ' 2 "fk-blocked: pass 1 fails (blocked by sibling), pass 2 retries and succeeds"
assert_log_count 'bd close fk-blocker ' 1 "fk-blocker closed on the first pass"
unset STUB_BDLIST_SWEEP_JSON_1 STUB_BDLIST_SWEEP_JSON_2 STUB_BDCLOSE_FAIL_FIRST_N_fk_blocked

start_case "cv_close_workflow_root: within a pass, control-kind beads (gc.kind=workflow/scope/check/...) close before plain lane beads (fk-dgia1g case 3: loop-control-bead-first ordering)"
export STUB_BDSHOW_JSON_fk_root5='{"id":"fk-root5","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDLIST_SWEEP_JSON_1='[{"id":"fk-lane-a","metadata":{}},{"id":"fk-loopctl","metadata":{"gc.kind":"check"}},{"id":"fk-lane-b","metadata":{}}]'
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
cv_close_workflow_root "fk-root5" "test teardown"
ctl_line="$(grep -nE 'bd close fk-loopctl ' "$GC_LOG" | head -1 | cut -d: -f1)"
lane_line="$(grep -nE 'bd close fk-lane-[ab] ' "$GC_LOG" | head -1 | cut -d: -f1)"
if [ -n "$ctl_line" ] && [ -n "$lane_line" ] && [ "$ctl_line" -lt "$lane_line" ]; then
  echo "  PASS: the control-kind descendant (fk-loopctl, gc.kind=check) closes before any plain lane descendant in the same pass"
else
  echo "  FAIL: expected the control-kind descendant to close first (control=${ctl_line:-<missing>}, lane=${lane_line:-<missing>})" >&2
  FAILURES=$((FAILURES+1))
fi
unset STUB_BDLIST_SWEEP_JSON_1

start_case "cv_close_workflow_root: a gc.kind=ralph descendant (graph.v2's loop-controller kind) closes before plain lane beads in the same pass (review fk-sku8km BLOCKING-1: CONTROL_KINDS previously omitted ralph)"
export STUB_BDSHOW_JSON_fk_root5b='{"id":"fk-root5b","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDLIST_SWEEP_JSON_1='[{"id":"fk-lane-c","metadata":{}},{"id":"fk-ralphctl","metadata":{"gc.kind":"ralph"}},{"id":"fk-lane-d","metadata":{}}]'
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
cv_close_workflow_root "fk-root5b" "test teardown"
ralph_line="$(grep -nE 'bd close fk-ralphctl ' "$GC_LOG" | head -1 | cut -d: -f1)"
lane_line="$(grep -nE 'bd close fk-lane-[cd] ' "$GC_LOG" | head -1 | cut -d: -f1)"
if [ -n "$ralph_line" ] && [ -n "$lane_line" ] && [ "$ralph_line" -lt "$lane_line" ]; then
  echo "  PASS: the gc.kind=ralph descendant (fk-ralphctl) closes before any plain lane descendant in the same pass"
else
  echo "  FAIL: expected the ralph descendant to close first (ralph=${ralph_line:-<missing>}, lane=${lane_line:-<missing>})" >&2
  FAILURES=$((FAILURES+1))
fi
unset STUB_BDLIST_SWEEP_JSON_1

start_case "cv_close_workflow_root: root already closed -> idempotent no-op on the root, descendants still swept"
export STUB_BDSHOW_JSON_fk_root2='{"id":"fk-root2","status":"closed","metadata":{},"dependencies":[]}'
export STUB_BDLIST_SWEEP_JSON_1='[{"id":"fk-lane3","metadata":{}}]'
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
cv_close_workflow_root "fk-root2" "test teardown"
assert_eq "0" "$CV_CLOSE_RC" "an already-closed root is a no-op, not a failure"
assert_log_count 'bd close fk-lane3 ' 1 "a still-open descendant is still swept even when the root is already closed"
assert_log_count 'bd close fk-root2 ' 0 "an already-closed root is never re-closed"
unset STUB_BDLIST_SWEEP_JSON_1

start_case "cv_close_workflow_root: a descendant stuck open across every pass is logged and counted, but never blocks the root's own close (best-effort sweep)"
export STUB_BDSHOW_JSON_fk_root3='{"id":"fk-root3","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDLIST_SWEEP_JSON_LAST='[{"id":"fk-stuck","metadata":{}}]'
export STUB_BDCLOSE_FAIL_fk_stuck=1
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
# fk-dgia1g: run in the current shell, not a `$(...)` subshell — the function
# sets CV_CLOSE_RC/CV_CLOSE_OPEN_DESCENDANTS as globals, and a subshell would
# assign those only in its own, discarded environment, silently stranding the
# parent's copies at whatever a prior case left them.
WARN_FILE="${SANDBOX}/stuck_warn.txt"
cv_close_workflow_root "fk-root3" "test teardown" 2> "$WARN_FILE"
root_close_warn="$(cat "$WARN_FILE")"
assert_eq "0" "$CV_CLOSE_RC" "CV_CLOSE_RC reflects only the root bead's own close outcome, not the descendant sweep"
assert_eq "1" "$CV_CLOSE_OPEN_DESCENDANTS" "the stuck descendant is counted as still open once the sweep gives up"
case "$root_close_warn" in
  *"could not close descendant fk-stuck"*) echo "  PASS: a stuck descendant's close failure is logged" ;;
  *) echo "  FAIL: expected a WARNING naming the stuck descendant, got: ${root_close_warn}" >&2; FAILURES=$((FAILURES+1)) ;;
esac
assert_log_count 'bd close fk-root3 ' 1 "the root is still closed despite a descendant sweep failure"
unset STUB_BDLIST_SWEEP_JSON_LAST STUB_BDCLOSE_FAIL_fk_stuck

start_case "cv_close_workflow_root: empty root id -> no-op, no bd calls"
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
cv_close_workflow_root "" "test teardown"
assert_eq "0" "$CV_CLOSE_RC" "empty root id is a clean no-op"
assert_eq "0" "$CV_CLOSE_OPEN_DESCENDANTS" "empty root id reports zero open descendants"
assert_log_count 'bd (close|list)' 0 "empty root id never calls bd list or bd close"

start_case "cv_close_workflow_root: an unresolved rig skips the descendant query entirely and fails closed rather than trusting a wrong-store result (fk-39mg5k/fk-gvnoof BLOCKING-1 follow-up; split out from the bash-3.2-gated case below so it actually runs on real CI's bash 5, per review fk-c42prb BLOCKING-2)"
export STUB_RIGLIST_JSON='{"rigs":[]}'
export STUB_BDSHOW_JSON_fk_root9='{"id":"fk-root9","status":"open","metadata":{},"dependencies":[]}'
# fk-39mg5k/fk-gvnoof BLOCKING-1: an unresolved rig must never trust ANY
# `bd list` result — a `--city`-only query against a rig-owned root can
# return a successful empty "[]" from the WRONG store (this pack's own
# fk-7v3r contract), which would falsely read as "genuinely zero
# descendants". Stubbing a non-empty sweep result here and asserting it is
# never consulted (no `bd list` call logged at all) proves the fix skips
# the query outright rather than merely getting lucky on an empty stub.
export STUB_BDLIST_SWEEP_JSON_1='[{"id":"fk-should-not-be-seen","metadata":{}}]'
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
cv_close_workflow_root "fk-root9" "test teardown" 2>/dev/null
assert_eq "0" "$CV_CLOSE_RC" "an unresolved rig still lets the root's own close succeed"
assert_eq "-1" "$CV_CLOSE_OPEN_DESCENDANTS" "an unresolved rig fails closed (-1, not confirmed converged), never trusting a wrong-store query"
assert_log_count 'bd list' 0 "an unresolved rig must never query bd list at all (would hit the wrong store)"
unset STUB_RIGLIST_JSON STUB_BDLIST_SWEEP_JSON_1
export STUB_RIGLIST_JSON='{"rigs":[{"name":"foundry-kc","prefix":"fk"}]}'

start_case "cv_close_workflow_root: an empty rig_args never aborts under 'set -u' on bash 3.2, the stock macOS /bin/bash (fk-tj3bih BLOCKING-1; the wrong-store-skip assertions this case used to carry now live in the ungated case above, per review fk-c42prb BLOCKING-2)"
if [ -x /bin/bash ] && /bin/bash -c 'case "$BASH_VERSION" in 3.*) exit 0;; *) exit 1;; esac' 2>/dev/null; then
  export STUB_RIGLIST_JSON='{"rigs":[]}'
  export STUB_BDSHOW_JSON_fk_root6='{"id":"fk-root6","status":"open","metadata":{},"dependencies":[]}'
  export STUB_BDLIST_SWEEP_JSON_1='[{"id":"fk-should-not-be-seen","metadata":{}}]'
  rm -f "$STUB_SWEEP_COUNTER_FILE"
  BASH32_GC_LOG="${SANDBOX}/bash32_gc_log.txt"
  : > "$BASH32_GC_LOG"
  BASH32_OUT="$(GC="$GC" GC_CITY="$GC_CITY" STUB_GC_LOG="$BASH32_GC_LOG" STUB_RIGLIST_JSON="$STUB_RIGLIST_JSON" STUB_BDSHOW_JSON_fk_root6="$STUB_BDSHOW_JSON_fk_root6" STUB_BDLIST_SWEEP_JSON_1="$STUB_BDLIST_SWEEP_JSON_1" STUB_SWEEP_COUNTER_FILE="$STUB_SWEEP_COUNTER_FILE" STUB_BDCLOSE_COUNTER_DIR="$STUB_BDCLOSE_COUNTER_DIR" /bin/bash -c "
    set -uo pipefail
    source '$LIB'
    cv_close_workflow_root 'fk-root6' 'test teardown' 2>/dev/null
    printf 'RC=%s OPEN=%s' \"\$CV_CLOSE_RC\" \"\$CV_CLOSE_OPEN_DESCENDANTS\"
  " 2>"${SANDBOX}/bash32_stderr.txt")"
  BASH32_RC=$?
  assert_eq "0" "$BASH32_RC" "cv_close_workflow_root with cv_rig_for_bead_id returning empty exits 0 under bash 3.2 set -u (no unbound-variable abort)"
  BASH32_STDERR="$(cat "${SANDBOX}/bash32_stderr.txt")"
  case "$BASH32_STDERR" in
    *"unbound variable"*) echo "  FAIL: empty rig_args still aborts under set -u on bash 3.2: ${BASH32_STDERR}" >&2; FAILURES=$((FAILURES+1)) ;;
    *) ;;
  esac
  case "$BASH32_OUT" in
    "RC=0 OPEN=-1") echo "  PASS: an unresolved rig fails closed (-1, not confirmed converged) under bash 3.2 without aborting (${BASH32_OUT})" ;;
    *) echo "  FAIL: unexpected output under bash 3.2: ${BASH32_OUT}" >&2; FAILURES=$((FAILURES+1)) ;;
  esac
  unset STUB_RIGLIST_JSON STUB_BDLIST_SWEEP_JSON_1
  export STUB_RIGLIST_JSON='{"rigs":[{"name":"foundry-kc","prefix":"fk"}]}'
else
  echo "  SKIP: /bin/bash is not bash 3.x on this host — cannot exercise the stock-macOS set -u path"
fi

start_case "cv_close_workflow_root: a failed/timed-out descendant listing is NOT reported as zero open descendants (fk-tj3bih BLOCKING-2)"
export STUB_BDSHOW_JSON_fk_root7='{"id":"fk-root7","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDLIST_SWEEP_FAIL_1=1
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
WARN_FILE="${SANDBOX}/list_fail_warn.txt"
cv_close_workflow_root "fk-root7" "test teardown" 2> "$WARN_FILE"
assert_eq "0" "$CV_CLOSE_RC" "the root's own close still succeeds even when the descendant listing fails"
assert_eq "-1" "$CV_CLOSE_OPEN_DESCENDANTS" "a failed listing reports the -1 'unknown, not confirmed converged' sentinel, never 0"
case "$(cat "$WARN_FILE")" in
  *"could not list open descendants"*"treating as not converged"*) echo "  PASS: the listing failure is logged and treated as not converged" ;;
  *) echo "  FAIL: expected a WARNING naming the listing failure, got: $(cat "$WARN_FILE")" >&2; FAILURES=$((FAILURES+1)) ;;
esac
unset STUB_BDLIST_SWEEP_FAIL_1

start_case "cv_close_workflow_root: the descendant-listing call is bounded by a timeout, not left to hang (fk-tj3bih BLOCKING-3)"
export STUB_BDSHOW_JSON_fk_root8='{"id":"fk-root8","status":"open","metadata":{},"dependencies":[]}'
export STUB_BDLIST_SWEEP_HANG_SECONDS=5
export CV_LENS_STORE_TIMEOUT_SECONDS=1
rm -f "$STUB_SWEEP_COUNTER_FILE"
: > "$GC_LOG"
TIMEOUT_START="$(date +%s)"
cv_close_workflow_root "fk-root8" "test teardown" 2>/dev/null
TIMEOUT_ELAPSED=$(( $(date +%s) - TIMEOUT_START ))
assert_eq "-1" "$CV_CLOSE_OPEN_DESCENDANTS" "a timed-out listing call is treated the same as a failed one (not converged)"
if [ "$TIMEOUT_ELAPSED" -lt 5 ]; then
  echo "  PASS: the sweep returned in ${TIMEOUT_ELAPSED}s, well under the stubbed 5s hang — cv_with_timeout bounded it"
else
  echo "  FAIL: the sweep took ${TIMEOUT_ELAPSED}s — the descendant listing call was not bounded by a timeout" >&2
  FAILURES=$((FAILURES+1))
fi
unset STUB_BDLIST_SWEEP_HANG_SECONDS CV_LENS_STORE_TIMEOUT_SECONDS

start_case "close_if_open: the bd close call itself is bounded by a timeout, not left to hang (fk-0ks7ui, review fk-sku8km BLOCKING-1)"
export STUB_BDCLOSE_HANG_SECONDS=5
export CV_LENS_STORE_TIMEOUT_SECONDS=1
: > "$GC_LOG"
TIMEOUT_START="$(date +%s)"
close_if_open "rb-open" "test teardown" 2>/dev/null
TIMEOUT_ELAPSED=$(( $(date +%s) - TIMEOUT_START ))
assert_eq "124" "$CV_CLOSE_RC" "a timed-out bd close is reported as a close failure (left open for retry), not silently treated as success"
if [ "$TIMEOUT_ELAPSED" -lt 5 ]; then
  echo "  PASS: close_if_open returned in ${TIMEOUT_ELAPSED}s, well under the stubbed 5s hang — cv_with_timeout bounded it"
else
  echo "  FAIL: close_if_open took ${TIMEOUT_ELAPSED}s — the bd close call was not bounded by a timeout" >&2
  FAILURES=$((FAILURES+1))
fi
unset STUB_BDCLOSE_HANG_SECONDS CV_LENS_STORE_TIMEOUT_SECONDS

# ---------------------------------------------------------------------------
# cv_branch_slug / cv_work_branch_name / cv_branch_bead_id (fk-6os73y: name
# work branches con-voyage/<bead-id>-<topic-slug>, operator-chosen option (b)
# in Slack C0C4D8TAVL5 thread 1791011333.310589 — "branch names should say
# what the work is"). Table-driven: every row is independent, no bd/gc stub
# needed since these three are pure string transforms.
# ---------------------------------------------------------------------------
start_case "cv_branch_slug: derives a slug from a work-bead title"

slug_cases=(
  "fix(helm): pin chart image tag|pin-chart-image-tag"
  "feat: add foo bar|add-foo-bar"
  "chore(main): release con-voyage-gascity 0.13.1|release-con-voyage-gascity-0-13-1"
  "No prefix here just words|no-prefix-here-just-words"
  "!!!only punctuation!!!|only-punctuation"
  "!!!!!|"
  "|"
  "one two three four five six seven eight nine ten eleven twelve|one-two-three-four-five-six-seven-eight"
  "alpha beta gamma delta epsilon zeta theta iota|alpha-beta-gamma-delta-epsilon-zeta"
)
for row in "${slug_cases[@]}"; do
  title="${row%%|*}"
  expected="${row#*|}"
  assert_eq "$expected" "$(cv_branch_slug "$title")" "slug('${title}')"
done

start_case "cv_work_branch_name: con-voyage/<bead-id>-<slug>, or bare con-voyage/<bead-id> when the slug is empty"

branch_name_cases=(
  "fk-ob4j8y|fix(helm): pin chart image tag|con-voyage/fk-ob4j8y-pin-chart-image-tag"
  "va-05ky|chore: bump|con-voyage/va-05ky-bump"
  "fk-a3k6x.1|!!!|con-voyage/fk-a3k6x.1"
  "fk-a3k6x.1||con-voyage/fk-a3k6x.1"
  "|some title|"
)
for row in "${branch_name_cases[@]}"; do
  IFS='|' read -r bead_id title expected <<< "$row"
  assert_eq "$expected" "$(cv_work_branch_name "$bead_id" "$title")" "work_branch_name('${bead_id}', '${title}')"
done

# fk-6os73y re-grade (operator severity rubric): a non-ASCII-only title (or
# any title that slugifies to empty) must not silently fall back to the bare
# branch name with zero signal — a human reading a stripped-down "ber-caf"
# style slug (or a bare name with no slug at all) deserves to know why.
start_case "cv_work_branch_name: a non-ASCII-only title falls back to the bare branch name AND logs why on stderr"
result="$(cv_work_branch_name "fk-ob4j8y" "名前" 2>"${SANDBOX}/non_ascii_title.stderr")"
assert_eq "con-voyage/fk-ob4j8y" "$result" "falls back to the bare con-voyage/<bead-id> name"
assert_eq "1" "$(grep -c 'yielded no usable slug characters' "${SANDBOX}/non_ascii_title.stderr")" "logs why the slug fell back, on stderr"

start_case "cv_work_branch_name: an empty title also logs why on fallback"
result="$(cv_work_branch_name "fk-a3k6x.1" "" 2>"${SANDBOX}/empty_title.stderr")"
assert_eq "con-voyage/fk-a3k6x.1" "$result" "falls back to the bare con-voyage/<bead-id> name"
assert_eq "1" "$(grep -c 'yielded no usable slug characters' "${SANDBOX}/empty_title.stderr")" "logs why the slug fell back, on stderr"

start_case "cv_branch_bead_id: extracts the bead id back out of EITHER branch form, never swallowing id into slug or slug into id"

bead_id_cases=(
  "con-voyage/fk-ob4j8y|fk-ob4j8y"
  "con-voyage/fk-ob4j8y-pin-chart-image-tag|fk-ob4j8y"
  "con-voyage/va-05ky|va-05ky"
  "con-voyage/va-05ky-bump|va-05ky"
  "con-voyage/fk-a3k6x.1|fk-a3k6x.1"
  "con-voyage/fk-a3k6x.1-pin-tag|fk-a3k6x.1"
  "con-voyage/fk-a3k6x.1-pin-tag-with-many-hyphens|fk-a3k6x.1"
  "main|"
  "con-voyage/|"
  "|"
)
for row in "${bead_id_cases[@]}"; do
  branch="${row%%|*}"
  expected="${row#*|}"
  assert_eq "$expected" "$(cv_branch_bead_id "$branch")" "branch_bead_id('${branch}')"
done

start_case "cv_branch_slug/cv_work_branch_name/cv_branch_bead_id round-trip: slug(title)+id -> branch -> id back out"

roundtrip_ids=("fk-ob4j8y" "va-05ky" "fk-a3k6x.1")
roundtrip_title="fix(helm): pin chart image tag"
for id in "${roundtrip_ids[@]}"; do
  branch="$(cv_work_branch_name "$id" "$roundtrip_title")"
  assert_eq "$id" "$(cv_branch_bead_id "$branch")" "round-trip for ${id}: ${branch} -> id"
done

# ---------------------------------------------------------------------------
# cv_ensure_work_branch_name (fk-6os73y): compute once, persist on ROOT_ID,
# and NEVER recompute from a (possibly since-changed) title once a value is
# already stored — the branch name must stay stable for the life of the
# journey.
# ---------------------------------------------------------------------------
start_case "cv_ensure_work_branch_name: no stored value yet -> computes it and persists it on ROOT_ID"
: > "$GC_LOG"
unset STUB_BDSHOW_JSON_fk_root1
export STUB_BDSHOW_JSON_fk_root1='{"id":"fk-root1","metadata":{}}'
result="$(cv_ensure_work_branch_name "fk-root1" "fk-ob4j8y" "fix(helm): pin chart image tag")"
assert_eq "con-voyage/fk-ob4j8y-pin-chart-image-tag" "$result" "computes the branch name on first call"
assert_log_count 'bd update fk-root1 --set-metadata gc\.build\.work_branch_name=con-voyage/fk-ob4j8y-pin-chart-image-tag' 1 "persists the computed name onto ROOT_ID"

start_case "cv_ensure_work_branch_name: a stored value wins even if the title would now slugify differently"
: > "$GC_LOG"
export STUB_BDSHOW_JSON_fk_root2='{"id":"fk-root2","metadata":{"gc.build.work_branch_name":"con-voyage/fk-ob4j8y-old-slug"}}'
result="$(cv_ensure_work_branch_name "fk-root2" "fk-ob4j8y" "a completely different title now")"
assert_eq "con-voyage/fk-ob4j8y-old-slug" "$result" "the cached value is returned unchanged"
assert_log_count 'bd update fk-root2' 0 "never re-persists once a value is already stored"
unset STUB_BDSHOW_JSON_fk_root1 STUB_BDSHOW_JSON_fk_root2

# review fk-ymqwd9 BLOCKING-1: a persist that fails on every retry must not
# be silently swallowed — the caller still gets the computed name back (it is
# self-healing for THIS call), but a durable flag must be stamped so a later
# attempt (which would otherwise recompute from a possibly title-drifted
# TITLE and desync from whatever branch actually got built) has a checkable
# signal that no value was ever cached, not just a buried stderr line.
start_case "cv_ensure_work_branch_name: persist fails on every retry -> still returns the computed name, retries 3x, and stamps the unpersisted flag"
: > "$GC_LOG"
export STUB_BDSHOW_JSON_fk_root3='{"id":"fk-root3","metadata":{}}'
export STUB_BDUPDATE_FAIL_fk_root3=1
result="$(cv_ensure_work_branch_name "fk-root3" "fk-ob4j8y" "fix(helm): pin chart image tag" 2>"${SANDBOX}/ensure_fail.stderr")"
assert_eq "con-voyage/fk-ob4j8y-pin-chart-image-tag" "$result" "still returns the computed name despite the persist failing"
assert_log_count 'bd update fk-root3 --set-metadata gc\.build\.work_branch_name=con-voyage/fk-ob4j8y-pin-chart-image-tag' 3 "retries the failed persist 3 times total"
assert_log_count 'bd update fk-root3 --set-metadata gc\.build\.work_branch_name_unpersisted=true' 1 "stamps a durable unpersisted flag once retries are exhausted"
assert_eq "1" "$(grep -c 'failed to persist gc.build.work_branch_name' "${SANDBOX}/ensure_fail.stderr")" "warns on stderr about the exhausted persist retries"
unset STUB_BDSHOW_JSON_fk_root3 STUB_BDUPDATE_FAIL_fk_root3

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
# cv_random_nonce / cv_build_pr_feedback_body: fail-closed when the primary
# /dev/urandom+od path is unavailable (qa-test fk-spxo3z, security fk-dopfd8
# follow-up). The prior version fell back to a date+$RANDOM+$$ mix — never
# exercised on a real target platform and attacker-influenceable (PID and
# wall-clock are not secret). The fix removes that fallback entirely: a
# degraded entropy source must refuse to produce a nonce, not silently hand
# back a weaker one. Exercised via a PATH that provides every OTHER command
# cv_random_nonce/sourcing the lib needs, but omits `od`, so the primary path
# fails exactly the way it would on a host actually missing `od` — not by
# faking out /dev/urandom itself (a device file, not a PATH lookup).
# ---------------------------------------------------------------------------
start_case "cv_random_nonce: od unavailable on PATH -> fails closed (no nonce printed, non-zero exit, clear stderr)"
NO_OD_PATH_DIR="${SANDBOX}/no-od-path"
mkdir -p "$NO_OD_PATH_DIR"
for bin in head tr date cat grep sed awk mktemp; do
  real_bin="$(command -v "$bin" 2>/dev/null)"
  [ -n "$real_bin" ] && ln -sf "$real_bin" "${NO_OD_PATH_DIR}/${bin}"
done
BASH_BIN="$(command -v bash)"
noodpath_out=""
noodpath_err=""
noodpath_out="$(PATH="$NO_OD_PATH_DIR" "$BASH_BIN" -c "source '$LIB'; cv_random_nonce" 2>"${SANDBOX}/no-od.err")"
noodpath_rc=$?
noodpath_err="$(cat "${SANDBOX}/no-od.err")"
assert_eq "" "$noodpath_out" "cv_random_nonce prints nothing when od is unavailable (no low-entropy fallback)"
assert_eq "1" "$noodpath_rc" "cv_random_nonce returns non-zero when od is unavailable"
case "$noodpath_err" in
  *"refusing to generate a low-entropy nonce"*)
    echo "  PASS: cv_random_nonce writes a clear fail-closed error to stderr" ;;
  *)
    echo "  FAIL: expected a fail-closed stderr message, got: $noodpath_err" >&2
    FAILURES=$((FAILURES+1))
    ;;
esac

start_case "cv_build_pr_feedback_body: propagates cv_random_nonce's fail-closed result instead of emitting a body with a blank/missing nonce"
feedback_out=""
feedback_err=""
feedback_out="$(PATH="$NO_OD_PATH_DIR" "$BASH_BIN" -c "source '$LIB'; cv_build_pr_feedback_body 'https://github.com/acme/widgets/pull/1' 'fix/example' 'some feedback' 'test-key'" 2>"${SANDBOX}/feedback.err")"
feedback_rc=$?
feedback_err="$(cat "${SANDBOX}/feedback.err")"
assert_eq "" "$feedback_out" "cv_build_pr_feedback_body emits nothing when it cannot obtain a trustworthy nonce"
assert_eq "1" "$feedback_rc" "cv_build_pr_feedback_body returns non-zero when it cannot obtain a trustworthy nonce"
case "$feedback_err" in
  *"refusing to fence untrusted PR content"*)
    echo "  PASS: cv_build_pr_feedback_body writes a clear fail-closed error to stderr" ;;
  *)
    echo "  FAIL: expected a fail-closed stderr message, got: $feedback_err" >&2
    FAILURES=$((FAILURES+1))
    ;;
esac

# ---------------------------------------------------------------------------
# cv_build_pr_feedback_body must hand workers a RESOLVED cv-pr-comment.sh
# path, not just name it in prose (fk-kza51h, dogfood friction 2026-10-08
# 11:35Z mail rc-wisp-zzyj2dy): vandoor/gc.implementation-worker-2 working a
# routed human-PR-feedback bead (va-oikb0, replicatedhq/vandoor#10620) could
# not find cv-pr-comment.sh on PATH or in its cached mold copy and closed the
# bead blocked with the fix pushed but no replies posted, because
# CV_PR_REPLY_INTEGRITY_REMINDER names the script by bare basename only. The
# fix resolves an absolute path via cv_pack_script before building the body,
# appends it to the body, and fails loud (non-zero exit, no output) rather
# than emit an unworkable bead when the script cannot be resolved.
# ---------------------------------------------------------------------------
start_case "cv_build_pr_feedback_body: output names a resolved, existing absolute cv-pr-comment.sh path"
resolved_bin="$(cv_pack_script cv-pr-comment.sh)"
if [ -z "$resolved_bin" ] || [ ! -f "$resolved_bin" ]; then
  echo "  FAIL: cv_pack_script could not resolve a real cv-pr-comment.sh in this checkout — cannot exercise the positive case" >&2
  FAILURES=$((FAILURES+1))
else
  path_body="$(cv_build_pr_feedback_body 'https://github.com/acme/widgets/pull/1' 'fix/example' 'some feedback' 'test-key-path')"
  case "$path_body" in
    *"$resolved_bin"*)
      echo "  PASS: body includes the resolved absolute cv-pr-comment.sh path (${resolved_bin})" ;;
    *)
      echo "  FAIL: body does not include the resolved path ${resolved_bin}" >&2
      FAILURES=$((FAILURES+1)) ;;
  esac
fi

start_case "cv_build_pr_feedback_body: fails loud (no output, non-zero exit, clear stderr) when cv-pr-comment.sh cannot be resolved"
NO_SCRIPT_REPO="${SANDBOX}/no-cv-pr-comment-repo"
NO_SCRIPT_CITY="${SANDBOX}/no-cv-pr-comment-city"
mkdir -p "$NO_SCRIPT_REPO" "$NO_SCRIPT_CITY/packs/con-voyage/assets/scripts"
git -C "$NO_SCRIPT_REPO" init -q -b main
noscript_out=""
noscript_err=""
noscript_out="$(
  cd "$NO_SCRIPT_REPO" && GC_CITY="$NO_SCRIPT_CITY" bash -c "source '$LIB'; cv_build_pr_feedback_body 'https://github.com/acme/widgets/pull/1' 'fix/example' 'some feedback' 'test-key-missing'" 2>"${SANDBOX}/noscript.err"
)"
noscript_rc=$?
noscript_err="$(cat "${SANDBOX}/noscript.err")"
assert_eq "" "$noscript_out" "cv_build_pr_feedback_body emits nothing when cv-pr-comment.sh cannot be resolved"
assert_eq "1" "$noscript_rc" "cv_build_pr_feedback_body returns non-zero when cv-pr-comment.sh cannot be resolved"
case "$noscript_err" in
  *"cv-pr-comment.sh"*)
    echo "  PASS: cv_build_pr_feedback_body writes a clear fail-loud error naming cv-pr-comment.sh" ;;
  *)
    echo "  FAIL: expected a clear fail-loud stderr message naming cv-pr-comment.sh, got: $noscript_err" >&2
    FAILURES=$((FAILURES+1))
    ;;
esac

start_case "cv_random_nonce: primary path still succeeds and yields full 128-bit (32 hex char) entropy when od IS available"
od_present_out="$(bash -c "source '$LIB'; cv_random_nonce")"
case "$od_present_out" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    echo "  PASS: cv_random_nonce yields a 32-char lowercase hex token on the primary path" ;;
  *)
    echo "  FAIL: expected a 32-char hex token, got: $od_present_out" >&2
    FAILURES=$((FAILURES+1))
    ;;
esac

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

  start_case "cv_with_timeout under zsh: no poll_s noise leaks into captured stdout across multiple poll iterations (fk-4i2er)"
  zsh_multi_out="$(zsh -c "source '$LIB'; cv_with_timeout 5 sh -c 'sleep 0.5; printf done'")"
  assert_eq "done" "$zsh_multi_out" "cv_with_timeout under zsh: stdout capture is clean across multiple poll iterations, no poll_s= leakage"

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

  start_case "cv_convoy_target under zsh: \$GC unset -> still resolves via default \"gc\" on PATH, not a silent no-op (fk-zl42t iteration-2 LOW-1: new \$GC-unset regression coverage needs bash+zsh from the start, not a bash-only case followed by a later zsh gap)"
  export STUB_CONVOY_STATUS_JSON_fk_convoygc_zsh='{"convoy":{"fields":{"target":"release/9.0"}}}'
  zsh_convoy_result="$(PATH="${STUBDIR}:${PATH}" zsh -c "unset GC; source '$LIB'; cv_convoy_target 'fk-convoygc-zsh'")"
  assert_eq "release/9.0" "$zsh_convoy_result" "under zsh: a caller that forgets to set \$GC still resolves the stacked-PR target, not empty"

  start_case "cv_session_route_handle under zsh: \$GC unset -> still resolves via default \"gc\" on PATH, not a silent no-op (same local/subshell shape as its implementor_alive/session_id_for_ident siblings in this section)"
  zsh_route_result="$(STUB_SESSION_LIST_JSON='{"sessions":[{"id":"rc-1","alias":"foundry-kc/gc.gap-analyst-1","name":"foundry-kc/gc.gap-analyst-1","session_name":"gc__gap-analyst-rc-1","template":"foundry-kc/gc.gap-analyst","state":"active"}]}' \
    PATH="${STUBDIR}:${PATH}" GC_CITY="$GC_CITY" zsh -c "unset GC; source '$LIB'; cv_session_route_handle 'gc__gap-analyst-rc-1'")"
  assert_eq "foundry-kc/gc.gap-analyst-1" "$zsh_route_result" "under zsh: a caller that forgets to set \$GC still resolves the rig-scoped route handle, not empty"
fi

# ===========================================================================
# cv_parse_pr_monitor_blocks (fk-dnjlg2: base-agnostic CI repair)
# ===========================================================================
PARSE_TOML_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cv-parse-monitors.XXXXXX")"

start_case "cv_parse_pr_monitor_blocks: multiple blocks, one with a multi-entry base_branches array"
cat > "${PARSE_TOML_DIR}/city.toml" <<'TOML'
[city]
name = "test"

[[github.pr_monitor]]
name = "vandoor-prs"
owner = "replicatedhq"
repo = "vandoor"
base_branches = ["main", "con-voyage/va-05ky"]
rig = "vandoor"
repair_route = "vandoor/gc.implementation-worker"
repair_workflow = "con-voyage-ci-repair"

[[github.pr_monitor]]
name = "ec-prs"
owner = "replicatedhq"
repo = "ec"
base_branches = ["main"]
rig = "ec"
repair_route = "ec/gc.implementation-worker"
TOML
parsed="$(cv_parse_pr_monitor_blocks "${PARSE_TOML_DIR}/city.toml")"
row1="$(printf '%s\n' "$parsed" | sed -n '1p')"
row2="$(printf '%s\n' "$parsed" | sed -n '2p')"
assert_eq "replicatedhq$(printf '\x1f')vandoor$(printf '\x1f')vandoor$(printf '\x1f')vandoor/gc.implementation-worker$(printf '\x1f')main,con-voyage/va-05ky" "$row1" "first block: owner/repo/rig/route/base_branches all extracted"
assert_eq "replicatedhq$(printf '\x1f')ec$(printf '\x1f')ec$(printf '\x1f')ec/gc.implementation-worker$(printf '\x1f')main" "$row2" "second block parsed independently of the first (no state bleed across blocks)"

start_case "cv_parse_pr_monitor_blocks: missing file -> no output, no error"
assert_eq "" "$(cv_parse_pr_monitor_blocks "${PARSE_TOML_DIR}/does-not-exist.toml" 2>/dev/null)" "unreadable path yields empty output, fails safe"

start_case "cv_parse_pr_monitor_blocks: empty path -> no output"
assert_eq "" "$(cv_parse_pr_monitor_blocks "" 2>/dev/null)" "empty input yields empty output"

rm -rf "$PARSE_TOML_DIR"

# ===========================================================================
# cv_classify_pr_signals (fk-dnjlg2: base-agnostic CI repair)
# ===========================================================================
classify() { printf '%s' "$1" | cv_classify_pr_signals; }

start_case "cv_classify_pr_signals: a failing required check wins regardless of merge state"
assert_eq "checks_failed$(printf '\x1f')1" "$(classify '{"statusCheckRollup":[{"conclusion":"FAILURE"}],"mergeStateStatus":"BEHIND","mergeable":"MERGEABLE","reviewDecision":""}')" "checks_failed takes precedence over BEHIND"

start_case "cv_classify_pr_signals: DIRTY merge state with all-green checks -> merge_conflict"
assert_eq "merge_conflict$(printf '\x1f')1" "$(classify '{"statusCheckRollup":[{"conclusion":"SUCCESS"}],"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","reviewDecision":""}')" "DIRTY/CONFLICTING classifies as merge_conflict"

start_case "cv_classify_pr_signals: BEHIND merge state with all-green checks -> behind_base"
assert_eq "behind_base$(printf '\x1f')1" "$(classify '{"statusCheckRollup":[{"conclusion":"SUCCESS"}],"mergeStateStatus":"BEHIND","mergeable":"MERGEABLE","reviewDecision":""}')" "BEHIND classifies as behind_base"

start_case "cv_classify_pr_signals: BLOCKED merge state, no failing checks -> blocked"
assert_eq "blocked$(printf '\x1f')1" "$(classify '{"statusCheckRollup":[{"conclusion":"SUCCESS"}],"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED"}')" "BLOCKED + REVIEW_REQUIRED classifies as blocked"

start_case "cv_classify_pr_signals: all green, CLEAN, no review gate -> empty failure_kind, not actionable"
assert_eq "$(printf '\x1f')0" "$(classify '{"statusCheckRollup":[{"conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}')" "a genuinely clean PR classifies as not actionable"

start_case "cv_classify_pr_signals: malformed JSON input -> empty failure_kind, not actionable (fail safe)"
assert_eq "$(printf '\x1f')0" "$(classify 'not json at all')" "malformed input never invents a repair"

start_case "cv_classify_pr_signals: StatusContext shape (state, not conclusion) failing -> checks_failed"
assert_eq "checks_failed$(printf '\x1f')1" "$(classify '{"statusCheckRollup":[{"state":"FAILURE"}],"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}')" "a legacy StatusContext failing state is also recognized"

# ---------------------------------------------------------------------------
# cv_minutes_since_iso8601 (fk-9oigyg review LOW-5: was duplicated verbatim
# in con-voyage-marshal-bead-sweep.sh and con-voyage-marshal-agent-sweep.sh)
# ---------------------------------------------------------------------------
start_case "cv_minutes_since_iso8601: a timestamp 90 minutes ago resolves to ~90"
past_ts="$(python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=90)).isoformat().replace('+00:00', 'Z'))
")"
assert_eq "90" "$(cv_minutes_since_iso8601 "$past_ts")" "90-minute-old timestamp resolves to 90 (+/- rounding)"

start_case "cv_minutes_since_iso8601: empty timestamp resolves empty, not an error"
assert_eq "" "$(cv_minutes_since_iso8601 "")" "empty input prints nothing"

start_case "cv_minutes_since_iso8601: unparseable timestamp resolves empty (fail safe, never a false stale age)"
assert_eq "" "$(cv_minutes_since_iso8601 "not-a-timestamp")" "unparseable input prints nothing"

# ---------------------------------------------------------------------------
# cv_mayor_is_bead_escalation (fk-9oigyg review LOW-6: was duplicated verbatim
# in con-voyage-marshal-bead-sweep.sh and con-voyage-marshal-formula-sweep.sh)
# ---------------------------------------------------------------------------
start_case "cv_mayor_is_bead_escalation: a failing outcome is an escalation"
if cv_mayor_is_bead_escalation "open" "fail" ""; then pass "outcome=fail is an escalation"; else fail "outcome=fail should be an escalation"; fi

start_case "cv_mayor_is_bead_escalation: a non-empty failure_class is an escalation"
if cv_mayor_is_bead_escalation "open" "" "boom"; then pass "a failure_class is an escalation"; else fail "a failure_class should be an escalation"; fi

start_case "cv_mayor_is_bead_escalation: routine open/in_progress/closed with no outcome/failure_class is NOT an escalation"
if cv_mayor_is_bead_escalation "open" "" ""; then fail "plain open status should not be an escalation"; else pass "plain open status is routine"; fi
if cv_mayor_is_bead_escalation "closed" "pass" ""; then fail "closed/pass should not be an escalation"; else pass "closed/pass is routine"; fi

start_case "cv_mayor_is_bead_escalation: an unrecognized status is an escalation (fail loud on the unexpected)"
if cv_mayor_is_bead_escalation "blocked" "" ""; then pass "an unrecognized status is an escalation"; else fail "an unrecognized status should be an escalation"; fi

# ---------------------------------------------------------------------------
# cv_path_safe_component (fk-9oigyg review LOW-1: bead/step/session ids are
# interpolated into state-file paths; this guards against an id containing a
# path separator or traversal sequence resolving outside the intended
# directory).
# ---------------------------------------------------------------------------
start_case "cv_path_safe_component: an ordinary id passes through unchanged"
assert_eq "fk-abc123" "$(cv_path_safe_component "fk-abc123")" "a normal bead id is unchanged"

start_case "cv_path_safe_component: a path separator is replaced"
assert_eq ".._etc_passwd" "$(cv_path_safe_component "../etc/passwd")" "slashes and traversal segments are neutralized to underscores"

start_case "cv_path_safe_component: an absolute path is neutralized"
assert_eq "_etc_passwd" "$(cv_path_safe_component "/etc/passwd")" "a leading slash is neutralized"

start_case "cv_path_safe_component: empty input resolves empty"
assert_eq "" "$(cv_path_safe_component "")" "empty input prints nothing"

start_case "cv_path_safe_component: a bare '..' (every char individually allowed) is still neutralized, not passed through as a traversal component"
assert_eq "__" "$(cv_path_safe_component "..")" "a bare '..' component is neutralized rather than left as a parent-dir traversal"

start_case "cv_path_safe_component: a bare '.' is still neutralized"
assert_eq "_" "$(cv_path_safe_component ".")" "a bare '.' component is neutralized rather than left as a self-dir reference"

# ---------------------------------------------------------------------------
# cv_marshal_send_digest (fk-9oigyg review LOW-7: the "bail if nothing
# flagged / send one digest mail / warn on failure" tail block was repeated
# verbatim across all three marshal sweep scripts with only labels varying).
# ---------------------------------------------------------------------------
MARSHAL_DIGEST_STUBDIR="$(mktemp -d "${TMPDIR:-/tmp}/cv-lib-digest-stub.XXXXXX")"
cat > "${MARSHAL_DIGEST_STUBDIR}/gc" <<'DIGEST_STUB'
#!/usr/bin/env bash
if [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ]; then
  echo "stub mail send failure" >&2
  exit 1
fi
exit 0
DIGEST_STUB
chmod +x "${MARSHAL_DIGEST_STUBDIR}/gc"

start_case "cv_marshal_send_digest: a successful send returns 0 and prints nothing to stderr"
digest_err="$( (
  export PATH="${MARSHAL_DIGEST_STUBDIR}:${PATH}"
  export GC="gc"
  export GC_CITY="."
  cv_marshal_send_digest 5 mayor "SUBJECT" "BODY" "test-script" "1 entry"
) 2>&1 1>/dev/null )"
digest_rc=$?
assert_eq "0" "$digest_rc" "returns 0 on a successful mail send"
assert_eq "" "$digest_err" "no WARNING on a successful send"

start_case "cv_marshal_send_digest: a failed send returns non-zero and logs a WARNING naming the script and pending count"
digest_err="$( (
  export PATH="${MARSHAL_DIGEST_STUBDIR}:${PATH}"
  export GC="gc"
  export GC_CITY="."
  export STUB_MAIL_SEND_FAIL=1
  cv_marshal_send_digest 5 mayor "SUBJECT" "BODY" "test-script" "1 entry"
) 2>&1 1>/dev/null )"
digest_rc=$?
if [ "$digest_rc" -eq 0 ]; then fail "should return non-zero when mail send fails"; else pass "returns non-zero when mail send fails"; fi
assert_contains "$digest_err" "test-script: WARNING: digest mail to mayor failed" "warns which script and target failed"
assert_contains "$digest_err" "1 entry" "warning names the caller-supplied pending-state description"
rm -rf "$MARSHAL_DIGEST_STUBDIR"

# ---------------------------------------------------------------------------
# cv_marshal_prune_state_dir (fk-9oigyg review LOW-2: per-bead/step/session
# state files in CV_STATE_DIR are never garbage-collected; a bounded,
# age-based prune keeps the directory from growing unbounded over a
# long-lived city without needing to know which ids are still live).
# ---------------------------------------------------------------------------
PRUNE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cv-lib-prune-test.XXXXXX")"
touch "${PRUNE_DIR}/fresh-file"
touch -t 202001010000 "${PRUNE_DIR}/ancient-file"
mkdir -p "${PRUNE_DIR}/root-subdir"
touch "${PRUNE_DIR}/root-subdir/fresh-nested"
touch -t 202001010000 "${PRUNE_DIR}/root-subdir/ancient-nested"

start_case "cv_marshal_prune_state_dir: removes only files older than the TTL, recursively, leaves the tree in place"
cv_marshal_prune_state_dir "$PRUNE_DIR" 30
assert_eq "0" "$([ -f "${PRUNE_DIR}/fresh-file" ] && echo 0 || echo 1)" "a fresh top-level file survives the prune"
assert_eq "1" "$([ -f "${PRUNE_DIR}/ancient-file" ] && echo 0 || echo 1)" "an ancient top-level file is pruned"
assert_eq "0" "$([ -f "${PRUNE_DIR}/root-subdir/fresh-nested" ] && echo 0 || echo 1)" "a fresh nested file survives the prune"
assert_eq "1" "$([ -f "${PRUNE_DIR}/root-subdir/ancient-nested" ] && echo 0 || echo 1)" "an ancient nested file is pruned"
assert_eq "0" "$([ -d "${PRUNE_DIR}/root-subdir" ] && echo 0 || echo 1)" "the subdirectory itself is left in place"

start_case "cv_marshal_prune_state_dir: a missing directory is a no-op, never an error"
if cv_marshal_prune_state_dir "${PRUNE_DIR}/does-not-exist" 30; then pass "missing dir is a no-op that still returns 0"; else fail "missing dir should not error"; fi
rm -rf "$PRUNE_DIR"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
