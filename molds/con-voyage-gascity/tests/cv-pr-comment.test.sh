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
# Records argv with any body-carrying temp path REDACTED to a fixed token, so the
# recorded line is deterministic run-to-run. Three body-carrying shapes are
# redacted+captured:
#   --body-file <path>   (pr comment/review/create modes)
#   -F body=@<path>      (the reply-thread mode's `gh api ... -F body=@file`,
#                         which mirrors --body-file's foot-gun avoidance: the
#                         body never round-trips through argv, only the file path
#                         does — and we redact that path too).
#   --input <path>       (the review-inline mode's `gh api ... --input file`,
#                         which submits the whole review payload — JSON body
#                         plus per-line comments — as a file, never argv).
{
  line=""
  prev=""
  for a in "$@"; do
    a="${a//$'\n'/ }"
    if [ "$prev" = "--body-file" ] || [ "$prev" = "--input" ]; then
      line="${line}<BODY_FILE_PATH> "
    elif [ "$prev" = "-F" ] && [ "${a#body=@}" != "$a" ]; then
      # `-F body=@<path>` — redact only the file path, keep the `body=@` shape
      # visible so assertions can prove the body traveled via a file, not argv.
      line="${line}body=@<BODY_FILE_PATH> "
    else
      line="${line}${a} "
    fi
    prev="$a"
  done
  printf '%s\n' "$line"
} >> "${STUB_GH_LOG}"

# Copy the body content (if any) to the body log, verbatim. Handles all three
# body-carrying shapes: `--body-file <path>`, `-F body=@<path>`, and
# `--input <path>`.
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ] || [ "$prev" = "--input" ]; then
    if [ -n "${STUB_BODY_LOG:-}" ]; then
      cat "$a" > "${STUB_BODY_LOG}" 2>/dev/null || true
    fi
  elif [ "$prev" = "-F" ] && [ "${a#body=@}" != "$a" ]; then
    if [ -n "${STUB_BODY_LOG:-}" ]; then
      cat "${a#body=@}" > "${STUB_BODY_LOG}" 2>/dev/null || true
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
  fail "banner still carries the impersonation disclaimer (dropped per PR #27 feedback)"
else
  pass "banner does not carry the impersonation disclaimer"
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
# CASE 12 — reply-thread: happy path. Addressing a specific INLINE review-thread
#   comment must post a THREADED reply within that thread (the review-comment
#   replies API), NOT a root-level `gh pr comment`. The banner leads the posted
#   body, the caller's original body follows verbatim, and the body travels via a
#   file (`-F body=@...`) — never inline in argv (same foot-gun avoidance as the
#   other modes). This is the core of C10 (bead fk-bhz).
# ===========================================================================
start_case "12: reply-thread happy path — threaded reply via replies API, banner leads, body via file"
setup_case_env "12"
printf 'Fixed: renamed the var to `retryBackoff` as you suggested.\n' > "$BODY_SRC"
ARGS=(reply-thread 42 --repo kriscoleman/foundry --comment-id 123456789 --body-file "$BODY_SRC" --formula con-voyage --agent foundry-kc/gc.implementation-worker)
run_script
assert_eq "0" "$RC" "script exits 0"
# It must hit the review-comment replies API for THIS comment id, with POST.
assert_log_count "$GH_LOG" '^api --method POST repos/kriscoleman/foundry/pulls/42/comments/123456789/replies' 1 "gh api POST targets the correct .../pulls/42/comments/123456789/replies endpoint"
# It must NOT fall back to a root-level pr comment (that is the general/summary path).
assert_log_count "$GH_LOG" '^pr comment ' 0 "reply-thread does NOT post a root-level pr comment"
# The body must travel via a file (-F body=@<path>), never inline in argv.
assert_log_count "$GH_LOG" 'body=@<BODY_FILE_PATH>' 1 "body travels via -F body=@file (out of argv), not inline"
assert_log_count "$GH_LOG" '\-f body=' 0 "body is never passed inline via -f body=<text>"
# Banner leads, original body preserved.
first_line="$(head -1 "$BODY_LOG")"
case "$first_line" in
  "${BANNER_PREFIX}"*) pass "posted reply body's first line leads with the identity banner" ;;
  *) fail "posted reply body's first line does not lead with the banner (got: ${first_line})" ;;
esac
if grep -q 'con-voyage / foundry-kc/gc.implementation-worker' "$BODY_LOG"; then
  pass "banner names the resolved formula and rig/agent"
else
  fail "banner missing formula/agent identification in reply body"
fi
if grep -q 'Fixed: renamed the var to' "$BODY_LOG"; then
  pass "original body content is preserved verbatim after the banner"
else
  fail "original body content missing from the posted reply body"
fi

# ===========================================================================
# CASE 13 — reply-thread: missing --comment-id is a hard error; gh never invoked.
# ===========================================================================
start_case "13: reply-thread without --comment-id is rejected before invoking gh"
setup_case_env "13"
printf 'body\n' > "$BODY_SRC"
ARGS=(reply-thread 42 --repo kriscoleman/foundry --body-file "$BODY_SRC")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing --comment-id"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when --comment-id is missing"

