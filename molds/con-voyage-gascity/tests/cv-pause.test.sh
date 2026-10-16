#!/usr/bin/env bash
# cv-pause.test.sh — hermetic, offline test for the operator pause toggles
# (cv-pause.sh) and the orders that honor them.
#
# Two independently pausable features, each a city-level flag file:
#
#   self-heal       the autonomous CI-repair loop.
#     Given self-heal is paused,
#     When  con-voyage-pr-watch runs, then PART A / PART A-native mint and
#           dispatch no CI repair (PART B comment routing still runs).
#     When  con-voyage-repair-watchdog runs, then it re-dispatches nothing.
#     When  con-voyage-ci-repair-guard runs, then every open ci-repair step
#           bead is closed as "dropped: self-heal paused" before a worker
#           claims it (this is what stops the native [[github.pr_monitor]]'s
#           own mints).
#
#   comment-repair  pr-watch PART B: routing PR review comments to the
#                   implementor for autonomous fixes.
#     Given comment-repair is paused,
#     When  con-voyage-pr-watch runs, then PART B routes nothing and records
#           no comment as seen (so nothing is lost: comments left while
#           paused are routed after resume), while PART A still runs.
#
# Given the operator resumes a feature, its flag is gone and it runs again.
#
# Run:  bash tests/cv-pause.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPTS_DIR="${MOLD_DIR}/pack/assets/scripts"
PAUSE="${SCRIPTS_DIR}/cv-pause.sh"
PR_WATCH="${SCRIPTS_DIR}/con-voyage-pr-watch.sh"
WATCHDOG="${SCRIPTS_DIR}/con-voyage-repair-watchdog.sh"
GUARD="${SCRIPTS_DIR}/con-voyage-ci-repair-guard.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-pause-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
start_case() { echo; echo "=== CASE: $1 ==="; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qE -- "$2"; then pass "$3"; else fail "$3 (no match for /$2/)"; fi; }
assert_not_contains() { if printf '%s' "$1" | grep -qE -- "$2"; then fail "$3 (unexpected match for /$2/)"; else pass "$3"; fi; }

# ---------------------------------------------------------------------------
# Recording stubs. Every call appends its argv to a log; canned JSON comes
# from STUB_* env vars.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GC_LOG}"
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"
case "$sub" in
  bd)
    bdsub="${args[$((i+1))]:-}"
    case "$bdsub" in
      list) printf '%s' "${STUB_BDLIST_JSON:-[]}" ;;
      show) printf '%s' "${STUB_BDSHOW_JSON:-{\}}" ;;
      create) printf '%s\n' "stub-bead-1" ;;
    esac
    exit 0
    ;;
  github) printf '%s' "${STUB_BACKFILL_JSON:-{\"results\":[]\}}"; exit 0 ;;
  session) printf '%s' '{"sessions":[]}'; exit 0 ;;
  *) exit 0 ;;
esac
GC_STUB
cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GH_LOG}"
case "${1:-}" in
  auth) exit 0 ;;
  api) printf '%s\n' "kriscoleman"; exit 0 ;;
  pr)
    case "${2:-}" in
      list) printf '%s' '[]' ;;
      view) printf '%s\n' "kriscoleman" ;;  # `--jq .author.login` result
    esac
    exit 0
    ;;
esac
exit 0
GH_STUB
chmod +x "${STUBDIR}/gc" "${STUBDIR}/gh"

# new_city — fresh city root + logs for one case. Sets CITY/GC_LOG/GH_LOG.
new_city() {
  CITY="${SANDBOX}/city-$1"
  mkdir -p "${CITY}/.gc"
  GC_LOG="${SANDBOX}/gc-$1.log"; GH_LOG="${SANDBOX}/gh-$1.log"
  : > "$GC_LOG"; : > "$GH_LOG"
}

# run_in_city CMD... — run CMD with the stubs and a city env; sets OUT/RC.
run_in_city() {
  OUT="$(cd "$CITY" && env -u CV_PAUSE_DIR -u GC_RIG_ROOT \
    PATH="${STUBDIR}:${PATH}" GC="${STUBDIR}/gc" GH="${STUBDIR}/gh" \
    GC_CITY="$CITY" CV_STATE_DIR="${CITY}/.gc/cv-pr-watch" \
    CV_PR_AUTHOR="kriscoleman" STUB_GC_LOG="$GC_LOG" STUB_GH_LOG="$GH_LOG" \
    "$@" 2>&1)"
  RC=$?
}

if [ ! -f "$PAUSE" ]; then
  echo "FATAL: ${PAUSE} not found" >&2
  exit 1
fi

