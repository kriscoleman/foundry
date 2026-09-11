#!/usr/bin/env bash
# con-voyage-ci-repair-guard.test.sh — hermetic, offline test proving the
# ci-repair bead guard only ever leaves operator-authored repair beads open,
# and that con-voyage-ci-repair.md itself carries a fail-closed Step 0 author
# gate plus a non-destructive-only CI retrigger path.
#
# This is a security-critical suite: a con-voyage-ci-repair bead can be minted
# for ANY PR by the native [[github.pr_monitor]] (no author filter), by
# con-voyage-pr-watch.sh, or by a manual mis-sling. Two independent layers must
# fail closed on a non-operator PR:
#   R2 — pack/assets/scripts/con-voyage-ci-repair-guard.sh sweeps open beads
#        and closes any not authored by CV_PR_AUTHOR BEFORE a worker can claim
#        them and take any GitHub action.
#   R1 — pack/assets/workflows/con-voyage-ci-repair/{target}.ci-repair.md
#        carries its own Step 0 re-check in case the sweep loses a claim race.
# R4 (non-destructive retrigger) is also re-asserted here as a content check.
#
# HOW IT WORKS (no network, no real gc/gh):
#   - We build recording STUB executables named `gh` and `gc` in a temp dir,
#     the same pattern as con-voyage-pr-watch.test.sh. Each stub returns canned
#     JSON per subcommand AND appends its full argv to a per-binary call-log.
#   - The guard script honors GH=/GC= (GH="${GH:-gh}", GC="${GC:-gc}"), so we
#     point it at the stubs. GC_CITY points at a throwaway dir.
#   - R1/R4 coverage reads the real, shipped {target}.ci-repair.md content —
#     no stubs involved, since that file is an LLM prompt, not a script.
#
# Run:  bash tests/con-voyage-ci-repair-guard.test.sh   (exit 0 => all passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script and prompt file under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-ci-repair-guard.sh"
CI_REPAIR_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage-ci-repair/{target}.ci-repair.md"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

if [ ! -f "$CI_REPAIR_MD" ]; then
  echo "FATAL: prompt file under test not found at ${CI_REPAIR_MD}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-ci-repair-guard-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gh` stub. Records argv, returns canned JSON keyed off the PR number.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GH_LOG}"

sub="${1:-}"
case "$sub" in
  api)
    # `gh api user --jq .login` — configurable login for default-resolution tests.
    if [ "${STUB_GH_USER_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    if [ -n "${STUB_GH_USER_LOGIN:-}" ]; then
      printf '%s\n' "${STUB_GH_USER_LOGIN}"
    fi
    exit 0
    ;;
  pr)
    prsub="${2:-}"
    num="${3:-}"
    case "$prsub" in
      view)
        # `gh pr view <n> --repo R --json author --jq .author.login`
        case "$num" in
          11)  echo "kriscoleman" ;;      # operator — KEEP
          500) echo "evansmungai" ;;      # other human — DROP
          700) echo "kriscoleman2" ;;     # near-match — DROP (exact match only)
          701) echo "KRISCOLEMAN" ;;      # case variant — DROP (case-sensitive)
          800) echo "" ;;                 # unresolved author — DROP (fail closed)
          *)   echo "" ;;
        esac
        exit 0
        ;;
    esac
    ;;
esac
exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv. Serves `bd list` (step beads) and `bd show`
# (root beads) with a fixed fixture set, and no-ops update/close (recorded).
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG}"

# gc is invoked as: gc --city <dir> <subcommand> ...
args=("$@")
i=0
if [ "${args[0]:-}" = "--city" ]; then
  i=2
fi
sub="${args[$i]:-}"
sub2="${args[$((i+1))]:-}"

if [ "$sub" = "bd" ] && [ "$sub2" = "list" ]; then
  # Selector-sensitive: only serve the fixture when the real selector this
  # guard depends on is present in argv. A future regression to a different
  # (or missing) selector must zero the fixture and fail the case 2-5
  # drop-count assertions below, not silently keep passing against stale data.
  call_line=""
  for a in "${args[@]}"; do call_line="${call_line}${a} "; done
  case "$call_line" in
    *"--status open"*"--has-metadata-key gc.root_bead_id"*) ;;
    *)
      printf '[]\n'
      exit 0
      ;;
  esac
  case "${STUB_STEPLIST_MODE:-full}" in
    empty)
      printf '[]\n'
      ;;
    full)
      cat <<'JSON'
