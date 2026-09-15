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
        #
        # STUB_PRLIST_LEAK=1 simulates a leaky/bypassed upstream --author
        # filter: the returned PR carries a DIFFERENT author than requested, so
        # the script's defensive per-PR author re-check must drop it before
        # routing. The `author` object mirrors gh's `--json author` shape.
        author="$(flagval --author "$@")"
        if [ "${STUB_PRLIST_LEAK:-0}" = "1" ]; then
          # Upstream filter "leaked": PR #999 authored by someone else slips in
          # even though we asked for the operator's PRs. The defensive re-check
          # must drop it (no comment fetch, no sling).
          cat <<'JSON'
[{"number":999,"headRefName":"feature/not-ours","url":"https://github.com/kriscoleman/foundry/pull/999","isDraft":false,"author":{"login":"someone-else"}}]
JSON
        elif [ "$author" = "kriscoleman" ]; then
          # Operator owns only PR #11 (open, non-draft), authored by kriscoleman.
          cat <<'JSON'
[{"number":11,"headRefName":"fix/con-voyage-author-scope-pr-monitor","url":"https://github.com/kriscoleman/foundry/pull/11","isDraft":false,"author":{"login":"kriscoleman"}}]
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
#
# STDIN CAPTURE: `gc sling ... --stdin` reads the bead title/body from stdin
# (first line = title, rest = body). The recorded argv alone would only show
# `sling <target> --stdin`, hiding the routed content, so when --stdin is present
# we drain stdin and APPEND its (newline-squashed) content to the same log line.
# This keeps content assertions (e.g. the "Human PR feedback on ..." title)
# working after the PART B fix that switched off the (nonexistent) --body flag.
stdin_capture=""
for _a in "$@"; do
  if [ "$_a" = "--stdin" ]; then
    stdin_capture="$(cat)"
    break
  fi
