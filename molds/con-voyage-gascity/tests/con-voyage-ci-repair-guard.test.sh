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
  # Infra-failure injection (LOW-1): simulate a transient store error on the
  # sweep's fetch. The guard retries a bounded number of times, then WARNs and
  # exits 0 (fail-open on infra, deferring to Step 0) — it must NOT proceed to
  # close beads it could not enumerate.
  if [ "${STUB_BDLIST_FAIL:-0}" = "1" ]; then
    exit 1
  fi
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
    noprrepo)
      # A single con-voyage-ci-repair step whose root resolves but is MISSING
      # gc.var.pr / gc.var.repo — exercises the :pr/repo-unresolved fail-CLOSED
      # DROP (bd close, no gh pr view), distinct from the bd-show fail-open SKIP.
      printf '[{"id":"step-noprrepo","status":"open","metadata":{"gc.root_bead_id":"root-noprrepo"}}]\n'
      ;;
    showfail)
      # A single step whose root bd show FAILS (STUB_BDSHOW_FAIL) — exercises
      # the fail-OPEN skip: no formula resolves, so the bead is left untouched.
      printf '[{"id":"step-showfail","status":"open","metadata":{"gc.root_bead_id":"root-showfail"}}]\n'
      ;;
    retry)
      # A single non-operator step used to prove drop_bead's bounded retry: the
      # bd close for it is made to fail a fixed number of times before it takes.
      printf '[{"id":"step-retry","status":"open","metadata":{"gc.root_bead_id":"root-retry"}}]\n'
      ;;
  esac
  exit 0
fi

if [ "$sub" = "bd" ] && [ "$sub2" = "show" ]; then
  root_id="${args[$((i+2))]:-}"
  # Infra-failure injection (LOW-1): a bd show failure means the root's formula
  # cannot be resolved, so the guard SKIPS the bead (fail-open) — it must not
  # close a bead it could not classify.
  if [ "${STUB_BDSHOW_FAIL:-0}" = "1" ] && [ "$root_id" = "root-showfail" ]; then
    exit 1
  fi
  case "$root_id" in
    root-op)
      printf '[{"id":"root-op","metadata":{"gc.formula_name":"con-voyage-ci-repair","gc.var.pr":"11","gc.var.repo":"kriscoleman/foundry"}}]\n'
      ;;
    root-noprrepo)
      # con-voyage-ci-repair root, but pr/repo vars absent — fail-closed DROP.
      printf '[{"id":"root-noprrepo","metadata":{"gc.formula_name":"con-voyage-ci-repair"}}]\n'
      ;;
    root-retry)
      # con-voyage-ci-repair root for a non-operator PR (#500) — will be dropped;
      # its bd close is made to fail-then-succeed to prove the bounded retry.
      printf '[{"id":"root-retry","metadata":{"gc.formula_name":"con-voyage-ci-repair","gc.var.pr":"500","gc.var.repo":"kriscoleman/foundry"}}]\n'
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

if [ "$sub" = "bd" ] && [ "$sub2" = "close" ]; then
  # Transient-close-failure injection (NEW LOW): if a fail-count file is set for
  # this exact bead, fail the close while the counter is positive (decrementing
  # each attempt), then succeed. Proves drop_bead retries a locked close instead
  # of silently no-oping it under `|| true`.
  close_target="${args[$((i+2))]:-}"
  if [ -n "${STUB_BDCLOSE_FAIL_FILE:-}" ] && [ "${STUB_BDCLOSE_FAIL_TARGET:-}" = "$close_target" ]; then
    remaining="$(cat "$STUB_BDCLOSE_FAIL_FILE" 2>/dev/null || echo 0)"
    if [ "${remaining:-0}" -gt 0 ]; then
      printf '%s' "$((remaining - 1))" > "$STUB_BDCLOSE_FAIL_FILE"
      exit 1
    fi
  fi
  exit 0
fi