[
  {"id":"step-op","status":"open","metadata":{"gc.root_bead_id":"root-op"}},
  {"id":"step-other","status":"open","metadata":{"gc.root_bead_id":"root-other"}},
  {"id":"step-unresolved","status":"open","metadata":{"gc.root_bead_id":"root-unresolved"}},
  {"id":"step-nearmatch","status":"open","metadata":{"gc.root_bead_id":"root-nearmatch"}},
  {"id":"step-casevariant","status":"open","metadata":{"gc.root_bead_id":"root-casevariant"}},
  {"id":"step-notformula","status":"open","metadata":{"gc.root_bead_id":"root-notformula"}}
]
JSON
      ;;
  esac
  exit 0
fi

if [ "$sub" = "bd" ] && [ "$sub2" = "show" ]; then
  root_id="${args[$((i+2))]:-}"
  case "$root_id" in
    root-op)
      printf '[{"id":"root-op","metadata":{"gc.formula_name":"con-voyage-ci-repair","gc.var.pr":"11","gc.var.repo":"kriscoleman/foundry"}}]\n'
      ;;
    root-other)
      printf '[{"id":"root-other","metadata":{"gc.formula_name":"con-voyage-ci-repair","gc.var.pr":"500","gc.var.repo":"kriscoleman/foundry"}}]\n'
      ;;
    root-unresolved)
      printf '[{"id":"root-unresolved","metadata":{"gc.formula_name":"con-voyage-ci-repair","gc.var.pr":"800","gc.var.repo":"kriscoleman/foundry"}}]\n'
      ;;
    root-nearmatch)
      printf '[{"id":"root-nearmatch","metadata":{"gc.formula_name":"con-voyage-ci-repair","gc.var.pr":"700","gc.var.repo":"kriscoleman/foundry"}}]\n'
      ;;
    root-casevariant)
      printf '[{"id":"root-casevariant","metadata":{"gc.formula_name":"con-voyage-ci-repair","gc.var.pr":"701","gc.var.repo":"kriscoleman/foundry"}}]\n'
      ;;
    root-notformula)
      printf '[{"id":"root-notformula","metadata":{"gc.formula_name":"some-other-formula","gc.var.pr":"999","gc.var.repo":"someone/else"}}]\n'
      ;;
    *)
      printf '[]\n'
      ;;
  esac
  exit 0
fi

# Unknown call (bd update, bd close, sling, run, etc.) — record already done above; succeed quietly.
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# ---------------------------------------------------------------------------
# Test harness bookkeeping.
# ---------------------------------------------------------------------------
FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

log_count() {
  local logfile="$1" pattern="$2"
  [ -f "$logfile" ] || { echo 0; return; }
  local n
  n="$(grep -E -c "$pattern" "$logfile")"
  printf '%s' "${n:-0}"
}

assert_log_count() {
  local n; n="$(log_count "$1" "$2")"
  assert_eq "$3" "$n" "$4"
}

CITY_DIR=""
GH_LOG=""
GC_LOG=""
OUT=""
RC=0

setup_case_env() {
  CITY_DIR="${SANDBOX}/city-${1}"
  mkdir -p "$CITY_DIR"
  GH_LOG="${SANDBOX}/gh-${1}.log"
  GC_LOG="${SANDBOX}/gc-${1}.log"
  : > "$GH_LOG"
  : > "$GC_LOG"
}

run_script() {
  OUT="$(
    env \
      GH="${STUBDIR}/gh" \
      GC="${STUBDIR}/gc" \
      GC_CITY="$CITY_DIR" \
      STUB_GH_LOG="$GH_LOG" \
      STUB_GC_LOG="$GC_LOG" \
      "$@" \
      bash "$SCRIPT" 2>&1
  )"
  RC=$?
}

