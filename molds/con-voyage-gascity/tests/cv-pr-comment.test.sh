#!/usr/bin/env bash
# cv-pr-comment.test.sh — hermetic, offline test proving cv-pr-comment.sh is
# the ONLY structural path for posting con-voyage text to a GitHub PR/issue,
# and that it always leads the body with the machine-identity banner.
#
# Why this exists: the identity banner used to be prose-only guidance inside
# {target}.ci-repair.md ("MUST lead with this identity banner") and a worker
# skipped it in production (a real @kriscoleman-attributed comment with no
# machine banner — an impersonation risk). This script makes the banner
# STRUCTURAL: every gh pr comment/review/create this pack issues must be
# routed through here, which prepends the banner unconditionally — the
# banner can no longer be "forgotten" by a worker following prose.
#
# HOW IT WORKS (no network, no real gh):
#   - A recording STUB `gh` executable is built in a temp dir (same pattern as
#     con-voyage-ci-repair-guard.test.sh / con-voyage-pr-watch.test.sh). It
#     appends its full argv to a call-log AND, whenever it sees --body-file,
#     copies that file's contents to a separate body-log so the test can
#     assert on the exact posted content (banner-first, then original body).
#   - cv-pr-comment.sh honors GH= (GH="${GH:-gh}"), so we point it at the stub.
#
# Run:  bash tests/cv-pr-comment.test.sh   (exit 0 => all passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-pr-comment.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-pr-comment-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gh` stub. Records argv (with --body-file's VALUE redacted to a fixed
# token, since it's a throwaway temp path that changes every run) and, when
# --body-file is present, copies the referenced file's contents verbatim to
# STUB_BODY_LOG so the test can assert on exactly what would have been
# posted. Exit code is controllable via STUB_GH_EXIT for failure-propagation
# cases.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
{
  line=""
  prev=""
  for a in "$@"; do
    a="${a//$'\n'/ }"
    if [ "$prev" = "--body-file" ]; then
      line="${line}<BODY_FILE_PATH> "
    else
      line="${line}${a} "
    fi
    prev="$a"
  done
  printf '%s\n' "$line"
} >> "${STUB_GH_LOG}"

# Copy the body-file content (if any) to the body log, verbatim.
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    if [ -n "${STUB_BODY_LOG:-}" ]; then
      cat "$a" > "${STUB_BODY_LOG}" 2>/dev/null || true
    fi
  fi
  prev="$a"
done

exit "${STUB_GH_EXIT:-0}"
GH_STUB
chmod +x "${STUBDIR}/gh"

# ---------------------------------------------------------------------------
# Test harness bookkeeping (same helpers as the other mold test files).
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

GH_LOG=""
BODY_LOG=""
BODY_SRC=""
OUT=""
RC=0

setup_case_env() {
  GH_LOG="${SANDBOX}/gh-${1}.log"
  BODY_LOG="${SANDBOX}/body-${1}.log"
  BODY_SRC="${SANDBOX}/src-body-${1}.md"
  : > "$GH_LOG"
  : > "$BODY_LOG"
}

run_script() {
  OUT="$(
    env \
      GH="${STUBDIR}/gh" \
      STUB_GH_LOG="$GH_LOG" \
      STUB_BODY_LOG="$BODY_LOG" \
      "$@" \
      bash "$SCRIPT" "${ARGS[@]}" 2>&1
  )"
  RC=$?
}

BANNER_PREFIX='🤖 **Automated con-voyage agent**'

# ===========================================================================
# CASE 1 — comment: happy path. Banner leads the posted body, original body
#   follows, and gh is invoked with the right pr comment shape.
# ===========================================================================
start_case "1: comment happy path — banner leads, body preserved, gh invoked correctly"
setup_case_env "1"
printf 'Diagnosed the flake: the runner hit a transient network timeout.\n' > "$BODY_SRC"
ARGS=(comment 42 --repo kriscoleman/foundry --body-file "$BODY_SRC" --formula con-voyage-ci-repair --agent foundry-kc/gc.implementation-worker)
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" '^pr comment 42 --repo kriscoleman/foundry --body-file <BODY_FILE_PATH>' 1 "gh invoked as pr comment with the right shape"
first_line="$(head -1 "$BODY_LOG")"
case "$first_line" in
  "${BANNER_PREFIX}"*) pass "posted body's first line leads with the identity banner" ;;
  *) fail "posted body's first line does not lead with the banner (got: ${first_line})" ;;
esac
if grep -q 'con-voyage-ci-repair / foundry-kc/gc.implementation-worker' "$BODY_LOG"; then
  pass "banner names the resolved formula and rig/agent"
else
  fail "banner missing formula/agent identification"
fi
if grep -q "posted via @kriscoleman's token, not by Kris personally" "$BODY_LOG"; then
  pass "banner carries the impersonation disclaimer"
else
  fail "banner missing the impersonation disclaimer"
fi
if grep -q 'Diagnosed the flake' "$BODY_LOG"; then
  pass "original body content is preserved in the posted body"
else
  fail "original body content missing from the posted body"
fi

