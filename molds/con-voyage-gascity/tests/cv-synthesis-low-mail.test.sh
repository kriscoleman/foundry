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
# Synthesis fixtures are built inline per case (see fixture() below) rather
# than as separate fixture files — see tests/fixtures/*.json for this pack's
# convention on genuinely-external fixtures; this one is small and
# case-specific enough to inline, matching con-voyage-review-watchdog.test.sh's
# own lane()-builder idiom. fixture()'s SHAPE parameter covers the real-world
# heading shapes BLOCKING-1 found the old `grep -c '^### BLOCKING-'` parser
# silently missing (e.g. fk-elkyf's actual `### 1. [lane] ...` shape counted
# 0 under the old parser) — see CASE 9-12 below.
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
# succeeds on `bd update`. STUB_MAIL_HANG=1 / STUB_BD_UPDATE_HANG=1 make the
# respective call sleep STUB_HANG_SECONDS (default 20) before responding —
# same simulated-hang idiom as con-voyage-review-watchdog.test.sh, used to
# prove the cv_with_timeout wrap (fk-72l6i BLOCKING-3) actually bounds these
# calls rather than trusting cv_with_timeout's own tests by proxy.
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
      if [ "${STUB_MAIL_HANG:-0}" = "1" ]; then
        sleep "${STUB_HANG_SECONDS:-20}"
      fi
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
      if [ "${STUB_BD_UPDATE_HANG:-0}" = "1" ]; then
        sleep "${STUB_HANG_SECONDS:-20}"
      fi
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

# fixture SYNTHESIS_PATH BLOCKING_COUNT LOW_COUNT [SHAPE] — writes a
# synthesis file at SYNTHESIS_PATH shaped like a real review-synthesis.md,
# with exactly BLOCKING_COUNT/LOW_COUNT findings in the given SHAPE. SHAPE
# defaults to "hyphen" (`### BLOCKING-<n>` / `### LOW-<n>`, byte-identical to
# this fixture's original output) and also covers the real-world shapes
# BLOCKING-1 found the old parser missing:
#   hyphen    - ### BLOCKING-<n> / ### LOW-<n>        (original shape)
#   numbered  - ### <n>. [lane] Title                  (fk-elkyf's real shape)
#   short     - ### B<n> / ### L<n>
#   bulleted  - no sub-headings at all, top-level "- " bullets only
fixture() {
  local path="$1" blocking="$2" low="$3" shape="${4:-hyphen}"
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
        case "$shape" in
          hyphen)   echo "### BLOCKING-${i} — sample blocking finding ${i}" ;;
          numbered) echo "### ${i}. [security] sample blocking finding ${i}" ;;
          short)    echo "### B${i} — sample blocking finding ${i}" ;;
          bulleted) echo "- [security] sample blocking finding ${i} (\`some/file.go:${i}\`) — something must be fixed." ;;
        esac
        if [ "$shape" != "bulleted" ]; then
          echo "- **Lanes:** security (BLOCKING-${i})"
          echo "- **File:line:** \`some/file.go:${i}\`"
          echo "- **Finding:** something must be fixed."
          echo
        fi
      done
    fi
    echo
    echo "## 3. LOW findings (surface to human for decision)"
    echo
    if [ "$low" -eq 0 ]; then
      echo "None."
    else
      for i in $(seq 1 "$low"); do
        case "$shape" in
          hyphen)   echo "### LOW-${i} — sample low finding ${i}" ;;
          numbered) echo "### ${i}. [simplicity] sample low finding ${i}" ;;
          short)    echo "### L${i} — sample low finding ${i}" ;;
          bulleted) echo "- [simplicity] sample low finding ${i} (\`some/file.go:$((i + 10))\`) — a minor concern." ;;
        esac
        if [ "$shape" != "bulleted" ]; then
          echo "- **Lanes:** simplicity (LOW-${i})"
          echo "- **File:line:** \`some/file.go:$((i + 10))\`"
          echo "- **Finding:** a minor concern."
          echo "- **Suggested fix:** optional cleanup."
          echo
        fi
      done
    fi
    echo
    echo "## 4. Lanes approved with no findings"
    echo
    echo "None."
  } > "$path"
}

