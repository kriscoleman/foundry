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
# STUB_BDCLOSE_FAIL_IDS: newline-delimited bead ids for which `bd close` exits
# 1 (simulates the fk-7v3r "bd close silently fails" scenario) — every other
# id's `bd close` succeeds (exit 0). Fails UNCONDITIONALLY, --force included
# (simulates a genuine bd-close error, not the assignee guard below).
# STUB_BDCLOSE_REQUIRES_FORCE_IDS (fk-c1xa): newline-delimited bead ids for
# which `bd close` exits 1 UNLESS `--force`/`-f` is present in argv, with
# real bd's "assignee is %q, actor is %q; reclaim or use --force" text on
# stderr (fk-16zsa iter-4: close_if_open's FORCE path is behavior-based —
# it only retries with --force when the plain close's refusal matches this
# exact text — so the stub must emit it, not just fail/succeed on exit code).
# STUB_BDBLOCKED_IDS / STUB_BDPINNED_IDS (fk-16zsa iter-5): newline-delimited
# bead ids that `bd blocked --json` / `bd list --pinned --json` report —
# close_if_open's FORCE path calls both via bead_pinned_or_blocked before
# trusting an assignee-guard refusal as force-safe. Unset/empty (the default
# for every case below) means neither call reports the id, matching a
# genuinely-only-assignee-mismatched bead.
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
  rig)
    rigsub="${args[$((i+1))]:-}"
    if [ "$rigsub" = "list" ]; then
      # fk-39mg5k/fk-gvnoof BLOCKING-1 follow-up: cv_close_workflow_root now
      # resolves the owning rig via `gc rig list --json` before trusting any
      # descendant-sweep `bd list` result. This suite's test ids all use the
      # real "fk" prefix, so stub a resolvable rig matching production,
      # unless a case explicitly wants to exercise an unresolved rig via
      # STUB_RIGLIST_JSON.
      if [ -n "${STUB_RIGLIST_JSON:-}" ]; then
        printf '%s' "$STUB_RIGLIST_JSON"
      else
        printf '%s' '{"rigs":[{"name":"foundry-kc","prefix":"fk"}]}'
      fi
      exit 0
    fi
    exit 0
    ;;
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
    if [ "$bdsub" = "close" ]; then
      close_id="${args[$((i+2))]:-}"
      if [ -n "${STUB_BDCLOSE_FAIL_IDS:-}" ] && printf '%s\n' "$STUB_BDCLOSE_FAIL_IDS" | grep -qx -- "$close_id"; then
        exit 1
      fi
      if [ -n "${STUB_BDCLOSE_REQUIRES_FORCE_IDS:-}" ] && printf '%s\n' "$STUB_BDCLOSE_REQUIRES_FORCE_IDS" | grep -qx -- "$close_id"; then
        has_force=0
        for a in "${args[@]}"; do
          [ "$a" = "--force" ] || [ "$a" = "-f" ] && has_force=1
        done
        if [ "$has_force" != "1" ]; then
          echo "Error: cannot close ${close_id}: assignee is \"con-voyage:work-bead\", actor is \"mayor\"; reclaim or use --force to override" >&2
          exit 1
        fi
      fi
      # fk-dgia1g: cv_close_workflow_root's descendant sweep now re-queries
      # "bd list --metadata-field gc.root_bead_id=..." across multiple
      # passes, like real `bd` would stop reporting a bead this stub already
      # closed — otherwise a static STUB_ROOT_SWEEP_MAP list gets "closed"
      # again on every later pass and double-logs.
      if [ -n "${STUB_CLOSED_IDS_FILE:-}" ]; then
        printf '%s\n' "$close_id" >> "$STUB_CLOSED_IDS_FILE"
      fi
      exit 0
    fi
    if [ "$bdsub" = "blocked" ]; then
      if [ -n "${STUB_BDBLOCKED_IDS:-}" ]; then
        printf '%s\n' "$STUB_BDBLOCKED_IDS" | awk 'NF{printf "{\"id\":\"%s\"},", $0}' | sed 's/,$//' | awk '{printf "[%s]", $0}'
      else
        printf '[]'
      fi
      exit 0
    fi
    if [ "$bdsub" = "list" ]; then
      has_title=0
      title_val=""
      j=0
      while [ "$j" -lt "${#args[@]}" ]; do
        if [ "${args[$j]}" = "--title-contains" ]; then
          has_title=1
          title_val="${args[$((j+1))]:-}"
        fi
        j=$((j+1))
      done
      if [ "$has_title" = "1" ]; then
        # STUB_TITLE_MATCH_MAP: newline rows "<title_prefix>|<id1>,<id2>,..."
        # (fk-nrfio: cv_sweep_repair_beads_by_title's `bd list --title-contains`
        # call).
        match_ids=""
        if [ -n "${STUB_TITLE_MATCH_MAP:-}" ]; then
          match_ids="$(printf '%s\n' "$STUB_TITLE_MATCH_MAP" | awk -F'|' -v t="$title_val" '$1==t{print $2; exit}')"
        fi
        if [ -n "$match_ids" ]; then
          printf '%s' "$match_ids" | tr ',' '\n' | awk 'NF{printf "{\"id\":\"%s\"},", $0}' | sed 's/,$//' | awk '{printf "[%s]", $0}'
        else
          printf '[]'
        fi
        exit 0
      fi
      meta_field=""
      j=0
      while [ "$j" -lt "${#args[@]}" ]; do
        if [ "${args[$j]}" = "--metadata-field" ]; then
          meta_field="${args[$((j+1))]:-}"
        fi
        j=$((j+1))
      done
      if [ -n "$meta_field" ]; then
        # STUB_ROOT_SWEEP_MAP: newline rows "<metadata_field>|<id1>,<id2>,..."
        # (fk-bkz94: cv_close_workflow_root's `bd list --status open
        # --metadata-field gc.root_bead_id=<root>` descendant sweep call).
        match_ids=""
        if [ -n "${STUB_ROOT_SWEEP_MAP:-}" ]; then
          match_ids="$(printf '%s\n' "$STUB_ROOT_SWEEP_MAP" | awk -F'|' -v f="$meta_field" '$1==f{print $2; exit}')"
        fi
        if [ -n "${STUB_CLOSED_IDS_FILE:-}" ] && [ -s "$STUB_CLOSED_IDS_FILE" ] && [ -n "$match_ids" ]; then
          match_ids="$(printf '%s' "$match_ids" | tr ',' '\n' | grep -vxFf "$STUB_CLOSED_IDS_FILE" | paste -sd, -)"
        fi
        if [ -n "$match_ids" ]; then
          printf '%s' "$match_ids" | tr ',' '\n' | awk 'NF{printf "{\"id\":\"%s\"},", $0}' | sed 's/,$//' | awk '{printf "[%s]", $0}'
        else
          printf '[]'
        fi
        exit 0
      fi
      if [ -n "${STUB_BDPINNED_IDS:-}" ]; then
        printf '%s\n' "$STUB_BDPINNED_IDS" | awk 'NF{printf "{\"id\":\"%s\"},", $0}' | sed 's/,$//' | awk '{printf "[%s]", $0}'
      else
        printf '[]'
      fi
      exit 0
    fi
    # bd update / bd set-state / bd note — generic accept (logged).
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