# ===========================================================================
# CASE 2 — review --comment: happy path, banner leads, correct gh shape.
# ===========================================================================
start_case "2: review --comment happy path"
setup_case_env "2"
printf 'LGTM once the flake is fixed.\n' > "$BODY_SRC"
ARGS=(review 42 --repo kriscoleman/foundry --comment --body-file "$BODY_SRC" --formula con-voyage --agent foundry-kc/reviewer-3)
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" '^pr review 42 --repo kriscoleman/foundry --comment --body-file <BODY_FILE_PATH>' 1 "gh invoked as pr review --comment with the right shape"
first_line="$(head -1 "$BODY_LOG")"
case "$first_line" in
  "${BANNER_PREFIX}"*) pass "review body leads with the identity banner" ;;
  *) fail "review body does not lead with the banner (got: ${first_line})" ;;
esac

# ===========================================================================
# CASE 3 — review requires exactly one verb (--comment/--approve/
#   --request-changes). Omitting it is a hard error; gh is never invoked.
# ===========================================================================
start_case "3: review without a verb is rejected before invoking gh"
setup_case_env "3"
printf 'body\n' > "$BODY_SRC"
ARGS=(review 42 --repo kriscoleman/foundry --body-file "$BODY_SRC")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing review verb"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when the review verb is missing"

# ===========================================================================
# CASE 4 — create: happy path (publish.md's PR-body use case). Banner leads
#   the PR body too.
# ===========================================================================
start_case "4: create happy path — PR body also leads with the banner"
setup_case_env "4"
printf '## Summary\n\nAdds retry backoff.\n' > "$BODY_SRC"
ARGS=(create --repo kriscoleman/foundry --title "feat: add retry backoff" --body-file "$BODY_SRC" --base main --head fix/retry-backoff --formula con-voyage --agent foundry-kc/gc.publisher)
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" '^pr create --repo kriscoleman/foundry --title feat: add retry backoff --body-file <BODY_FILE_PATH> --base main --head fix/retry-backoff' 1 "gh invoked as pr create with the right shape"
first_line="$(head -1 "$BODY_LOG")"
case "$first_line" in
  "${BANNER_PREFIX}"*) pass "PR body leads with the identity banner" ;;
  *) fail "PR body does not lead with the banner (got: ${first_line})" ;;
esac
if grep -q '## Summary' "$BODY_LOG"; then
  pass "original PR body content is preserved after the banner"
else
  fail "original PR body content missing"
fi

# ===========================================================================
# CASE 5 — missing --body-file entirely is a hard error; gh never invoked.
# ===========================================================================
start_case "5: missing --body-file is rejected before invoking gh"
setup_case_env "5"
ARGS=(comment 42 --repo kriscoleman/foundry)
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing --body-file"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when --body-file is missing"

# ===========================================================================
# CASE 6 — --body-file pointing at a nonexistent file is a hard error.
# ===========================================================================
start_case "6: nonexistent --body-file is rejected before invoking gh"
setup_case_env "6"
ARGS=(comment 42 --repo kriscoleman/foundry --body-file "${SANDBOX}/does-not-exist.md")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for a nonexistent body file"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when the body file does not exist"

# ===========================================================================
# CASE 7 — missing --repo is a hard error; gh never invoked.
# ===========================================================================
start_case "7: missing --repo is rejected before invoking gh"
setup_case_env "7"
printf 'body\n' > "$BODY_SRC"
ARGS=(comment 42 --body-file "$BODY_SRC")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing --repo"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when --repo is missing"

# ===========================================================================
# CASE 8 — missing PR number for comment/review is a hard error.
# ===========================================================================
start_case "8: missing PR number is rejected before invoking gh"
setup_case_env "8"
printf 'body\n' > "$BODY_SRC"
ARGS=(comment --repo kriscoleman/foundry --body-file "$BODY_SRC")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing PR number"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when the PR number is missing"

# ===========================================================================
# CASE 9 — unknown subcommand is rejected with a usage error; gh never
#   invoked. This is what structurally forbids a raw `gh pr comment` from
#   masquerading as this script's contract — there is no passthrough mode.
# ===========================================================================
start_case "9: unknown subcommand is rejected"
setup_case_env "9"
printf 'body\n' > "$BODY_SRC"
ARGS=(frobnicate 42 --repo kriscoleman/foundry --body-file "$BODY_SRC")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for an unknown subcommand"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked for an unknown subcommand"

# ===========================================================================
# CASE 10 — gh failure propagates as this script's own exit code (so callers
#   can detect a failed post rather than assuming success).
# ===========================================================================
start_case "10: gh failure propagates"
setup_case_env "10"
printf 'body\n' > "$BODY_SRC"
ARGS=(comment 42 --repo kriscoleman/foundry --body-file "$BODY_SRC")
run_script STUB_GH_EXIT=7
assert_eq "7" "$RC" "script propagates gh's non-zero exit code"

# ===========================================================================
# CASE 11 — formula/agent are optional: the script still posts (never
#   silently drops the banner) even when identity cannot be fully resolved,
#   matching ci-repair.md's "still post the banner with a clear
#   self-identification" fallback contract.
# ===========================================================================
start_case "11: banner still posts when --formula/--agent are omitted"
setup_case_env "11"
printf 'body\n' > "$BODY_SRC"
ARGS=(comment 42 --repo kriscoleman/foundry --body-file "$BODY_SRC")
run_script
assert_eq "0" "$RC" "script exits 0 even without --formula/--agent"
first_line="$(head -1 "$BODY_LOG")"
case "$first_line" in
  "${BANNER_PREFIX}"*) pass "banner still leads the body without --formula/--agent" ;;
  *) fail "banner missing when --formula/--agent are omitted (got: ${first_line})" ;;
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