# fixture_elkyf_shaped PATH LOW_COUNT — reproduces the exact structural
# shape of the real fk-elkyf synthesis doc that BLOCKING-1 was filed
# against: an unnumbered "## Overall verdict: ... N LOW findings" heading
# that mentions "LOW findings" in passing (this alone broke an earlier,
# looser version of the section-boundary parser — it locked onto this
# verdict line instead of the real "## LOW findings" section below), a
# "## BLOCKING findings" body of "None. Zero BLOCKING findings from any of
# the N active lanes." (trailing prose after "None.", not just "None."
# alone), and "### <n>. [lane] Title" LOW sub-headings (no "LOW-" prefix).
fixture_elkyf_shaped() {
  local path="$1" low="$2"
  {
    echo "# Con-voyage Review Synthesis — root fixture"
    echo
    echo "## Overall verdict: APPROVE (0 BLOCKING) — human decision pending on ${low} LOW findings"
    echo
    echo "Every active lane reports zero BLOCKING findings."
    echo
    echo "## BLOCKING findings (must fix before landing)"
    echo
    echo "None. Zero BLOCKING findings from any of the active lanes."
    echo
    echo "## LOW findings (surface to human for decision)"
    echo
    for i in $(seq 1 "$low"); do
      echo "### ${i}. [security] sample low finding ${i}"
      echo "- **Lane:** security"
      echo "- **Issue:** a minor concern."
      echo
    done
    echo "## Lanes approved with no findings"
    echo
    echo "None."
  } > "$path"
}

# fixture_unparseable PATH — a BLOCKING findings section with real prose
# content but no recognized per-finding shape (no ### sub-headings, no
# top-level "- " bullets). The script must fail loud rather than silently
# treating this as "0 findings" (BLOCKING-1's exact failure mode).
fixture_unparseable() {
  local path="$1"
  {
    echo "# Con-voyage Review Synthesis — root fixture (iteration 1)"
    echo
    echo "## 1. Overall verdict: **iterate**"
    echo
    echo "## 2. BLOCKING findings (must fix before landing)"
    echo
    echo "There is a real problem here but whoever wrote this synthesis forgot"
    echo "to use a list, so there is nothing here a machine can count."
    echo
    echo "## 3. LOW findings (surface to human for decision)"
    echo
    echo "None."
    echo
    echo "## 4. Lanes approved with no findings"
    echo
    echo "None."
  } > "$path"
}

