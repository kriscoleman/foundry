#!/usr/bin/env bash
# cv-rereview-seed-fallback.test.sh — hermetic, offline tests for
# cv-rereview-seed-fallback.sh, the CV_LIB-unresolved sweep extracted out of
# main.rereview-seed.md's prose (review fk-xfewni BLOCKING LOW-6/LOW-7).
#
# Before this extraction, the ONLY coverage of this fallback was textual
# (grep/line-order against the markdown source, in
# con-voyage-gated-review-dispatch.test.sh) — a regression in the invocation
# itself (wrong flag, wrong id variable) would pass undetected as long as the
# literal substring and line order stayed intact. This suite stub-executes
# the real script against recorded bd/gc stubs to prove the actual call
# sequence and arguments.
#
# Run:  bash tests/cv-rereview-seed-fallback.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-rereview-seed-fallback.sh"
TIMEOUT_SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-timeout.sh"

for f in "$SCRIPT" "$TIMEOUT_SCRIPT"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: required file not found at ${f}" >&2
    exit 2
  fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-rereview-seed-fallback-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then pass "${desc} (=${actual})"; else fail "${desc}: expected '${expected}', got '${actual}'"; fi
}
assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
    *"$needle"*) pass "$desc" ;;
    *) fail "${desc}: expected to find '${needle}' in: ${haystack}" ;;
  esac
}
assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
    *"$needle"*) fail "${desc}: did NOT expect to find '${needle}'" ;;
    *) pass "$desc" ;;
  esac
}
line_no_matching() {
  local file="$1" needle="$2"
  grep -nF -- "$needle" "$file" | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# gc stub — records every call to STUB_GC_LOG. `mail send` succeeds unless
# STUB_GC_MAIL_FAIL=1.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG:-/dev/null}"
if [ "${1:-}" = "mail" ]; then
  if [ "${STUB_GC_MAIL_FAIL:-0}" = "1" ]; then
    echo "mail send failed (stub)" >&2
    exit 1
  fi
  printf '{"message":{"id":"msg-1"}}\n'
  exit 0
fi
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# ---------------------------------------------------------------------------
# bd stub — `list --metadata-field gc.root_bead_id=X --status open,in_progress
# --json` returns STUB_BD_LIST_JSON (default "[]"), or fails if
# STUB_BD_LIST_FAIL=1. `close <id>` records the call and succeeds unless the
# id is listed in STUB_BD_CLOSE_FAIL_IDS (space-separated).
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/bd" <<'BD_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_BD_LOG:-/dev/null}"
if [ "${1:-}" = "list" ]; then
  if [ "${STUB_BD_LIST_FAIL:-0}" = "1" ]; then
    echo "bd list failed (stub)" >&2
    exit 1
  fi
  printf '%s' "${STUB_BD_LIST_JSON:-[]}"
  exit 0
fi
if [ "${1:-}" = "close" ]; then
  id="${2:-}"
  for bad in ${STUB_BD_CLOSE_FAIL_IDS:-}; do
    if [ "$bad" = "$id" ]; then
      echo "bd close ${id} failed (stub)" >&2
      exit 1
    fi
  done
  exit 0
fi
exit 0
BD_STUB
chmod +x "${STUBDIR}/bd"

export PATH="${STUBDIR}:${PATH}"

run_fallback() {
  local gc_log="${SANDBOX}/gc.log" bd_log="${SANDBOX}/bd.log"
  : > "$gc_log"; : > "$bd_log"
  export STUB_GC_LOG="$gc_log" STUB_BD_LOG="$bd_log"
  OUT="$(bash "$SCRIPT" "$@" 2>"${SANDBOX}/stderr.log")"
  RC=$?
  GC_LOG_CONTENT="$(cat "$gc_log")"
  BD_LOG_CONTENT="$(cat "$bd_log")"
  STDERR_CONTENT="$(cat "${SANDBOX}/stderr.log")"
}

# ===========================================================================
start_case "happy path: mails the mayor, closes every descendant, then closes the root LAST"
export STUB_GC_MAIL_FAIL=0
export STUB_BD_LIST_FAIL=0
export STUB_BD_LIST_JSON='[{"id":"desc-1"},{"id":"desc-2"}]'
unset STUB_BD_CLOSE_FAIL_IDS
run_fallback "root-1" "step-1" "feature-branch" "failed to attach a worktree"
assert_eq "0" "$RC" "script exits 0 (best-effort, never fatal to the caller)"
assert_contains "$GC_LOG_CONTENT" "mail send mayor" "mails the mayor"
assert_contains "$GC_LOG_CONTENT" "con-voyage rereview-seed (step-1) could not attach a worktree for feature-branch: failed to attach a worktree" "mail body names the claimed bead, branch, and SEED_FAIL"
assert_contains "$BD_LOG_CONTENT" "close desc-1" "closes descendant desc-1"
assert_contains "$BD_LOG_CONTENT" "close desc-2" "closes descendant desc-2"
assert_contains "$BD_LOG_CONTENT" "close root-1" "closes the root bead"

BD_LOG_FILE="${SANDBOX}/bd.log"
L1="$(line_no_matching "$BD_LOG_FILE" "close desc-1")"
L2="$(line_no_matching "$BD_LOG_FILE" "close desc-2")"
LR="$(line_no_matching "$BD_LOG_FILE" "close root-1")"
if [ -n "$L1" ] && [ -n "$L2" ] && [ -n "$LR" ] && [ "$L1" -lt "$LR" ] && [ "$L2" -lt "$LR" ]; then
  pass "root closed strictly after every descendant"
else
  fail "ordering wrong: desc-1=${L1:-?} desc-2=${L2:-?} root=${LR:-?}"
fi

# ===========================================================================
start_case "bd list failure: no descendants to sweep, but the root is still closed"
export STUB_BD_LIST_FAIL=1
run_fallback "root-2" "step-2" "feature-branch" "failed to fetch feature-branch from origin"
assert_eq "0" "$RC" "script still exits 0"
assert_contains "$STDERR_CONTENT" "bd list during fallback sweep reported" "logs the bd list failure to stderr"
assert_contains "$BD_LOG_CONTENT" "close root-2" "still closes the root bead"
unset STUB_BD_LIST_FAIL

# ===========================================================================
start_case "mail failure: logged but does not block the sweep"
export STUB_GC_MAIL_FAIL=1
export STUB_BD_LIST_FAIL=0
export STUB_BD_LIST_JSON='[{"id":"desc-3"}]'
run_fallback "root-3" "step-3" "feature-branch" "seed failed"
assert_eq "0" "$RC" "script still exits 0"
assert_contains "$STDERR_CONTENT" "mail to mayor on seed failure failed/timed out" "logs the mail failure to stderr"
assert_contains "$STDERR_CONTENT" "mayor NOT confirmed notified" "makes the lack of confirmation explicit"
assert_contains "$BD_LOG_CONTENT" "close desc-3" "sweep still proceeds despite the mail failure"
assert_contains "$BD_LOG_CONTENT" "close root-3" "root still closed despite the mail failure"
unset STUB_GC_MAIL_FAIL

# ===========================================================================
start_case "a descendant close failure is warned about but the root is still closed"
export STUB_BD_LIST_JSON='[{"id":"desc-4"},{"id":"desc-5"}]'
export STUB_BD_CLOSE_FAIL_IDS="desc-4"
run_fallback "root-4" "step-4" "feature-branch" "seed failed"
assert_eq "0" "$RC" "script still exits 0"
assert_contains "$STDERR_CONTENT" "WARNING: could not close descendant desc-4" "warns about the failed descendant close"
assert_contains "$BD_LOG_CONTENT" "close desc-5" "still closes the other descendant"
assert_contains "$BD_LOG_CONTENT" "close root-4" "still closes the root"
unset STUB_BD_CLOSE_FAIL_IDS

# ===========================================================================
start_case "missing required args exits non-zero without calling bd/gc"
OUT="$(bash "$SCRIPT" "" "" "" "" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then pass "non-zero exit on missing args (rc=${RC})"; else fail "expected non-zero exit, got 0"; fi
assert_contains "$OUT" "usage:" "prints a usage message"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
