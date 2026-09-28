#!/usr/bin/env bash
# cv-synthesis-low-mail.test.sh — hermetic, offline test for the LOW-only
# human-escalation mail the con-voyage synthesize-review step must send
# before it closes (fk-8g9ue).
#
# BACKGROUND: {target}.synthesize-review.md has always said a LOW-only
# verdict (0 BLOCKING, N LOW remaining) must "stop and surface the findings
# to the human facilitator" — but that was prose only. apply-review-findings
# only branches on BLOCKING, so a LOW-only cycle silently rolled straight to
# done/publish with nobody ever mailed, while the synthesis text itself often
# claimed the opposite ("the human escalation target has been mailed").
# Reported twice in the field against real synthesis output (roots fk-sy5zb,
# fk-1du8z, fk-whmdb, fk-elkyf). This script makes the mail an actual side
# effect the step runs, instead of a promise an LLM pass could forget to
# keep.
#
# HOW IT WORKS (no network, no real gc): a recording STUB `gc` is built in a
# temp dir. It logs every invocation's argv (one call per line, embedded
# newlines collapsed to spaces — same idiom as con-voyage-review-watchdog's
# stub) to STUB_GC_LOG, answers `mail send <to> ... --json` with an
# incrementing fake message id (or a simulated failure when STUB_MAIL_FAIL=1),
# and always succeeds on `bd update ... --set-metadata`. The script under
# test honors GC= (default gc) so we point it at the stub.
#
# Synthesis fixtures are built inline per case from the real document shape
# (`### BLOCKING-<n>` / `### LOW-<n>` sub-headings) rather than as separate
# fixture files — see tests/fixtures/*.json for this pack's convention on
# genuinely-external fixtures; this one is small and case-specific enough to
# inline, matching con-voyage-review-watchdog.test.sh's own lane()-builder
# idiom.
#
# Run:  bash tests/cv-synthesis-low-mail.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-synthesis-low-mail.sh"

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-synthesis-low-mail-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv (one line per call), answers `mail send` with
# an incrementing fake message id backed by STUB_COUNTER_FILE, and always
# succeeds on `bd update`.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

args=("$@")

case "${args[0]:-}" in
  mail)
    if [ "${args[1]:-}" = "send" ]; then
      if [ "${STUB_MAIL_FAIL:-0}" = "1" ]; then
        echo "gc mail send: simulated failure" >&2
        exit 1
      fi
      n=$(( $(cat "${STUB_COUNTER_FILE}") + 1 ))
      echo "$n" > "${STUB_COUNTER_FILE}"
      printf '{"schema_version":"1","ok":true,"command":"mail.send","action":"send","message":{"id":"msg-%s"}}' "$n"
      exit 0
    fi
    exit 0
    ;;
  bd)
    if [ "${args[1]:-}" = "update" ]; then
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# ---------------------------------------------------------------------------
# Test harness bookkeeping (same idioms as con-voyage-review-watchdog.test.sh).
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
  n="$(grep -E -c -- "$pattern" "$logfile")"
  printf '%s' "${n:-0}"
}

assert_log_count() {
  local n; n="$(log_count "$1" "$2")"
  assert_eq "$3" "$n" "$4"
}

setup_case_env() {
  GC_LOG="${SANDBOX}/gc-${1}.log"
  COUNTER_FILE="${SANDBOX}/counter-${1}"
  : > "$GC_LOG"
  echo 0 > "$COUNTER_FILE"
}

run_script() {
  OUT="$(
    env \
      GC="${STUBDIR}/gc" \
      STUB_GC_LOG="$GC_LOG" \
      STUB_COUNTER_FILE="$COUNTER_FILE" \
      "$@" \
      bash "$SCRIPT" "$SYNTHESIS_FILE" "$ROOT_ID" "$WORK_BEAD" "$PR_OR_BRANCH" 2>&1
  )"
  RC=$?
}

# fixture SYNTHESIS_PATH BLOCKING_COUNT LOW_COUNT — writes a synthesis file
# at SYNTHESIS_PATH shaped like a real review-synthesis.md, with exactly
# BLOCKING_COUNT `### BLOCKING-<n>` sub-headings and LOW_COUNT `### LOW-<n>`
# sub-headings (the only shape the script is required to parse).
fixture() {
  local path="$1" blocking="$2" low="$3"
  {
    echo "# Con-voyage Review Synthesis — root fixture (iteration 1)"
    echo
    echo "## 1. Overall verdict: **$([ "$blocking" -gt 0 ] && echo iterate || echo approve)**"
    echo
    echo "## 2. BLOCKING findings (must fix before landing)"
    echo
    if [ "$blocking" -eq 0 ]; then
      echo "None."
    else
      for i in $(seq 1 "$blocking"); do
        echo "### BLOCKING-${i} — sample blocking finding ${i}"
        echo "- **Lanes:** security (BLOCKING-${i})"
        echo "- **File:line:** \`some/file.go:${i}\`"
        echo "- **Finding:** something must be fixed."
        echo
      done
    fi
    echo
    echo "## 3. LOW findings (surface to human for decision)"
    echo
    if [ "$low" -eq 0 ]; then
      echo "None."
    else
      for i in $(seq 1 "$low"); do
        echo "### LOW-${i} — sample low finding ${i}"
        echo "- **Lanes:** simplicity (LOW-${i})"
        echo "- **File:line:** \`some/file.go:$((i + 10))\`"
        echo "- **Finding:** a minor concern."
        echo "- **Suggested fix:** optional cleanup."
        echo
      done
    fi
    echo
    echo "## 4. Lanes approved with no findings"
    echo
    echo "None."
  } > "$path"
}

