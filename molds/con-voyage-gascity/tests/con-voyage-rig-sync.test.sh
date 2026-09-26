#!/usr/bin/env bash
# con-voyage-rig-sync.test.sh — hermetic, offline test for the con-voyage-rig-
# sync order (fk-hewd2; operator directive, Slack #repl-city-mayor,
# 2026-09-26: "We need our rigs to try and be synced with main consistently.")
#
# WHAT IT COVERS: for every rig `gc rig list --json` reports (skipping HQ and
# any rig with no default_branch), fetch origin and fast-forward the rig
# ROOT's local default branch to origin ONLY when that root is already
# checked out on the default branch AND its tracked tree is clean. A rig that
# can't be fast-forwarded (dirty, diverged, on another branch, or a failed
# fetch) is left completely untouched and reported to the mayor at most once
# per state change — a persisting problem is logged every cycle but not
# re-mailed until something about it changes.
#
# HOW IT WORKS: real, local git repos under a temp sandbox (an "origin" bare
# repo plus a rig-root clone) exercise the actual git plumbing — no git stub,
# since git's own fetch/status/merge behavior is exactly what's under test.
# `gc` is a recording stub (rig list + mail send only; this script never
# touches bd/session/sling) — same idiom as con-voyage-repair-watchdog.test.sh.
#
# Run:  bash tests/con-voyage-rig-sync.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# Hermetic / offline: never prompt for credentials, never read a developer's
# system git config (same posture as cv-worktree-prep.test.sh).
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-rig-sync.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-rig-sync-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv, returns canned `rig list --json` output, and
# simulates `mail send` (success/failure/artificial delay for the concurrency
# case). This script never calls bd/session/sling, so the stub covers only
# what it actually uses.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city) i=$((i+2)) ;;
    --rig)  i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"

case "$sub" in
  rig)
    rigsub="${args[$((i+1))]:-}"
    if [ "$rigsub" = "list" ]; then
      printf '%s' "${STUB_RIG_LIST_JSON:-}"
      exit 0
    fi
    exit 0
    ;;
  mail)
    mailsub="${args[$((i+1))]:-}"
    if [ "$mailsub" = "send" ]; then
      if [ -n "${STUB_MAIL_SEND_SLEEP:-}" ]; then
        sleep "$STUB_MAIL_SEND_SLEEP"
      fi
      if [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ]; then
        echo "gc mail send: failed to deliver (simulated)" >&2
        exit 1
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
# Real-git fixture helpers. git_c mirrors cv-worktree-prep.test.sh's own
# helper: inline user.name/email so nothing depends on a developer's global
# git config.
# ---------------------------------------------------------------------------
git_c() { git -C "$1" -c user.email=test@example.com -c user.name="Test" "${@:2}"; }

# make_rig NAME [BRANCH] -> creates SANDBOX/origin-<name>.git (bare) and
# SANDBOX/rig-<name> (a real clone-shaped rig root with 'origin' pointed at
# the bare repo), one initial commit already pushed. Prints the rig root path.
make_rig() {
  local name="$1" branch="${2:-main}"
  local origin="${SANDBOX}/origin-${name}.git"
  local root="${SANDBOX}/rig-${name}"
  # -b matches the bare repo's HEAD symref to the branch we're about to push,
  # so a later `git clone` of it (advance_origin) checks out a real local
  # branch instead of leaving HEAD pointed at a nonexistent "master".
  git init -q --bare -b "$branch" "$origin"
  mkdir -p "$root"
  git_c "$root" init -q -b "$branch"
  printf 'placeholder\n' > "${root}/README.md"
  git_c "$root" add README.md
  git_c "$root" commit -q -m "init"
  git_c "$root" remote add origin "$origin"
  git_c "$root" push -q origin "${branch}:${branch}"
  printf '%s' "$root"
}

# advance_origin NAME BRANCH MSG -> pushes one more commit to origin-<name>.git
# via a throwaway clone, so the rig root (left untouched) ends up behind.
advance_origin() {
  local name="$1" branch="$2" msg="$3"
  local origin="${SANDBOX}/origin-${name}.git"
  local writer="${SANDBOX}/writer-${name}-$$-${RANDOM}"
  git -c user.email=test@example.com -c user.name="Test" clone -q "$origin" "$writer"
  printf '%s\n' "$msg" >> "${writer}/README.md"
  git_c "$writer" add README.md
  git_c "$writer" commit -q -m "$msg"
  git_c "$writer" push -q origin "$branch"
  rm -rf "$writer"
}