# write_finalize DIR KEY work_bead convoy_id repo_full pr_number pr_author implementor last_phase [root_bead_id]
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
    printf 'root_bead_id=%s\n' "${10:-}"
  } > "${dir}/${key}.finalize"
}

# write_state DIR DEDUP_KEY implementor inflight last_state pr_author route repo_full pr_number branch attempt_count escalated [last_dispatch_at]
# Same repair ".state" record shape con-voyage-pr-watch.sh/con-voyage-repair-
# watchdog.sh read and write (see con-voyage-lib.sh state_read/state_write) —
# fk-f1vp extends this monitor to ALSO glob these records for merge/close
# cleanup of repair beads (a separate concern from the ".finalize" work-bead
# lifecycle above).
write_state() {
  local dir="$1" key="$2"
  {
    printf 'implementor_session=%s\n' "${3}"
    printf 'inflight_rework=%s\n' "${4}"
    printf 'last_handled_state=%s\n' "${5}"
    printf 'pr_author=%s\n' "${6}"
    printf 'repair_route=%s\n' "${7}"
    printf 'repo_full=%s\n' "${8}"
    printf 'pr_number=%s\n' "${9}"
    printf 'branch=%s\n' "${10}"
    printf 'attempt_count=%s\n' "${11}"
    printf 'escalated=%s\n' "${12}"
    printf 'last_dispatch_at=%s\n' "${13:-}"
  } > "${dir}/${key}.state"
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
  CLOSED_IDS_FILE="${SANDBOX}/closed-${1}.log"
  mkdir -p "$CITY_DIR" "$STATE_DIR"
  : > "$GC_LOG"; : > "$GH_LOG"; : > "$CLOSED_IDS_FILE"
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
      STUB_CLOSED_IDS_FILE="$CLOSED_IDS_FILE" \
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
assert_log_count "$GC_LOG" '--city' 0 "no bd/mail call in this run passes --city (fk-7v3r: --city alone routes to the wrong store)"

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
assert_log_count "$GC_LOG" '--city' 0 "bd set-state never passes --city (fk-7v3r)"

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
# CASE 17 — fk-f1vp (FIX-B): a repair ".state" record whose PR has MERGED must
#   close its tracked inflight_rework bead ("superseded: PR #N merged") and
#   remove the .state record, exactly like a ".finalize" record does for the
#   work bead. ROOT CAUSE this closes: this monitor previously globbed ONLY
#   "*.finalize" — repair beads tracked in "*.state" (inflight_rework=...)
#   never closed on merge/close, orphaning them (kots#6067's 15 beads,
#   fk-eiw/#29, fk-wgl/#27).
# ===========================================================================
start_case "17: merged PR -> tracked repair bead closes (superseded), .state removed"
setup_case_env "17"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-83" \
  "gc__impl-rc-1" "rw-bead83" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "83" "fix/x" "1" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|83|MERGED|2026-09-19T10:00:00Z|2026-09-19T10:00:00Z|||" \
  STUB_BDSHOW_MAP="rw-bead83|open"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close rw-bead83 .*superseded: PR #83 merged' 1 "tracked repair bead closes with 'superseded: PR #83 merged'"
assert_file_absent "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-83.state" ".state record removed after finalize"

# ===========================================================================
# CASE 18 — CLOSED-without-merge PR: same teardown, "closed" phrasing instead
#   of "merged".
# ===========================================================================
start_case "18: closed-unmerged PR -> tracked repair bead closes (superseded: PR #N closed)"
setup_case_env "18"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-84" \
  "gc__impl-rc-2" "rw-bead84" "blocked" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "84" "fix/y" "0" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|84|CLOSED||2026-09-19T11:00:00Z|||" \
  STUB_BDSHOW_MAP="rw-bead84|open"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close rw-bead84 .*superseded: PR #84 closed' 1 "tracked repair bead closes with 'superseded: PR #84 closed'"
assert_log_count "$GC_LOG" 'superseded: PR #84 merged' 0 "not reported as merged"
assert_file_absent "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-84.state" ".state record removed"

# ===========================================================================
# CASE 19 — Acceptance: "PR still OPEN -> no-op." The repair-watchdog script
#   owns dead/stalled handling for an open PR; this monitor's repair-state
#   sweep only ever acts on a TERMINAL PR state.
# ===========================================================================
start_case "19: open PR -> no action, .state record kept"
setup_case_env "19"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-85" \
  "gc__impl-rc-3" "rw-bead85" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "85" "fix/z" "0" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|85|OPEN|||MERGEABLE|CLEAN|SUCCESS" \
  STUB_BDSHOW_MAP="rw-bead85|open"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close rw-bead85' 0 "no close while the PR is still open"
assert_file_present "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-85.state" ".state record kept for an open PR"

# ===========================================================================
# CASE 20 — Acceptance: "sibling orphan repair beads exist for the same merged
#   PR -> swept closed too." Two independent .state records (different dedup
#   keys) both point at the SAME repo+PR — e.g. a stale/legacy dedup-key
#   collision — so the sweep must close BOTH tracked beads, not just the one
#   the outer loop happened to iterate to.
# ===========================================================================
start_case "20: sibling .state records for the same PR are all swept closed"
setup_case_env "20"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-90" \
  "gc__impl-rc-4" "rw-bead90" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "90" "fix/a" "1" "0"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-90-legacy" \
  "" "rw-bead90-old" "merge_conflict" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "90" "fix/a" "0" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|90|MERGED|2026-09-19T12:00:00Z|2026-09-19T12:00:00Z|||" \
  STUB_BDSHOW_MAP=$'rw-bead90|open\nrw-bead90-old|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close rw-bead90 .*superseded: PR #90 merged' 1 "primary record's tracked bead closes"
assert_log_count "$GC_LOG" 'bd close rw-bead90-old .*superseded: PR #90 merged' 1 "sibling record's tracked bead is swept closed too"
assert_file_absent "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-90.state" "primary .state record removed"
assert_file_absent "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-90-legacy.state" "sibling .state record removed too"

# ===========================================================================
# CASE 21 — Author scoping: a repair .state record authored by someone else is
#   never polled or acted on (HARD INVARIANT, defensive re-check).
# ===========================================================================
start_case "21: author-scope skip on a mismatched pr_author -> no poll, no close, record kept"
setup_case_env "21"
write_state "$STATE_DIR" "cv-ci-repair-someone-else-repo-91" \
  "" "rw-bead91" "checks_failed" "someone-else" "vandoor/gc.implementation-worker" \
  "someone-else/repo" "91" "fix/b" "0" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="someone-else/repo|91|MERGED|2026-09-19T13:00:00Z|2026-09-19T13:00:00Z|||" \
  STUB_BDSHOW_MAP="rw-bead91|open"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GH_LOG" 'pr view 91' 0 "no gh pr view for a non-operator repair record"
assert_log_count "$GC_LOG" 'bd close' 0 "no bd close for a non-operator repair record"
assert_file_present "${STATE_DIR}/cv-ci-repair-someone-else-repo-91.state" "non-operator .state record left untouched"

# ===========================================================================
# CASE 22 — gh failure (unresolved PR state): FAIL SAFE, same posture as the
#   ".finalize" loop — no close, record kept for the next cycle.
# ===========================================================================
start_case "22: unresolved PR state (gh error) -> fail safe, no close, record kept"
setup_case_env "22"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-92" \
  "gc__impl-rc-5" "rw-bead92" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "92" "fix/c" "0" "0"
# STUB_PR_MAP omits #92 => gh pr view exits 1 => unresolved state.
run_script "${DEFAULT_ENV[@]}" STUB_BDSHOW_MAP="rw-bead92|open"
assert_eq "0" "$RC" "script exits 0 (transient, retried next cycle)"
assert_log_count "$GC_LOG" 'bd close' 0 "no bd close on an unresolved PR state"
assert_file_present "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-92.state" ".state record kept for retry on gh error"

# ===========================================================================
# CASE 23 — Idempotent re-poll: run twice on a merged repair record. The
#   second run finds the record already gone and cleanly no-ops.
# ===========================================================================
start_case "23: idempotent re-poll after repair-record finalize"
setup_case_env "23"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-93" \
  "gc__impl-rc-6" "rw-bead93" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "93" "fix/d" "0" "0"
PRMAP93="kriscoleman/foundry|93|MERGED|2026-09-19T14:00:00Z|2026-09-19T14:00:00Z|||"
run_script "${DEFAULT_ENV[@]}" STUB_PR_MAP="$PRMAP93" STUB_BDSHOW_MAP="rw-bead93|open"
assert_eq "0" "$RC" "first run exits 0"
assert_file_absent "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-93.state" "record removed after first run"
: > "$GC_LOG"; : > "$GH_LOG"
run_script "${DEFAULT_ENV[@]}" STUB_PR_MAP="$PRMAP93" STUB_BDSHOW_MAP="rw-bead93|open"
assert_eq "0" "$RC" "second run exits 0 (idempotent)"
assert_log_count "$GC_LOG" 'bd close' 0 "second run makes zero bd close calls (record already gone)"
assert_log_count "$GH_LOG" 'pr view' 0 "second run polls nothing"

# ===========================================================================
# CASE 24 — Bead-less repair record (inflight_rework empty — e.g. a mail-only
#   reuse dispatch that never minted a bead) on a merged PR: the .state record
#   is still removed (cleanup is unconditional), and cv_bead_close's own
#   empty-id fail-safe means no bd close is ever attempted.
# ===========================================================================
start_case "24: bead-less repair record on a merged PR -> record removed, no close attempted"
setup_case_env "24"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-94" \
  "gc__impl-rc-7" "" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "94" "fix/e" "0" "0" "2026-09-19T09:00:00Z"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|94|MERGED|2026-09-19T15:00:00Z|2026-09-19T15:00:00Z|||"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close' 0 "no bd close attempted — there is no tracked bead"
assert_file_absent "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-94.state" ".state record still removed"

# ===========================================================================
# CASE 25 — Sibling author-scope re-check: the sibling-sweep loop's OWN
#   HARD-INVARIANT author gate (finalize.sh:399-401) must fire even when the
#   sibling's repo_full+pr_number match the primary. CASE 20 only proves the
#   sweep mechanism when both records share the same author; this proves the
#   defensive re-check on the sibling is not dead code — a mismatched-author
#   sibling must be left untouched while the matching primary still closes.
# ===========================================================================
start_case "25: sibling with mismatched pr_author is not swept, record kept"
setup_case_env "25"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-95" \
  "gc__impl-rc-8" "rw-bead95" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "95" "fix/f" "0" "0"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-95-forged" \
  "" "rw-bead95-forged" "checks_failed" "someone-else" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "95" "fix/f" "0" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|95|MERGED|2026-09-19T16:00:00Z|2026-09-19T16:00:00Z|||" \
  STUB_BDSHOW_MAP=$'rw-bead95|open\nrw-bead95-forged|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close rw-bead95 .*superseded: PR #95 merged' 1 "primary record's tracked bead still closes"
assert_log_count "$GC_LOG" 'bd close rw-bead95-forged' 0 "mismatched-author sibling bead is never closed"
assert_file_absent "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-95.state" "primary .state record removed"
assert_file_present "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-95-forged.state" "mismatched-author sibling .state record is left untouched (fail closed)"

# ===========================================================================
# CASE 26 — fk-7v3r COMPOUNDING fix: close_if_open no longer swallows a failed
#   `bd close`'s exit status. When the WORK BEAD's close fails, the finalize
#   record must be KEPT (not deleted) so the next cycle retries the same
#   close instead of losing the bead forever. Before this fix, close_if_open
#   always reported success (`|| true`) and finalize.sh unconditionally
#   removed the record right after, self-destructing its own retry safety net
#   on the very first close failure.
# ===========================================================================
start_case "26: work-bead bd close fails -> finalize record kept for retry (fk-7v3r)"
setup_case_env "26"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-96" \
  "fk-w96" "fk-c96" "kriscoleman/foundry" "96" "kriscoleman" "foundry/impl-13" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|96|MERGED|2026-09-19T10:00:00Z|2026-09-19T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w96|in_progress\nfk-c96|open' \
  STUB_BDCLOSE_FAIL_IDS="fk-w96"
assert_eq "0" "$RC" "script still exits 0 (a failed close is logged, not fatal)"
assert_log_count "$GC_LOG" 'bd close fk-w96' 1 "bd close was attempted for the work bead"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-96.finalize" "record KEPT because the work-bead close failed — no self-destructing retry record"
assert_out_contains 'keeping finalize record for retry' "logs that the record is being kept for retry"

# ===========================================================================
# CASE 27 — Same fix, the CONVOY close fails instead of the work bead: the
#   record must still be kept (either close failing is reason enough to retry
#   next cycle — close_if_open is idempotent, so re-running a close that
#   already succeeded is a safe no-op).
# ===========================================================================
start_case "27: convoy bd close fails -> finalize record kept for retry too"
setup_case_env "27"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-97" \
  "fk-w97" "fk-c97" "kriscoleman/foundry" "97" "kriscoleman" "foundry/impl-14" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|97|MERGED|2026-09-19T10:00:00Z|2026-09-19T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w97|in_progress\nfk-c97|open' \
  STUB_BDCLOSE_FAIL_IDS="fk-c97"
assert_eq "0" "$RC" "script still exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w97' 1 "work-bead close succeeded"
assert_log_count "$GC_LOG" 'bd close fk-c97' 1 "convoy close was attempted"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-97.finalize" "record kept because the convoy close failed"

# ===========================================================================
# CASE 28 — fk-mr07: when CV_STATE_DIR is not provided, the script must
#   default to GC_RIG_ROOT's state dir, NOT GC_CITY's. GC_CITY is the
#   multi-rig city root; defaulting to it silently pointed the monitor at
#   the wrong directory whenever it ran in a context where GC_CITY did not
#   happen to equal the owning rig root (confirmed live: PR #59's finalize
#   record landed at the city root and was never scanned). CITY_DIR here
#   stands in for a deliberately WRONG/unrelated city root that must stay
#   untouched; RIG_DIR is where the record actually lives and where
#   GC_RIG_ROOT points.
# ===========================================================================
start_case "28: CV_STATE_DIR unset -> defaults to GC_RIG_ROOT, not GC_CITY (fk-mr07)"
setup_case_env "28"
RIG_DIR="${SANDBOX}/rig-28"
mkdir -p "${RIG_DIR}/.gc/cv-pr-watch"
write_finalize "${RIG_DIR}/.gc/cv-pr-watch" "cv-finalize-kriscoleman-foundry-98" \
  "fk-w98" "fk-c98" "kriscoleman/foundry" "98" "kriscoleman" "foundry/impl-15" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  CV_STATE_DIR="" \
  GC_RIG_ROOT="$RIG_DIR" \
  STUB_PR_MAP="kriscoleman/foundry|98|MERGED|2026-09-19T10:00:00Z|2026-09-19T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w98|in_progress\nfk-c98|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w98 .*landed: PR #98 merged' 1 "finds and finalizes the record that lives under GC_RIG_ROOT, not GC_CITY"
assert_file_absent "${RIG_DIR}/.gc/cv-pr-watch/cv-finalize-kriscoleman-foundry-98.finalize" "record removed from the RIG_ROOT-derived directory after finalize"
assert_eq "0" "$(find "$CITY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')" "GC_CITY's own directory is never touched when GC_RIG_ROOT is available"

# ===========================================================================
# CASE 29 — fk-2c937: this monitor runs as a CITY-scoped cooldown order (no
#   GC_RIG_ROOT), so unlike case 28 it can't rely on GC_RIG_ROOT to find a
#   rig's directory. con-voyage's publish step writes ".finalize" records with
#   cwd inside the RIG's own worktree, so ITS cv_default_state_dir call lands
#   at "<rig>/.gc/cv-pr-watch" via the ".beads" ancestor walk-up. This
#   finalize order's own cv_default_state_dir call never walks INTO any rig
#   (only up from its own cwd), so it must instead learn about every
#   registered rig from "${GC_CITY}/.gc/site.toml" and check each one's
#   ".gc/cv-pr-watch" explicitly. CV_STATE_DIR (STATE_DIR) here stands in for
#   this order's own primary/default directory and must stay untouched —
#   the fixture record lives ONLY under the registered rig's own directory.
# ===========================================================================
start_case "29: finalize record under a registered rig (not CV_STATE_DIR) is still found (fk-2c937)"
setup_case_env "29"
RIG_DIR="${SANDBOX}/rig-29"
mkdir -p "${RIG_DIR}/.gc/cv-pr-watch" "${CITY_DIR}/.gc"
cat > "${CITY_DIR}/.gc/site.toml" <<SITE_TOML
workspace_name = "test-city"

[[rig]]
name = "foundry-kc"
path = "${RIG_DIR}"
SITE_TOML
write_finalize "${RIG_DIR}/.gc/cv-pr-watch" "cv-finalize-kriscoleman-foundry-99" \
  "fk-w99" "fk-c99" "kriscoleman/foundry" "99" "kriscoleman" "foundry/impl-16" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|99|MERGED|2026-09-25T10:00:00Z|2026-09-25T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w99|in_progress\nfk-c99|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w99 .*landed: PR #99 merged' 1 "finds and finalizes the record that lives under the registered rig's own dir, not CV_STATE_DIR"
assert_file_absent "${RIG_DIR}/.gc/cv-pr-watch/cv-finalize-kriscoleman-foundry-99.finalize" "record removed from the rig-derived directory after finalize"
assert_eq "0" "$(find "$STATE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')" "this order's own primary/default directory is never touched"

# ===========================================================================
# CASE 30 — fk-2c937: the repair ".state" sweep has the SAME blind spot as the
#   ".finalize" loop in case 29 above — a record living under a registered
#   rig's own state dir must also be found and swept once its PR lands.
# ===========================================================================
start_case "30: repair .state record under a registered rig is swept too (fk-2c937)"
setup_case_env "30"
RIG_DIR="${SANDBOX}/rig-30"
mkdir -p "${RIG_DIR}/.gc/cv-pr-watch" "${CITY_DIR}/.gc"
cat > "${CITY_DIR}/.gc/site.toml" <<SITE_TOML
workspace_name = "test-city"

[[rig]]
name = "foundry-kc"
path = "${RIG_DIR}"
SITE_TOML
write_state "${RIG_DIR}/.gc/cv-pr-watch" "cv-ci-repair-kriscoleman-foundry-100" \
  "gc__impl-rc-3" "rw-bead100" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/foundry" "100" "fix/x" "1" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|100|MERGED|2026-09-25T10:00:00Z|2026-09-25T10:00:00Z|||" \
  STUB_BDSHOW_MAP="rw-bead100|open"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close rw-bead100 .*superseded: PR #100 merged' 1 "tracked repair bead under the registered rig closes (superseded)"
assert_file_absent "${RIG_DIR}/.gc/cv-pr-watch/cv-ci-repair-kriscoleman-foundry-100.state" ".state record removed from the rig-derived directory"

# ===========================================================================
# CASE 31 — fk-2c937 review (SRE LOW-1): log the resolved multi-rig scan set
#   so an operator can tell a healthy N-directory scan from a silent
#   single-directory degradation (e.g. a missing/unparsable site.toml) —
#   before this, the scan set was resolved but never logged anywhere.
# ===========================================================================
start_case "31: logs the resolved state-dir scan set, naming every directory (fk-2c937 SRE LOW-1)"
setup_case_env "31"
RIG_31A="${SANDBOX}/rig-31a"
RIG_31B="${SANDBOX}/rig-31b"
mkdir -p "${RIG_31A}/.gc/cv-pr-watch" "${RIG_31B}/.gc/cv-pr-watch" "${CITY_DIR}/.gc"
cat > "${CITY_DIR}/.gc/site.toml" <<SITE_TOML
[[rig]]
name = "rig-31a"
path = "${RIG_31A}"

[[rig]]
name = "rig-31b"
path = "${RIG_31B}"
SITE_TOML
run_script "${DEFAULT_ENV[@]}"
assert_eq "0" "$RC" "script exits 0 with no finalize records to act on"
assert_out_contains "con-voyage-finalize: scanning 3 state dir" "logs the resolved scan-set count (primary + 2 registered rigs)"
assert_out_contains "${STATE_DIR}" "scan-set log names this order's own primary directory"
assert_out_contains "${RIG_31A}/.gc/cv-pr-watch" "scan-set log names the first registered rig's directory"
assert_out_contains "${RIG_31B}/.gc/cv-pr-watch" "scan-set log names the second registered rig's directory"

# ===========================================================================
# CASE 32 — fk-c1xa: an assignee-guarded work bead (con-voyage's setup step
#   claims it as "con-voyage:work-bead", so a plain `bd close` run as this
#   monitor's own actor is refused: "assignee is %q, actor is %q; reclaim or
#   use --force") still closes, because this monitor now forces the work-bead
#   and convoy closes it exclusively owns once the PR is terminal. Live
#   evidence: fk-8b5fl/#100, fk-htx5p/#101, fk-q2pon/#103, fk-o9ntx/#105 all
#   sat in_progress with a merged PR until force-closed by hand.
# ===========================================================================
start_case "32: assignee-guarded work bead + merged PR -> closed with --force, record removed"
setup_case_env "32"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-101" \
  "fk-w101" "fk-c101" "kriscoleman/foundry" "101" "kriscoleman" "foundry/impl-17" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|101|MERGED|2026-09-26T10:00:00Z|2026-09-26T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w101|in_progress\nfk-c101|open' \
  STUB_BDCLOSE_REQUIRES_FORCE_IDS=$'fk-w101\nfk-c101'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w101 --reason .*--force' 1 "work bead close was retried/sent with --force"
assert_log_count "$GC_LOG" 'bd close fk-c101 --reason .*--force' 1 "convoy close was also forced"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-101.finalize" "finalize record removed — the forced close succeeded"
assert_log_count "$GC_LOG" 'mail send mayor' 0 "no mayor escalation mail needed — the forced close succeeded"

# ===========================================================================
# CASE 33 — fk-c1xa: a close that fails even WITH --force (a real `bd close`
#   error, not the assignee guard) must keep the finalize record for retry
#   AND mail CV_ESCALATE_TARGET (default "mayor") — but only ONCE, not every
#   5-minute cooldown cycle, via a sibling ".mayor-notified" marker.
# ===========================================================================
start_case "33: forced close still fails -> record kept, mayor mailed once (not re-mailed on retry)"
setup_case_env "33"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-102" \
  "fk-w102" "fk-c102" "kriscoleman/foundry" "102" "kriscoleman" "foundry/impl-18" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|102|MERGED|2026-09-26T10:00:00Z|2026-09-26T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w102|in_progress\nfk-c102|open' \
  STUB_BDCLOSE_FAIL_IDS="fk-w102"
assert_eq "0" "$RC" "first run still exits 0 (a stuck close is logged, not fatal)"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-102.finalize" "record kept for retry after the forced close still failed"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "mayor mailed once about the stuck close"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-102.finalize.mayor-notified" "dedup marker written alongside the kept record"
# Re-run against the SAME state dir/log (next cooldown cycle) — still stuck,
# but must NOT mail a second time.
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|102|MERGED|2026-09-26T10:00:00Z|2026-09-26T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w102|in_progress\nfk-c102|open' \
  STUB_BDCLOSE_FAIL_IDS="fk-w102"
assert_eq "0" "$RC" "second run also exits 0"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "still only ONE mayor mail total across both cycles (deduped)"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-102.finalize" "record still kept — the close is still stuck"

# ===========================================================================
# CASE 34 — fk-c1xa: once the stuck close finally succeeds (e.g. an operator
#   fixes the underlying assignee/permission issue), the record AND its
#   dedup marker are both removed — no orphaned marker left behind forever.
# ===========================================================================
start_case "34: once the stuck close finally succeeds, both the record and its dedup marker are removed"
setup_case_env "34"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-103" \
  "fk-w103" "fk-c103" "kriscoleman/foundry" "103" "kriscoleman" "foundry/impl-19" "awaiting_merge"
: > "${STATE_DIR}/cv-finalize-kriscoleman-foundry-103.finalize.mayor-notified"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|103|MERGED|2026-09-26T10:00:00Z|2026-09-26T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w103|in_progress\nfk-c103|open'
assert_eq "0" "$RC" "script exits 0"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-103.finalize" "finalize record removed now that the close succeeds"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-103.finalize.mayor-notified" "stale dedup marker cleaned up alongside the record"

# ===========================================================================
# CASE 35 — fk-nrfio: a merged PR with N ORPHANED repair beads that the
#   ".state" record does NOT track (only the most-recently-minted bead's id is
#   ever recorded as inflight_rework — every earlier mint from a retry storm
#   falls out of tracking) must still all close via the title-based sweep, not
#   just the one tracked bead. Acceptance: "Given a merged PR with N open
#   repair beads, When the watch/finalize cycle runs, Then all N close with a
#   reason."
# ===========================================================================
start_case "35: merged PR with untracked orphan repair beads -> ALL close via title sweep"
setup_case_env "35"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-replicated-docs-4580" \
  "" "rw-tracked" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/replicated-docs" "4580" "fix/g" "1" "0"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/replicated-docs|4580|MERGED|2026-09-28T16:45:00Z|2026-09-28T16:45:00Z|||" \
  STUB_BDSHOW_MAP=$'rw-tracked|open\nrw-orphan-1|open\nrw-orphan-2|open' \
  STUB_TITLE_MATCH_MAP="Repair GitHub PR kriscoleman/replicated-docs#4580 (|rw-tracked,rw-orphan-1,rw-orphan-2"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close rw-tracked .*superseded: PR #4580 merged' 1 "the tracked bead closes"
assert_log_count "$GC_LOG" 'bd close rw-orphan-1 .*superseded: PR #4580 merged' 1 "untracked orphan 1 closes via title sweep"
assert_log_count "$GC_LOG" 'bd close rw-orphan-2 .*superseded: PR #4580 merged' 1 "untracked orphan 2 closes via title sweep"
assert_file_absent "${STATE_DIR}/cv-ci-repair-kriscoleman-replicated-docs-4580.state" ".state record removed"

# ===========================================================================
# CASE 36 — fk-nrfio: idempotent re-run — a second cycle against the SAME PR
#   (record already gone, orphans already closed) makes no further close
#   calls. Acceptance: "a re-run is a no-op."
# ===========================================================================
start_case "36: idempotent re-run after the title sweep already closed everything"
setup_case_env "36"
write_state "$STATE_DIR" "cv-ci-repair-kriscoleman-replicated-docs-4581" \
  "" "rw-tracked2" "checks_failed" "kriscoleman" "vandoor/gc.implementation-worker" \
  "kriscoleman/replicated-docs" "4581" "fix/h" "1" "0"
PRMAP36="kriscoleman/replicated-docs|4581|MERGED|2026-09-28T16:50:00Z|2026-09-28T16:50:00Z|||"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="$PRMAP36" \
  STUB_BDSHOW_MAP=$'rw-tracked2|open\nrw-orphan-3|open' \
  STUB_TITLE_MATCH_MAP="Repair GitHub PR kriscoleman/replicated-docs#4581 (|rw-tracked2,rw-orphan-3"
assert_eq "0" "$RC" "first run exits 0"
assert_log_count "$GC_LOG" 'bd close rw-orphan-3' 1 "orphan closed on first run"
: > "$GC_LOG"; : > "$GH_LOG"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="$PRMAP36" \
  STUB_BDSHOW_MAP=$'rw-tracked2|closed\nrw-orphan-3|closed' \
  STUB_TITLE_MATCH_MAP="Repair GitHub PR kriscoleman/replicated-docs#4581 (|rw-tracked2,rw-orphan-3"
assert_eq "0" "$RC" "second run exits 0 (idempotent)"
assert_log_count "$GC_LOG" 'bd close' 0 "second run makes zero bd close calls (record already gone, orphans already closed)"

# ===========================================================================
# CASE 37 — fk-nrfio: a work bead's ".finalize" record has no companion
#   ".state" record at all (e.g. it was already swept in a prior cycle) — the
#   ".finalize" loop's own title sweep must still close any open repair beads
#   for that same repo+PR.
# ===========================================================================
start_case "37: finalize loop sweeps repair beads by title with no .state record present"
setup_case_env "37"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-110" \
  "fk-w110" "fk-c110" "kriscoleman/foundry" "110" "kriscoleman" "foundry/impl-20" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|110|MERGED|2026-09-28T17:00:00Z|2026-09-28T17:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w110|in_progress\nfk-c110|open\nrw-orphan-4|open' \
  STUB_TITLE_MATCH_MAP="Repair GitHub PR kriscoleman/foundry#110 (|rw-orphan-4"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close rw-orphan-4 .*superseded: PR #110 merged' 1 "orphan repair bead closes from the .finalize loop's own title sweep"

# ===========================================================================
# CASE 38 — fk-bkz94: a record WITH root_bead_id tears down the graph.v2
#   workflow root too, plus every other open bead tracked under that root
#   (the review-loop lane/step orphans a stalled loop leaves behind) — not
#   just the work bead and convoy.
# ===========================================================================
start_case "38: merged PR with root_bead_id tears down workflow root + its open descendants"
setup_case_env "38"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-120" \
  "fk-w120" "fk-c120" "kriscoleman/foundry" "120" "kriscoleman" "foundry/impl-30" "awaiting_merge" \
  "fk-root120"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|120|MERGED|2026-10-02T10:00:00Z|2026-10-02T10:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w120|in_progress\nfk-c120|open\nfk-root120|in_progress' \
  STUB_ROOT_SWEEP_MAP="gc.root_bead_id=fk-root120|fk-lane1,fk-lane2"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close fk-w120 .*landed: PR #120 merged' 1 "work bead closed"
assert_log_count "$GC_LOG" 'bd close fk-c120' 1 "convoy closed"
assert_log_count "$GC_LOG" 'bd close fk-lane1 .*con-voyage finalized: landed: PR #120 merged' 1 "orphaned lane 1 closed via root sweep"
assert_log_count "$GC_LOG" 'bd close fk-lane2 .*con-voyage finalized: landed: PR #120 merged' 1 "orphaned lane 2 closed via root sweep"
assert_log_count "$GC_LOG" 'bd close fk-root120 .*con-voyage finalized: landed: PR #120 merged' 1 "workflow root itself closed"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-120.finalize" "finalize record removed once root + descendants are all closed"

# ===========================================================================
# CASE 39 — fk-bkz94: the root bead itself still refuses to close even with
#   --force (a real human pin/gate, not the routine assignee mismatch) —
#   the finalize record must be KEPT for retry even though the work bead and
#   convoy both closed fine, exactly like an unresolved work-bead/convoy close
#   already does.
# ===========================================================================
start_case "39: root bead close still fails -> finalize record kept for retry"
setup_case_env "39"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-121" \
  "fk-w121" "fk-c121" "kriscoleman/foundry" "121" "kriscoleman" "foundry/impl-31" "awaiting_merge" \
  "fk-root121"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|121|MERGED|2026-10-02T11:00:00Z|2026-10-02T11:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w121|in_progress\nfk-c121|open\nfk-root121|in_progress' \
  STUB_ROOT_SWEEP_MAP="gc.root_bead_id=fk-root121|" \
  STUB_BDCLOSE_FAIL_IDS="fk-root121"
assert_eq "0" "$RC" "script still exits 0 (a stuck close is reported, not fatal)"
assert_log_count "$GC_LOG" 'bd close fk-w121' 1 "work bead still closed"
assert_log_count "$GC_LOG" 'bd close fk-c121' 1 "convoy still closed"
assert_file_present "${STATE_DIR}/cv-finalize-kriscoleman-foundry-121.finalize" "finalize record KEPT — root bead close failed"
assert_log_count "$GC_LOG" 'mail send mayor' 1 "mayor escalated about the stuck root-bead close"
assert_log_count "$GC_LOG" 'workflow root fk-root121' 1 "escalation mail names the stuck root bead"

# ===========================================================================
# CASE 40 — backward compatibility: an older record written before
#   root_bead_id existed (empty field) behaves EXACTLY as before — no
#   bd list --metadata-field sweep call at all, record removed normally.
# ===========================================================================
start_case "40: record with no root_bead_id -> unchanged prior behavior, no sweep call"
setup_case_env "40"
write_finalize "$STATE_DIR" "cv-finalize-kriscoleman-foundry-122" \
  "fk-w122" "fk-c122" "kriscoleman/foundry" "122" "kriscoleman" "foundry/impl-32" "awaiting_merge"
run_script "${DEFAULT_ENV[@]}" \
  STUB_PR_MAP="kriscoleman/foundry|122|MERGED|2026-10-02T12:00:00Z|2026-10-02T12:00:00Z|||" \
  STUB_BDSHOW_MAP=$'fk-w122|in_progress\nfk-c122|open'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" '\-\-metadata-field' 0 "no root-bead sweep attempted without a root_bead_id"
assert_file_absent "${STATE_DIR}/cv-finalize-kriscoleman-foundry-122.finalize" "finalize record removed as before"

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
