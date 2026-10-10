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
  python3 -c '
import json, os, sys
args = sys.argv[1:]
query = None
for i, a in enumerate(args):
    if a == "--title-contains" and i + 1 < len(args):
        query = args[i + 1]
with open(os.environ["STUB_BD_LIST_JSON"]) as f:
    data = json.load(f)
if query is not None:
    data = [item for item in data if query in item.get("title", "")]
print(json.dumps(data))
' "$@"
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
  echo "https://github.com/example-org/example-pack/issues/999"
  exit 0
fi

exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

export PATH="${STUBDIR}:${PATH}"
export BD="${STUBDIR}/bd"
export GH="${STUBDIR}/gh"
export CV_SCRIBE_GH_REPO="example-org/example-pack"

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

echo "=== CASE: routing — pack-general text routes to pack ==="
reset_fixtures
ROUTE="$(scribe_route_target "con-voyage-lib.sh's cv_sync_worktree_to_base has three bootstrap call sites")"
assert_eq "pack" "$ROUTE" "pack-general friction routes to pack"

echo
echo "=== CASE: routing — city-specific text routes to city ==="
reset_fixtures
ROUTE="$(scribe_route_target "this rig's own mayor watch script leaked a token on error")"
assert_eq "city" "$ROUTE" "city-specific friction routes to city"
ROUTE2="$(scribe_route_target "this city's own .gc/con-voyage-assistants.toml override file is missing")"
assert_eq "city" "$ROUTE2" "explicit 'this city' mention routes to city"

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
[{"id": "fk-existing1", "title": "fix: duplicate suppression-log trim mechanism keeps firing twice"}]
JSON
OUT="$(scribe_file_friction "duplicate suppression-log trim mechanism keeps firing twice" --route city)"
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
OUT="$(scribe_file_friction "need a Scribe friction-logging assistant" --route pack)"
assert_eq "DEDUP:gh:example-org/example-pack#48" "$OUT" "dedup match on gh prevents re-filing"
if grep -q '^issue create ' "$STUB_GH_LOG"; then
  fail "gh issue create was NOT called when a dedup match was found"
else
  pass "gh issue create was NOT called when a dedup match was found"
fi

echo
echo "=== CASE: filing — no dedup match files a new GitHub issue for pack-general friction ==="
reset_fixtures
OUT="$(scribe_file_friction "a new friction with no existing match anywhere" --route pack --gh-repo example-org/example-pack)"
if printf '%s' "$OUT" | grep -qF 'github.com/example-org/example-pack/issues/999'; then
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
OUT="$(scribe_file_friction "this rig's own watchdog script leaks a token" --route city)"
assert_eq "bd:created-fixture-id" "$OUT" "a genuinely new city-specific friction files a bead"
if grep -q '^create ' "$STUB_BD_LOG"; then
  pass "bd create was called for a genuinely new friction"
else
  fail "bd create was called for a genuinely new friction"
fi

echo
echo "=== CASE: dedup (review fk-ert7m1 BLOCKING-2) — bd list is scoped to OPEN beads only ==="
reset_fixtures
scribe_dedup_match "some friction" >/dev/null
if grep -q -- '--all' "$STUB_BD_LOG"; then
  fail "bd list dedup lookup does NOT request --all (would match closed beads)"
else
  pass "bd list dedup lookup does NOT request --all (would match closed beads)"
fi

echo
echo "=== CASE: dedup (review fk-ert7m1 BLOCKING-2) — gh issue list is scoped to OPEN issues only ==="
reset_fixtures
scribe_dedup_match "some friction" "example-org/example-pack" >/dev/null
if grep -q -- '--state all' "$STUB_GH_LOG"; then
  fail "gh issue list dedup lookup does NOT request --state all (would match closed issues)"
else
  pass "gh issue list dedup lookup does NOT request --state all (would match closed issues)"
fi

echo
echo "=== CASE: dedup (review fk-ert7m1 BLOCKING-1) — a bd lookup failure warns and falls through, not silent ==="
reset_fixtures
cat > "${STUBDIR}/bd" <<'BD_FAIL_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_BD_LOG}"
if [ "$1" = "list" ]; then
  echo "bd: simulated auth failure" >&2
  exit 1
