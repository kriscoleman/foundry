#!/usr/bin/env bash
# con-voyage-pr-watch.test.sh — hermetic, offline test proving the PR monitor
# only ever acts on the operator's own PRs (author scoping).
#
# This is a security-critical test: an earlier unfiltered version of the monitor
# acted on 43 PRs it did not own and got the operator removed from the org. The
# script under test (pack/assets/scripts/con-voyage-pr-watch.sh) enforces a hard
# author-scoping invariant, and this suite proves it.
#
# HOW IT WORKS (no network, no real gc/gh):
#   - We build recording STUB executables named `gh` and `gc` in a temp dir.
#     Each stub returns canned JSON per subcommand AND appends its full argv to
#     a per-binary call-log. The tests assert on those logs.
#   - The script honors GH= / GC= (GH="${GH:-gh}", GC="${GC:-gc}") so we point
#     it at the stubs. GC_CITY and CV_STATE_DIR point at temp dirs.
#   - Stub behavior is switched per test case via env vars read by the stubs
#     (STUB_GH_USER_LOGIN, STUB_PRLIST_MODE, STUB_BACKFILL_MODE, etc.), so a
#     single pair of stubs covers every scenario deterministically.
#
# Run:  bash tests/con-voyage-pr-watch.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-pr-watch.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-pr-watch-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gh` stub. Records argv, returns canned JSON, and varies its output by
# subcommand + env-var switches so one stub serves every test case.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
# Recording gh stub. Appends full argv (one space-joined line per invocation)
# to $STUB_GH_LOG, then emulates gh. Newlines within an arg are squashed to
# spaces so each invocation stays on exactly one line (grep-friendly).
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GH_LOG}"

# Helper: read the value following a flag in the argv (e.g. --repo X).
flagval() {
  local want="$1"; shift
  local prev=""
  for a in "$@"; do
    if [ "$prev" = "$want" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  return 1
}

sub="${1:-}"
case "$sub" in
  auth)
    # `gh auth status` — always OK in tests.
    exit 0
    ;;
  api)
    # `gh api user --jq .login` — configurable login for default-resolution tests.
    # STUB_GH_USER_LOGIN unset/empty => emit nothing (simulates unresolvable).
    # STUB_GH_USER_FAIL=1 => exit non-zero.
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
    case "$prsub" in
      list)
        # `gh pr list --repo R --author A --state open --json ...`
        # Vary by --author to prove filtering: only the configured operator's
        # PRs are returned; any other author yields an empty list.
        author="$(flagval --author "$@")"
        if [ "$author" = "kriscoleman" ]; then
          # Operator owns only PR #11 (open, non-draft).
          cat <<'JSON'
[{"number":11,"headRefName":"fix/con-voyage-author-scope-pr-monitor","url":"https://github.com/kriscoleman/foundry/pull/11","isDraft":false}]
JSON
        else
          # Any non-operator author sees nothing.
          printf '[]\n'
        fi
        exit 0
        ;;
      view)
        # Two shapes:
        #   gh pr view <n> --repo R --json author --jq .author.login   (PART A)
        #   gh pr view <n> --repo R --json reviews,comments,reviewThreads (PART B)
        num="${3:-}"
        jsonfields="$(flagval --json "$@")"
        if printf '%s' "$jsonfields" | grep -q 'reviews'; then
          # PART B comment fetch. Return one human comment for the operator's PR.
          cat <<'JSON'
{"reviews":[],"comments":[{"id":"IC_test_11","author":{"login":"a-human-reviewer"},"body":"please fix the null check"}],"reviewThreads":[]}
JSON
          exit 0
        fi
        # PART A author resolution. Map PR number -> canned author.
        case "$num" in
          11)  echo "kriscoleman" ;;      # operator — KEEP
          500) echo "evansmungai" ;;      # other human — DROP
          600) echo "dependabot[bot]" ;;  # bot — DROP
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
# Unknown call — record already done; succeed quietly.
exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv, returns canned backfill JSON, and no-ops sling.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
# Recording gc stub. Appends full argv (one space-joined line per invocation)
# to $STUB_GC_LOG, then emulates gc. Newlines within an arg are squashed to
# spaces so each invocation stays on exactly one line (grep-friendly).
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG}"

# gc is invoked as: gc --city <dir> <subcommand> ...
# Strip the leading `--city <dir>` if present to find the real subcommand.
args=("$@")
i=0
if [ "${args[0]:-}" = "--city" ]; then
  i=2
fi
sub="${args[$i]:-}"