ROOT_ID="fk-root1"
WORK_BEAD="fk-work1"
PR_OR_BRANCH="con-voyage/fk-root1"

# ===========================================================================
# CASE 1 — 0 BLOCKING / 3 LOW, no escalation target configured: exactly one
#   mail to the mayor, plus metadata recorded on the root bead.
# ===========================================================================
start_case "1: 0 BLOCKING / 3 LOW, no escalate target -> exactly one mail to mayor + metadata"
setup_case_env "1"
SYNTHESIS_FILE="${SANDBOX}/synthesis-1.md"
fixture "$SYNTHESIS_FILE" 0 3
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "exactly one mail sent, to the mayor"
assert_log_count "$GC_LOG" 'mail send ' 1 "no other mail sent (no distinct escalate target configured)"
assert_log_count "$GC_LOG" "^bd update ${ROOT_ID} .*code_review\\.low_mail_sent=true" 1 "low_mail_sent=true recorded on the root bead"
assert_log_count "$GC_LOG" "^bd update ${ROOT_ID} .*code_review\\.low_mail_id=msg-1" 1 "the mayor's mail id recorded on the root bead"
assert_log_count "$GC_LOG" "LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} .* 3 LOW" 1 "subject line names the work bead, PR/branch, and LOW count"

# ===========================================================================
# CASE 2 — 0 BLOCKING / 2 LOW, a distinct real escalate target: mail BOTH the
#   mayor and the escalate target, and record both mail ids.
# ===========================================================================
start_case "2: 0 BLOCKING / 2 LOW, distinct escalate target -> mail mayor AND escalate target"
setup_case_env "2"
SYNTHESIS_FILE="${SANDBOX}/synthesis-2.md"
fixture "$SYNTHESIS_FILE" 0 2
run_script CV_LENS_ESCALATE_TARGET="human"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "mailed the mayor"
assert_log_count "$GC_LOG" '^mail send human ' 1 "also mailed the distinct escalate target"
assert_log_count "$GC_LOG" "^bd update ${ROOT_ID} .*code_review\\.low_mail_id=msg-1" 1 "mayor's mail id recorded"
assert_log_count "$GC_LOG" "^bd update ${ROOT_ID} .*code_review\\.low_escalation_mail_id=msg-2" 1 "escalate target's mail id recorded separately"

# ===========================================================================
# CASE 3 — escalate target resolves to the SAME address as the mayor: only
#   one mail is sent (no duplicate send to the same mailbox).
# ===========================================================================
start_case "3: escalate target == mayor -> no duplicate send"
setup_case_env "3"
SYNTHESIS_FILE="${SANDBOX}/synthesis-3.md"
fixture "$SYNTHESIS_FILE" 0 1
run_script CV_LENS_ESCALATE_TARGET="mayor"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send ' 1 "only one mail total when the escalate target equals the mayor"

# ===========================================================================
# CASE 4 — escalate target is an unsubstituted {var} placeholder: treated as
#   not a real mailbox, only the mayor is mailed.
# ===========================================================================
start_case "4: escalate target is an unsubstituted placeholder -> ignored"
setup_case_env "4"
SYNTHESIS_FILE="${SANDBOX}/synthesis-4.md"
fixture "$SYNTHESIS_FILE" 0 1
run_script CV_LENS_ESCALATE_TARGET="{cv_lens_escalate_target}"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send ' 1 "only the mayor is mailed; the unresolved placeholder is not treated as a real mailbox"

# ===========================================================================
# CASE 5 — BLOCKING findings present (iterate path owns escalation): no LOW
#   mail is sent even though LOW findings are also present.
# ===========================================================================
start_case "5: BLOCKING > 0 -> no LOW mail (iterate path)"
setup_case_env "5"
SYNTHESIS_FILE="${SANDBOX}/synthesis-5.md"
fixture "$SYNTHESIS_FILE" 2 2
run_script
assert_eq "0" "$RC" "script exits 0 (not an error, just a no-op)"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail sent while BLOCKING findings remain"
assert_log_count "$GC_LOG" 'bd update' 0 "no metadata recorded either"

# ===========================================================================
# CASE 6 — 0 BLOCKING / 0 LOW: nothing to escalate, no mail.
# ===========================================================================
start_case "6: 0 BLOCKING / 0 LOW -> no mail"
setup_case_env "6"
SYNTHESIS_FILE="${SANDBOX}/synthesis-6.md"
fixture "$SYNTHESIS_FILE" 0 0
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail sent when there is nothing to surface"

# ===========================================================================
# CASE 7 — missing synthesis file: usage/lookup error, fails loud.
# ===========================================================================
start_case "7: missing synthesis file -> fails loud, no mail"
setup_case_env "7"
SYNTHESIS_FILE="${SANDBOX}/does-not-exist.md"
run_script
assert_eq "1" "$RC" "script exits 1 when the synthesis file is missing"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail sent on a lookup failure"

# ===========================================================================
# CASE 8 — gc mail send itself fails: the step must fail loud rather than
#   silently recording metadata that claims a mail it never actually sent
#   (this is the exact shape of bug being fixed — the text must never claim
#   an unsent mail).
# ===========================================================================
start_case "8: gc mail send fails -> script fails loud, no metadata claimed"
setup_case_env "8"
SYNTHESIS_FILE="${SANDBOX}/synthesis-8.md"
fixture "$SYNTHESIS_FILE" 0 1
run_script STUB_MAIL_FAIL="1"
assert_eq "1" "$RC" "script exits 1 when gc mail send fails"
assert_log_count "$GC_LOG" "^bd update ${ROOT_ID} .*code_review\\.low_mail_sent=true" 0 "never claims a mail was sent when the send actually failed"

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