# ===========================================================================
# CASE 14 — reply-thread: non-numeric --comment-id is a hard error (mirrors the
#   PR-number validation). gh never invoked.
# ===========================================================================
start_case "14: reply-thread with a non-numeric --comment-id is rejected before invoking gh"
setup_case_env "14"
printf 'body\n' > "$BODY_SRC"
ARGS=(reply-thread 42 --repo kriscoleman/foundry --comment-id PRRC_notanumber --body-file "$BODY_SRC")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for a non-numeric --comment-id"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when --comment-id is non-numeric"

# ===========================================================================
# CASE 15 — reply-thread: missing --body-file is a hard error; gh never invoked
#   (the body-out-of-argv contract applies to this mode too).
# ===========================================================================
start_case "15: reply-thread without --body-file is rejected before invoking gh"
setup_case_env "15"
ARGS=(reply-thread 42 --repo kriscoleman/foundry --comment-id 123456789)
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing --body-file"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when --body-file is missing"

# ===========================================================================
# CASE 16 — reply-thread: still requires the PR number and --repo (same as the
#   other PR-scoped modes). A missing PR number is a hard error; gh never invoked.
# ===========================================================================
start_case "16: reply-thread without a PR number is rejected before invoking gh"
setup_case_env "16"
printf 'body\n' > "$BODY_SRC"
ARGS=(reply-thread --repo kriscoleman/foundry --comment-id 123456789 --body-file "$BODY_SRC")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing PR number"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when the PR number is missing"

# ===========================================================================
# CASE 17 — reply-thread: gh failure propagates as this script's own exit code
#   (so a caller can tell a failed threaded reply from a success).
# ===========================================================================
start_case "17: reply-thread gh failure propagates"
setup_case_env "17"
printf 'body\n' > "$BODY_SRC"
ARGS=(reply-thread 42 --repo kriscoleman/foundry --comment-id 123456789 --body-file "$BODY_SRC")
run_script STUB_GH_EXIT=7
assert_eq "7" "$RC" "script propagates gh's non-zero exit code"

# ===========================================================================
# CASE 18 — comment-aggregate: happy path structure. One surface line (with
#   the con-voyage identity + overall verdict + optional extra line), a hidden
#   round marker, and one <details> block per entry with the
#   [<rig>/<agent> — <lens>] identity inside each <summary>. Per the fix
#   spec's "(LOW list first)" ordering, the synthesis block is rendered
#   BEFORE the per-lane blocks — the human sees the actionable summary first,
#   full lane reports below it for provenance.
# ===========================================================================
start_case "18: comment-aggregate happy path — surface line, marker, synthesis-first details, identity in each summary"
setup_case_env "18"
printf 'Security lane report.\nNo blocking findings found here.\n' > "${SANDBOX}/lane-security.md"
printf 'Simplicity lane report.\nOne LOW finding about duplication.\n' > "${SANDBOX}/lane-simplicity.md"
printf 'Synthesis: 0 BLOCKING, 2 LOW findings.\nLOW #1 ...\nLOW #2 ...\n' > "${SANDBOX}/synthesis.md"
MANIFEST="${SANDBOX}/manifest-18.json"
cat > "$MANIFEST" <<JSON
{
  "rig": "foundry-kc",
  "root_bead_id": "fk-testroot",
  "round": 1,
  "overall_line": "Approved: 2 lanes, 0 blocking, 2 low.",
  "extra_line": "LOWs for the human reviewer below.",
  "lanes": [
    {"agent": "reviewer-3", "lens": "security", "verdict": "approve", "findings": 0, "body_file": "${SANDBOX}/lane-security.md"},
    {"agent": "reviewer-4", "lens": "simplicity", "verdict": "approve", "findings": 1, "body_file": "${SANDBOX}/lane-simplicity.md"}
  ],
  "synthesis": {"agent": "gc.review-synthesizer", "lens": "synthesis", "verdict": "approve", "findings": 2, "body_file": "${SANDBOX}/synthesis.md"}
}
JSON
ARGS=(comment-aggregate 42 --repo kriscoleman/foundry --manifest "$MANIFEST" --formula con-voyage --agent foundry-kc/gc.publisher)
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" '^pr comment 42 --repo kriscoleman/foundry --body-file <BODY_FILE_PATH>' 1 "gh invoked as a single root-level pr comment"
first_line="$(head -1 "$BODY_LOG")"
case "$first_line" in
  "${BANNER_PREFIX}"*) pass "aggregate body still leads with the structural identity banner" ;;
  *) fail "aggregate body does not lead with the banner (got: ${first_line})" ;;
esac
if grep -qF '**[foundry-kc/con-voyage — review]** Approved: 2 lanes, 0 blocking, 2 low.' "$BODY_LOG"; then
  pass "surface line has the con-voyage identity and overall verdict"
else
  fail "surface line missing or malformed"
fi
if grep -qF 'LOWs for the human reviewer below.' "$BODY_LOG"; then
  pass "extra surface line included"
else
  fail "extra surface line missing"
fi
if grep -qF '<!-- con-voyage-review:fk-testroot round=1 -->' "$BODY_LOG"; then
  pass "hidden round marker present with the correct root bead id and round number"
else
  fail "hidden round marker missing or wrong"