done
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  if [ -n "$stdin_capture" ]; then
    sc="${stdin_capture//$'\n'/ }"
    line="${line}STDIN: ${sc} "
  fi
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

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
          #
          # STUB_HEAD_SHA overrides ONLY PR #11's head_sha (defaults to the
          # historical "aaa111" so every pre-existing case is unaffected). This
          # lets a test advance #11's branch head between cycles to prove that a
          # NEW head-sha yields a NEW dedup key and re-mints a fresh repair bead
          # (the head-sha is pinned into the dedup key in the script under test).
          # #11's line is emitted via printf (so the env var expands); the rest
          # stay in a single-quoted heredoc (byte-identical, no expansion).
          printf '{"results":[\n'
          printf '  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":11,"title":"author-scope pr monitor","head_ref_name":"fix/con-voyage-author-scope-pr-monitor","head_sha":"%s","repair_route":"gc.implementation-worker"},\n' "${STUB_HEAD_SHA:-aaa111}"
          cat <<'JSON'
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
  bd)
    # `gc [--city X] bd create "<title>" --priority N --silent`
    # Faithful stub of the repair-bead pre-create step: --silent makes real gc
    # print ONLY the new bead id on stdout. We mint a deterministic fake id so
    # the sling step (below) has a real positional bead to attach the formula to.
    #
    # STUB_BD_CREATE_FAIL=1 simulates a failed pre-create (gc prints nothing and
    # exits non-zero), so the script's empty-id guard is exercised: it must abort
    # the mint before slinging and leave NO dedup marker (so the mint is retried).
    if [ "${args[$((i+1))]:-}" = "create" ]; then
      if [ "${STUB_BD_CREATE_FAIL:-0}" = "1" ]; then
        exit 1
      fi
      printf '%s\n' "${STUB_BD_CREATE_ID:-fk-newbead}"
      exit 0
    fi
    exit 0
    ;;
  sling)
    # Faithful stub of `gc sling` v2-formula validation (gc 1.4.1).
    #
    # This is the crux of the bug the fix addresses. Real gc 1.4.1 REJECTS a
    # v2 formula that references {{convoy_id}} (like con-voyage-ci-repair) when
    # it is inline-created with `--on <formula>` and no positional bead — it errors
    # with "inline text requires explicit target" and exits non-zero, so NO bead is
    # ever minted. The correct form supplies a PRE-CREATED bead as the positional:
    #     gc sling <target> <BEAD> --on <formula> --var ...
    #
    # We emulate exactly that acceptance rule so the tests go RED against the old
    # (no-bead) invocation and GREEN against the fixed (bead-positional) one.
    #
    # Parse the args after the subcommand: sling <target> [<bead>] [flags...]
    # (the leading `--city <dir>` is already accounted for by $i).
    has_on=0
    on_val=""
    # sling positional target/bead are the non-flag args immediately after `sling`.
    # Collect up to two leading positionals before the first flag.
    positionals=()
    j=$((i+1))
    seen_flag=0
    prev_flag=""
    while [ "$j" -lt "${#args[@]}" ]; do
      cur="${args[$j]}"
      case "$cur" in
        --on)
          has_on=1
          prev_flag="--on"
          seen_flag=1
          ;;
        --*)
          # A value-taking flag we care about: capture --on's value on next arg.
          prev_flag="$cur"
          seen_flag=1
          ;;
        *)
          if [ "$prev_flag" = "--on" ]; then
            on_val="$cur"
            prev_flag=""
          elif [ "$seen_flag" -eq 0 ]; then
            # Leading positional (target or bead), before any flag.
            positionals+=("$cur")
          else
            # value for some other flag; ignore
            prev_flag=""
          fi
          ;;
      esac
      j=$((j+1))
    done

    if [ "$has_on" -eq 1 ]; then
      # v2-formula attach path. Require a positional BEAD in addition to the
      # target — i.e. at least two leading positionals (target + bead).
      if [ "${#positionals[@]}" -lt 2 ]; then
        # Mirror real gc 1.4.1's rejection.
        echo "gc sling: inline text requires explicit target; usage: gc sling <target> <bead> --on <formula>" >&2
        exit 1
      fi
      # target = positionals[0], bead = positionals[1]. Well-formed mint.
      #
      # STUB_SLING_FAIL=1 makes ONLY this well-formed bead-positional formula
      # mint fail (routing to the ci-repair convoy fails after the bead was
      # already created). This is deliberately scoped to the --on formula path
      # so PART B's plain `sling <target> --stdin` route (which never sets
      # has_on) is unaffected — exactly like a transient routing error that hits
      # the repair mint but not comment routing. Exercises the script's contract
      # that the .minted dedup marker is written ONLY after a successful
      # mint+route, so a failed sling is retried (no marker) next cycle.
      if [ "${STUB_SLING_FAIL:-0}" = "1" ]; then
        echo "gc sling: failed to route bead to con-voyage-ci-repair convoy (simulated)" >&2
        exit 1
      fi
      # Accept.
      exit 0
    fi

    # Non-formula path (PART B). Accept plain text/stdin routes.
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
  # Unspaced assignments (owner="...") — parses under both BSD awk and gawk.
  # (The spaced variant is exercised separately by setup_case_env_spaced, which
  # guards the awk-portability fix.)
  cat > "${CITY_DIR}/city.toml" <<'TOML'
[[github.pr_monitor]]
owner="kriscoleman"
repo="foundry"
base="main"
merge_queue="observe"
TOML
}

