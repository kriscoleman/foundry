#!/usr/bin/env bash
# con-voyage-scribe.test.sh — hermetic unit tests for Scribe, the
# friction-logging assistant (fk-ohjjjb / fk-g24r / foundry#48, see
# .claude/plans/con-voyage-assistants.md "Scribe").
#
# HOW IT WORKS (no network, no real gc/bd/gh): the lib is `source`d directly
# (functions only, no side effects at source time — see its own header).
# Recording `bd` and `gh` stubs on PATH serve canned list/search JSON and
# record every invocation to their own log files, so a dedup match can be
# asserted to have suppressed the corresponding create call.
#
# Run:  bash tests/con-voyage-scribe.test.sh   (exit 0 => pass)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-scribe.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: lib under test not found at ${LIB}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-scribe-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
export STUB_BD_LOG="${SANDBOX}/bd.log"
export STUB_GH_LOG="${SANDBOX}/gh.log"
export STUB_BD_LIST_JSON="${SANDBOX}/bd_list.json"
export STUB_GH_LIST_JSON="${SANDBOX}/gh_list.json"
mkdir -p "$STUBDIR"
: > "$STUB_BD_LOG"
: > "$STUB_GH_LOG"
printf '[]' > "$STUB_BD_LIST_JSON"
printf '[]' > "$STUB_GH_LIST_JSON"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

cat > "${STUBDIR}/bd" <<'BD_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_BD_LOG}"

if [ "$1" = "list" ]; then
  cat "${STUB_BD_LIST_JSON}"
  exit 0
fi

if [ "$1" = "create" ]; then
  echo "bd:created-fixture-id"
  exit 0
fi

exit 0
BD_STUB
chmod +x "${STUBDIR}/bd"

cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GH_LOG}"

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  cat "${STUB_GH_LIST_JSON}"
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/kriscoleman/foundry/issues/999"
  exit 0
fi

exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

export PATH="${STUBDIR}:${PATH}"
export BD="${STUBDIR}/bd"
export GH="${STUBDIR}/gh"

# shellcheck source=../pack/assets/scripts/con-voyage-scribe.sh
source "$LIB"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then
    pass "${desc} (=${actual})"
  else
    fail "${desc} (expected=${expected@Q} actual=${actual@Q})"
  fi
}

reset_fixtures() {
  : > "$STUB_BD_LOG"
  : > "$STUB_GH_LOG"
  printf '[]' > "$STUB_BD_LIST_JSON"
  printf '[]' > "$STUB_GH_LIST_JSON"
}

echo "=== CASE: routing — pack-general text routes to foundry ==="
reset_fixtures
ROUTE="$(scribe_route_target "con-voyage-lib.sh's cv_sync_worktree_to_base has three bootstrap call sites")"
assert_eq "foundry" "$ROUTE" "pack-general friction routes to foundry"

echo
echo "=== CASE: routing — city-specific text routes to repl_city ==="
reset_fixtures
ROUTE="$(scribe_route_target "this rig's own mayor watch script leaked a token on error")"
assert_eq "repl_city" "$ROUTE" "city-specific friction routes to repl_city"
ROUTE2="$(scribe_route_target "repl_city's own .gc/con-voyage-assistants.toml override file is missing")"
assert_eq "repl_city" "$ROUTE2" "explicit repl_city mention routes to repl_city"

echo
echo "=== CASE: title/body — Conventional-Commit + INVEST shape ==="
reset_fixtures
TITLE="$(scribe_format_title "A bug causes the suppression log trim to double-fire on every write")"
if printf '%s' "$TITLE" | grep -qE '^fix: '; then
  pass "a bug-shaped friction gets a fix: prefix"
else
  fail "a bug-shaped friction gets a fix: prefix (got: ${TITLE})"
fi
if [ "${#TITLE}" -le 72 ]; then
  pass "title stays within 72 characters (len=${#TITLE})"
else
  fail "title stays within 72 characters (len=${#TITLE})"
fi

BODY="$(scribe_format_body "The suppression log trim fires twice per write.")"
if printf '%s' "$BODY" | grep -qF '## Problem'; then
  pass "body includes a ## Problem section"
else
  fail "body includes a ## Problem section"
fi
if printf '%s' "$BODY" | grep -qF '## INVEST'; then
  pass "body includes a ## INVEST section"
else
  fail "body includes a ## INVEST section"
fi
for word in Independent Negotiable Valuable Estimable Small Testable; do
  if printf '%s' "$BODY" | grep -qF "${word}:"; then
    pass "body's INVEST section covers ${word}"
  else
    fail "body's INVEST section covers ${word}"
  fi
done

echo
echo "=== CASE: dedup — a friction matching an existing bead is not re-filed ==="
reset_fixtures
cat > "$STUB_BD_LIST_JSON" <<'JSON'
[{"id": "fk-existing1", "title": "fix: duplicate suppression-log trim mechanism"}]
JSON
OUT="$(scribe_file_friction "duplicate suppression-log trim mechanism keeps firing twice" --route repl_city)"
assert_eq "DEDUP:bd:fk-existing1" "$OUT" "dedup match on bd prevents re-filing"
if grep -q '^create ' "$STUB_BD_LOG"; then
  fail "bd create was NOT called when a dedup match was found"
else
  pass "bd create was NOT called when a dedup match was found"
fi

echo
echo "=== CASE: dedup — a friction matching an existing GitHub issue is not re-filed ==="
reset_fixtures
cat > "$STUB_GH_LIST_JSON" <<'JSON'
[{"number": 48, "title": "feat: Scribe friction-logging assistant"}]
JSON
OUT="$(scribe_file_friction "need a Scribe friction-logging assistant" --route foundry)"
assert_eq "DEDUP:gh:kriscoleman/foundry#48" "$OUT" "dedup match on gh prevents re-filing"
if grep -q '^issue create ' "$STUB_GH_LOG"; then
  fail "gh issue create was NOT called when a dedup match was found"
else
  pass "gh issue create was NOT called when a dedup match was found"
fi

echo
echo "=== CASE: filing — no dedup match files a new GitHub issue for pack-general friction ==="
reset_fixtures
OUT="$(scribe_file_friction "a new friction with no existing match anywhere" --route foundry --gh-repo kriscoleman/foundry)"
if printf '%s' "$OUT" | grep -qF 'github.com/kriscoleman/foundry/issues/999'; then
  pass "a genuinely new pack-general friction files a GitHub issue"
else
  fail "a genuinely new pack-general friction files a GitHub issue (got: ${OUT})"
fi
if grep -q '^issue create ' "$STUB_GH_LOG"; then
  pass "gh issue create was called for a genuinely new friction"
else
  fail "gh issue create was called for a genuinely new friction"
fi

echo
echo "=== CASE: filing — no dedup match files a new bead for city-specific friction ==="
reset_fixtures
OUT="$(scribe_file_friction "this rig's own watchdog script leaks a token" --route repl_city)"
assert_eq "bd:created-fixture-id" "$OUT" "a genuinely new city-specific friction files a bead"
if grep -q '^create ' "$STUB_BD_LOG"; then
  pass "bd create was called for a genuinely new friction"
else
  fail "bd create was called for a genuinely new friction"
fi

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "SOME CASES FAILED"
  exit 1
fi