# Unknown call (bd update, sling, run, etc.) — record already done above; succeed quietly.
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
      GUARD_RETRY_SLEEP=0 \
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
# CASE 1b (LOW-2) — Guard's OWN default-author resolution SUCCESS path.
#   CASE 1 only covers the failure half of the `gh api user` fallback; every
#   other case sets CV_PR_AUTHOR explicitly. Here CV_PR_AUTHOR is empty and the
#   stub `gh api user` resolves to kriscoleman, so the guard must resolve its
#   own author and then produce the SAME keep/drop outcome as CASE 2 — proving
#   this file's copy of the resolution logic (not just pr-watch.sh's) works.
# ===========================================================================
start_case "1b: guard resolves CV_PR_AUTHOR from gh api user (success path)"
setup_case_env "1b"
run_script CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0 (author resolved via gh api user)"
if printf '%s' "$OUT" | grep -q "author-scoped to 'kriscoleman'"; then
  pass "logs author-scoped banner with the resolved login"
else
  fail "expected author-scoped banner naming kriscoleman"
fi
assert_log_count "$GC_LOG" 'bd close step-op'    0 "operator bead kept under default resolution"
assert_log_count "$GC_LOG" 'bd close step-other' 1 "non-operator bead dropped under default resolution"

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
# LOW-3: the paired drop-note (operator's forensic breadcrumb) must fire on
# these drop paths too, not just the CASE 2 non-operator path.
assert_log_count "$GC_LOG" 'bd update step-nearmatch'   1 "near-match drop leaves a drop-note"
assert_log_count "$GC_LOG" 'bd update step-casevariant' 1 "case-variant drop leaves a drop-note"

# ===========================================================================
# CASE 4 — Unresolved PR author (#800): dropped, fail closed.
# ===========================================================================
start_case "4: unresolved PR author is dropped (fail closed)"
setup_case_env "4"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-unresolved' 1 "unresolved-author bead is dropped"
# LOW-3: the unresolved-author drop must also leave the paired drop-note.
assert_log_count "$GC_LOG" 'bd update step-unresolved' 1 "unresolved-author drop leaves a drop-note"
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
# CASE 6a (LOW-1) — bd list infra failure: the sweep's fetch fails on every
#   (bounded-retry) attempt. The guard must WARN, exit 0 (fail-OPEN on infra,
#   deferring to Step 0), and make ZERO bd update / bd close / gh pr view calls
#   — it must never close a bead it could not even enumerate.
# ===========================================================================
start_case "6a: bd list failure skips the sweep with zero writes (fail-open)"
setup_case_env "6a"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BDLIST_FAIL=1
assert_eq "0" "$RC" "script exits 0 (infra failure defers, not fatal)"
if printf '%s' "$OUT" | grep -q 'WARNING: bd list failed'; then
  pass "logs the bd list WARNING"
else
  fail "expected 'WARNING: bd list failed' in output"
fi
assert_log_count "$GC_LOG" 'bd update' 0 "no bd update when the sweep can't enumerate"
assert_log_count "$GC_LOG" 'bd close'  0 "no bd close when the sweep can't enumerate"
assert_log_count "$GH_LOG" 'pr view'   0 "no gh pr view when the sweep can't enumerate"

# ===========================================================================
# CASE 6b (LOW-1) — two distinct root-inspection branches, pinned apart:
#   (i) a con-voyage-ci-repair root that RESOLVES but has pr/repo ABSENT —
#       fail-CLOSED DROP: bd close runs once, gh pr view is never called.
#   (ii) a root whose bd show FAILS (STUB_BDSHOW_FAIL) — fail-OPEN SKIP: the
#        formula can't be classified, so the bead is left untouched (no close).
# ===========================================================================
start_case "6b: pr/repo-absent root is dropped fail-closed (no gh pr view)"
setup_case_env "6b"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_STEPLIST_MODE="noprrepo"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-noprrepo'  1 "pr/repo-unresolved bead is dropped exactly once"
assert_log_count "$GC_LOG" 'bd update step-noprrepo' 1 "pr/repo-unresolved drop leaves a drop-note"
assert_log_count "$GH_LOG" 'pr view'                 0 "no gh pr view for a bead with no pr/repo"
if printf '%s' "$OUT" | grep -q 'pr/repo unresolved'; then
  pass "logs the fail-closed pr/repo-unresolved reason"
else
  fail "expected a 'pr/repo unresolved' DROP reason"
fi

start_case "6c: bd show failure skips the bead fail-open (no close)"
setup_case_env "6c"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_STEPLIST_MODE="showfail" STUB_BDSHOW_FAIL=1
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-showfail' 0 "bead whose root can't be shown is left open (fail-open)"
assert_log_count "$GH_LOG" 'pr view'                0 "no gh pr view when the root can't be shown"
if printf '%s' "$OUT" | grep -q 'WARNING: bd show failed'; then
  pass "logs the bd show WARNING"