# setup_case_env_spaced — like setup_case_env, but writes SPACED TOML
# assignments (owner = "..."). This is the fixture that catches the awk
# portability bug: the old parser used `\s`, which BSD/macOS awk treats as a
# literal 's', so it parsed ZERO repos from spaced assignments and PART B
# silently no-oped. With the [[:space:]] fix it parses correctly under BOTH
# BSD awk and gawk. Run under the system awk (this box is macOS/BSD) so the
# case actually exercises the bug.
setup_case_env_spaced() {
  setup_case_env "$1"
  cat > "${CITY_DIR}/city.toml" <<'TOML'
[[github.pr_monitor]]
owner = "replicatedhq"
repo = "x"
base = "main"
merge_queue = "observe"
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
# The sling is the wire that carries PART A's resolved author into Step 0's
# {{cv_pr_author}} — if this var were dropped, typo'd, or wrong, no other
# assertion in this suite would catch it (con-voyage-ci-repair-guard.test.sh
# covers the guard's own resolution, not this forwarding step).
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11.*cv_pr_author=kriscoleman' 1 "ci-repair sling forwards cv_pr_author"
assert_log_count "$GC_LOG" 'sling .*pr=500' 0 "no sling for #500 (other human)"
assert_log_count "$GC_LOG" 'sling .*pr=600' 0 "no sling for #600 (bot)"

# --- WELL-FORMED v2-FORMULA MINT (regression guard for the fk-f7x bug) ---
# The mint MUST be the gc 1.4.1 v2-formula shape:
#   gc [--city X] sling <target> <BEAD> --on con-voyage-ci-repair --var ...
# i.e. a PRE-CREATED bead positional BETWEEN the target and --on. The old broken
# form was `sling <target> --on <formula> --title <text>` (no bead), which real
# gc rejects with "inline text requires explicit target" and mints NOTHING.
#
# 1. A repair bead was pre-created for the KEPT PR (bd create ... --silent).
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "PART A pre-creates a repair bead for the KEPT PR"
# 2. The sling carries the real bead id (fk-newbead) as a positional BEFORE --on.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker fk-newbead --on con-voyage-ci-repair' 1 "ci-repair sling passes the pre-created bead positional before --on"
# 3. The mint MUST NOT use the old inline-create form (--title with --on and no bead).
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*--title' 0 "mint does not use the broken --on+--title inline form"
# 4. All PR-context vars ride on the (correct) sling for #11.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker fk-newbead --on con-voyage-ci-repair .*pr=11 .*repo=kriscoleman/foundry .*branch=fix/con-voyage-author-scope-pr-monitor' 1 "mint forwards pr/repo/branch vars on the bead-positional sling"
# 5. The KEEP log names the minted bead id (operator-observable evidence).
if printf '%s' "$OUT" | grep -q 'repair bead fk-newbead created/attached and routed'; then
  pass "logs the minted repair bead id for #11"
else
  fail "expected a 'repair bead <id> created/attached and routed' log for #11"
fi

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
# fire to the implementor for #11's human comment. PART B routes via
# `gc sling <target> --stdin` (gc 1.4.1 has NO --body flag); the stub captures
# stdin and appends it to the log line, so the routed title ("Human PR feedback
# on ...", the first stdin line) is grep-able here.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin' 1 "PART B routes via gc sling --stdin (not the nonexistent --body flag)"
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN: Human PR feedback on kriscoleman/foundry#11' 1 "one comment-route sling to implementor for #11"
# PART B must NOT use the old --body flag (gc 1.4.1 rejects it: unknown flag).
assert_log_count "$GC_LOG" 'sling .*--body' 0 "PART B does not use the unsupported --body flag"
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
# Prove the *resolved* login (not just an explicitly-set CV_PR_AUTHOR, per
# CASE 2 above) is what gets forwarded.
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11.*cv_pr_author=kriscoleman' 1 "ci-repair sling forwards the resolved cv_pr_author"
assert_log_count "$GC_LOG" 'sling .*pr=500' 0 "no sling for #500 under default resolution"
assert_log_count "$GH_LOG" 'pr list .*--author kriscoleman' 1 "PART B pr list scoped to resolved login"

# ===========================================================================
# CASE 7 — PART B awk portability: SPACED assignments (owner = "replicatedhq")
#   must parse under the system awk (this box is macOS/BSD). Before the
#   [[:space:]] fix, the `\s`-based parser matched ZERO repos here and PART B
#   no-oped ("no [[github.pr_monitor]] blocks found"). We assert the repo was
#   parsed (gh pr list --repo replicatedhq/x was called) and that the
#   no-blocks-found message is absent.
# ===========================================================================
start_case "7: PART B awk parses SPACED owner/repo (BSD-awk portability)"
setup_case_env_spaced "7"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
# The spaced fixture declares repo replicatedhq/x. If awk parsed it, PART B
# lists PRs for exactly that repo. Before the fix this count would be 0.
assert_log_count "$GH_LOG" 'pr list --repo replicatedhq/x' 1 "PART B parsed spaced repo and listed replicatedhq/x"
if printf '%s' "$OUT" | grep -q 'no \[\[github.pr_monitor\]\] blocks found'; then
  fail "PART B reported no blocks — awk failed to parse spaced assignments (the bug)"
else
  pass "PART B did not report 'no blocks found' (spaced assignments parsed)"
fi

# ===========================================================================
# CASE 8 — PART B defensive author re-check: even if the upstream
#   `gh pr list --author` filter LEAKS a PR authored by someone else, the
#   per-PR author re-check drops it before any comment fetch or routing.
#   STUB_PRLIST_LEAK=1 returns PR #999 authored by "someone-else".
# ===========================================================================
start_case "8: PART B defensive re-check drops a leaked non-operator PR"
setup_case_env "8"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_PRLIST_LEAK=1
assert_eq "0" "$RC" "script exits 0"
# The leaked PR (#999, author someone-else) must NOT be fetched for comments...
assert_log_count "$GH_LOG" 'pr view 999 .*reviews' 0 "no comment fetch for leaked #999"
# ...and must NOT be routed to the implementor.
assert_log_count "$GC_LOG" 'sling .*Human PR feedback on kriscoleman/foundry#999' 0 "no comment-route sling for leaked #999"
# And the defensive DROP was logged.
if printf '%s' "$OUT" | grep -q "DROP kriscoleman/foundry#999 (author='someone-else'"; then
  pass "logs defensive PART B DROP for leaked #999"
else
  fail "expected defensive PART B DROP log for #999"
fi

# ===========================================================================
# CASE 9 — PART A dedup across cycles: minting is idempotent per PR+head-sha.
#   The fix pre-creates a bead every mint, so WITHOUT dedup a second cooldown
#   tick would mint a DUPLICATE repair bead for the same #11 @ same head-sha.
#   The per-key marker file under CV_STATE_DIR must suppress the second mint.
#   We run the script TWICE against the SAME state dir and assert the second
#   run creates NO new bead and issues NO new ci-repair sling for #11.
# ===========================================================================
start_case "9: PART A dedup — second cycle does not re-mint same PR+sha"
setup_case_env "9"
# --- Cycle 1 (first backfill tick): mints one repair bead for #11. ---
GC_LOG_1="${SANDBOX}/gc-9a.log"; : > "$GC_LOG_1"
OUT="$(
  env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
    CV_STATE_DIR="$STATE_DIR" STUB_GH_LOG="${SANDBOX}/gh-9a.log" \
    STUB_GC_LOG="$GC_LOG_1" CV_PR_AUTHOR="kriscoleman" \
    STUB_GH_USER_LOGIN="kriscoleman" \
    bash "$SCRIPT" 2>&1
)"; RC=$?
assert_eq "0" "$RC" "cycle 1 exits 0"
assert_log_count "$GC_LOG_1" 'bd create .*--silent' 1 "cycle 1 pre-creates exactly one repair bead"
assert_log_count "$GC_LOG_1" 'sling gc.implementation-worker fk-newbead --on con-voyage-ci-repair' 1 "cycle 1 mints one ci-repair sling for #11"
# The dedup marker must now exist on disk (keyed on repo+PR+head-sha aaa111).
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11-aaa111.minted" ]; then
  pass "cycle 1 wrote the dedup marker for #11 @ aaa111"