fi
assert_log_count "$BODY_LOG" '<details>' 3 "one details block per lane plus one for the synthesis (3 total)"
if grep -qF '<summary>[foundry-kc/gc.review-synthesizer — synthesis] approve · 2 findings</summary>' "$BODY_LOG"; then
  pass "synthesis details summary carries identity, verdict, and finding count"
else
  fail "synthesis details summary missing or malformed"
fi
if grep -qF '<summary>[foundry-kc/reviewer-3 — security] approve · 0 findings</summary>' "$BODY_LOG"; then
  pass "security lane details summary carries identity, verdict, and finding count"
else
  fail "security lane details summary missing or malformed"
fi
if grep -qF 'Security lane report.' "$BODY_LOG" && grep -qF 'Simplicity lane report.' "$BODY_LOG" && grep -qF 'Synthesis: 0 BLOCKING' "$BODY_LOG"; then
  pass "every entry's full report content is present in the posted body"
else
  fail "one or more entries' report content missing from the posted body"
fi
synth_line="$(grep -n 'gc.review-synthesizer' "$BODY_LOG" | head -1 | cut -d: -f1)"
security_line="$(grep -n 'reviewer-3 — security' "$BODY_LOG" | head -1 | cut -d: -f1)"
if [ -n "$synth_line" ] && [ -n "$security_line" ] && [ "$synth_line" -lt "$security_line" ]; then
  pass "synthesis details block is ordered before the per-lane details blocks (LOW list first)"
else
  fail "synthesis details block is not ordered first (synth line ${synth_line:-?}, security line ${security_line:-?})"
fi

# ===========================================================================
# CASE 19 — comment-aggregate: each review round posts a brand-new root-level
#   comment. There is no edit/update mode — round 2 must never touch round
#   1's already-posted content. GH_LOG deliberately spans both calls (not
#   reset between them) so we can prove exactly two independent posts happen,
#   with no edit-shaped gh invocation anywhere in between.
# ===========================================================================
start_case "19: comment-aggregate round 2 posts a NEW comment; round 1 is never edited"
GH_LOG_19="${SANDBOX}/gh-19.log"
BODY_LOG_R1="${SANDBOX}/body-19-r1.md"
BODY_LOG_R2="${SANDBOX}/body-19-r2.md"
: > "$GH_LOG_19"
printf 'Round 1 lane report.\n' > "${SANDBOX}/lane-19.md"
MANIFEST_R1="${SANDBOX}/manifest-19-r1.json"
cat > "$MANIFEST_R1" <<JSON
{
  "rig": "foundry-kc", "root_bead_id": "fk-testroot", "round": 1,
  "overall_line": "Approved: 1 lane, 0 blocking, 0 low.",
  "lanes": [{"agent": "reviewer-3", "lens": "security", "verdict": "approve", "findings": 0, "body_file": "${SANDBOX}/lane-19.md"}]
}
JSON
MANIFEST_R2="${SANDBOX}/manifest-19-r2.json"
cat > "$MANIFEST_R2" <<JSON
{
  "rig": "foundry-kc", "root_bead_id": "fk-testroot", "round": 2,
  "overall_line": "Approved: 1 lane, 0 blocking, 0 low.",
  "lanes": [{"agent": "reviewer-3", "lens": "security", "verdict": "approve", "findings": 0, "body_file": "${SANDBOX}/lane-19.md"}]
}
JSON
RC1=0; RC2=0
OUT="$(env GH="${STUBDIR}/gh" STUB_GH_LOG="$GH_LOG_19" STUB_BODY_LOG="$BODY_LOG_R1" bash "$SCRIPT" comment-aggregate 42 --repo kriscoleman/foundry --manifest "$MANIFEST_R1" --formula con-voyage --agent foundry-kc/gc.publisher 2>&1)" || true
RC1=$?
OUT="$(env GH="${STUBDIR}/gh" STUB_GH_LOG="$GH_LOG_19" STUB_BODY_LOG="$BODY_LOG_R2" bash "$SCRIPT" comment-aggregate 42 --repo kriscoleman/foundry --manifest "$MANIFEST_R2" --formula con-voyage --agent foundry-kc/gc.publisher 2>&1)" || true
RC2=$?
assert_eq "0" "$RC1" "round 1 comment-aggregate exits 0"
assert_eq "0" "$RC2" "round 2 comment-aggregate exits 0"
assert_log_count "$GH_LOG_19" '^pr comment 42 --repo kriscoleman/foundry --body-file <BODY_FILE_PATH>' 2 "two independent NEW root-level comments posted, one per round"
assert_log_count "$GH_LOG_19" 'edit' 0 "no gh invocation ever attempts to edit an existing comment"
if grep -qF 'round=1' "$BODY_LOG_R1"; then pass "round 1's posted body carries the round=1 marker"; else fail "round 1 body missing round=1 marker"; fi
if grep -qF 'round=2' "$BODY_LOG_R2"; then pass "round 2's posted body carries the round=2 marker"; else fail "round 2 body missing round=2 marker"; fi
if grep -qF 'round=2' "$BODY_LOG_R1"; then fail "round 1's captured body was mutated to mention round=2"; else pass "round 1's captured body is untouched by round 2's call"; fi

