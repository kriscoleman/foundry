#!/usr/bin/env bash
# cv-reopen-findings.test.sh — hermetic, offline test for cv-reopen-findings.sh
# (fk-9iqxnx (b): a real re-open command for the mayor, replacing the "reply
# to the LOW-only mail" affordance that had no effect).
#
# HOW IT WORKS (no network, no real gc/gh): recording STUB `gc` and `gh`
# binaries are built in a temp dir, same idiom as
# tests/cv-synthesis-low-mail.test.sh. The stub answers `bd show --include-
# dependents`, `bd list --metadata-field`, `bd update`, `session list`, and
# `sling --stdin` with fixture JSON/success, and logs every call's argv (one
# line per call) plus, for `sling`, the piped stdin body to a per-call file
# so assertions can inspect what was actually sent.
#
# Run:  bash tests/cv-reopen-findings.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-reopen-findings.sh"

[ -f "$SCRIPT" ] || { echo "FATAL: script under test not found: $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-reopen-findings-test.XXXXXX")"
export SANDBOX
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR" "${SANDBOX}/state"

# shellcheck disable=SC2329
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

args=("$@")

case "${args[0]:-}" in
  bd)
    case "${args[1]:-}" in
      show)
        if printf '%s\n' "${args[@]}" | grep -qx -- "--include-dependents"; then
          cat "${STUB_BDSHOW_DEPS_FILE:-/dev/null}" 2>/dev/null || echo '{}'
        fi
        exit 0
        ;;
      list)
        cat "${STUB_BDLIST_ROOT_FILE:-/dev/null}" 2>/dev/null || echo '[]'
        exit 0
        ;;
      update)
        if [ "${STUB_BDUPDATE_FAIL:-0}" = "1" ]; then
          echo "bd update: simulated failure" >&2
          exit 1
        fi
        exit 0
        ;;
    esac
    exit 0
    ;;
  session)
    if [ "${args[1]:-}" = "list" ]; then
      cat "${STUB_SESSION_LIST_FILE:-/dev/null}" 2>/dev/null || echo '{"sessions":[]}'
      exit 0
    fi
    exit 0
    ;;
  --city)
    # implementor_alive invokes `gc --city "$GC_CITY" session list --json`.
    if [ "${args[2]:-}" = "session" ] && [ "${args[3]:-}" = "list" ]; then
      cat "${STUB_SESSION_LIST_FILE:-/dev/null}" 2>/dev/null || echo '{"sessions":[]}'
      exit 0
    fi
    exit 0
    ;;
  sling)
    target="${args[1]:-}"
    n=$(( $(cat "${STUB_SLING_COUNTER_FILE}") + 1 ))
    echo "$n" > "${STUB_SLING_COUNTER_FILE}"
    cat > "${SANDBOX}/sling-body-${n}.txt"
    if printf '%s\n' "${STUB_SLING_FAIL_TARGETS:-}" | grep -qxF -- "$target"; then
      echo "gc sling: simulated failure for ${target}" >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GH_LOG}"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ "${STUB_GH_FAIL:-0}" = "1" ]; then
    echo "gh pr view: simulated failure" >&2
    exit 1
  fi
  printf '%s' "${STUB_HEAD_REF:-main-feature-branch}"
  exit 0
fi
exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}
assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (did not find '$2')"; fi
}
assert_not_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3 (unexpectedly found '$2')"; else pass "$3"; fi
}

setup_env() {
  STUB_GC_LOG="${SANDBOX}/gc-$1.log"
  STUB_GH_LOG="${SANDBOX}/gh-$1.log"
  STUB_SLING_COUNTER_FILE="${SANDBOX}/sling-counter-$1"
  : > "$STUB_GC_LOG"
  : > "$STUB_GH_LOG"
  echo 0 > "$STUB_SLING_COUNTER_FILE"
  rm -f "${SANDBOX}"/sling-body-*.txt
}