else
  fail "expected dedup marker file after cycle 1"
fi
# --- Cycle 2 (next backfill tick, SAME state dir, SAME head-sha): no re-mint. ---
GC_LOG_2="${SANDBOX}/gc-9b.log"; : > "$GC_LOG_2"
OUT="$(
  env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
    CV_STATE_DIR="$STATE_DIR" STUB_GH_LOG="${SANDBOX}/gh-9b.log" \
    STUB_GC_LOG="$GC_LOG_2" CV_PR_AUTHOR="kriscoleman" \
    STUB_GH_USER_LOGIN="kriscoleman" \
    bash "$SCRIPT" 2>&1
)"; RC=$?
assert_eq "0" "$RC" "cycle 2 exits 0"
assert_log_count "$GC_LOG_2" 'bd create .*--silent' 0 "cycle 2 creates NO duplicate repair bead"
assert_log_count "$GC_LOG_2" 'sling gc.implementation-worker fk-newbead --on con-voyage-ci-repair' 0 "cycle 2 issues NO duplicate ci-repair sling for #11"
if printf '%s' "$OUT" | grep -q 'SKIP kriscoleman/foundry#11 @ aaa111 — repair bead already minted'; then
  pass "cycle 2 logs the dedup SKIP for #11"
else
  fail "expected a dedup SKIP log for #11 in cycle 2"