# ===========================================================================
# CASE 20 — comment-aggregate: an oversized lane report truncates INSIDE its
#   own details block with a pointer to the full report, to stay under
#   GitHub's 65536-char comment limit. Sibling entries (synthesis and the
#   normal-sized lane) are left completely untouched.
# ===========================================================================
start_case "20: comment-aggregate truncates an oversized lane report inside its details block, leaves siblings untouched"
setup_case_env "20"
python3 -c "print('LINEFULLOFCONTENT_' * 4200)" > "${SANDBOX}/huge-lane.md"
printf 'NORMALSIZE_SENTINEL lane report, fully intact.\n' > "${SANDBOX}/normal-lane.md"
printf 'SYNTHESIS_SENTINEL: 0 BLOCKING, 1 LOW.\n' > "${SANDBOX}/synthesis-20.md"
MANIFEST="${SANDBOX}/manifest-20.json"
cat > "$MANIFEST" <<JSON
{
  "rig": "foundry-kc", "root_bead_id": "fk-testroot", "round": 1,
  "overall_line": "Approved: 2 lanes, 0 blocking, 1 low.",
  "lanes": [
    {"agent": "reviewer-huge", "lens": "code-review", "verdict": "approve", "findings": 0, "body_file": "${SANDBOX}/huge-lane.md"},
    {"agent": "reviewer-normal", "lens": "security", "verdict": "approve", "findings": 0, "body_file": "${SANDBOX}/normal-lane.md"}
  ],
  "synthesis": {"agent": "gc.review-synthesizer", "lens": "synthesis", "verdict": "approve", "findings": 1, "body_file": "${SANDBOX}/synthesis-20.md"}
}
JSON
ARGS=(comment-aggregate 42 --repo kriscoleman/foundry --manifest "$MANIFEST" --formula con-voyage --agent foundry-kc/gc.publisher)
run_script
assert_eq "0" "$RC" "script exits 0 even with an oversized lane report"
posted_size="$(wc -c < "$BODY_LOG" | tr -d ' ')"
if [ "$posted_size" -le 65536 ]; then
  pass "posted body stays within GitHub's 65536-char comment limit (size ${posted_size})"
else
  fail "posted body exceeds GitHub's 65536-char comment limit (size ${posted_size})"
fi
if grep -q 'truncated.*full report at' "$BODY_LOG"; then
  pass "oversized lane's details block carries a pointer to the full report"
else
  fail "truncation pointer missing from the oversized lane's details block"
fi
if grep -qF 'NORMALSIZE_SENTINEL lane report, fully intact.' "$BODY_LOG"; then
  pass "sibling normal-sized lane report is left fully intact"
else
  fail "sibling normal-sized lane report was altered or dropped"
fi
if grep -qF 'SYNTHESIS_SENTINEL: 0 BLOCKING, 1 LOW.' "$BODY_LOG"; then
  pass "synthesis content is left fully intact"
else
  fail "synthesis content was altered or dropped"
fi

# ===========================================================================
# CASE 21 — comment-aggregate: hygiene scan rewrites a local city-root path
#   to the neutral placeholder <city-root> before posting, so an internal
#   filesystem layout never leaks into an enterprise-visible PR comment.
# ===========================================================================
start_case "21: comment-aggregate hygiene scan rewrites local city-root paths"
setup_case_env "21"
printf 'See /fake/city/rigs/foundry-kc/worktrees/fk-x for details.\n' > "${SANDBOX}/lane-path.md"
MANIFEST="${SANDBOX}/manifest-21.json"
cat > "$MANIFEST" <<JSON
{
  "rig": "foundry-kc", "root_bead_id": "fk-testroot", "round": 1,
  "overall_line": "Approved: 1 lane, 0 blocking, 0 low.",
  "lanes": [{"agent": "reviewer-3", "lens": "security", "verdict": "approve", "findings": 0, "body_file": "${SANDBOX}/lane-path.md"}]
}
JSON
ARGS=(comment-aggregate 42 --repo kriscoleman/foundry --manifest "$MANIFEST" --city-root /fake/city --formula con-voyage --agent foundry-kc/gc.publisher)
run_script
assert_eq "0" "$RC" "script exits 0"
if grep -qF '<city-root>/rigs/foundry-kc/worktrees/fk-x' "$BODY_LOG"; then
  pass "local city-root path rewritten to the <city-root> placeholder"
else
  fail "local city-root path was not rewritten"
fi
if grep -qF '/fake/city' "$BODY_LOG"; then
  fail "raw city-root path still present in the posted body"
else
  pass "raw city-root path no longer present in the posted body"
fi

# ===========================================================================
# CASE 22 — comment-aggregate: hygiene scan BLOCKS (refuses to post, gh never
#   invoked) when a lane report contains a token-shaped string, rather than
#   trying to redact it and risking a wrong redaction shipping to GitHub.
# ===========================================================================
start_case "22: comment-aggregate hygiene scan blocks posting when a token shape is present"
setup_case_env "22"
printf 'Found a leaked credential: ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA in the diff.\n' > "${SANDBOX}/lane-token.md"
MANIFEST="${SANDBOX}/manifest-22.json"
cat > "$MANIFEST" <<JSON
{
  "rig": "foundry-kc", "root_bead_id": "fk-testroot", "round": 1,
  "overall_line": "Approved: 1 lane, 0 blocking, 0 low.",
  "lanes": [{"agent": "reviewer-3", "lens": "security", "verdict": "approve", "findings": 0, "body_file": "${SANDBOX}/lane-token.md"}]
}
JSON
ARGS=(comment-aggregate 42 --repo kriscoleman/foundry --manifest "$MANIFEST")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero when a token shape is detected"; else fail "expected non-zero exit when a token shape is present"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when the hygiene scan blocks on a token shape"