fi
if [ "$1" = "create" ]; then
  echo "bd:created-fixture-id"
  exit 0
fi
exit 0
BD_FAIL_STUB
chmod +x "${STUBDIR}/bd"
ERR_OUT="$(scribe_dedup_match "some friction" 2>&1 1>/dev/null)"
if printf '%s' "$ERR_OUT" | grep -qF "dedup search failed"; then
  pass "a bd lookup failure is surfaced as a WARNING to stderr"
else
  fail "a bd lookup failure is surfaced as a WARNING to stderr (got: ${ERR_OUT})"
fi
RC_MATCH="$(scribe_dedup_match "some friction")"
RC=$?
assert_eq "0" "$RC" "scribe_dedup_match still returns 0 despite the bd lookup failure (never hard-blocks filing)"
assert_eq "" "$RC_MATCH" "a failed bd lookup falls through to 'no match found', not a false match"
# restore the normal (query-filtering) bd stub for subsequent cases
cat > "${STUBDIR}/bd" <<'BD_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_BD_LOG}"

if [ "$1" = "list" ]; then
  python3 -c '
import json, os, sys
args = sys.argv[1:]
query = None
for i, a in enumerate(args):
    if a == "--title-contains" and i + 1 < len(args):
        query = args[i + 1]
with open(os.environ["STUB_BD_LIST_JSON"]) as f:
    data = json.load(f)
if query is not None:
    data = [item for item in data if query in item.get("title", "")]
print(json.dumps(data))
' "$@"
  exit 0
fi

if [ "$1" = "create" ]; then
  echo "bd:created-fixture-id"
  exit 0
fi

exit 0
BD_STUB
chmod +x "${STUBDIR}/bd"

echo
echo "=== CASE: dedup (review fk-ert7m1 BLOCKING-3) — the dedup key is a stable fragment of the raw input, not the decorated title ==="
reset_fixtures
scribe_file_friction "duplicate suppression-log trim mechanism keeps firing twice on every write" --route city >/dev/null
if grep -qF 'duplicate suppression-log trim mechanism' "$STUB_BD_LOG"; then
  pass "dedup search sends a fragment of the raw friction text, not the keyword-prefixed/truncated title"
else
  fail "dedup search sends a fragment of the raw friction text, not the keyword-prefixed/truncated title (log: $(cat "$STUB_BD_LOG"))"
fi
if grep -qF 'fix: duplicate' "$STUB_BD_LOG"; then
  fail "dedup search did NOT send the decorated title verbatim"
else
  pass "dedup search did NOT send the decorated title verbatim"
fi

echo
echo "=== CASE: dedup (review fk-ert7m1 BLOCKING-1) — a short period-terminated friction still dedups against its own period-stripped stored title ==="
reset_fixtures
cat > "$STUB_BD_LIST_JSON" <<'JSON'
[{"id": "fk-shortdot", "title": "fix: Build fails"}]
JSON
OUT="$(scribe_file_friction "Build fails." --route city)"
assert_eq "DEDUP:bd:fk-shortdot" "$OUT" "a period-terminated short friction dedups against its own period-stripped stored title (query-filtering stub would have caught the pre-fix trailing-period mismatch)"

echo
echo "=== CASE: timeout (review fk-ert7m1 BLOCKING-2) — a hung bd lookup is bounded by CV_SCRIBE_STORE_TIMEOUT_SECONDS, not left to hang ==="
reset_fixtures
cat > "${STUBDIR}/bd" <<'BD_HANG_STUB'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
  sleep 20
  exit 0
fi
exit 0
BD_HANG_STUB
chmod +x "${STUBDIR}/bd"
SAVED_TIMEOUT="$CV_SCRIBE_STORE_TIMEOUT_SECONDS"
CV_SCRIBE_STORE_TIMEOUT_SECONDS=1
t0=$(date +%s)
OUT="$(scribe_dedup_match "some friction" 2>/dev/null)"
t1=$(date +%s)
CV_SCRIBE_STORE_TIMEOUT_SECONDS="$SAVED_TIMEOUT"
elapsed=$((t1 - t0))
assert_eq "" "$OUT" "a timed-out bd lookup falls through to 'no match found', not a hang or a crash"
if [ "$elapsed" -lt 10 ]; then
  pass "scribe_dedup_match returned in ${elapsed}s, bounded by CV_SCRIBE_STORE_TIMEOUT_SECONDS=1, not the stub's full 20s sleep"
