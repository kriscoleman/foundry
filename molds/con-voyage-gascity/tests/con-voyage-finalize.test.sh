#!/usr/bin/env bash
# con-voyage-finalize.test.sh — hermetic, offline test for the con-voyage
# work-bead finalize monitor (fk-hsca, the teardown side of fk-p7j9's work-bead
# lifecycle).
#
# The finalize monitor reads the per-PR ".finalize" records con-voyage's publish
# step writes under CV_STATE_DIR and, per record: polls the PR's terminal state
# via `gh pr view`, and on merged/closed closes the WORK BEAD (accurate reason),
# closes the convoy, releases the implementor (best-effort mail), and removes the
# record. While the PR is still open it reflects the live phase (awaiting_merge |
# repairing) on the work bead. Every action is idempotent and author-scoped.
#
# HOW IT WORKS (no network, no real gc/gh): recording STUB `gc` and `gh` binaries
# are built in a temp dir; finalize fixtures are written directly as ".finalize"
# files under a temp CV_STATE_DIR. The `gh` stub returns canned PR JSON keyed by
# a STUB_PR_MAP env var; the `gc` stub records argv for assertions and no-ops
# writes. The script honors GC=/GH= so we point it at the stubs.
#
# Run:  bash tests/con-voyage-finalize.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-finalize.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-finalize-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gh` stub. Records argv, emulates the two `gh pr view --json` shapes the
# finalize monitor asks for, plus `auth status` and `api user`.
#
# STUB_PR_MAP: newline-delimited rows describing each PR the test cares about:
#   "<repo>|<number>|<state>|<merged_at>|<closed_at>|<mergeable>|<mergeStateStatus>|<check_conclusion>"
#   - state: MERGED | CLOSED | OPEN
#   - merged_at/closed_at: raw ISO strings (empty allowed)
#   - mergeable: MERGEABLE | CONFLICTING | UNKNOWN | "" (only used for OPEN)
#   - mergeStateStatus: CLEAN | DIRTY | BEHIND | BLOCKED | "" (only used for OPEN)
#   - check_conclusion: a single statusCheckRollup conclusion (SUCCESS | FAILURE
#     | "" for none) — enough to exercise the repairing-vs-awaiting_merge split.
# A PR with no matching row makes `gh pr view` fail (exit 1) — the unresolved-
# state fail-safe path.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GH_LOG}"

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
  auth) exit 0 ;;
  api)
    # `gh api user --jq .login`
    if [ "${STUB_GH_USER_FAIL:-0}" = "1" ]; then exit 1; fi
    if [ -n "${STUB_GH_USER_LOGIN:-}" ]; then printf '%s\n' "${STUB_GH_USER_LOGIN}"; fi
    exit 0
    ;;
  pr)
    prsub="${2:-}"
    if [ "$prsub" = "view" ]; then
      num="${3:-}"
      repo="$(flagval --repo "$@")"
      json_fields="$(flagval --json "$@")"
      row=""
      if [ -n "${STUB_PR_MAP:-}" ]; then
        row="$(printf '%s\n' "$STUB_PR_MAP" | awk -F'|' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}')"
      fi
      # No row => simulate a gh failure (unresolved state fail-safe path).
      [ -n "$row" ] || exit 1
      state="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
      merged_at="$(printf '%s' "$row" | awk -F'|' '{print $4}')"
      closed_at="$(printf '%s' "$row" | awk -F'|' '{print $5}')"
      mergeable="$(printf '%s' "$row" | awk -F'|' '{print $6}')"
      merge_state="$(printf '%s' "$row" | awk -F'|' '{print $7}')"
      check_conc="$(printf '%s' "$row" | awk -F'|' '{print $8}')"
      case "$json_fields" in
        *state*)
          # terminal-state fetch: state,mergedAt,closedAt
          printf '{"state":"%s","mergedAt":%s,"closedAt":%s}\n' \
            "$state" \
            "$([ -n "$merged_at" ] && printf '"%s"' "$merged_at" || printf 'null')" \
            "$([ -n "$closed_at" ] && printf '"%s"' "$closed_at" || printf 'null')"
          ;;
        *mergeable*)
          # live-phase fetch: mergeable,mergeStateStatus,statusCheckRollup
          checks='[]'
          if [ -n "$check_conc" ]; then
            checks="[{\"conclusion\":\"${check_conc}\"}]"
          fi
          printf '{"mergeable":"%s","mergeStateStatus":"%s","statusCheckRollup":%s}\n' \
            "$mergeable" "$merge_state" "$checks"
          ;;
        *)
          printf '{}\n'
          ;;
      esac
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv, returns canned JSON for `bd show`, no-ops writes.
# STUB_BDSHOW_MAP: newline-delimited "<id>|<status>" rows (finalize only ever
# reads a bead's status, via close_if_open). An id with no row => empty {} =>
# treated as unknown/closed (close_if_open no-ops).
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG}"

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
  bd)
    bdsub="${args[$((i+1))]:-}"
    if [ "$bdsub" = "show" ]; then
      show_id="${args[$((i+2))]:-}"
      match=""
      if [ -n "${STUB_BDSHOW_MAP:-}" ]; then
        match="$(printf '%s\n' "$STUB_BDSHOW_MAP" | awk -F'|' -v id="$show_id" '$1==id{print; exit}')"
      fi
      if [ -n "$match" ]; then
        show_status="$(printf '%s' "$match" | awk -F'|' '{print $2}')"
        printf '{"id":"%s","status":"%s"}\n' "$show_id" "$show_status"
      else
        printf '{}\n'
      fi
      exit 0
    fi
    # bd close / bd update / bd set-state / bd note — generic accept (logged).
    exit 0
    ;;
  mail)
    if [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ]; then
      echo "gc mail send: failed (simulated)" >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# ---------------------------------------------------------------------------