# ===========================================================================
# CASE 23 — comment-aggregate: missing --manifest is a hard error; gh never
#   invoked (mirrors the missing --body-file validation for other modes).
# ===========================================================================
start_case "23: comment-aggregate without --manifest is rejected before invoking gh"
setup_case_env "23"
ARGS=(comment-aggregate 42 --repo kriscoleman/foundry)
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing --manifest"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when --manifest is missing"

# ===========================================================================
# CASE 24 — comment-aggregate: --manifest pointing at a nonexistent file is a
#   hard error; gh never invoked.
# ===========================================================================
start_case "24: comment-aggregate with a nonexistent --manifest is rejected before invoking gh"
setup_case_env "24"
ARGS=(comment-aggregate 42 --repo kriscoleman/foundry --manifest "${SANDBOX}/does-not-exist.json")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for a nonexistent manifest file"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when the manifest file does not exist"

# ===========================================================================
# CASE 25 — review-inline: happy path. Findings with path+line land as inline
#   review comments on the exact line, each body carrying the
#   [<rig>/<agent> — <lane>] identity + severity + title header and the
#   trailing cv-finding v1 marker. One GitHub review is submitted
#   (gh api POST .../reviews --input <file>, never pr comment/review).
# ===========================================================================
start_case "25: review-inline happy path — inline comments on exact lines, identity+severity+marker, one review posted"
setup_case_env "25"
FINDINGS="${SANDBOX}/findings-25.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "security", "severity": "blocking", "path": "src/auth.go", "line": 42, "title": "missing nil check", "body": "Dereferences token without a nil check.\nFix: guard before use."},
  {"lane": "simplicity", "severity": "low", "path": "src/util.go", "line": 7, "title": "duplicated helper", "body": "This mirrors helper() above.\nFix: extract a shared function."}
]
JSON
# review fk-ppj8bx BLOCKING-4: a path+line finding only anchors to the exact
# line when --diff-lines-file confirms it's actually in the diff (fail-safe
# default otherwise) — supply one covering both findings' lines.
DIFF_LINES_25="${SANDBOX}/diff-lines-25.txt"
printf 'src/auth.go:42\nsrc/util.go:7\n' > "$DIFF_LINES_25"
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --diff-lines-file "$DIFF_LINES_25" --rig foundry-kc --agent reviewer-3)
run_script
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" '^api --method POST repos/kriscoleman/foundry/pulls/42/reviews --input <BODY_FILE_PATH>' 1 "gh invoked exactly once as a single POST .../reviews call"
assert_log_count "$GH_LOG" 'pr comment|pr review' 0 "review-inline never falls back to pr comment/review"
if grep -qF '"event": "COMMENT"' "$BODY_LOG"; then pass "review event is COMMENT"; else fail "review event missing or wrong"; fi
if grep -qF '"commit_id": "deadbeef1234"' "$BODY_LOG"; then pass "commit_id matches --commit"; else fail "commit_id missing or wrong"; fi
if grep -qF '"path": "src/auth.go"' "$BODY_LOG" && grep -qF '"line": 42' "$BODY_LOG"; then
  pass "first finding anchored to its exact path/line"
else
  fail "first finding not anchored correctly"
fi
if grep -qF '"path": "src/util.go"' "$BODY_LOG" && grep -qF '"line": 7' "$BODY_LOG"; then
  pass "second finding anchored to its exact path/line"
else
  fail "second finding not anchored correctly"
fi
if grep -qF '[foundry-kc/reviewer-3 — security] **BLOCKING** missing nil check' "$BODY_LOG"; then
  pass "blocking finding header carries identity, severity, and title"
elif python3 -c "
import json, sys
d = json.load(open('${BODY_LOG}'))
ok = any('[foundry-kc/reviewer-3' in c.get('body','') and 'BLOCKING' in c.get('body','') and 'missing nil check' in c.get('body','') for c in d.get('comments', []))
sys.exit(0 if ok else 1)
" 2>/dev/null; then
  pass "blocking finding header carries identity, severity, and title"
else
  fail "blocking finding header missing identity/severity/title"
fi
if grep -qF 'cv-finding v1 id=' "$BODY_LOG" && grep -qF 'severity=blocking' "$BODY_LOG" && grep -qF 'lane=security' "$BODY_LOG"; then
  pass "blocking finding carries the cv-finding v1 marker with severity and lane"
else
  fail "cv-finding v1 marker missing or malformed"
fi

# ===========================================================================
# CASE 26 — review-inline: a finding with no path is PR-level, folded into
#   the review's top body rather than dropped or crashing.
# ===========================================================================
start_case "26: review-inline PR-level finding (no path) folds into the review body"
setup_case_env "26"
FINDINGS="${SANDBOX}/findings-26.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "acceptance", "severity": "low", "title": "missing test evidence", "body": "No test run was attached to this PR."}
]
JSON
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --rig foundry-kc --agent reviewer-9)
run_script
assert_eq "0" "$RC" "script exits 0"
if grep -qF 'missing test evidence' "$BODY_LOG"; then pass "PR-level finding content present in the payload"; else fail "PR-level finding missing"; fi
python3 -c "
import json, sys
d = json.load(open('${BODY_LOG}'))
comments = d.get('comments') or []
sys.exit(0 if all('path' not in c or c.get('path') != '' for c in comments) and 'missing test evidence' in d.get('body','') else 1)
" && pass "PR-level finding lands in the top body, not as a line comment" || fail "PR-level finding did not land in the top body"