else
  fail "expected 'WARNING: bd show failed' in output"
fi

# ===========================================================================
# CASE 6d (NEW LOW) — bounded-retry on a transient close failure. The bd close
#   for a non-operator drop is made to FAIL its first 2 attempts (Dolt-lock
#   sim) then succeed. drop_bead must retry rather than silently no-op under
#   `|| true`, so the recorded close count for this bead is 3 (2 fails + 1 ok),
#   proving the stranger's control bead really did get closed.
# ===========================================================================
start_case "6d: drop_bead retries a transient close failure (fail-closed intent kept)"
setup_case_env "6d"
CLOSE_FAIL_FILE="${SANDBOX}/close-fail-6d"
printf '2' > "$CLOSE_FAIL_FILE"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_STEPLIST_MODE="retry" \
  STUB_BDCLOSE_FAIL_FILE="$CLOSE_FAIL_FILE" \
  STUB_BDCLOSE_FAIL_TARGET="step-retry"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-retry' 3 "close is retried until it takes (2 fails + 1 success)"
# And the counter file was fully drained — no fail budget left unused.
assert_eq "0" "$(cat "$CLOSE_FAIL_FILE" 2>/dev/null || echo missing)" "all injected close failures were consumed"

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
# R6 — CONFIGURABLE AUTHOR GATE (CV_AUTHOR_GATE=enabled|disabled)
#
# PR #17 added a fail-closed author gate; R6 puts it behind a toggle. The
# toggle's contract (this is the security-critical part):
#   - CV_AUTHOR_GATE unset/enabled (DEFAULT) => today's fail-closed behavior:
#     resolve CV_PR_AUTHOR, drop every non-operator bead, and if the allow-list
#     is empty/unresolved DROP EVERYTHING (exit 1) — never a silent "work all".
#   - CV_AUTHOR_GATE=disabled => explicit, documented opt-in to work ALL PRs
#     regardless of author. This is the ONLY path that keeps a stranger's bead.
#   - Any other value => treated as enabled (fail closed on ambiguity).
#
# CV_PR_AUTHOR stays the allow-list; CV_AUTHOR_GATE is the enable/disable switch
# layered over it (mirrors gc #6280's authors allow-list + on/off concept, but
# with our incident-driven divergence: empty allow-list + gate on = drop-all,
# not work-all).
# ===========================================================================

# ---------------------------------------------------------------------------
# R6a (spec (a): enabled + author IN allow-list => WORK). Same outcome as
#   CASE 2 but with the gate toggled ON *explicitly*, pinning that an explicit
#   CV_AUTHOR_GATE=enabled is honored (not just the default).
# ---------------------------------------------------------------------------
start_case "R6a: enabled + author in allow-list keeps operator bead, drops others"
setup_case_env "R6a"
run_script CV_AUTHOR_GATE="enabled" CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-op'    0 "operator bead kept when gate explicitly enabled"
assert_log_count "$GC_LOG" 'bd close step-other' 1 "non-operator bead dropped when gate explicitly enabled"

# ---------------------------------------------------------------------------
# R6b (spec (b): enabled + author NOT in allow-list => DROP, fail closed).
#   The operator allow-list is a DIFFERENT login than any fixture PR author, so
#   EVERY resolvable bead is a non-match and must be dropped. Proves the gate
#   isn't just "keep whoever authored it".
# ---------------------------------------------------------------------------
start_case "R6b: enabled + author not in allow-list drops the bead"
setup_case_env "R6b"
run_script CV_AUTHOR_GATE="enabled" CV_PR_AUTHOR="someone-else" STUB_GH_USER_LOGIN="someone-else"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-op'    1 "operator's own bead is dropped when they aren't in the allow-list"
assert_log_count "$GC_LOG" 'bd close step-other' 1 "other-author bead is dropped too"

