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
# Several leading global flags (`--city <dir>`, `--rig <name>`) may prefix
# the real subcommand depending on the call site. Strip any number of them so
# every case below dispatches on the actual subcommand regardless of which
# combination was used.
while true; do
  case "${args[0]:-}" in
    --city|--rig)
      args=("${args[@]:2}")
      ;;
    *)
      break
      ;;
  esac
done

case "${args[0]:-}" in
  rig)
    if [ "${args[1]:-}" = "list" ]; then
      cat "${STUB_RIGLIST_FILE:-/dev/null}" 2>/dev/null || echo '{"rigs":[]}'
      exit 0
    fi
    exit 0
    ;;
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
      CV_LOCK_STALE_SECONDS="${STUB_LOCK_STALE_SECONDS:-300}" \
      PATH="${STUB_PATH:-$PATH}" \
      STUB_GC_LOG="$STUB_GC_LOG" \
      STUB_GH_LOG="$STUB_GH_LOG" \
      STUB_SLING_COUNTER_FILE="$STUB_SLING_COUNTER_FILE" \
      STUB_BDSHOW_DEPS_FILE="${STUB_BDSHOW_DEPS_FILE:-}" \
      STUB_BDLIST_ROOT_FILE="${STUB_BDLIST_ROOT_FILE:-}" \
      STUB_RIGLIST_FILE="${STUB_RIGLIST_FILE:-$DEFAULT_RIGLIST_FILE}" \
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

# Default `gc rig list --json` fixture: every work bead used below is
# "fk-*"-prefixed, owned by rig "foundry-kc" — the same shape `gc rig list
# --json` returns for real, with an "hq" entry a prefix match must never pick.
DEFAULT_RIGLIST_FILE="${SANDBOX}/rig-list-default.json"
cat > "$DEFAULT_RIGLIST_FILE" <<'JSON'
{"rigs": [
  {"name": "repl-city", "prefix": "rc", "hq": true},
  {"name": "foundry-kc", "prefix": "fk", "hq": false}
]}
JSON

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
assert_eq "1" "$(grep -c -- "--city ${GC_CITY_DIR} --rig foundry-kc bd list --metadata-field gc.build.source_anchor_id=fk-convoy1 --json --limit=0" "$STUB_GC_LOG")" "fk-jekxaw: routes the root lookup to the work bead's own rig explicitly, not whatever store cwd happens to resolve to"

# ===========================================================================
# fk-jekxaw: cv-reopen-findings misses rig workflow roots when run from the
# city root. The root-lookup `bd list --metadata-field` query has no bead-id
# positional for gc's own auto-routing to key off (unlike bd show/update
# elsewhere in this script), so it must resolve --rig itself from the work
# bead's own id prefix via `gc rig list --json` — this must hold regardless
# of which rig's prefix is involved, and must never resolve the city's own
# "hq" entry as a --rig target.
# ===========================================================================
start_case "PRE-publish: root lookup resolves --rig from a DIFFERENT work bead prefix than the default fixture"
setup_env otherrig1
OTHER_RIGLIST_FILE="${SANDBOX}/rig-list-other.json"
cat > "$OTHER_RIGLIST_FILE" <<'JSON'
{"rigs": [
  {"name": "repl-city", "prefix": "rc", "hq": true},
  {"name": "vandoor", "prefix": "va", "hq": false}
]}
JSON
STUB_RIGLIST_FILE="$OTHER_RIGLIST_FILE"
STUB_BDSHOW_DEPS_FILE="${SANDBOX}/deps-va-work1.json"
cat > "$STUB_BDSHOW_DEPS_FILE" <<'JSON'
{
  "id": "va-work1",
  "dependents": [
    {"id": "va-convoy1", "dependency_type": "tracks", "issue_type": "convoy"}
  ]
}
JSON
STUB_BDLIST_ROOT_FILE="${SANDBOX}/root-list-open-va.json"
cat > "$STUB_BDLIST_ROOT_FILE" <<'JSON'
[
  {"id": "va-root-open", "status": "in_progress"}
]
JSON
run_script "va-work1" --finding "address the mayor note about X"
assert_eq "0" "$RC" "exits clean"
assert_eq "1" "$(grep -c -- "--rig vandoor bd list --metadata-field gc.build.source_anchor_id=va-convoy1" "$STUB_GC_LOG")" "resolves --rig vandoor from the va- prefix, not the hq entry or the default fk- fixture"
# Restore the fk-work1 fixtures used by every case below.
STUB_RIGLIST_FILE=""
STUB_BDSHOW_DEPS_FILE="${SANDBOX}/deps-fk-work1.json"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/root-list-open.json"

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
assert_eq "1" "$(grep -c -- "--city ${GC_CITY_DIR} sling foundry-kc/gc.implementation-worker-9 --stdin" "$STUB_GC_LOG")" "routes directly to the recorded, alive implementor, with --city for parity with pr-watch"
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
assert_eq "1" "$(grep -c -- "--city ${GC_CITY_DIR} sling acme-rig/gc.implementation-worker --stdin" "$STUB_GC_LOG")" "falls back to the rig-scoped pool route from city.toml, with --city for parity with pr-watch"
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
assert_eq "1" "$(grep -c -- "--city ${GC_CITY_DIR} sling acme-rig/gc.implementation-worker --stdin" "$STUB_GC_LOG")" "retries via the pool route after the direct sling fails, with --city for parity with pr-watch"
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