else
  fail "scribe_dedup_match took ${elapsed}s — cv_with_timeout did not bound the hung bd call"
fi
# restore the normal (query-filtering) bd stub for any later cases
cat > "${STUBDIR}/bd" <<'BD_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_BD_LOG}"

if [ "$1" = "list" ]; then
  python3 -c '
import json, os, sys
args = sys.argv[1:]
query = None
for i, a in enumerate(args):
    if a == "--title-contains" and i + 1 < len(args):
        query = args[i + 1]
with open(os.environ["STUB_BD_LIST_JSON"]) as f:
    data = json.load(f)
if query is not None:
    data = [item for item in data if query in item.get("title", "")]
print(json.dumps(data))
' "$@"
  exit 0
fi

if [ "$1" = "create" ]; then
  echo "bd:created-fixture-id"
  exit 0
fi

exit 0
BD_STUB
chmod +x "${STUBDIR}/bd"

echo
echo "=== CASE: filing failure (review fk-ert7m1 BLOCKING-1) — a hung/failing bd create is reported as a WARNING, not silently dropped ==="
reset_fixtures
cat > "${STUBDIR}/bd" <<'BD_HANG_CREATE_STUB'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
  echo "[]"
  exit 0
fi
if [ "$1" = "create" ]; then
  sleep 20
  exit 0
fi
exit 0
BD_HANG_CREATE_STUB
chmod +x "${STUBDIR}/bd"
SAVED_TIMEOUT="$CV_SCRIBE_STORE_TIMEOUT_SECONDS"
CV_SCRIBE_STORE_TIMEOUT_SECONDS=1
t0=$(date +%s)
FILING_OUT="$(scribe_file_friction "a new friction whose filing call hangs" --route city 2>&1 1>/dev/null)"
FILING_RC=$?
t1=$(date +%s)
CV_SCRIBE_STORE_TIMEOUT_SECONDS="$SAVED_TIMEOUT"
elapsed=$((t1 - t0))
if [ "$elapsed" -lt 10 ]; then
  pass "scribe_file_friction's filing call returned in ${elapsed}s, bounded by CV_SCRIBE_STORE_TIMEOUT_SECONDS=1"
else
  fail "scribe_file_friction's filing call took ${elapsed}s — cv_with_timeout did not bound the hung bd create"
fi
if printf '%s' "$FILING_OUT" | grep -qF "filing failed"; then
  pass "a timed-out bd create is surfaced as a WARNING to stderr"
else
  fail "a timed-out bd create is surfaced as a WARNING to stderr (got: ${FILING_OUT})"
fi
if [ "$FILING_RC" -ne 0 ]; then
  pass "scribe_file_friction propagates the filing call's non-zero exit code (rc=${FILING_RC})"
else
  fail "scribe_file_friction propagates the filing call's non-zero exit code (got rc=0)"
fi
# restore the normal (query-filtering) bd stub for any later cases
cat > "${STUBDIR}/bd" <<'BD_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_BD_LOG}"

if [ "$1" = "list" ]; then
  python3 -c '
import json, os, sys
args = sys.argv[1:]
query = None
for i, a in enumerate(args):
    if a == "--title-contains" and i + 1 < len(args):
        query = args[i + 1]
with open(os.environ["STUB_BD_LIST_JSON"]) as f:
    data = json.load(f)
if query is not None:
    data = [item for item in data if query in item.get("title", "")]
print(json.dumps(data))
' "$@"
  exit 0
fi

if [ "$1" = "create" ]; then
  echo "bd:created-fixture-id"
  exit 0
fi

exit 0
BD_STUB
chmod +x "${STUBDIR}/bd"

echo
echo "=== CASE: filing failure (review fk-ert7m1 BLOCKING-1, qa_test BLOCKING-1) — a hung/failing gh issue create is reported as a WARNING, not silently dropped ==="
reset_fixtures
cat > "${STUBDIR}/gh" <<'GH_HANG_CREATE_STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  echo "[]"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  sleep 20
  exit 0