# Test harness bookkeeping (same idioms as the other two suites).
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

assert_file_absent() {
  if [ ! -e "$1" ]; then pass "$2"; else fail "$2 (file still present: $1)"; fi
}
assert_file_present() {
  if [ -e "$1" ]; then pass "$2"; else fail "$2 (file missing: $1)"; fi
}

# assert_out_contains PATTERN MSG — assert the captured stdout ($OUT) matches
# the extended-regex PATTERN.
assert_out_contains() {
  if printf '%s' "$OUT" | grep -qE -- "$1"; then pass "$2"; else fail "$2 (stdout did not match /$1/)"; fi
}

fs_field() {
  local f="${1}/${2}.finalize" field="$3"
  [ -f "$f" ] || return 0
  awk -F= -v k="$field" '$1==k{ sub(/^[^=]*=/, ""); print; exit }' "$f"
}

# write_finalize DIR KEY work_bead convoy_id repo_full pr_number pr_author implementor last_phase
write_finalize() {
  local dir="$1" key="$2"
  {
    printf 'work_bead=%s\n' "${3}"
    printf 'convoy_id=%s\n' "${4}"
    printf 'repo_full=%s\n' "${5}"
    printf 'pr_number=%s\n' "${6}"
    printf 'pr_author=%s\n' "${7}"
    printf 'implementor_session=%s\n' "${8}"
    printf 'last_phase=%s\n' "${9:-}"
  } > "${dir}/${key}.finalize"
}

CITY_DIR=""
STATE_DIR=""
GC_LOG=""
GH_LOG=""
OUT=""
RC=0

setup_case_env() {
  CITY_DIR="${SANDBOX}/city-${1}"
  STATE_DIR="${SANDBOX}/state-${1}"
  GC_LOG="${SANDBOX}/gc-${1}.log"
  GH_LOG="${SANDBOX}/gh-${1}.log"
  mkdir -p "$CITY_DIR" "$STATE_DIR"
  : > "$GC_LOG"; : > "$GH_LOG"
}

run_script() {
  OUT="$(
    env \
      GH="${STUBDIR}/gh" \
      GC="${STUBDIR}/gc" \
      GC_CITY="$CITY_DIR" \
      CV_STATE_DIR="$STATE_DIR" \
      STUB_GC_LOG="$GC_LOG" \
      STUB_GH_LOG="$GH_LOG" \
      "$@" \
      bash "$SCRIPT" 2>&1
  )"
  RC=$?
}

DEFAULT_ENV=(CV_PR_AUTHOR="kriscoleman")