run_script() {
  OUT="$(
    env \
      GC="${STUBDIR}/gc" \
      GH="${STUBDIR}/gh" \
      GC_CITY="$GC_CITY_DIR" \
      CV_STATE_DIR="${CV_STATE_DIR:-${SANDBOX}/state}" \
      STUB_GC_LOG="$STUB_GC_LOG" \
      STUB_GH_LOG="$STUB_GH_LOG" \
      STUB_SLING_COUNTER_FILE="$STUB_SLING_COUNTER_FILE" \
      STUB_BDSHOW_DEPS_FILE="${STUB_BDSHOW_DEPS_FILE:-}" \
      STUB_BDLIST_ROOT_FILE="${STUB_BDLIST_ROOT_FILE:-}" \
      STUB_SESSION_LIST_FILE="${STUB_SESSION_LIST_FILE:-}" \
      STUB_SLING_FAIL_TARGETS="${STUB_SLING_FAIL_TARGETS:-}" \
      STUB_HEAD_REF="${STUB_HEAD_REF:-}" \
      STUB_GH_FAIL="${STUB_GH_FAIL:-0}" \
      STUB_BDUPDATE_FAIL="${STUB_BDUPDATE_FAIL:-0}" \
      bash "$SCRIPT" "$@" 2>&1
  )"
  RC=$?
}

GC_CITY_DIR="${SANDBOX}/city"
mkdir -p "$GC_CITY_DIR"

# ===========================================================================
# CASE: usage errors
# ===========================================================================
start_case "usage: no arguments at all"
setup_env usage1
run_script
assert_eq "1" "$RC" "exits non-zero"
assert_contains "$OUT" "usage:" "prints a usage message"

start_case "usage: work-bead given but no --finding/--findings-file"
setup_env usage2
run_script "fk-work1"
assert_eq "1" "$RC" "exits non-zero"
assert_contains "$OUT" "at least one --finding or a --findings-file is required" "names the missing requirement"

start_case "usage: --finding with no value"
setup_env usage3
run_script "fk-work1" --finding
assert_eq "1" "$RC" "exits non-zero"
assert_contains "$OUT" "--finding requires a value" "names the bad flag"

start_case "usage: --findings-file pointing at a missing path"
setup_env usage4
run_script "fk-work1" --findings-file "${SANDBOX}/does-not-exist.txt"
assert_eq "1" "$RC" "exits non-zero"
assert_contains "$OUT" "findings file not found" "names the missing file"

start_case "usage: unknown argument"
setup_env usage5
run_script "fk-work1" --bogus
assert_eq "1" "$RC" "exits non-zero"
assert_contains "$OUT" "unknown argument" "names the bad argument"

# ===========================================================================
# PRE-publish: an open workflow root tracks this work bead.
# ===========================================================================
STUB_BDSHOW_DEPS_FILE="${SANDBOX}/deps-fk-work1.json"
cat > "$STUB_BDSHOW_DEPS_FILE" <<'JSON'
{
  "id": "fk-work1",
  "dependents": [
    {"id": "fk-convoy1", "dependency_type": "tracks", "issue_type": "convoy"},
    {"id": "fk-other", "dependency_type": "depends_on", "issue_type": "task"}
  ]
}
JSON

STUB_BDLIST_ROOT_FILE="${SANDBOX}/root-list-open.json"
cat > "$STUB_BDLIST_ROOT_FILE" <<'JSON'
[
  {"id": "fk-root-closed", "status": "closed"},
  {"id": "fk-root-open", "status": "in_progress"}
]
JSON

start_case "PRE-publish: records findings on the still-open workflow root and exits clean"
setup_env prepublish1
run_script "fk-work1" --finding "address the mayor note about X"
assert_eq "0" "$RC" "exits clean"
assert_contains "$OUT" "PRE-publish" "reports the PRE-publish path"
assert_contains "$OUT" "fk-root-open" "names the resolved workflow root"
assert_eq "1" "$(grep -c 'bd update fk-root-open --set-metadata gc.build.mayor_reopen_requested=true' "$STUB_GC_LOG")" "stamps mayor_reopen_requested=true on the open root"
assert_eq "1" "$(grep -cF 'gc.build.mayor_reopen_findings=address the mayor note about X' "$STUB_GC_LOG")" "stamps the finding text on the open root"
assert_eq "0" "$(grep -c '^sling ' "$STUB_GC_LOG")" "never routes a PR-feedback bead when a workflow root is still open"
assert_eq "0" "$(wc -l < "$STUB_GH_LOG" | tr -d ' ')" "never calls gh in the PRE-publish path"