# ===========================================================================
# CASE 1 — Fail-closed: CV_PR_AUTHOR unset AND gh api user resolves empty.
#   Expect exit 1 and ZERO bd list / bd show / gh pr view calls (bail early).
# ===========================================================================
start_case "1: fail-closed when CV_PR_AUTHOR unresolved"
setup_case_env "1"
run_script CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="" STUB_GH_USER_FAIL=1
assert_eq "1" "$RC" "script exits 1 (fail closed)"
assert_log_count "$GC_LOG" 'bd list' 0 "zero 'bd list' calls"
assert_log_count "$GH_LOG" 'pr view'  0 "zero 'gh pr view' calls"
if printf '%s' "$OUT" | grep -q 'FATAL: CV_PR_AUTHOR is empty'; then
  pass "prints fail-closed FATAL message"
else
  fail "expected fail-closed FATAL message in output"
fi

# ===========================================================================
# CASE 2 — Full sweep: operator bead kept, non-operator bead dropped, and
#   the guard NEVER takes a GitHub write action (only reads via gh pr view).
# ===========================================================================
start_case "2: guard drops non-operator bead, keeps operator bead"
setup_case_env "2"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd update step-op'    0 "operator bead is never updated"
assert_log_count "$GC_LOG" 'bd close step-op'     0 "operator bead is never closed"
assert_log_count "$GC_LOG" 'bd close step-other'  1 "non-operator bead #500 is closed exactly once"
assert_log_count "$GC_LOG" 'bd update step-other' 1 "non-operator bead #500 gets a drop note"
# The sweep must be unbounded: bd list defaults to 50 results, and silently
# dropping beads past the 50th would defeat the whole point of this guard.
assert_log_count "$GC_LOG" 'bd list .*--limit 0' 1 "bd list overrides the default 50-result limit"
# Pin the exact selector so a future edit can't silently narrow it back to a
# compiler-internal key (gc.step_id/gc.step_ref) that isn't guaranteed set —
# see the empirical finding recorded above the bd list call in guard.sh.
assert_log_count "$GC_LOG" 'bd list --status open --has-metadata-key gc\.root_bead_id --limit 0' 1 "bd list uses the prefix-independent gc.root_bead_id selector"
# Zero external GitHub-mutating action anywhere, on any bead, in either log.
assert_log_count "$GH_LOG" 'run rerun'   0 "guard never calls gh run rerun"
assert_log_count "$GH_LOG" 'pr comment'  0 "guard never calls gh pr comment"
assert_log_count "$GH_LOG" 'pr review'   0 "guard never calls gh pr review"
assert_log_count "$GC_LOG" 'sling'       0 "guard never calls gc sling"

# ===========================================================================
# CASE 3 — Exact, case-sensitive match: #700 (kriscoleman2) and #701
#   (KRISCOLEMAN) are both dropped — no bypass via prefix or case.
# ===========================================================================
start_case "3: exact case-sensitive match (no bypass)"
setup_case_env "3"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-nearmatch'    1 "near-match author (kriscoleman2) is dropped"
assert_log_count "$GC_LOG" 'bd close step-casevariant'  1 "case-variant author (KRISCOLEMAN) is dropped"

# ===========================================================================
# CASE 4 — Unresolved PR author (#800): dropped, fail closed.
# ===========================================================================
start_case "4: unresolved PR author is dropped (fail closed)"
setup_case_env "4"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-unresolved' 1 "unresolved-author bead is dropped"
if printf '%s' "$OUT" | grep -q 'DROP step-unresolved'; then
  pass "logs explicit DROP for step-unresolved"
else
  fail "expected DROP log line for step-unresolved"
fi

# ===========================================================================
# CASE 5 — A bead whose root is NOT a con-voyage-ci-repair formula is left
#   completely untouched (never inspected via gh, never closed).
# ===========================================================================
start_case "5: non-matching formula bead is skipped entirely"
setup_case_env "5"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-notformula' 0 "non-matching-formula bead is never closed"
assert_log_count "$GH_LOG" 'pr view 999' 0 "non-matching-formula bead's PR is never even looked up"