# ===========================================================================
# CASE 1 — Fail-closed: CV_PR_AUTHOR unset AND gh api user resolves empty.
# ===========================================================================
start_case "1: fail-closed when author unresolved"
setup_case_env "1"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-29" \
  "fk-work" "fk-convoy" "kriscoleman/foundry" "29" "kriscoleman" "foundry/impl-1" "awaiting_merge"
run_script CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="" STUB_GH_USER_FAIL=1
assert_eq "1" "$RC" "script exits 1 (fail closed)"
assert_log_count "$GH_LOG" 'pr view' 0 "zero 'gh pr view' calls before fail-closed exit"
assert_log_count "$GC_LOG" 'bd close' 0 "zero 'bd close' calls before fail-closed exit"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-29.finalize" "record untouched on fail-closed"

# ===========================================================================
# CASE 2 — Empty state dir: clean no-op, exit 0.
# ===========================================================================
start_case "2: empty state dir is a clean no-op"
setup_case_env "2"
run_script "${DEFAULT_ENV[@]}"
assert_eq "0" "$RC" "script exits 0 with no finalize records"
assert_log_count "$GH_LOG" 'pr view' 0 "no gh pr view without records"
assert_log_count "$GC_LOG" 'bd close' 0 "no bd close without records"

# ===========================================================================
# CASE 3 — MERGED PR: close work bead with 'landed' reason, close convoy,
#   release implementor, remove record. (core happy path, Req 1/2/4)
# ===========================================================================
start_case "3: merged PR -> close work bead (landed), close convoy, release, cleanup"
setup_case_env "3"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-29" \
  "fk-work" "fk-convoy" "kriscoleman/foundry" "29" "kriscoleman" "foundry/impl-1" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|29|MERGED|2026-09-18T10:00:00Z|2026-09-18T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-work|in_progress\nfk-convoy|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-work .*landed: PR #29 merged' 1 "work bead closed with 'landed: PR #29 merged'"
assert_log_count "$GC_LOG" 'bd close fk-convoy' 1 "convoy closed"
assert_log_count "$GC_LOG" 'mail send foundry/impl-1' 1 "implementor released via mail"
assert_out_contains 'FINALIZE kriscoleman/foundry#29' "logs a FINALIZE line for the PR"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-29.finalize" "finalize record removed after finalize"

# ===========================================================================
# CASE 4 — CLOSED-without-merge PR: 'abandoned' reason.
# ===========================================================================
start_case "4: closed-unmerged PR -> close work bead (abandoned)"
setup_case_env "4"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-27" \
  "fk-w27" "fk-c27" "kriscoleman/foundry" "27" "kriscoleman" "foundry/impl-2" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|27|CLOSED||2026-09-18T11:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w27|in_progress\nfk-c27|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w27 .*abandoned: PR #27 closed without merge' 1 "work bead closed with 'abandoned' reason"
assert_log_count "$GC_LOG" 'bd close fk-w27 .*landed' 0 "NOT closed as landed"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-27.finalize" "record removed"

# ===========================================================================
# CASE 5 — Merged PR reported as state=CLOSED WITH a mergedAt (older gh shape):
#   must normalize to landed, not abandoned.
# ===========================================================================
start_case "5: CLOSED+mergedAt normalizes to landed (not abandoned)"
setup_case_env "5"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-40" \
  "fk-w40" "fk-c40" "kriscoleman/foundry" "40" "kriscoleman" "" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|40|CLOSED|2026-09-18T12:00:00Z|2026-09-18T12:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w40|in_progress\nfk-c40|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w40 .*landed: PR #40 merged' 1 "CLOSED+mergedAt closed as landed"
assert_log_count "$GC_LOG" 'bd close fk-w40 .*abandoned' 0 "not abandoned"

# ===========================================================================
# CASE 6 — Still-OPEN PR, clean: reflect cv=awaiting_merge phase, no close,
#   record kept. (phase reflection)
# ===========================================================================
start_case "6: open+clean PR -> cv=awaiting_merge, no close, record kept"
setup_case_env "6"
# last_phase deliberately reviewing so a transition is expected.
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-50" \
  "fk-w50" "fk-c50" "kriscoleman/foundry" "50" "kriscoleman" "foundry/impl-5" "reviewing"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|50|OPEN|||MERGEABLE|CLEAN|SUCCESS"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close' 0 "no bd close on an open PR"