# ===========================================================================
# CASE 27 — review-inline: a finding whose line is not present in the
#   --diff-lines-file (the PR's actual diff) degrades to a file-level
#   comment rather than being dropped or erroring.
# ===========================================================================
start_case "27: review-inline finding outside the diff degrades to a file-level comment"
setup_case_env "27"
FINDINGS="${SANDBOX}/findings-27.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "code-review", "severity": "low", "path": "src/legacy.go", "line": 999, "title": "stale comment", "body": "This comment is out of date."}
]
JSON
DIFF_LINES="${SANDBOX}/diff-lines-27.txt"
printf 'src/legacy.go:5\nsrc/legacy.go:6\n' > "$DIFF_LINES"
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --diff-lines-file "$DIFF_LINES" --rig foundry-kc --agent reviewer-5)
run_script
assert_eq "0" "$RC" "script exits 0"
python3 -c "
import json, sys
d = json.load(open('${BODY_LOG}'))
comments = d.get('comments') or []
ok = len(comments) == 1 and comments[0].get('path') == 'src/legacy.go' and 'line' not in comments[0] and comments[0].get('subject_type') == 'FILE'
sys.exit(0 if ok else 1)
" && pass "out-of-diff finding degrades to a file-level comment (no line, subject_type=FILE)" || fail "out-of-diff finding was not degraded to file-level"

# ===========================================================================
# CASE 28 — review-inline: a finding whose stable id is already listed in
#   --skip-ids-file (an open thread from a prior round) is NOT re-posted.
# ===========================================================================
start_case "28: review-inline skips findings with an already-open thread"
setup_case_env "28"
FINDINGS="${SANDBOX}/findings-28.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "security", "severity": "low", "path": "src/a.go", "line": 1, "title": "old finding", "body": "already open from round 1", "id": "cvf-alreadyopen1"},
  {"lane": "security", "severity": "low", "path": "src/b.go", "line": 2, "title": "new finding", "body": "new in this round", "id": "cvf-brandnew0001"}
]
JSON
SKIP_IDS="${SANDBOX}/skip-ids-28.txt"
printf 'cvf-alreadyopen1\n' > "$SKIP_IDS"
# review fk-ppj8bx BLOCKING-1: a file-level/line comment's path must be
# confirmed changed, so give both findings' paths a --diff-lines-file entry
# -- this case is proving skip-ids dedup, not path confirmation.
DIFF_LINES_28="${SANDBOX}/diff-lines-28.txt"
printf 'src/a.go:1\nsrc/b.go:2\n' > "$DIFF_LINES_28"
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --skip-ids-file "$SKIP_IDS" --diff-lines-file "$DIFF_LINES_28" --rig foundry-kc --agent reviewer-3)
run_script
assert_eq "0" "$RC" "script exits 0"
python3 -c "
import json, sys
d = json.load(open('${BODY_LOG}'))
comments = d.get('comments') or []
ids = [c.get('body','') for c in comments]
has_old = any('old finding' in b for b in ids)
has_new = any('new finding' in b for b in ids)
sys.exit(0 if (not has_old and has_new and len(comments) == 1) else 1)
" && pass "already-open finding skipped, new finding still posted" || fail "dedup via --skip-ids-file did not work as expected"

# ===========================================================================
# CASE 29 — review-inline: zero findings (all deduped or none supplied)
#   still posts a single review with just the one-line summary body and no
#   inline comments — never an empty/crashing payload.
# ===========================================================================
start_case "29: review-inline with zero findings posts a summary-only review"
setup_case_env "29"
FINDINGS="${SANDBOX}/findings-29.json"
printf '[]\n' > "$FINDINGS"
SUMMARY="${SANDBOX}/summary-29.txt"
printf '[foundry-kc/con-voyage - review] 0 lanes, 0 blocking, 0 low - see inline\n' > "$SUMMARY"
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --summary-file "$SUMMARY" --rig foundry-kc --agent gc.publisher)
run_script
assert_eq "0" "$RC" "script exits 0"
if grep -qF '0 lanes, 0 blocking, 0 low' "$BODY_LOG"; then pass "summary-only body posted"; else fail "summary body missing"; fi
python3 -c "
import json, sys
d = json.load(open('${BODY_LOG}'))
sys.exit(0 if not (d.get('comments') or []) else 1)
" && pass "no inline comments posted when there are zero findings" || fail "unexpected inline comments with zero findings"

# ===========================================================================
# CASE 30 — review-inline: missing --commit is a hard error; gh never
#   invoked.
# ===========================================================================
start_case "30: review-inline without --commit is rejected before invoking gh"
setup_case_env "30"
FINDINGS="${SANDBOX}/findings-30.json"
printf '[]\n' > "$FINDINGS"
ARGS=(review-inline 42 --repo kriscoleman/foundry --findings "$FINDINGS")
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing --commit"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when --commit is missing"