# ===========================================================================
start_case "1: a fresh city has nothing paused (both features run by default)"
new_city 1
run_in_city bash "$PAUSE" is-paused self-heal
assert_eq "1" "$RC" "is-paused self-heal exits 1 when no flag exists"
run_in_city bash "$PAUSE" is-paused comment-repair
assert_eq "1" "$RC" "is-paused comment-repair exits 1 when no flag exists"
run_in_city bash "$PAUSE" status
assert_eq "0" "$RC" "status exits 0"
assert_contains "$OUT" "self-heal: RUNNING" "status reports self-heal RUNNING"
assert_contains "$OUT" "comment-repair: RUNNING" "status reports comment-repair RUNNING"

# ===========================================================================
start_case "2: pause writes the city flag; status and is-paused see it"
new_city 2
run_in_city bash "$PAUSE" pause self-heal "burning tokens on vandoor"
assert_eq "0" "$RC" "pause exits 0"
if [ -f "${CITY}/.gc/cv-self-heal.paused" ]; then pass "flag file written under the city root's .gc"; else fail "flag file missing at ${CITY}/.gc/cv-self-heal.paused"; fi
assert_contains "$(cat "${CITY}/.gc/cv-self-heal.paused" 2>/dev/null)" "reason=burning tokens on vandoor" "flag records the reason"
run_in_city bash "$PAUSE" is-paused self-heal
assert_eq "0" "$RC" "is-paused exits 0 once paused"
run_in_city bash "$PAUSE" is-paused comment-repair
assert_eq "1" "$RC" "pausing self-heal leaves comment-repair running"
run_in_city bash "$PAUSE" status
assert_contains "$OUT" "self-heal: PAUSED" "status reports PAUSED"
assert_contains "$OUT" "burning tokens on vandoor" "status shows the reason"
assert_contains "$OUT" "comment-repair: RUNNING" "status still reports the other feature RUNNING"
run_in_city bash "$PAUSE" pause self-heal
assert_eq "0" "$RC" "pausing again is idempotent"

# ===========================================================================
start_case "3: resume removes the flag; resuming twice is idempotent"
run_in_city bash "$PAUSE" resume self-heal
assert_eq "0" "$RC" "resume exits 0"
if [ -e "${CITY}/.gc/cv-self-heal.paused" ]; then fail "flag still present after resume"; else pass "flag removed"; fi
run_in_city bash "$PAUSE" is-paused self-heal
assert_eq "1" "$RC" "is-paused exits 1 after resume"
run_in_city bash "$PAUSE" resume self-heal
assert_eq "0" "$RC" "resuming when already running is a no-op success"

# ===========================================================================
start_case "4: comment-repair has its own flag; CV_PAUSE_DIR overrides the location"
new_city 4
run_in_city bash "$PAUSE" pause comment-repair
if [ -f "${CITY}/.gc/cv-comment-repair.paused" ]; then pass "comment-repair flag written"; else fail "comment-repair flag missing"; fi
OVERRIDE="${SANDBOX}/elsewhere"
run_in_city env CV_PAUSE_DIR="$OVERRIDE" bash "$PAUSE" pause self-heal
if [ -f "${OVERRIDE}/cv-self-heal.paused" ]; then pass "pause honored CV_PAUSE_DIR"; else fail "CV_PAUSE_DIR not honored"; fi
run_in_city env CV_PAUSE_DIR="$OVERRIDE" bash "$PAUSE" is-paused self-heal
assert_eq "0" "$RC" "is-paused honors CV_PAUSE_DIR"

# ===========================================================================
start_case "5: an unknown subcommand or feature fails with usage"
run_in_city bash "$PAUSE" bogus self-heal
assert_eq "2" "$RC" "unknown subcommand exits 2"
assert_contains "$OUT" "usage" "prints usage"
run_in_city bash "$PAUSE" pause everything
assert_eq "2" "$RC" "unknown feature exits 2"
run_in_city bash "$PAUSE" pause
assert_eq "2" "$RC" "missing feature exits 2"

# ===========================================================================
start_case "6: pr-watch while paused mints and dispatches no CI repair"
new_city 6
: > "${CITY}/.gc/cv-self-heal.paused"
run_in_city env CV_NATIVE_DISCOVERY=enabled bash "$PR_WATCH"
assert_eq "0" "$RC" "pr-watch exits 0"
assert_contains "$OUT" "\[PART A\] skipped .*self-heal is paused" "PART A logs that it is paused"
assert_contains "$OUT" "\[PART A-native\] skipped .*self-heal is paused" "PART A-native logs that it is paused"
assert_not_contains "$(cat "$GC_LOG")" "github pr backfill" "no backfill call while paused"
assert_not_contains "$(cat "$GC_LOG")" "bd create|sling" "no repair bead minted or slung"
assert_not_contains "$(cat "$GH_LOG")" "pr list" "no native discovery gh calls"

