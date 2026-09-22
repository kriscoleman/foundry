#!/usr/bin/env bash
# cv-verify-review-approved.test.sh — hermetic unit tests for the publish-time
# defense-in-depth guard (fk-6i53).
#
# WHY: con-voyage's publish step depends on `{target}.con-voyage-review-loop`
# via graph.v2 `needs = [...]`, which is satisfied by bead CLOSURE alone,
# regardless of the review loop's own gc.outcome. A controller-level gate
# error (e.g. a missing check script, fk-6i53) can close that bead with
# gc.outcome=fail while still leaving publish's dependency satisfied — a
# missing/broken gate silently reads downstream as "review approved" (this
# happened for real: va-9p08 closed gc.outcome=fail, va-8bes/publish still
# routed as if review had passed). cv-verify-review-approved.sh re-derives the
# true verdict directly from the review-loop sibling bead's own gc.outcome
# instead of trusting graph dispatch, so publish can refuse to proceed.
#
# Contract under test:
#   cv-verify-review-approved.sh <root-bead-id>
#   - Looks up every bead sharing gc.root_bead_id=<root-bead-id> via
#     `$GC --city $GC_CITY bd list --all --metadata-field ... --json`.
#   - Finds the sibling titled "Run con-voyage review until approved" (the
#     con-voyage-review-loop node's stable title), picks the most recently
#     updated if more than one is returned.
#   - Exit 0 only when that sibling is status=closed AND
#     metadata['gc.outcome']=pass. Exit 1 for every other case (still open,
#     closed with any other outcome, missing entirely, or a lookup failure) —
#     fails SAFE (blocks publish) rather than silently trusting dispatch.
#
# The `gc` CLI is stubbed: a recording script honors `bd list --all
# --metadata-field ... --json` by echoing STUB_BDLIST_JSON verbatim, so no
# real gc/bd/network is involved (hermetic).
#
# Run:  bash tests/cv-verify-review-approved.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-verify-review-approved.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-verify-review-approved-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Recording `gc` stub: `bd list --all --metadata-field ... --json` echoes
# STUB_BDLIST_JSON verbatim. Everything else no-ops (exit 0, empty output).
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "list" ]; then
  printf '%s' "${STUB_BDLIST_JSON:-[]}"
  exit 0
fi
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

export GC="${STUBDIR}/gc"
export GC_CITY="${SANDBOX}/city"
mkdir -p "$GC_CITY"

FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

run_script() {
  OUT="$(STUB_BDLIST_JSON="$1" "$SCRIPT" "${@:2}" 2>&1)"
  RC=$?
}

bead_json() {
  # bead_json ID TITLE STATUS OUTCOME UPDATED_AT -> one bead JSON object
  local id="$1" title="$2" status="$3" outcome="$4" updated="$5"
  python3 -c "
import json, sys
print(json.dumps({
    'id': sys.argv[1], 'title': sys.argv[2], 'status': sys.argv[3],
    'updated_at': sys.argv[5],
    'metadata': {'gc.outcome': sys.argv[4]} if sys.argv[4] else {},
}))
" "$id" "$title" "$status" "$outcome" "$updated"
}

OUT=""
RC=0

# ===========================================================================
# CASE 1 — genuinely approved: closed + gc.outcome=pass -> exit 0.
# ===========================================================================
start_case "1: review loop closed with gc.outcome=pass -> approved (exit 0)"
BEAD1="$(bead_json va-loop1 'Run con-voyage review until approved' closed pass 2026-09-22T10:00:00Z)"
run_script "[${BEAD1}]" root-1
assert_eq "0" "$RC" "exit 0 when genuinely approved"