# ===========================================================================
# CASE 31 — review-inline: missing --findings is a hard error; gh never
#   invoked.
# ===========================================================================
start_case "31: review-inline without --findings is rejected before invoking gh"
setup_case_env "31"
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234)
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero"; else fail "expected non-zero exit for missing --findings"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when --findings is missing"

# ===========================================================================
# CASE 32 — review-inline: gh failure propagates verbatim.
# ===========================================================================
start_case "32: review-inline gh failure propagates"
setup_case_env "32"
FINDINGS="${SANDBOX}/findings-32.json"
printf '[{"lane": "security", "severity": "blocking", "path": "src/d.go", "line": 1, "title": "unreachable finding", "body": "would have 422ed"}]\n' > "$FINDINGS"
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS")
OUT="$(env GH="${STUBDIR}/gh" STUB_GH_LOG="$GH_LOG" STUB_BODY_LOG="$BODY_LOG" STUB_GH_EXIT=7 bash "$SCRIPT" "${ARGS[@]}" 2>&1)"
RC=$?
assert_eq "7" "$RC" "script propagates gh's exit code verbatim"
# review fk-ppj8bx BLOCKING-4: the rendered review payload must survive the
# cleanup trap on a failed POST, so a human/ci-repair can see which finding
# triggered it.
PRESERVED_PATH="$(printf '%s' "$OUT" | sed -n 's/.*rendered payload preserved at \([^ ]*\) for diagnosis.*/\1/p')"
if [ -n "$PRESERVED_PATH" ] && [ -f "$PRESERVED_PATH" ] && grep -qF "unreachable finding" "$PRESERVED_PATH"; then
  pass "rendered review payload is preserved on disk after a failed POST, for diagnosis"
else
  fail "rendered review payload was not preserved after a failed POST (stderr: ${OUT})"
fi
[ -n "$PRESERVED_PATH" ] && rm -f "$PRESERVED_PATH"

# ===========================================================================
# CASE 33 — review-inline: stable-id determinism. The same lane/path/title
#   produces the same id across two separate invocations with no explicit
#   --id, so a later round's dedup (--skip-ids-file) can actually match it.
# ===========================================================================
start_case "33: review-inline stable id is deterministic across separate invocations"
setup_case_env "33"
FINDINGS="${SANDBOX}/findings-33.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "security", "severity": "low", "path": "src/c.go", "line": 3, "title": "Same Finding Title", "body": "body text"}
]
JSON
BODY_LOG_A="${SANDBOX}/body-33-a.json"
BODY_LOG_B="${SANDBOX}/body-33-b.json"
env GH="${STUBDIR}/gh" STUB_GH_LOG="${SANDBOX}/gh-33a.log" STUB_BODY_LOG="$BODY_LOG_A" bash "$SCRIPT" review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --rig foundry-kc --agent reviewer-3 >/dev/null 2>&1
env GH="${STUBDIR}/gh" STUB_GH_LOG="${SANDBOX}/gh-33b.log" STUB_BODY_LOG="$BODY_LOG_B" bash "$SCRIPT" review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --rig foundry-kc --agent reviewer-3 >/dev/null 2>&1
ID_A="$(python3 -c "import json; print(json.load(open('${BODY_LOG_A}'))['comments'][0]['body'].split('id=')[1].split()[0])" 2>/dev/null)"
ID_B="$(python3 -c "import json; print(json.load(open('${BODY_LOG_B}'))['comments'][0]['body'].split('id=')[1].split()[0])" 2>/dev/null)"
assert_eq "$ID_A" "$ID_B" "the same finding produces the same stable id across invocations"

# ===========================================================================
# CASE 34 — review-inline: hygiene scan rewrites a local city-root path
#   inside a finding body AND the summary (review fk-ppj8bx BLOCKING-2 —
#   mirrors comment-aggregate's case 21, review-inline's own copy of this
#   control previously had zero coverage).
# ===========================================================================
start_case "34: review-inline hygiene scan rewrites local city-root paths"
setup_case_env "34"
FINDINGS="${SANDBOX}/findings-34.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "sre", "severity": "low", "path": "src/e.go", "line": 1, "title": "path leak", "body": "See /fake/city/rigs/foundry-kc/worktrees/fk-x for details."}
]
JSON
SUMMARY_34="${SANDBOX}/summary-34.txt"
printf 'Also see /fake/city/rigs/foundry-kc/worktrees/fk-x in the summary.\n' > "$SUMMARY_34"
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --summary-file "$SUMMARY_34" --rig foundry-kc --agent reviewer-3 --city-root /fake/city)
run_script
assert_eq "0" "$RC" "script exits 0"
if grep -qF '<city-root>/rigs/foundry-kc/worktrees/fk-x' "$BODY_LOG"; then
  pass "local city-root path rewritten to the <city-root> placeholder in a finding body and the summary"
else
  fail "local city-root path was not rewritten"
fi
if grep -qF '/fake/city' "$BODY_LOG"; then
  fail "raw city-root path still present in the posted review payload"
else
  pass "raw city-root path no longer present in the posted review payload"
fi