fi
exit 0
GH_HANG_CREATE_STUB
chmod +x "${STUBDIR}/gh"
SAVED_TIMEOUT="$CV_SCRIBE_STORE_TIMEOUT_SECONDS"
CV_SCRIBE_STORE_TIMEOUT_SECONDS=1
t0=$(date +%s)
FILING_OUT="$(scribe_file_friction "a new friction whose pack filing call hangs" --route pack --gh-repo example-org/example-pack 2>&1 1>/dev/null)"
FILING_RC=$?
t1=$(date +%s)
CV_SCRIBE_STORE_TIMEOUT_SECONDS="$SAVED_TIMEOUT"
elapsed=$((t1 - t0))
if [ "$elapsed" -lt 10 ]; then
  pass "scribe_file_friction's gh filing call returned in ${elapsed}s, bounded by CV_SCRIBE_STORE_TIMEOUT_SECONDS=1"
else
  fail "scribe_file_friction's gh filing call took ${elapsed}s — cv_with_timeout did not bound the hung gh issue create"
fi
if printf '%s' "$FILING_OUT" | grep -qF "filing failed"; then
  pass "a timed-out gh issue create is surfaced as a WARNING to stderr"
else
  fail "a timed-out gh issue create is surfaced as a WARNING to stderr (got: ${FILING_OUT})"
fi
if [ "$FILING_RC" -ne 0 ]; then
  pass "scribe_file_friction propagates the gh filing call's non-zero exit code (rc=${FILING_RC})"
else
  fail "scribe_file_friction propagates the gh filing call's non-zero exit code (got rc=0)"
fi
# restore the normal gh stub for any later cases
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
  echo "https://github.com/example-org/example-pack/issues/999"
  exit 0
fi

exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

echo
echo "=== CASE: --route rejects an unrecognized value instead of silently falling through ==="
reset_fixtures
set +e
BAD_ROUTE_OUT="$(scribe_file_friction "some friction text" --route fundry 2>&1 1>/dev/null)"
BAD_ROUTE_RC=$?
set -e 2>/dev/null || true
if [ "$BAD_ROUTE_RC" -ne 0 ]; then
  pass "scribe_file_friction exits non-zero on an unrecognized --route value (rc=${BAD_ROUTE_RC})"
else
  fail "scribe_file_friction exits non-zero on an unrecognized --route value (got rc=0)"
fi
if [ -s "$STUB_BD_LOG" ] || [ -s "$STUB_GH_LOG" ]; then
  fail "an unrecognized --route value must not file anywhere (bd.log/gh.log should stay empty)"
else
  pass "an unrecognized --route value does not file to bd or gh"
fi
if printf '%s' "$BAD_ROUTE_OUT" | grep -qi "route"; then
  pass "the rejection message mentions the bad --route value (got: ${BAD_ROUTE_OUT})"
else
  fail "the rejection message mentions the bad --route value (got: ${BAD_ROUTE_OUT})"
fi

echo
echo "=== CASE: pack is never hardcoded to this operator's own fork — an unconfigured --gh-repo refuses to file instead of silently defaulting to one ==="
reset_fixtures
set +e
NO_REPO_OUT="$(CV_SCRIBE_GH_REPO= scribe_file_friction "some pack-general friction text" --route pack 2>&1 1>/dev/null)"
NO_REPO_RC=$?
set -e 2>/dev/null || true
if [ "$NO_REPO_RC" -ne 0 ]; then
  pass "scribe_file_friction exits non-zero on --route pack with no CV_SCRIBE_GH_REPO configured (rc=${NO_REPO_RC})"
else
  fail "scribe_file_friction exits non-zero on --route pack with no CV_SCRIBE_GH_REPO configured (got rc=0)"
fi
if [ -s "$STUB_BD_LOG" ] || [ -s "$STUB_GH_LOG" ]; then
  fail "an unconfigured pack repo must not file anywhere (bd.log/gh.log should stay empty)"
else
  pass "an unconfigured pack repo does not file to bd or gh"
fi
if printf '%s' "$NO_REPO_OUT" | grep -qi "CV_SCRIBE_GH_REPO"; then
  pass "the rejection message names CV_SCRIBE_GH_REPO as the fix (got: ${NO_REPO_OUT})"
else
  fail "the rejection message names CV_SCRIBE_GH_REPO as the fix (got: ${NO_REPO_OUT})"
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