case "$sub" in
  github)
    # gc --city X github pr backfill --json
    if [ "${args[$((i+1))]:-}" = "pr" ] && [ "${args[$((i+2))]:-}" = "backfill" ]; then
      case "${STUB_BACKFILL_MODE:-full}" in
        empty)
          printf '{"results":[]}\n'
          ;;
        full)
          # Mixed authors + actionability. Exactly the cases the test needs.
          cat <<'JSON'
{"results":[
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":11,"title":"author-scope pr monitor","head_ref_name":"fix/con-voyage-author-scope-pr-monitor","head_sha":"aaa111","repair_route":"gc.implementation-worker"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":500,"title":"someone elses pr","head_ref_name":"feature/x","head_sha":"bbb500","repair_route":"gc.implementation-worker"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":600,"title":"dep bump","head_ref_name":"deps/y","head_sha":"ccc600","repair_route":"gc.implementation-worker"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":700,"title":"near match author","head_ref_name":"feature/z","head_sha":"ddd700","repair_route":"gc.implementation-worker"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":701,"title":"case variant author","head_ref_name":"feature/w","head_sha":"eee701","repair_route":"gc.implementation-worker"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":800,"title":"unresolved author","head_ref_name":"feature/u","head_sha":"fff800","repair_route":"gc.implementation-worker"},
  {"actionable":false,"owner":"kriscoleman","repo":"foundry","number":999,"title":"not actionable","head_ref_name":"feature/na","head_sha":"999999","repair_route":"gc.implementation-worker"}
]}
JSON
          ;;
      esac
      exit 0
    fi
    exit 0
    ;;
  sling)
    # Record only (already done above). Succeed.
    exit 0
    ;;
esac
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

# assert_eq EXPECTED ACTUAL MESSAGE
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

# Count how many stub invocations in a log match a grep -E pattern.
# Each invocation is one space-joined line in the log (see stub logging above),
# so a plain line-oriented grep -c is exact.
log_count() {
  local logfile="$1" pattern="$2"
  [ -f "$logfile" ] || { echo 0; return; }
  # grep -c prints the count and exits 1 when zero matches; capture the count
  # regardless of exit status (do NOT chain `|| echo 0`, which double-prints).
  local n
  n="$(grep -E -c "$pattern" "$logfile")"
  printf '%s' "${n:-0}"
}

# assert_log_count LOGFILE PATTERN EXPECTED MESSAGE
assert_log_count() {
  local n; n="$(log_count "$1" "$2")"
  assert_eq "$3" "$n" "$4"
}

# Fresh per-case environment. Sets up city dir, state dir, empty logs.
CITY_DIR=""
STATE_DIR=""
GH_LOG=""
GC_LOG=""
OUT=""
RC=0

setup_case_env() {
  CITY_DIR="${SANDBOX}/city-${1}"
  STATE_DIR="${SANDBOX}/state-${1}"
  GH_LOG="${SANDBOX}/gh-${1}.log"
  GC_LOG="${SANDBOX}/gc-${1}.log"
  mkdir -p "$CITY_DIR" "$STATE_DIR"
  : > "$GH_LOG"
  : > "$GC_LOG"
  # A city.toml with one pr_monitor block so PART B has a repo to scan.
  # NOTE: no spaces around `=`. Both are valid TOML, but the script parses this
  # with awk using `\s` in its regexes, which BSD/macOS awk treats as a literal
  # 's' (only GNU awk honors `\s`). Writing `owner="..."` (no space) parses
  # correctly under BOTH awk flavors, keeping this test deterministic on macOS
  # and Linux alike. (The production gc runtime is Linux/gawk, where either
  # spacing works; this fixture just stays portable.)
  cat > "${CITY_DIR}/city.toml" <<'TOML'
[[github.pr_monitor]]
owner="kriscoleman"
repo="foundry"
base="main"
merge_queue="observe"
TOML
}

# run_script — invoke the script under test with the stubs wired in.
# Extra args ("$@") are KEY=VAL overrides passed to `env`. To simulate an unset
# CV_PR_AUTHOR, pass CV_PR_AUTHOR="" — the script treats empty and unset
# identically (it does `${CV_PR_AUTHOR:-}` then a `-z` check), and this avoids
# BSD `env -u` operand-ordering quirks on macOS.
# Captures combined stdout+stderr into $OUT and the exit code into $RC.
run_script() {
  OUT="$(
    env \
      GH="${STUBDIR}/gh" \
      GC="${STUBDIR}/gc" \
      GC_CITY="$CITY_DIR" \
      CV_STATE_DIR="$STATE_DIR" \
      STUB_GH_LOG="$GH_LOG" \
      STUB_GC_LOG="$GC_LOG" \
      "$@" \
      bash "$SCRIPT" 2>&1
  )"
  RC=$?
}