start_case "PRE-publish: multiple --finding values join with newlines"
setup_env prepublish2
run_script "fk-work1" --finding "first finding" --finding "second finding"
assert_eq "0" "$RC" "exits clean"
assert_eq "1" "$(grep -cF 'gc.build.mayor_reopen_findings=first finding' "$STUB_GC_LOG")" "includes the first finding"
assert_eq "1" "$(grep -cF 'second finding' "$STUB_GC_LOG")" "includes the second finding"

start_case "PRE-publish: --findings-file content is appended after --finding text"
setup_env prepublish3
FINDINGS_FILE="${SANDBOX}/findings.txt"
printf 'finding from file line 1\nfinding from file line 2\n' > "$FINDINGS_FILE"
run_script "fk-work1" --finding "inline finding" --findings-file "$FINDINGS_FILE"
assert_eq "0" "$RC" "exits clean"
assert_eq "1" "$(grep -c 'bd update fk-root-open' "$STUB_GC_LOG")" "stamps the open root exactly once"

start_case "PRE-publish: bd update failure is a hard failure, not silently swallowed"
setup_env prepublish4
STUB_BDUPDATE_FAIL=1
run_script "fk-work1" --finding "x"
assert_eq "1" "$RC" "exits non-zero"
assert_contains "$OUT" "failed to record reopen findings" "names the failure"
STUB_BDUPDATE_FAIL=0

# ===========================================================================
# POST-publish: no open workflow root resolves; a .finalize record exists.
# ===========================================================================
STUB_BDSHOW_DEPS_FILE_NONE="${SANDBOX}/deps-fk-work2.json"
echo '{"id": "fk-work2", "dependents": []}' > "$STUB_BDSHOW_DEPS_FILE_NONE"

mkdir -p "${SANDBOX}/state"
cat > "${SANDBOX}/state/cv-finalize-acme-widgets-42.finalize" <<'EOF'
work_bead=fk-work2
convoy_id=fk-convoy2
repo_full=acme/widgets
pr_number=42
pr_author=acme-bot
implementor_session=foundry-kc/gc.implementation-worker-9
last_phase=awaiting_merge
root_bead_id=fk-oldroot
roster_vars=
last_reviewed_head_sha=
review_round=1
rereview_root_bead_id=
EOF

cat > "${GC_CITY_DIR}/city.toml" <<'EOF'
[[github.pr_monitor]]
owner = "acme"
repo = "widgets"
rig = "acme-rig"
EOF

STUB_SESSION_LIST_ALIVE="${SANDBOX}/sessions-alive.json"
cat > "$STUB_SESSION_LIST_ALIVE" <<'JSON'
{"sessions": [{"id": "foundry-kc/gc.implementation-worker-9", "state": "running"}]}
JSON

STUB_SESSION_LIST_DEAD="${SANDBOX}/sessions-dead.json"
echo '{"sessions": []}' > "$STUB_SESSION_LIST_DEAD"

start_case "POST-publish: no open root, implementor alive -> routes directly to the recorded implementor"
setup_env postpublish1
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
echo '[]' > "$STUB_BDLIST_ROOT_FILE"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_ALIVE"
STUB_HEAD_REF="feature/widget-fix"
run_script "fk-work2" --finding "mayor says fix the widget"
assert_eq "0" "$RC" "exits clean"
assert_contains "$OUT" "POST-publish" "reports the POST-publish path"
assert_eq "1" "$(grep -c '^sling foundry-kc/gc.implementation-worker-9 --stdin' "$STUB_GC_LOG")" "routes directly to the recorded, alive implementor"
assert_eq "0" "$(grep -c 'acme-rig/gc.implementation-worker' "$STUB_GC_LOG")" "does not fall back to the pool route when the implementor is alive"
assert_contains "$(cat "${SANDBOX}/sling-body-1.txt")" "mayor says fix the widget" "the routed bead body carries the mayor's finding text"
assert_contains "$(cat "${SANDBOX}/sling-body-1.txt")" "acme/widgets/pull/42" "the routed bead body names the PR"
assert_contains "$(cat "${SANDBOX}/sling-body-1.txt")" "feature/widget-fix" "the routed bead body names the branch to push the fix on"