assert_log_count "$GC_LOG" 'bd set-state fk-w50 cv=awaiting_merge' 1 "cv=awaiting_merge set on open+clean PR"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-50.finalize" "record kept for an open PR"
assert_eq "awaiting_merge" "$(fs_field "$STATE_DIR" "cv-finalize-kriscoleman-foundry-50" "last_phase")" "last_phase advanced to awaiting_merge"

# ===========================================================================
# CASE 7 — Still-OPEN PR with a FAILED check: reflect cv=repairing.
# ===========================================================================
start_case "7: open PR with failing CI -> cv=repairing"
setup_case_env "7"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-51" \
  "fk-w51" "fk-c51" "kriscoleman/foundry" "51" "kriscoleman" "foundry/impl-6" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|51|OPEN|||MERGEABLE|BLOCKED|FAILURE"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd set-state fk-w51 cv=repairing' 1 "cv=repairing set when CI is red"
assert_log_count "$GC_LOG" 'bd close' 0 "no close for an open PR"
assert_eq "repairing" "$(fs_field "$STATE_DIR" "cv-finalize-kriscoleman-foundry-51" "last_phase")" "last_phase advanced to repairing"

# ===========================================================================
# CASE 8 — Idempotent phase: open PR whose live phase already == last_phase.
#   No redundant set-state, no record rewrite churn beyond a no-op.
# ===========================================================================
start_case "8: open PR, phase unchanged -> no redundant set-state"
setup_case_env "8"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-52" \
  "fk-w52" "fk-c52" "kriscoleman/foundry" "52" "kriscoleman" "foundry/impl-7" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|52|OPEN|||MERGEABLE|CLEAN|SUCCESS"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd set-state fk-w52' 0 "no set-state when phase is unchanged"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-52.finalize" "record kept"

# ===========================================================================
# CASE 9 — Author scoping: record for a PR authored by someone else -> no
#   action at all, record left (defensive skip, HARD INVARIANT).
# ===========================================================================
start_case "9: author-scope skip on a mismatched pr_author"
setup_case_env "9"
write_finalize "$STATE_DIR" "cv-finalize-someone-else-repo-60" \
  "xx-work" "xx-convoy" "someone-else/repo" "60" "someone-else" "r/impl" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="someone-else/repo|60|MERGED|2026-09-18T10:00:00Z|2026-09-18T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'xx-work|in_progress'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" 'pr view 60' 0 "no gh pr view for a non-operator record (skipped before polling)"
assert_log_count "$GC_LOG" 'bd close' 0 "no bd close for a non-operator record"
assert_out_contains 'SKIP .* author scoping' "logs an author-scoping SKIP line"
assert_file_present "${STATE_DIR}/cv-finalize-someone-else-repo-60.finalize" "non-operator record left untouched"

# ===========================================================================
# CASE 10 — Idempotent re-poll: run twice on a merged PR. Second run finds no
#   record and cleanly no-ops (no second close, exit 0).
# ===========================================================================
start_case "10: idempotent re-poll after finalize"
setup_case_env "10"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-70" \
  "fk-w70" "fk-c70" "kriscoleman/foundry" "70" "kriscoleman" "foundry/impl-8" "awaiting_merge"
PRMAP="kriscoleman/foundry|70|MERGED|2026-09-18T10:00:00Z|2026-09-18T10:00:00Z|||"
run_script "${DEFAULT_ENV[@]}" STUB_PR_MAP="$PRMAP" STUB_BDSHOW_MAP=$'fk-w70|in_progress\nfk-c70|open'
assert_eq "0" "$RC" "first run exits 0"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-70.finalize" "record removed after first run"
# Second run: record gone.
: > "$GC_LOG"; : > "$GH_LOG"
run_script "${DEFAULT_ENV[@]}" STUB_PR_MAP="$PRMAP" STUB_BDSHOW_MAP=$'fk-w70|in_progress\nfk-c70|open'
assert_eq "0" "$RC" "second run exits 0 (idempotent)"
assert_log_count "$GC_LOG" 'bd close' 0 "second run makes zero bd close calls (record already gone)"
assert_log_count "$GH_LOG" 'pr view' 0 "second run polls nothing"