# fixture_bold_none PATH LOW_COUNT [TRAILING] — a zero-BLOCKING section whose
# body is the dominant real-world bold shape, "**None.**", not the plain
# "None." fixture() emits. Optional TRAILING appends trailing prose after the
# bold marker ("**None.** <prose>") — the second variant BLOCKING-1's fix
# must also tolerate. Reproduces the exact 7-of-59 on-disk-document miss:
# the old zero-case regex only matched an unbolded "none"/"n/a" prefix, so a
# leading "*" made it fail the match, fall through to `return -1`
# (UNPARSEABLE), and `die` instead of sending the LOW-only mail.
fixture_bold_none() {
  local path="$1" low="$2" trailing="${3:-}"
  {
    echo "# Con-voyage Review Synthesis — root fixture (iteration 1)"
    echo
    echo "## 1. Overall verdict: **approve**"
    echo
    echo "## 2. BLOCKING findings (must fix before landing)"
    echo
    if [ -n "$trailing" ]; then
      echo "**None.** Zero BLOCKING findings from any of the active lanes."
    else
      echo "**None.**"
    fi
    echo
    echo "## 3. LOW findings (surface to human for decision)"
    echo
    for i in $(seq 1 "$low"); do
      echo "### LOW-${i} — sample low finding ${i}"
      echo "- **Lanes:** simplicity (LOW-${i})"
      echo "- **File:line:** \`some/file.go:$((i + 10))\`"
      echo "- **Finding:** a minor concern."
      echo
    done
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
# CASE 9 — real-world "### <n>. [lane] Title" shape (fk-elkyf's actual doc
#   shape, the exact miss BLOCKING-1 found — the old `grep -c '^### BLOCKING-'`
#   parser silently counted 0 on this shape): 0 BLOCKING / 3 LOW still fires
#   the mail with the correct count.
# ===========================================================================
start_case "9: numbered [lane]-heading shape (fk-elkyf real shape) -> mail still fires, correct count"
setup_case_env "9"
SYNTHESIS_FILE="${SANDBOX}/synthesis-9.md"
fixture "$SYNTHESIS_FILE" 0 3 numbered
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "mail still sent for the numbered [lane] heading shape"
assert_log_count "$GC_LOG" "LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} .* 3 LOW" 1 "count is correct (3), not silently 0"

# ===========================================================================
# CASE 10 — "### B1"/"### L1" short-id heading shape: same contract.
# ===========================================================================
start_case "10: short B<n>/L<n> heading shape -> mail still fires, correct count"
setup_case_env "10"
SYNTHESIS_FILE="${SANDBOX}/synthesis-10.md"
fixture "$SYNTHESIS_FILE" 0 2 short
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "mail still sent for the B<n>/L<n> heading shape"
assert_log_count "$GC_LOG" "LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} .* 2 LOW" 1 "count is correct (2), not silently 0"

# ===========================================================================
# CASE 11 — no sub-headings at all, a plain top-level bulleted findings
#   section: same contract.
# ===========================================================================
start_case "11: plain bulleted findings section (no ### headings) -> mail still fires, correct count"
setup_case_env "11"
SYNTHESIS_FILE="${SANDBOX}/synthesis-11.md"
fixture "$SYNTHESIS_FILE" 0 4 bulleted
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "mail still sent for a plain bulleted section"
assert_log_count "$GC_LOG" "LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} .* 4 LOW" 1 "count is correct (4), not silently 0"

# ===========================================================================
# CASE 12 — a findings section with real content but no recognizable
#   per-finding shape: the script must fail loud, never silently default to
#   "0 findings" (the exact failure mode BLOCKING-1 exists to close).
# ===========================================================================
start_case "12: unparseable findings section -> fails loud, no mail"
setup_case_env "12"
SYNTHESIS_FILE="${SANDBOX}/synthesis-12.md"
fixture_unparseable "$SYNTHESIS_FILE"
run_script
assert_eq "1" "$RC" "script exits 1 rather than silently treating unparseable content as 0 findings"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail sent when the finding count itself could not be trusted"

# ===========================================================================
# CASE 13 — the real fk-elkyf document shape, reproduced exactly: an
#   unnumbered verdict heading that mentions "N LOW findings" in passing
#   (must not be mistaken for the real LOW section), a "None. <trailing
#   prose>" BLOCKING body, and numbered [lane] LOW sub-headings. This is the
#   literal on-disk document BLOCKING-1 was filed against.
# ===========================================================================
start_case "13: real fk-elkyf document shape -> mail still fires, correct count"
setup_case_env "13"
SYNTHESIS_FILE="${SANDBOX}/synthesis-13.md"
fixture_elkyf_shaped "$SYNTHESIS_FILE" 4
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "mail still sent for the real fk-elkyf document shape"
assert_log_count "$GC_LOG" "LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} .* 4 LOW" 1 "count is correct (4), not silently 0 — the exact bug BLOCKING-1 closes"

# ===========================================================================
# CASE 14 — a hung `gc mail send` is bounded by CV_LENS_STORE_TIMEOUT_SECONDS
#   (fk-72l6i BLOCKING-3): the script must time out and fail loud rather than
#   block indefinitely inside the one call chain whose entire job is making
#   sure a human gets told. Proves the cv_with_timeout wrap is actually wired
#   in (returns well inside the hang duration), not just present in the diff.
# ===========================================================================
start_case "14: gc mail send hangs -> bounded by CV_LENS_STORE_TIMEOUT_SECONDS, fails loud"
setup_case_env "14"
SYNTHESIS_FILE="${SANDBOX}/synthesis-14.md"
fixture "$SYNTHESIS_FILE" 0 1
START_TS=$(date +%s)
run_script CV_LENS_STORE_TIMEOUT_SECONDS="1" STUB_MAIL_HANG="1" STUB_HANG_SECONDS="20"
ELAPSED=$(( $(date +%s) - START_TS ))
assert_eq "1" "$RC" "script exits 1 when gc mail send hangs past the timeout"
assert_eq "1" "$(printf '%s' "$OUT" | grep -qi 'timed out' && echo 1 || echo 0)" "failure message says it timed out, not a generic send failure"
assert_eq "1" "$([ "$ELAPSED" -lt 10 ] && echo 1 || echo 0)" "returned quickly (~1s bound), not after the full 20s hang (elapsed=${ELAPSED}s)"
assert_log_count "$GC_LOG" "^bd update ${ROOT_ID} .*code_review\\.low_mail_sent=true" 0 "never claims a mail was sent when the send actually hung"

# ===========================================================================
# CASE 15 — zero-BLOCKING body is bold "**None.**" (the dominant real-world
#   shape, per iteration-2's code-review sweep: 7 of 59 on-disk synthesis
#   docs hit this and `die`d instead of sending the LOW-only mail): mail
#   still fires, correct count.
# ===========================================================================
start_case "15: bold **None.** zero-BLOCKING body -> mail still fires, correct count"
setup_case_env "15"
SYNTHESIS_FILE="${SANDBOX}/synthesis-15.md"
fixture_bold_none "$SYNTHESIS_FILE" 3
run_script
assert_eq "0" "$RC" "script exits 0 rather than dying on the bold zero-case body"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "mail still sent for a bold **None.** BLOCKING body"
assert_log_count "$GC_LOG" "LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} .* 3 LOW" 1 "count is correct (3), not a die on UNPARSEABLE"

# ===========================================================================
# CASE 16 — same bold "**None.**" shape with trailing prose after the marker
#   ("**None.** Zero BLOCKING findings from any of the active lanes."): same
#   contract, must not require the body be nothing but the marker itself.
# ===========================================================================
start_case "16: bold **None.** with trailing prose -> mail still fires, correct count"
setup_case_env "16"
SYNTHESIS_FILE="${SANDBOX}/synthesis-16.md"
fixture_bold_none "$SYNTHESIS_FILE" 2 trailing
run_script
assert_eq "0" "$RC" "script exits 0 rather than dying on the bold zero-case body with trailing prose"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "mail still sent for a bold **None.** BLOCKING body with trailing prose"
assert_log_count "$GC_LOG" "LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} .* 2 LOW" 1 "count is correct (2), not a die on UNPARSEABLE"

# ===========================================================================
# CASE 17 — BLOCKING > 0 doc whose YAML frontmatter `low_count` disagrees
#   with the body's actual LOW sub-heading count (root fk-5vupw iteration-3
#   code-review BLOCKING-1: the LOW_MISMATCH guard used to run before the
#   BLOCKING>0 no-op exit, so this legitimate iterate doc `die`d instead of
#   no-op'ing — LOW has no bearing on an iterate doc's mail decision).
# ===========================================================================
start_case "17: BLOCKING>0 with mismatched LOW frontmatter -> no-op exit 0, not a die"
setup_case_env "17"
SYNTHESIS_FILE="${SANDBOX}/synthesis-17.md"
{
  echo "---"
  echo "blocking_count: 1"
  echo "low_count: 7"
  echo "---"
  echo "# Con-voyage Review Synthesis — root fixture (iteration 1)"
  echo
  echo "## 1. Overall verdict: **iterate**"
  echo
  echo "## 2. BLOCKING findings (must fix before landing)"
  echo
  echo "### BLOCKING-1 — sample blocking finding 1"
  echo "- **Lanes:** security (BLOCKING-1)"
  echo "- **File:line:** \`some/file.go:1\`"
  echo "- **Finding:** something must be fixed."
  echo
  echo "## 3. LOW findings (surface to human for decision)"
  echo
  for i in $(seq 1 8); do
    echo "### LOW-${i} — sample low finding ${i}"
    echo "- **Lanes:** simplicity (LOW-${i})"
    echo "- **File:line:** \`some/file.go:$((i + 10))\`"
    echo "- **Finding:** a minor concern."
    echo
  done
  echo "## 4. Lanes approved with no findings"
  echo
  echo "None."
} > "$SYNTHESIS_FILE"
run_script
assert_eq "0" "$RC" "script exits 0 (BLOCKING no-op) instead of dying on the unrelated LOW-count mismatch"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail sent while BLOCKING findings remain, even with a LOW mismatch"
assert_log_count "$GC_LOG" 'bd update' 0 "no metadata recorded either"

# ===========================================================================
# CASE 18 — BLOCKING == 0 doc whose YAML frontmatter `low_count` disagrees
#   with the body's actual LOW sub-heading count (root fk-5vupw iteration-4
#   code-review BLOCKING-1: on the terminal LOW-only path, the LOW_MISMATCH
#   guard still `die`d on frontmatter/body drift even though the parsed body
#   count is already authoritative and is exactly what the mail body below
#   is built from — suppressing the very escalation mail this script exists
#   to send). Frontmatter under-claims (low_count: 2) against 3 actual
#   ### LOW-<n> sub-headings in the body: the body count must win, the
#   mismatch must only warn (not die), and the mail must still fire.
# ===========================================================================
start_case "18: BLOCKING==0 with mismatched LOW frontmatter -> warns, mails anyway, body count wins"
setup_case_env "18"
SYNTHESIS_FILE="${SANDBOX}/synthesis-18.md"
{
  echo "---"
  echo "blocking_count: 0"
  echo "low_count: 2"
  echo "---"
  echo "# Con-voyage Review Synthesis — root fixture (iteration 1)"
  echo
  echo "## 1. Overall verdict: **approve**"
  echo
  echo "## 2. BLOCKING findings (must fix before landing)"
  echo
  echo "None."
  echo
  echo "## 3. LOW findings (surface to human for decision)"
  echo
  for i in $(seq 1 3); do
    echo "### LOW-${i} — sample low finding ${i}"
    echo "- **Lanes:** simplicity (LOW-${i})"
    echo "- **File:line:** \`some/file.go:$((i + 10))\`"
    echo "- **Finding:** a minor concern."
    echo
  done
  echo "## 4. Lanes approved with no findings"
  echo
  echo "None."
} > "$SYNTHESIS_FILE"
run_script
assert_eq "0" "$RC" "script exits 0 (mails) instead of dying on the LOW-count frontmatter/body mismatch"
assert_log_count "$GC_LOG" '^mail send mayor ' 1 "mail still sent to the mayor despite the frontmatter drift"
assert_log_count "$GC_LOG" "^bd update ${ROOT_ID} .*code_review\\.low_mail_id=msg-1" 1 "mail id recorded on the root bead"
assert_log_count "$GC_LOG" "LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} .* 3 LOW" 1 "subject uses the parsed body count (3), not the stale frontmatter count (2)"
case "$OUT" in
  *"WARNING"*"low_count=2"*"3 LOW"*) pass "warns about the mismatch on stderr/stdout instead of dying silently" ;;
  *) fail "expected a WARNING mentioning frontmatter low_count=2 vs 3 parsed LOW sub-heading(s), got: ${OUT}" ;;
esac

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