fi
# --- Cycle 3 (branch ADVANCED: #11 now @ a NEW head-sha bcd222): RE-MINT. ---
# This is the positive proof that the head-sha is pinned into the dedup key.
# STUB_HEAD_SHA overrides #11's head_sha in the backfill JSON, so the dedup key
# becomes cv-ci-repair-...-11-bcd222 — a DIFFERENT key than aaa111. The script
# must therefore treat this as a fresh mint: pre-create a NEW bead, issue a NEW
# well-formed ci-repair sling, and write a NEW marker under the new key.
#
# TRIPWIRE: if the script ever dropped the head-sha from the dedup key (keyed on
# repo+PR only), cycle 3 would collide with the aaa111 marker from cycle 1 and
# SKIP — so `bd create` would be 0 here and this case would go RED. Keeping this
# green requires the sha to genuinely re-key the mint.
GC_LOG_3="${SANDBOX}/gc-9c.log"; : > "$GC_LOG_3"
OUT="$(
  env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
    CV_STATE_DIR="$STATE_DIR" STUB_GH_LOG="${SANDBOX}/gh-9c.log" \
    STUB_GC_LOG="$GC_LOG_3" CV_PR_AUTHOR="kriscoleman" \
    STUB_GH_USER_LOGIN="kriscoleman" STUB_HEAD_SHA="bcd222" \
    bash "$SCRIPT" 2>&1
)"; RC=$?
assert_eq "0" "$RC" "cycle 3 exits 0"
assert_log_count "$GC_LOG_3" 'bd create .*--silent' 1 "cycle 3 pre-creates a FRESH repair bead at the new head-sha"
assert_log_count "$GC_LOG_3" 'sling gc.implementation-worker fk-newbead --on con-voyage-ci-repair' 1 "cycle 3 mints one well-formed ci-repair sling at the new head-sha"
# All PR-context vars still ride on the re-mint sling (proves it's a real,
# complete mint at the new sha — not a degenerate/partial sling).
assert_log_count "$GC_LOG_3" 'sling gc.implementation-worker fk-newbead --on con-voyage-ci-repair .*pr=11 .*repo=kriscoleman/foundry .*branch=fix/con-voyage-author-scope-pr-monitor' 1 "cycle 3 re-mint forwards pr/repo/branch vars"
# A NEW marker keyed on the NEW head-sha must now exist...
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11-bcd222.minted" ]; then
  pass "cycle 3 wrote a NEW dedup marker for #11 @ bcd222"
else
  fail "expected a NEW dedup marker file (bcd222) after cycle 3 — head-sha not re-keyed?"
fi
# ...and the ORIGINAL marker (aaa111) must still be present (distinct keys, not
# overwritten): the two head-shas map to two independent dedup entries.
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11-aaa111.minted" ]; then
  pass "original aaa111 marker still present (per-sha keys are independent)"
else
  fail "original aaa111 marker vanished — dedup markers are not per-head-sha"
fi
# The KEEP log for cycle 3 names the new-sha dedup key (operator-observable).
if printf '%s' "$OUT" | grep -q 'KEEP kriscoleman/foundry#11 .* (dedup: cv-ci-repair-kriscoleman-foundry-11-bcd222)'; then
  pass "cycle 3 logs a KEEP naming the new-sha dedup key"
else
  fail "expected a KEEP log naming the bcd222 dedup key in cycle 3"
fi