# ===========================================================================
# CASE 11 — Idempotent close: merged PR whose work bead is ALREADY closed.
#   close_if_open must no-op the close; record still removed.
# ===========================================================================
start_case "11: merged PR, work bead already closed -> no duplicate close, record removed"
setup_case_env "11"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-71" \
  "fk-w71" "fk-c71" "kriscoleman/foundry" "71" "kriscoleman" "" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|71|MERGED|2026-09-18T10:00:00Z|2026-09-18T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w71|closed\nfk-c71|closed'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w71' 0 "already-closed work bead is NOT re-closed"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-71.finalize" "record removed even when already closed"

# ===========================================================================
# CASE 12 — gh failure (unknown PR / API error): FAIL SAFE. No close, record
#   kept for retry next cycle.
# ===========================================================================
start_case "12: unresolved PR state (gh error) -> fail safe, no close, record kept"
setup_case_env "12"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-80" \
  "fk-w80" "fk-c80" "kriscoleman/foundry" "80" "kriscoleman" "foundry/impl-9" "awaiting_merge"
# STUB_PR_MAP omits #80 => gh pr view exits 1 => unresolved state.
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP=$'fk-w80|in_progress'
assert_eq "0" "$RC" "script exits 0 (transient, retried next cycle)"
assert_log_count "$GC_LOG" 'bd close' 0 "no bd close on an unresolved PR state"
assert_out_contains 'SKIP .* PR state unresolved' "logs a fail-safe SKIP line on gh error"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-80.finalize" "record kept for retry on gh error"

# ===========================================================================
# CASE 13 — Malformed record (missing work_bead): safe skip, record kept.
# ===========================================================================
start_case "13: record missing work_bead -> safe skip"
setup_case_env "13"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-81" \
  "" "fk-c81" "kriscoleman/foundry" "81" "kriscoleman" "foundry/impl-10" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|81|MERGED|2026-09-18T10:00:00Z|2026-09-18T10:00:00Z|||"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" 'pr view 81' 0 "no polling for a record missing work_bead"
assert_log_count "$GC_LOG" 'bd close' 0 "no close for a malformed record"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-81.finalize" "malformed record left for next cycle"

# ===========================================================================
# CASE 14 — Release toggle off: merged PR still closes bead/convoy but sends
#   NO release mail (CV_RELEASE_IMPLEMENTOR=0).
# ===========================================================================
start_case "14: CV_RELEASE_IMPLEMENTOR=0 skips the release mail, still closes"
setup_case_env "14"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-90" \
  "fk-w90" "fk-c90" "kriscoleman/foundry" "90" "kriscoleman" "foundry/impl-11" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" CV_RELEASE_IMPLEMENTOR=0 \
  STUB_PR_MAP="kriscoleman/foundry|90|MERGED|2026-09-18T10:00:00Z|2026-09-18T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w90|in_progress\nfk-c90|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w90 .*landed' 1 "work bead still closed"
assert_log_count "$GC_LOG" 'mail send' 0 "no release mail when CV_RELEASE_IMPLEMENTOR=0"

# ===========================================================================
# CASE 15 — Release mail failure is non-fatal: bead/convoy still closed and the
#   record still removed even if the release mail errors.
# ===========================================================================
start_case "15: release mail failure is non-fatal (bead closed, record removed)"
setup_case_env "15"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-91" \
  "fk-w91" "fk-c91" "kriscoleman/foundry" "91" "kriscoleman" "foundry/impl-12" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" STUB_MAIL_SEND_FAIL=1 \
  STUB_PR_MAP="kriscoleman/foundry|91|MERGED|2026-09-18T10:00:00Z|2026-09-18T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w91|in_progress\nfk-c91|open'
assert_eq "0" "$RC" "script exits 0 despite mail failure"
assert_log_count "$GC_LOG" 'bd close fk-w91 .*landed' 1 "work bead closed despite mail failure"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-91.finalize" "record removed despite mail failure"

# ===========================================================================
# CASE 16 — Convoy == work bead (non-synthetic direct sling): do not double-
#   close; only one close call for that id.
# ===========================================================================
start_case "16: convoy_id == work_bead -> single close, no double-close"
setup_case_env "16"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-92" \
  "fk-same" "fk-same" "kriscoleman/foundry" "92" "kriscoleman" "" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|92|MERGED|2026-09-18T10:00:00Z|2026-09-18T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-same|in_progress'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-same' 1 "exactly one close when convoy_id == work_bead"

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