# diverge_locally ROOT MSG -> one local commit the rig root has that origin
# does not, so a later `advance_origin` makes the two histories diverge.
diverge_locally() {
  local root="$1" msg="$2"
  printf '%s\n' "$msg" >> "${root}/local-change.txt"
  git_c "$root" add local-change.txt
  git_c "$root" commit -q -m "$msg"
}

# rig_json NAME PATH BRANCH -> one non-HQ rig JSON object for STUB_RIG_LIST_JSON.
rig_json() {
  printf '{"name":"%s","path":"%s","default_branch":"%s","hq":false}' "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Test harness bookkeeping (same idioms as con-voyage-repair-watchdog.test.sh).
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

rs_state_field() {
  local f="${1}/${2}.state" field="$3"
  [ -f "$f" ] || return 0
  awk -F= -v k="$field" '$1==k{ sub(/^[^=]*=/, ""); print; exit }' "$f"
}

CITY_DIR=""
STATE_DIR=""
GC_LOG=""
OUT=""
RC=0

setup_case_env() {
  CITY_DIR="${SANDBOX}/city-${1}"
  STATE_DIR="${SANDBOX}/state-${1}"
  GC_LOG="${SANDBOX}/gc-${1}.log"
  mkdir -p "$CITY_DIR" "$STATE_DIR"
  : > "$GC_LOG"
}

# run_script — invoke the script under test with the stub wired in. Extra
# "$@" env assignments (e.g. STUB_GC_LOG=... for a second cycle's own log)
# override the fixed ones listed before them.
run_script() {
  OUT="$(
    env \
      GC="${STUBDIR}/gc" \
      GC_CITY="$CITY_DIR" \
      CV_STATE_DIR="$STATE_DIR" \
      STUB_GC_LOG="$GC_LOG" \
      "$@" \
      bash "$SCRIPT" 2>&1
  )"
  RC=$?
}

# ===========================================================================
# CASE 1 — behind + clean -> fast-forwards to origin, no mail.
# ===========================================================================
start_case "1: behind + clean fast-forwards to origin"
setup_case_env "1"
ROOT1="$(make_rig r1 main)"
BEFORE_HEAD_1="$(git -C "$ROOT1" rev-parse HEAD)"
advance_origin r1 main "advance-1"
RIGS_JSON1="{\"rigs\":[$(rig_json r1 "$ROOT1" main)]}"
run_script STUB_RIG_LIST_JSON="$RIGS_JSON1"
assert_eq "0" "$RC" "script exits 0"
ORIGIN_HEAD_1="$(git -C "$ROOT1" rev-parse origin/main)"
AFTER_HEAD_1="$(git -C "$ROOT1" rev-parse HEAD)"
assert_eq "$ORIGIN_HEAD_1" "$AFTER_HEAD_1" "rig root fast-forwards to match origin/main"
if [ "$AFTER_HEAD_1" != "$BEFORE_HEAD_1" ]; then pass "HEAD actually advanced"; else fail "HEAD did not advance"; fi
assert_log_count "$GC_LOG" 'mail send' 0 "a clean fast-forward never mails"
assert_eq "ok" "$(rs_state_field "$STATE_DIR" "r1" "last_state")" "state records 'ok'"

# ===========================================================================
# CASE 2 — already current -> no-op, no mail.
# ===========================================================================
start_case "2: already current is a clean no-op"
setup_case_env "2"
ROOT2="$(make_rig r2 main)"
BEFORE_HEAD_2="$(git -C "$ROOT2" rev-parse HEAD)"
RIGS_JSON2="{\"rigs\":[$(rig_json r2 "$ROOT2" main)]}"
run_script STUB_RIG_LIST_JSON="$RIGS_JSON2"
assert_eq "0" "$RC" "script exits 0"
AFTER_HEAD_2="$(git -C "$ROOT2" rev-parse HEAD)"
assert_eq "$BEFORE_HEAD_2" "$AFTER_HEAD_2" "HEAD is unchanged when already current"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail when already current"
assert_eq "ok" "$(rs_state_field "$STATE_DIR" "r2" "last_state")" "state records 'ok'"