# ===========================================================================
# CASE 1 — Fail-closed: CV_PR_AUTHOR unset AND gh api user resolves empty.
#   Expect exit 1 and ZERO pr list / pr view / gc sling calls (bail early).
# ===========================================================================
start_case "1: fail-closed when author unresolved"
setup_case_env "1"
# CV_PR_AUTHOR unset; gh api user emits nothing.
run_script CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="" STUB_GH_USER_FAIL=1
assert_eq "1" "$RC" "script exits 1 (fail closed)"
assert_log_count "$GH_LOG" 'pr list' 0 "zero 'gh pr list' calls"
assert_log_count "$GH_LOG" 'pr view' 0 "zero 'gh pr view' calls"
assert_log_count "$GC_LOG" 'sling'   0 "zero 'gc sling' calls"
if printf '%s' "$OUT" | grep -q 'FATAL: CV_PR_AUTHOR is empty'; then
  pass "prints fail-closed FATAL message"
else
  fail "expected fail-closed FATAL message in output"
fi

# ===========================================================================
# CASE 2 — PART A author drop: only the operator's PR (#11) gets a repair bead.
#   #500 (other human), #600 (bot) must NEVER be slung.
# ===========================================================================
start_case "2: PART A slings only operator PR, drops others"
setup_case_env "2"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_PRLIST_MODE="operator"
assert_eq "0" "$RC" "script exits 0"
# Exactly one CI-repair sling, and it is for PR #11.
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 1 "exactly one ci-repair sling"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11' 1 "ci-repair sling is for pr=11"
assert_log_count "$GC_LOG" 'sling .*pr=500' 0 "no sling for #500 (other human)"
assert_log_count "$GC_LOG" 'sling .*pr=600' 0 "no sling for #600 (bot)"

# ===========================================================================
# CASE 3 — PART A exact, case-sensitive match: #700 (kriscoleman2) and
#   #701 (KRISCOLEMAN) both dropped — no bypass via prefix or case.
# ===========================================================================
start_case "3: PART A exact case-sensitive match (no bypass)"
setup_case_env "3"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=700' 0 "no sling for #700 (kriscoleman2 near-match)"
assert_log_count "$GC_LOG" 'sling .*pr=701' 0 "no sling for #701 (KRISCOLEMAN case variant)"

# ===========================================================================
# CASE 4 — PART A unresolved author (#800): dropped, no bead.
# ===========================================================================
start_case "4: PART A drops PR with unresolved author"
setup_case_env "4"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=800' 0 "no sling for #800 (unresolved author)"
# And confirm the DROP was logged with the unresolved marker.
if printf '%s' "$OUT" | grep -q 'DROP kriscoleman/foundry#800'; then
  pass "logs explicit DROP for #800"
else
  fail "expected DROP log line for #800"
fi

# ===========================================================================
# CASE 5 — PART B author filter: gh pr list carries --author kriscoleman,
#   and comment-routing only happens for the operator's PR (#11). No
#   non-operator PR is ever viewed for comments.
# ===========================================================================
start_case "5: PART B scopes pr list + comment routing to operator"
setup_case_env "5"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
# gh pr list must be called with --author kriscoleman.
assert_log_count "$GH_LOG" 'pr list .*--author kriscoleman' 1 "gh pr list uses --author kriscoleman"
# The stub returns only #11 for that author, so a comment-routing sling should
# fire to the implementor for #11's human comment. PART B comment slings carry
# a "Human PR feedback on ..." title (PART A repair slings carry --on
# con-voyage-ci-repair instead), so match on that to isolate PART B.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker .*Human PR feedback on kriscoleman/foundry#11' 1 "one comment-route sling to implementor for #11"
# And that comment route is NOT a ci-repair (PART A) sling.
assert_log_count "$GC_LOG" 'sling .*Human PR feedback.*--on con-voyage-ci-repair' 0 "comment route is not a ci-repair sling"
# Belt-and-suspenders: a comment fetch (pr view --json reviews,...) happened for
# #11 and for no other PR number in PART B.
assert_log_count "$GH_LOG" 'pr view 11 .*reviews' 1 "comment fetch for #11 only"
assert_log_count "$GH_LOG" 'pr view 500 .*reviews' 0 "no comment fetch for #500"

# ===========================================================================
# CASE 6 — Happy-path default: CV_PR_AUTHOR unset, gh api user => kriscoleman.
#   Script proceeds (exit 0), logs the author-scoped banner, and behaves like
#   cases 2 & 5 (slings for #11, drops others).
# ===========================================================================
start_case "6: default author resolution from gh api user"
setup_case_env "6"
run_script CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
if printf '%s' "$OUT" | grep -q "author-scoped to PRs authored by 'kriscoleman'"; then
  pass "logs author-scoped banner with resolved login"
else
  fail "expected author-scoped banner naming kriscoleman"
fi
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11' 1 "ci-repair sling for #11 under default resolution"
assert_log_count "$GC_LOG" 'sling .*pr=500' 0 "no sling for #500 under default resolution"
assert_log_count "$GH_LOG" 'pr list .*--author kriscoleman' 1 "PART B pr list scoped to resolved login"

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