# ===========================================================================
# CASE 2 — THE BUG SCENARIO: closed with gc.outcome=fail (va-9p08) -> BLOCKED.
# ===========================================================================
start_case "2: review loop closed with gc.outcome=fail -> BLOCKED (exit 1) [reproduces va-9p08]"
BEAD2="$(bead_json va-9p08 'Run con-voyage review until approved' closed fail 2026-09-22T10:00:00Z)"
run_script "[${BEAD2}]" root-2
if [ "$RC" -ne 0 ]; then pass "exit non-zero when closed with gc.outcome=fail"; else fail "should BLOCK on gc.outcome=fail, got exit 0"; fi
if printf '%s' "$OUT" | grep -qi 'fail'; then pass "reason mentions the fail outcome"; else fail "reason does not mention the fail outcome: $OUT"; fi

# ===========================================================================
# CASE 3 — still open (not yet closed) -> BLOCKED.
# ===========================================================================
start_case "3: review loop still open -> BLOCKED (exit 1)"
BEAD3="$(bead_json va-loop3 'Run con-voyage review until approved' open '' 2026-09-22T10:00:00Z)"
run_script "[${BEAD3}]" root-3
if [ "$RC" -ne 0 ]; then pass "exit non-zero when still open"; else fail "should BLOCK on open status, got exit 0"; fi

# ===========================================================================
# CASE 4 — no sibling bead with the review-loop's title at all -> BLOCKED.
# ===========================================================================
start_case "4: no matching review-loop sibling found -> BLOCKED (exit 1)"
OTHER="$(bead_json va-other 'Some unrelated step' closed pass 2026-09-22T10:00:00Z)"
run_script "[${OTHER}]" root-4
if [ "$RC" -ne 0 ]; then pass "exit non-zero when no review-loop sibling exists"; else fail "should BLOCK when review-loop sibling missing, got exit 0"; fi

# ===========================================================================
# CASE 5 — empty bd list result -> BLOCKED, fails safe.
# ===========================================================================
start_case "5: empty bd list result -> BLOCKED (exit 1)"
run_script "[]" root-5
if [ "$RC" -ne 0 ]; then pass "exit non-zero on empty bd list"; else fail "should BLOCK on empty result, got exit 0"; fi

# ===========================================================================
# CASE 6 — malformed JSON from bd list -> fails safe, does not crash.
# ===========================================================================
start_case "6: malformed bd list JSON -> fails safe (exit 1), no crash"
run_script "not valid json{{{" root-6
if [ "$RC" -ne 0 ]; then pass "exit non-zero on malformed JSON"; else fail "should fail safe on malformed JSON, got exit 0"; fi

# ===========================================================================
# CASE 7 — multiple candidates: the MOST RECENTLY UPDATED one governs.
# ===========================================================================
start_case "7: multiple review-loop siblings -> most recently updated governs"
OLDER="$(bead_json va-loop-old 'Run con-voyage review until approved' closed fail 2026-09-22T09:00:00Z)"
NEWER="$(bead_json va-loop-new 'Run con-voyage review until approved' closed pass 2026-09-22T11:00:00Z)"
run_script "[${OLDER}, ${NEWER}]" root-7
assert_eq "0" "$RC" "the newer (approved) sibling determines the outcome"

start_case "7b: multiple review-loop siblings, newest is the failing one -> BLOCKED"
NEWER_FAIL="$(bead_json va-loop-new2 'Run con-voyage review until approved' closed fail 2026-09-22T12:00:00Z)"
OLDER_PASS="$(bead_json va-loop-old2 'Run con-voyage review until approved' closed pass 2026-09-22T09:00:00Z)"
run_script "[${OLDER_PASS}, ${NEWER_FAIL}]" root-7b
if [ "$RC" -ne 0 ]; then pass "the newer (failing) sibling correctly blocks"; else fail "should BLOCK when the most recent sibling failed, got exit 0"; fi

# ===========================================================================
# CASE 8 — usage error: no root-bead-id argument.
# ===========================================================================
start_case "8: usage error when root-bead-id argument is missing"
OUT="$(STUB_BDLIST_JSON="[]" "$SCRIPT" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then pass "exit non-zero with no arguments"; else fail "should fail with no arguments, got exit 0"; fi

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