# ===========================================================================
# CASE 3 — dirty -> skipped, reported once; a second cycle does not re-mail.
# ===========================================================================
start_case "3: dirty rig is skipped and reported once"
setup_case_env "3"
ROOT3="$(make_rig r3 main)"
echo "uncommitted" > "${ROOT3}/scratch.txt"
RIGS_JSON3="{\"rigs\":[$(rig_json r3 "$ROOT3" main)]}"
run_script STUB_RIG_LIST_JSON="$RIGS_JSON3"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "dirty rig mails the mayor exactly once"
assert_eq "dirty" "$(rs_state_field "$STATE_DIR" "r3" "last_state")" "state records 'dirty'"
if [ -f "${ROOT3}/scratch.txt" ]; then pass "uncommitted file untouched"; else fail "uncommitted file disappeared"; fi

GC_LOG_3B="${SANDBOX}/gc-3b.log"; : > "$GC_LOG_3B"
run_script STUB_RIG_LIST_JSON="$RIGS_JSON3" STUB_GC_LOG="$GC_LOG_3B"
assert_eq "0" "$RC" "second cycle also exits 0"
assert_log_count "$GC_LOG_3B" 'mail send' 0 "second cycle does not re-mail for the same persisting dirty state"

# ===========================================================================
# CASE 4 — diverged -> reported, untouched; a second cycle does not re-mail.
# ===========================================================================
start_case "4: diverged rig is reported and left untouched"
setup_case_env "4"
ROOT4="$(make_rig r4 main)"
advance_origin r4 main "origin-advance-4"
diverge_locally "$ROOT4" "local-advance-4"
LOCAL_HEAD_BEFORE_4="$(git -C "$ROOT4" rev-parse HEAD)"
RIGS_JSON4="{\"rigs\":[$(rig_json r4 "$ROOT4" main)]}"
run_script STUB_RIG_LIST_JSON="$RIGS_JSON4"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "diverged rig mails the mayor exactly once"
assert_eq "diverged" "$(rs_state_field "$STATE_DIR" "r4" "last_state")" "state records 'diverged'"
LOCAL_HEAD_AFTER_4="$(git -C "$ROOT4" rev-parse HEAD)"
assert_eq "$LOCAL_HEAD_BEFORE_4" "$LOCAL_HEAD_AFTER_4" "local HEAD is untouched — no merge/rebase attempted"

GC_LOG_4B="${SANDBOX}/gc-4b.log"; : > "$GC_LOG_4B"
run_script STUB_RIG_LIST_JSON="$RIGS_JSON4" STUB_GC_LOG="$GC_LOG_4B"
assert_log_count "$GC_LOG_4B" 'mail send' 0 "second cycle does not re-mail for the same persisting diverged state"

# ===========================================================================
# CASE 5 — on another branch -> skipped, reported once; branch never switched.
# ===========================================================================
start_case "5: rig on a non-default branch is skipped"
setup_case_env "5"
ROOT5="$(make_rig r5 main)"
git_c "$ROOT5" checkout -q -b feature/other
RIGS_JSON5="{\"rigs\":[$(rig_json r5 "$ROOT5" main)]}"
run_script STUB_RIG_LIST_JSON="$RIGS_JSON5"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "other-branch rig mails the mayor exactly once"
assert_eq "other_branch" "$(rs_state_field "$STATE_DIR" "r5" "last_state")" "state records 'other_branch'"
CURRENT_BRANCH_AFTER_5="$(git -C "$ROOT5" rev-parse --abbrev-ref HEAD)"
assert_eq "feature/other" "$CURRENT_BRANCH_AFTER_5" "the checked-out branch is never switched"