# ===========================================================================
# CASE 10 — PART A mint failure is retried (no dedup marker on failure).
#   If the sling fails, we must NOT write the dedup marker, so the next cycle
#   retries the mint rather than silently suppressing it forever. We force a
#   failed pre-create (STUB_BD_CREATE_FAIL=1 -> gc bd create prints nothing and
#   exits non-zero); the script must abort the mint before slinging, leave no
#   marker, and log the failure.
# ===========================================================================
start_case "10: PART A leaves no dedup marker when the mint cannot proceed"
setup_case_env "10"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BD_CREATE_FAIL=1
assert_eq "0" "$RC" "script exits 0 (mint failure is non-fatal)"
# bd create was attempted, but returned empty -> the script must NOT sling and
# must NOT write a marker (so the next cycle retries).
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 0 "no ci-repair sling when bead pre-create yields no id"
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11-aaa111.minted" ]; then
  fail "dedup marker written despite a failed mint (would suppress retries)"
else
  pass "no dedup marker written on failed mint (mint will be retried next cycle)"
fi
if printf '%s' "$OUT" | grep -q 'failed to create repair bead for kriscoleman/foundry#11'; then
  pass "logs the bead-create failure for #11"
else
  fail "expected a bead-create failure log for #11"
fi

# ===========================================================================
# CASE 11 — PART A sling failure leaves NO dedup marker (dedicated GREEN test).
#   CASE 10 covers the bd-create-fail path (mint aborts before slinging). This
#   case covers the OTHER failure branch: the bead IS pre-created successfully,
#   but the subsequent v2-formula `sling <target> <bead> --on con-voyage-ci-repair`
#   fails (STUB_SLING_FAIL=1). The script must then:
#     * still exit 0 (a failed sling is non-fatal — best effort, retried),
#     * have actually pre-created the bead (bd create --silent == 1),
#     * write NO .minted marker (the marker is recorded ONLY after a successful
#       mint+route, so the next cycle retries rather than suppressing forever),
#     * log the 'repair-bead sling failed ... will retry' WARNING.
#   This pins the ordering invariant in the script under test: the marker write
#   sits INSIDE the `if sling; then ...` success branch. If a refactor ever moved
#   the marker write before/around the sling, this case would go RED (a marker
#   would exist after a failed sling).
# ===========================================================================
start_case "11: PART A sling failure writes no dedup marker (retryable)"
setup_case_env "11"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_SLING_FAIL=1
assert_eq "0" "$RC" "script exits 0 (sling failure is non-fatal)"
# The bead WAS pre-created (we got past pre-create and into the sling)...
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "a repair bead was pre-created for #11"
# ...and exactly one well-formed ci-repair sling was ATTEMPTED for that bead
# (the stub rejects it via STUB_SLING_FAIL, mirroring a routing failure).
assert_log_count "$GC_LOG" 'sling gc.implementation-worker fk-newbead --on con-voyage-ci-repair' 1 "one well-formed ci-repair sling was attempted for #11"
# CRUX: because that sling failed, NO dedup marker may be written — otherwise the
# mint would be suppressed forever and never retried.
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11-aaa111.minted" ]; then
  fail "dedup marker written despite a FAILED sling (would suppress retries)"
else
  pass "no dedup marker written on failed sling (mint will be retried next cycle)"
fi
# The retry WARNING must be logged (operator-observable evidence of the retry path).
if printf '%s' "$OUT" | grep -q 'repair-bead sling failed for kriscoleman/foundry#11'; then
  pass "logs the 'repair-bead sling failed ... will retry' WARNING for #11"
else
  fail "expected a 'repair-bead sling failed ... will retry' WARNING for #11"
fi
# And the success log must be ABSENT (the mint did not complete).
if printf '%s' "$OUT" | grep -q 'repair bead fk-newbead created/attached and routed'; then
  fail "logged mint success despite a failed sling"
else
  pass "no 'created/attached and routed' success log on failed sling"
fi
# FAITHFULNESS GUARD: STUB_SLING_FAIL is scoped to the --on formula MINT only; it
# must NOT break PART B's plain `sling <target> --stdin` comment route. The stub
# returns a human comment for #11, so PART B must still route it successfully
# even while the PART A mint sling is failing.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN: Human PR feedback on kriscoleman/foundry#11' 1 "PART B --stdin comment route still succeeds under STUB_SLING_FAIL"
if printf '%s' "$OUT" | grep -q 'kriscoleman/foundry#11: routed to gc.implementation-worker'; then
  pass "PART B still routes #11 comment despite PART A sling failure"
else
  fail "expected PART B to still route #11 comment under STUB_SLING_FAIL"
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