start_case "POST-publish: recorded implementor is dead -> falls back to the rig-scoped pool route"
setup_env postpublish2
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_DEAD"
STUB_HEAD_REF="feature/widget-fix"
run_script "fk-work2" --finding "mayor says fix the widget"
assert_eq "0" "$RC" "exits clean"
assert_eq "1" "$(grep -c '^sling acme-rig/gc.implementation-worker --stdin' "$STUB_GC_LOG")" "falls back to the rig-scoped pool route from city.toml"
assert_eq "0" "$(grep -c 'gc.implementation-worker-9' "$STUB_GC_LOG")" "never targets the dead implementor session"

start_case "POST-publish: direct route to a live-but-unroutable implementor falls through to the pool route on sling failure"
setup_env postpublish3
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_ALIVE"
STUB_HEAD_REF="feature/widget-fix"
STUB_SLING_FAIL_TARGETS="foundry-kc/gc.implementation-worker-9"
run_script "fk-work2" --finding "mayor says fix the widget"
assert_eq "0" "$RC" "exits clean after falling through"
assert_contains "$OUT" "falling back to pool route" "logs the fallback"
assert_eq "1" "$(grep -c '^sling acme-rig/gc.implementation-worker --stdin' "$STUB_GC_LOG")" "retries via the pool route after the direct sling fails"
STUB_SLING_FAIL_TARGETS=""

start_case "POST-publish: neither an open root nor a .finalize record exists -> fails loud"
setup_env postpublish4
STUB_BDSHOW_DEPS_FILE="${SANDBOX}/deps-fk-ghost.json"
echo '{"id": "fk-ghost", "dependents": []}' > "$STUB_BDSHOW_DEPS_FILE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
run_script "fk-ghost" --finding "nobody will ever see this"
assert_eq "1" "$RC" "exits non-zero"
assert_contains "$OUT" "no open con-voyage workflow and no published PR found" "names the failure clearly"

start_case "POST-publish: gh failing to resolve the head branch is a hard failure, not a silent empty route"
setup_env postpublish5
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_ALIVE"
STUB_GH_FAIL=1
run_script "fk-work2" --finding "x"
assert_eq "1" "$RC" "exits non-zero"
assert_contains "$OUT" "could not resolve the head branch" "names the failure"
STUB_GH_FAIL=0

# ===========================================================================
# Idempotency: re-running with identical findings produces the same
# idempotency key (so a repeat mayor run, or a retried sling, dedups
# downstream the same way a repeated human-feedback poll would).
# ===========================================================================
start_case "POST-publish: the idempotency key is stable across repeated runs with identical findings"
setup_env idempotent1
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_ALIVE"
STUB_HEAD_REF="feature/widget-fix"
run_script "fk-work2" --finding "same finding text"
FIRST_BODY="$(cat "${SANDBOX}/sling-body-1.txt")"
run_script "fk-work2" --finding "same finding text"
SECOND_BODY="$(cat "${SANDBOX}/sling-body-2.txt")"
FIRST_KEY="$(printf '%s' "$FIRST_BODY" | grep -oE 'idempotency: .*' )"
SECOND_KEY="$(printf '%s' "$SECOND_BODY" | grep -oE 'idempotency: .*' )"
assert_contains "$FIRST_KEY" "mayor-reopen-acme_widgets-42-" "the idempotency key is the expected mayor-reopen shape"
assert_eq "$FIRST_KEY" "$SECOND_KEY" "idempotency key is identical for identical findings text"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
