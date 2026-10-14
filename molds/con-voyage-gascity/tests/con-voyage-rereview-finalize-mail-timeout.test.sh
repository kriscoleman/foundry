#!/usr/bin/env bash
# con-voyage-rereview-finalize-mail-timeout.test.sh — content-check proof that
# every mayor-mail escalation call in main.rereview-finalize.md is bounded by
# cv_with_timeout, and that cv_defer_status_clear_through's non-zero-return
# comment accurately describes both of its non-zero return cases (mayor
# regrade on foundry#200 round 3, BLOCKING-1 (was LOW-2, SRE) and FIX-ALSO
# (was LOW-1)).
#
# HOW IT WORKS: main.rereview-finalize.md is an LLM prompt, not a script, so
# there is nothing to execute or stub (same approach as
# con-voyage-ci-repair-defer-status-wiring.test.sh). We grep the real,
# shipped prompt file and con-voyage-lib.sh for the required wiring.
#
# Run:  bash tests/con-voyage-rereview-finalize-mail-timeout.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REREVIEW_FINALIZE_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.rereview-finalize.md"
CV_LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

for f in "$REREVIEW_FINALIZE_MD" "$CV_LIB"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: file under test not found at ${f}" >&2
    exit 2
  fi
done

FAILURES=0
CASE_NAME=""
start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# ===========================================================================
# CASE 1 — every "gc mail send mayor" call site in main.rereview-finalize.md
# is wrapped by cv_with_timeout on the same source line (mayor regrade
# BLOCKING-1, was LOW-2: the file's SRE finding flagged every mayor-mail
# escalation call in this file, not just the new round-3 one).
# ===========================================================================
start_case "1: every gc mail send mayor call in main.rereview-finalize.md is wrapped by cv_with_timeout"
MAIL_LINES="$(grep -nE 'gc mail send mayor' "$REREVIEW_FINALIZE_MD")"
MAIL_CALL_COUNT="$(printf '%s\n' "$MAIL_LINES" | grep -c . || true)"
if [ "$MAIL_CALL_COUNT" -lt 1 ]; then
  fail "expected at least one 'gc mail send mayor' call in ${REREVIEW_FINALIZE_MD}, found none — test fixture assumption broken"
else
  pass "found ${MAIL_CALL_COUNT} 'gc mail send mayor' call site(s)"
fi

UNWRAPPED=0
while IFS=: read -r lineno line; do
  [ -n "$lineno" ] || continue
  if printf '%s' "$line" | grep -q 'cv_with_timeout'; then
    pass "line ${lineno}: wrapped by cv_with_timeout"
  else
    fail "line ${lineno}: 'gc mail send mayor' is NOT wrapped by cv_with_timeout: ${line}"
    UNWRAPPED=$((UNWRAPPED + 1))
  fi
done <<EOF
$MAIL_LINES
EOF

# ===========================================================================
# CASE 2 — cv_defer_status_clear_through's doc comment in con-voyage-lib.sh
# describes BOTH non-zero return cases: a prefix mismatch AND the
# pending-status file being absent entirely at clear time (FIX-ALSO, was
# LOW-1).
# ===========================================================================
start_case "2: con-voyage-lib.sh's cv_defer_status_clear_through comment describes the file-absent return case"
# Extraction: grab the 20 lines immediately before the function definition,
# which is where its doc comment lives.
FUNC_LINE="$(grep -n '^cv_defer_status_clear_through()' "$CV_LIB" | head -1 | cut -d: -f1)"
if [ -z "$FUNC_LINE" ]; then
  fail "cv_defer_status_clear_through() not found in ${CV_LIB}"
else
  START=$((FUNC_LINE - 20))
  [ "$START" -ge 1 ] || START=1
  LIB_COMMENT_BLOCK="$(sed -n "${START},${FUNC_LINE}p" "$CV_LIB")"
  if printf '%s' "$LIB_COMMENT_BLOCK" | grep -qi "disappeared\|absent\|no longer exists\|record .*gone"; then
    pass "con-voyage-lib.sh doc comment mentions the file-absent/disappeared case"
  else
    fail "con-voyage-lib.sh doc comment above cv_defer_status_clear_through() does not mention the file-absent/disappeared return case"
  fi
fi

# ===========================================================================
# CASE 3 — main.rereview-finalize.md's inline comment on the same topic also
# describes the file-absent return case, not just the prefix-mismatch case.
# ===========================================================================
start_case "3: main.rereview-finalize.md's inline comment describes the file-absent return case"
MD_COMMENT_BLOCK="$(grep -n 'cv_defer_status_clear_through only returns non-zero' "$REREVIEW_FINALIZE_MD")"
if [ -z "$MD_COMMENT_BLOCK" ]; then
  fail "expected inline comment describing cv_defer_status_clear_through's return contract in ${REREVIEW_FINALIZE_MD}, found none — test fixture assumption broken"
else
  MD_LINE="$(printf '%s\n' "$MD_COMMENT_BLOCK" | head -1 | cut -d: -f1)"
  MD_BLOCK="$(sed -n "${MD_LINE},$((MD_LINE + 6))p" "$REREVIEW_FINALIZE_MD")"
  if printf '%s' "$MD_BLOCK" | grep -qi "disappeared\|absent\|no longer exists\|record .*gone"; then
    pass "main.rereview-finalize.md inline comment mentions the file-absent/disappeared case"
  else
    fail "main.rereview-finalize.md inline comment does not mention the file-absent/disappeared return case"
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "${FAILURES} CASE(S) FAILED"
  exit 1
fi