# ===========================================================================
# LOW-1 (review fk-9iqxnx): multiple still-open workflow roots match the same
# convoy. Picking the first one silently is an ambiguous guess; fail closed
# and name every candidate instead.
# ===========================================================================
STUB_BDLIST_ROOT_FILE_MULTI="${SANDBOX}/root-list-multi-open.json"
cat > "$STUB_BDLIST_ROOT_FILE_MULTI" <<'JSON'
[
  {"id": "fk-root-a", "status": "in_progress"},
  {"id": "fk-root-closed", "status": "closed"},
  {"id": "fk-root-b", "status": "open"}
]
JSON

start_case "PRE-publish: multiple open workflow roots match the same convoy -> fails closed naming every candidate"
setup_env multiroot1
STUB_BDSHOW_DEPS_FILE="${SANDBOX}/deps-fk-work1.json"
STUB_BDLIST_ROOT_FILE="$STUB_BDLIST_ROOT_FILE_MULTI"
run_script "fk-work1" --finding "ambiguous root test"
assert_eq "1" "$RC" "exits non-zero rather than guessing"
assert_contains "$OUT" "fk-root-a" "names the first candidate root"
assert_contains "$OUT" "fk-root-b" "names the second candidate root"
assert_not_contains "$OUT" "fk-root-closed" "never lists the already-closed root as a candidate"
assert_eq "0" "$(grep -c 'bd update fk-root-a' "$STUB_GC_LOG")" "never mutates either candidate root"
assert_eq "0" "$(grep -c 'bd update fk-root-b' "$STUB_GC_LOG")" "never mutates either candidate root"

# ===========================================================================
# LOW-4 (review fk-9iqxnx): the [[github.pr_monitor]] rig lookup shares
# con-voyage-lib.sh's cv_parse_pr_monitor_blocks instead of a hand-rolled
# python regex parser, and must pick the right block among several.
# ===========================================================================
start_case "POST-publish: resolves the correct rig from a city.toml with multiple [[github.pr_monitor]] blocks"
setup_env multiblock1
cat > "${GC_CITY_DIR}/city.toml" <<'EOF'
[[github.pr_monitor]]
owner = "other-owner"
repo = "other-repo"
rig = "other-rig"

[[github.pr_monitor]]
owner = "acme"
repo = "widgets"
rig = "acme-rig"
EOF
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_DEAD"
STUB_HEAD_REF="feature/widget-fix"
run_script "fk-work2" --finding "mayor says fix the widget"
assert_eq "0" "$RC" "exits clean"
assert_eq "1" "$(grep -c -- "--city ${GC_CITY_DIR} sling acme-rig/gc.implementation-worker --stdin" "$STUB_GC_LOG")" "picks the SECOND block's rig (acme-rig), matching on owner/repo rather than block order"
assert_eq "0" "$(grep -c 'other-rig' "$STUB_GC_LOG")" "never routes to the non-matching block's rig"
# Restore the single-block fixture used by every other case below.
cat > "${GC_CITY_DIR}/city.toml" <<'EOF'
[[github.pr_monitor]]
owner = "acme"
repo = "widgets"
rig = "acme-rig"
EOF

# ===========================================================================
# LOW-3 (review fk-9iqxnx): FINDINGS_HASH falls back to the literal "nohash"
# when neither shasum nor sha256sum is on PATH.
# ===========================================================================
NOHASH_STUBDIR="${SANDBOX}/nohash-stub"
mkdir -p "$NOHASH_STUBDIR"
cat > "${NOHASH_STUBDIR}/shasum" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cp "${NOHASH_STUBDIR}/shasum" "${NOHASH_STUBDIR}/sha256sum"
chmod +x "${NOHASH_STUBDIR}/shasum" "${NOHASH_STUBDIR}/sha256sum"