# ---------------------------------------------------------------------------
# R6c (spec (c) — THE INVARIANT: enabled + EMPTY/unset allow-list => DROP ALL,
#   never work-all). Gate is enabled (default) but CV_PR_AUTHOR is empty and the
#   gh-login fallback also fails. The guard MUST fail closed (exit 1) BEFORE
#   inspecting any bead — it must NOT silently treat an empty allow-list as
#   "work every PR". This is the exact org-removal-incident invariant.
# ---------------------------------------------------------------------------
start_case "R6c: enabled + empty allow-list drops everything (exit 1), never work-all"
setup_case_env "R6c"
run_script CV_AUTHOR_GATE="enabled" CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="" STUB_GH_USER_FAIL=1
assert_eq "1" "$RC" "script exits 1 (fail closed on empty allow-list, gate enabled)"
assert_log_count "$GC_LOG" 'bd list'  0 "zero 'bd list' — bails before enumerating any bead"
assert_log_count "$GC_LOG" 'bd close' 0 "zero 'bd close' — empty allow-list is NOT interpreted as work-all"
assert_log_count "$GH_LOG" 'pr view'  0 "zero 'gh pr view' — no PR is ever inspected"

# ---------------------------------------------------------------------------
# R6d (spec (d): DISABLED => WORK ALL PRs regardless of author). The explicit
#   opt-in. Every bead — operator, other-human, near-match, case-variant,
#   unresolved-author — is KEPT: ZERO bd close, zero drop-notes. This is the
#   ONLY toggle state that yields "work all". A bead whose root is not a
#   con-voyage-ci-repair formula is still left alone (that's formula scoping,
#   not author gating).
# ---------------------------------------------------------------------------
start_case "R6d: disabled works ALL PRs (no bead is ever dropped for authorship)"
setup_case_env "R6d"
run_script CV_AUTHOR_GATE="disabled" CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close' 0 "gate disabled: NOTHING is closed for authorship (work-all)"
assert_log_count "$GC_LOG" 'bd update .*not authored by operator' 0 "gate disabled: no author drop-notes written"
if printf '%s' "$OUT" | grep -qi 'author gate DISABLED'; then
  pass "logs that the author gate is disabled (work-all mode)"
else
  fail "expected a log line announcing the author gate is DISABLED"
fi

# ---------------------------------------------------------------------------
# R6e (spec (d) hardening): DISABLED must work-all even with an EMPTY
#   CV_PR_AUTHOR — the disable opt-in does NOT require an allow-list and must
#   NOT fail closed. Proves "work all" is driven purely by the toggle, never by
#   an empty allow-list fall-through (the two are decoupled).
# ---------------------------------------------------------------------------
start_case "R6e: disabled + empty allow-list still works all (no fail-closed exit)"
setup_case_env "R6e"
run_script CV_AUTHOR_GATE="disabled" CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="" STUB_GH_USER_FAIL=1
assert_eq "0" "$RC" "script exits 0 (disabled never fails closed on an empty allow-list)"
assert_log_count "$GC_LOG" 'bd close' 0 "disabled + empty allow-list keeps every bead (work-all)"

# ---------------------------------------------------------------------------
# R6f (spec (e) MUTATION GUARD #1 — default must stay ENABLED). No
#   CV_AUTHOR_GATE at all: behavior MUST be the fail-closed default (drops the
#   non-operator bead). If someone flips the default to "disabled", this case
#   flips to keeping step-other and FAILS. This is the tripwire on the safe
#   default (R6.2).
# ---------------------------------------------------------------------------
start_case "R6f: default (no toggle) is ENABLED — non-operator bead still dropped"
setup_case_env "R6f"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-other' 1 "default gate drops the non-operator bead (default == enabled)"
assert_log_count "$GC_LOG" 'bd close step-op'    0 "default gate keeps the operator bead"

# ---------------------------------------------------------------------------
# R6g (spec (e) MUTATION GUARD #2 — unrecognized value fails CLOSED as enabled).
#   A typo'd/garbage CV_AUTHOR_GATE must NOT be treated as "disabled/work-all";
#   it must fall through to the enabled (gated) behavior. If the flag parse ever
#   inverted to "anything != enabled => disabled", this case would keep the
#   non-operator bead and FAIL.
# ---------------------------------------------------------------------------
start_case "R6g: unrecognized toggle value fails closed (treated as enabled)"
setup_case_env "R6g"
run_script CV_AUTHOR_GATE="banana" CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close step-other' 1 "garbage toggle value is gated (fail-closed), non-operator bead dropped"

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