# ===========================================================================
# CASE 6 — fetch failure -> reported, no crash.
# ===========================================================================
start_case "6: fetch failure is reported without crashing the script"
setup_case_env "6"
ROOT6="$(make_rig r6 main)"
git_c "$ROOT6" remote set-url origin "${SANDBOX}/nonexistent-origin-6.git"
RIGS_JSON6="{\"rigs\":[$(rig_json r6 "$ROOT6" main)]}"
run_script STUB_RIG_LIST_JSON="$RIGS_JSON6"
assert_eq "0" "$RC" "script exits 0 even though fetch failed"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "fetch-failure rig mails the mayor exactly once"
assert_eq "fetch_failed" "$(rs_state_field "$STATE_DIR" "r6" "last_state")" "state records 'fetch_failed'"

# ===========================================================================
# CASE 7 — HQ / branch-less rigs are filtered out before ever being touched.
# ===========================================================================
start_case "7: HQ and branch-less rigs are never dereferenced"
setup_case_env "7"
RIGS_JSON7='{"rigs":[{"name":"repl-city","path":"/definitely/does/not/exist","hq":true},{"name":"no-branch-rig","path":"/also/does/not/exist"}]}'
run_script STUB_RIG_LIST_JSON="$RIGS_JSON7"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail — nothing eligible to process"
if printf '%s' "$OUT" | grep -qi 'does not exist'; then
  fail "an ineligible rig's nonexistent path was dereferenced"
else
  pass "ineligible rigs (hq, or missing default_branch) are filtered before any path is touched"
fi

# ===========================================================================
# CASE 8 — malformed rig-list JSON degrades to a no-op, never crashes.
# ===========================================================================
start_case "8: malformed rig-list JSON does not crash the script"
setup_case_env "8"
run_script STUB_RIG_LIST_JSON="not valid json{{{"
assert_eq "0" "$RC" "script exits 0 on unparseable rig-list JSON"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail when rig discovery itself failed"

# ===========================================================================
# CASE 9 — two overlapping invocations against the same dirty rig: the
#   per-rig mkdir lock (fk-8b5fl-style dedup) lets only one of them act; the
#   other yields a lock-contention SKIP. Exactly one mail either way.
# ===========================================================================
start_case "9: two overlapping invocations send exactly one mail"
setup_case_env "9"
ROOT9="$(make_rig r9 main)"
echo "uncommitted" > "${ROOT9}/scratch.txt"
RIGS_JSON9="{\"rigs\":[$(rig_json r9 "$ROOT9" main)]}"
LOG_9A="${SANDBOX}/gc-9a.log"; : > "$LOG_9A"
LOG_9B="${SANDBOX}/gc-9b.log"; : > "$LOG_9B"
OUT_9A="${SANDBOX}/out-9a.log"
OUT_9B="${SANDBOX}/out-9b.log"

(
  env GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" CV_STATE_DIR="$STATE_DIR" \
      STUB_GC_LOG="$LOG_9A" STUB_RIG_LIST_JSON="$RIGS_JSON9" STUB_MAIL_SEND_SLEEP="1" \
      bash "$SCRIPT" > "$OUT_9A" 2>&1
) &
PID_9A=$!
(
  env GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" CV_STATE_DIR="$STATE_DIR" \
      STUB_GC_LOG="$LOG_9B" STUB_RIG_LIST_JSON="$RIGS_JSON9" STUB_MAIL_SEND_SLEEP="1" \
      bash "$SCRIPT" > "$OUT_9B" 2>&1
) &
PID_9B=$!

RC_9A=0; RC_9B=0
wait "$PID_9A" || RC_9A=$?
wait "$PID_9B" || RC_9B=$?

assert_eq "0" "$RC_9A" "invocation A exits 0"
assert_eq "0" "$RC_9B" "invocation B exits 0"

TOTAL_MAIL_9=$(( $(log_count "$LOG_9A" 'mail send') + $(log_count "$LOG_9B" 'mail send') ))
assert_eq "1" "$TOTAL_MAIL_9" "exactly one mail is sent across both overlapping invocations"

LOCK_SKIPS_9=$(( $(log_count "$OUT_9A" 'locked by a concurrent run') + $(log_count "$OUT_9B" 'locked by a concurrent run') ))
assert_eq "1" "$LOCK_SKIPS_9" "exactly one invocation yields a lock-contention SKIP"

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