start_case "POST-publish: FINDINGS_HASH falls back to the literal 'nohash' when no hasher is available"
setup_env nohash1
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_ALIVE"
STUB_HEAD_REF="feature/widget-fix"
STUB_PATH="${NOHASH_STUBDIR}:${PATH}"
run_script "fk-work2" --finding "hash fallback check"
assert_eq "0" "$RC" "exits clean even without a hasher available"
BODY="$(cat "${SANDBOX}/sling-body-1.txt")"
assert_contains "$BODY" "idempotency: mayor-reopen-acme_widgets-42-nohash" "falls back to the literal 'nohash' idempotency suffix"
STUB_PATH=""

# ===========================================================================
# LOW-2 (review fk-9iqxnx): the POST-publish route must take the SAME per-PR
# dedup lock con-voyage-pr-watch.sh's CI-repair minting uses
# (cv-ci-repair-<owner>-<repo>-<num>), so the two can never double-mint for
# the same PR in the same cycle.
# ===========================================================================
start_case "POST-publish: a concurrent CI-repair lock for the same PR blocks the mayor-reopen route instead of racing it"
setup_env lockheld1
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_ALIVE"
STUB_HEAD_REF="feature/widget-fix"
LOCK_DIR="${SANDBOX}/state/.locks/cv-ci-repair-acme-widgets-42.lock"
mkdir -p "$LOCK_DIR"
echo 99999 > "${LOCK_DIR}/pid"
STUB_LOCK_STALE_SECONDS="300"
run_script "fk-work2" --finding "mayor says fix the widget"
assert_eq "1" "$RC" "exits non-zero rather than racing the held lock"
assert_contains "$OUT" "cv-ci-repair-acme-widgets-42" "names the contended dedup key"
assert_eq "0" "$(grep -c '^sling \|--city .* sling ' "$STUB_GC_LOG")" "never slings while the CI-repair lock is held"
rm -rf "${SANDBOX}/state/.locks"
STUB_LOCK_STALE_SECONDS=""

start_case "POST-publish: a stale CI-repair lock (older than CV_LOCK_STALE_SECONDS) is stolen, not left blocking forever"
setup_env lockstale1
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_ALIVE"
STUB_HEAD_REF="feature/widget-fix"
LOCK_DIR="${SANDBOX}/state/.locks/cv-ci-repair-acme-widgets-42.lock"
mkdir -p "$LOCK_DIR"
echo 99999 > "${LOCK_DIR}/pid"
touch -t 202001010000 "$LOCK_DIR" 2>/dev/null || touch -d '2020-01-01' "$LOCK_DIR" 2>/dev/null || true
STUB_LOCK_STALE_SECONDS="1"
run_script "fk-work2" --finding "mayor says fix the widget"
assert_eq "0" "$RC" "exits clean after stealing the stale lock"
assert_eq "1" "$(grep -c -- "--city ${GC_CITY_DIR} sling foundry-kc/gc.implementation-worker-9 --stdin" "$STUB_GC_LOG")" "proceeds to route after reclaiming the stale lock"
rm -rf "${SANDBOX}/state/.locks"
STUB_LOCK_STALE_SECONDS=""

# ===========================================================================
# LOW-6 (review fk-9iqxnx): the routed bead body must be labeled as a mayor
# reopen, not mislabeled as human PR review feedback.
# ===========================================================================
start_case "POST-publish: the routed bead body is labeled as a mayor reopen, not as human PR review feedback"
setup_env labeled1
STUB_BDSHOW_DEPS_FILE="$STUB_BDSHOW_DEPS_FILE_NONE"
STUB_BDLIST_ROOT_FILE="${SANDBOX}/empty-list.json"
STUB_SESSION_LIST_FILE="$STUB_SESSION_LIST_ALIVE"
STUB_HEAD_REF="feature/widget-fix"
run_script "fk-work2" --finding "mayor says fix the widget"
BODY="$(cat "${SANDBOX}/sling-body-1.txt")"
assert_contains "$BODY" "Mayor re-opened findings on PR" "the body's own provenance line calls out the mayor reopen"
assert_not_contains "$BODY" "New human review feedback" "never mislabels a mayor reopen as human PR review feedback"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