# ===========================================================================
start_case "7: pr-watch when running still does PART A"
new_city 7
run_in_city bash "$PR_WATCH"
assert_eq "0" "$RC" "pr-watch exits 0"
assert_contains "$(cat "$GC_LOG")" "github pr backfill" "backfill runs when not paused"

# ===========================================================================
start_case "8: repair-watchdog while paused re-dispatches nothing"
new_city 8
mkdir -p "${CITY}/.gc/cv-pr-watch"
printf 'implementor_session=\ninflight_rework=wd-1\nlast_handled_state=blocked\n' > "${CITY}/.gc/cv-pr-watch/cv-ci-repair-kriscoleman-foundry-1.state"
: > "${CITY}/.gc/cv-self-heal.paused"
run_in_city bash "$WATCHDOG"
assert_eq "0" "$RC" "watchdog exits 0"
assert_contains "$OUT" "self-heal is paused" "watchdog logs that it is paused"
assert_eq "" "$(cat "$GC_LOG")" "watchdog makes no gc calls at all while paused"

# ===========================================================================
start_case "9: ci-repair-guard while paused drops open ci-repair step beads"
new_city 9
: > "${CITY}/.gc/cv-self-heal.paused"
BDLIST='[{"id":"va-step1","metadata":{"gc.root_bead_id":"va-root1"}}]'
BDSHOW='{"metadata":{"gc.formula_name":"con-voyage-ci-repair","gc.var.pr":"7","gc.var.repo":"kriscoleman/foundry"}}'
run_in_city env STUB_BDLIST_JSON="$BDLIST" STUB_BDSHOW_JSON="$BDSHOW" GUARD_RETRY_SLEEP=0 bash "$GUARD"
assert_eq "0" "$RC" "guard exits 0"
assert_contains "$(cat "$GC_LOG")" "bd close va-step1 --reason dropped: self-heal paused" "operator-authored bead is dropped while paused"
assert_not_contains "$(cat "$GH_LOG")" "pr view" "no PR author lookups needed while paused"

# ===========================================================================
start_case "10: ci-repair-guard while paused drops beads even with CV_AUTHOR_GATE=disabled"
new_city 10
: > "${CITY}/.gc/cv-self-heal.paused"
run_in_city env CV_AUTHOR_GATE=disabled STUB_BDLIST_JSON="$BDLIST" STUB_BDSHOW_JSON="$BDSHOW" GUARD_RETRY_SLEEP=0 bash "$GUARD"
assert_eq "0" "$RC" "guard exits 0"
assert_contains "$(cat "$GC_LOG")" "bd close va-step1 --reason dropped: self-heal paused" "pause wins over the author-gate opt-out"

# ===========================================================================
start_case "11: ci-repair-guard when running keeps an operator-authored bead"
new_city 11
run_in_city env STUB_BDLIST_JSON="$BDLIST" STUB_BDSHOW_JSON="$BDSHOW" GUARD_RETRY_SLEEP=0 bash "$GUARD"
assert_eq "0" "$RC" "guard exits 0"
assert_not_contains "$(cat "$GC_LOG")" "bd close" "nothing is closed when not paused"
assert_contains "$OUT" "KEEP va-step1" "bead is kept for a worker"

# ===========================================================================
start_case "12: pr-watch with comment-repair paused routes no PR comments"
new_city 12
printf '[[github.pr_monitor]]\nname = "f"\nowner = "kriscoleman"\nrepo = "foundry"\n' > "${CITY}/city.toml"
: > "${CITY}/.gc/cv-comment-repair.paused"
run_in_city bash "$PR_WATCH"
assert_eq "0" "$RC" "pr-watch exits 0"
assert_contains "$OUT" "\[PART B\] skipped .*comment-repair is paused" "PART B logs that it is paused"
assert_contains "$(cat "$GC_LOG")" "github pr backfill" "PART A (self-heal) still runs"
assert_not_contains "$(cat "$GH_LOG")" "pr list" "PART B lists no PRs while paused"
if ls "${CITY}/.gc/cv-pr-watch/"*.seen-ids >/dev/null 2>&1; then fail "seen-ids written while paused (comments would be lost)"; else pass "no comment is marked seen while paused"; fi

# ===========================================================================
start_case "13: pr-watch with comment-repair running scans PR comments"
new_city 13
printf '[[github.pr_monitor]]\nname = "f"\nowner = "kriscoleman"\nrepo = "foundry"\n' > "${CITY}/city.toml"
run_in_city bash "$PR_WATCH"
assert_eq "0" "$RC" "pr-watch exits 0"
assert_contains "$OUT" "\[PART B\] scanning" "PART B runs when not paused"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
fi
echo "${FAILURES} assertion(s) FAILED" >&2
exit 1