# ===========================================================================
# CASE 35 — review-inline: hygiene scan BLOCKS (refuses to post, gh never
#   invoked) when a finding body contains a token-shaped string (review
#   fk-ppj8bx BLOCKING-2 — mirrors comment-aggregate's case 22).
# ===========================================================================
start_case "35: review-inline hygiene scan blocks posting when a token shape is present"
setup_case_env "35"
FINDINGS="${SANDBOX}/findings-35.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "security", "severity": "blocking", "path": "src/f.go", "line": 1, "title": "leaked credential", "body": "Found ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA in the diff."}
]
JSON
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --rig foundry-kc --agent reviewer-3)
run_script
if [ "$RC" -ne 0 ]; then pass "script exits non-zero when a token shape is detected"; else fail "expected non-zero exit when a token shape is present"; fi
assert_log_count "$GH_LOG" '.' 0 "gh is never invoked when the hygiene scan blocks on a token shape"

# ===========================================================================
# CASE 36 — review-inline: without --diff-lines-file, no path can be
#   confirmed changed, so a path+line finding fails SAFE all the way to the
#   PR-level summary body rather than becoming an unconfirmed file-level
#   comment (review fk-ppj8bx BLOCKING-1, supersedes the file-level degrade
#   this case originally proved for BLOCKING-4). GitHub's create-review
#   endpoint 422s its ENTIRE comments[] array if any one comment's path
#   isn't part of the diff — line-anchored or file-level alike — so with no
#   --diff-lines-file to confirm either the line OR the path, the only safe
#   default left is the summary body, which never 422s.
# ===========================================================================
start_case "36: review-inline without --diff-lines-file fails safe to the PR-level summary, never an unconfirmed file-level comment"
setup_case_env "36"
FINDINGS="${SANDBOX}/findings-36.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "sre", "severity": "blocking", "path": "src/g.go", "line": 123, "title": "unverifiable line", "body": "no diff-lines-file was supplied this round"}
]
JSON
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --rig foundry-kc --agent reviewer-3)
run_script
assert_eq "0" "$RC" "script exits 0"
python3 -c "
import json, sys
d = json.load(open('${BODY_LOG}'))
comments = d.get('comments') or []
ok = len(comments) == 0 and 'unverifiable line' in d.get('body','')
sys.exit(0 if ok else 1)
" && pass "a path+line finding with no --diff-lines-file folds into the PR-level summary (fails safe, no unconfirmed comment)" || fail "a path+line finding with no --diff-lines-file was posted as a comment anyway (unsafe default)"

# ===========================================================================
# CASE 36b — review-inline: a file-level finding whose path is NOT among the
#   paths --diff-lines-file lists as changed folds into the PR-level summary
#   instead of becoming an unconfirmed file-level comment (review fk-ppj8bx
#   BLOCKING-1). A "missing test" finding naturally cites a file the PR
#   never touched; posting it as a file-level comment on that path 422s the
#   whole atomic review the same way an out-of-diff line does.
# ===========================================================================
start_case "36b: review-inline finding on a path absent from --diff-lines-file folds into the summary, not comments[]"
setup_case_env "36b"
FINDINGS="${SANDBOX}/findings-36b.json"
cat > "$FINDINGS" <<JSON
[
  {"lane": "qa-test", "severity": "blocking", "path": "tests/unrelated_test.go", "title": "missing test coverage", "body": "no test pins this new behavior"}
]
JSON
DIFF_LINES="${SANDBOX}/diff-lines-36b.txt"
printf 'src/changed.go:10\n' > "$DIFF_LINES"
ARGS=(review-inline 42 --repo kriscoleman/foundry --commit deadbeef1234 --findings "$FINDINGS" --diff-lines-file "$DIFF_LINES" --rig foundry-kc --agent reviewer-3)
run_script
assert_eq "0" "$RC" "script exits 0"
python3 -c "
import json, sys
d = json.load(open('${BODY_LOG}'))
comments = d.get('comments') or []
ok = len(comments) == 0 and 'missing test coverage' in d.get('body','')
sys.exit(0 if ok else 1)
" && pass "finding on an unchanged path folds into the PR-level summary, never an unconfirmed file-level comment" || fail "finding on a path absent from --diff-lines-file was posted as comments[] anyway"

# ===========================================================================
# CASE 37 — static regression guard (review fk-ppj8bx BLOCKING-1): neither
#   review-inline's nor comment-aggregate's mktemp templates may carry a
#   suffix after the XXXXXX placeholder. BSD/macOS mktemp only substitutes
#   the trailing run of X's when they are the LAST characters of the
#   template; a ".py"/".json" suffix after them makes it return the
#   literal, unsubstituted filename every time, so two overlapping
#   invocations collide on the identical path. This can't be exercised
#   reliably as a behavioral test (the collision only manifests under
#   overlapping invocations), so guard the source shape directly instead.
# ===========================================================================
start_case "37: no mktemp template in this script carries a suffix after XXXXXX (BSD/macOS does not randomize those)"
if grep -qE 'mktemp "\$\{TMPDIR:-/tmp\}/[^"]*XXXXXX\.[A-Za-z]+"' "$SCRIPT"; then
  fail "found a mktemp template with a suffix after XXXXXX — this never randomizes on BSD/macOS mktemp"
else
  pass "no mktemp template in this script has a suffix after XXXXXX"
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