# ===========================================================================
# CASE 6 — Empty sweep: no open con-voyage-ci-repair beads found.
# ===========================================================================
start_case "6: empty sweep is a clean no-op"
setup_case_env "6"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_STEPLIST_MODE="empty"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" 'pr view' 0 "no gh pr view calls when nothing is open"
if printf '%s' "$OUT" | grep -q 'no open con-voyage-ci-repair beads found'; then
  pass "logs the empty-sweep message"
else
  fail "expected empty-sweep message"
fi

# ===========================================================================
# CASE 7 (R1 content coverage) — {target}.ci-repair.md carries a Step 0
#   fail-closed author gate, positioned before Step 1 and before the rerun /
#   push commands (ci-repair.md:56,59 rerun; ci-repair.md:195 push, at the
#   time this suite was authored — asserted here by relative ORDER, not fixed
#   line numbers, so the check survives future edits above these sections).
# ===========================================================================
start_case "7: ci-repair.md has a Step 0 author gate before rerun/push"
if grep -q 'CV_PR_AUTHOR' "$CI_REPAIR_MD"; then
  pass "ci-repair.md references CV_PR_AUTHOR"
else
  fail "ci-repair.md does not reference CV_PR_AUTHOR anywhere"
fi

step0_line=$(grep -n '^## Step 0' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
step1_line=$(grep -n '^## Step 1' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
first_rerun_line=$(grep -n 'gh run rerun' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)
push_line=$(grep -n '^git push origin' "$CI_REPAIR_MD" | head -1 | cut -d: -f1)

if [ -n "$step0_line" ]; then
  pass "found a '## Step 0' section"
else
  fail "no '## Step 0' section found in ci-repair.md"
fi

if [ -n "$step0_line" ] && [ -n "$step1_line" ] && [ "$step0_line" -lt "$step1_line" ]; then
  pass "Step 0 (line ${step0_line:-?}) precedes Step 1 (line ${step1_line:-?})"
else
  fail "Step 0 does not precede Step 1 (step0=${step0_line:-missing}, step1=${step1_line:-missing})"
fi

if [ -n "$step0_line" ] && [ -n "$first_rerun_line" ] && [ "$step0_line" -lt "$first_rerun_line" ]; then
  pass "Step 0 (line ${step0_line:-?}) precedes the first 'gh run rerun' (line ${first_rerun_line:-?})"
else
  fail "Step 0 does not precede 'gh run rerun' (step0=${step0_line:-missing}, rerun=${first_rerun_line:-missing})"
fi

if [ -n "$step0_line" ] && [ -n "$push_line" ] && [ "$step0_line" -lt "$push_line" ]; then
  pass "Step 0 (line ${step0_line:-?}) precedes 'git push origin' (line ${push_line:-?})"
else
  fail "Step 0 does not precede 'git push origin' (step0=${step0_line:-missing}, push=${push_line:-missing})"
fi

if grep -q 'dropped: not authored by operator' "$CI_REPAIR_MD"; then
  pass "Step 0 closes with a 'dropped: not authored by operator' note"
else
  fail "expected a 'dropped: not authored by operator' close note in ci-repair.md"
fi

# ===========================================================================
# CASE 8 (R4 content coverage) — non-destructive retrigger path is present,
#   and the forbidden destructive tactics are still explicitly disallowed.
# ===========================================================================
start_case "8: ci-repair.md keeps the non-destructive retrigger contract"
if grep -q 'gh run rerun <run-id> --failed --repo' "$CI_REPAIR_MD"; then
  pass "asserts the run-specific, failed-only rerun path"
else
  fail "expected 'gh run rerun <run-id> --failed --repo' rerun path"
fi
if grep -qi 'do not close and reopen the pr' "$CI_REPAIR_MD"; then
  pass "forbids close+reopen retrigger"
else
  fail "expected an explicit prohibition on close+reopen retrigger"
fi
if grep -qi 'do not push an empty commit' "$CI_REPAIR_MD"; then
  pass "forbids empty-commit retrigger"
else
  fail "expected an explicit prohibition on empty-commit retrigger"
fi
if grep -qi 'do not force-push' "$CI_REPAIR_MD"; then
  pass "forbids force-push retrigger"
else
  fail "expected an explicit prohibition on force-push retrigger"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
