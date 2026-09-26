#!/usr/bin/env bash
# implementation-review-approved.test.sh — hermetic unit tests for the
# con-voyage-review-loop exit gate (fk-s15g6).
#
# WHY: `code_review.verdict` is written by two independent producers under
# the SAME metadata key name on DIFFERENT beads that share one
# gc.root_bead_id + gc.attempt: apply-review-findings owns it with the
# done|iterate vocabulary (contract in
# assets/workflows/con-voyage/{target}.apply-review-findings.md: "The
# apply-review-findings lane owns code_review.verdict=done|iterate"), while
# the review-loop's own per-iteration scope/body bead independently ends up
# carrying a same-named code_review.verdict with the approve|iterate lane
# rollup vocabulary (not written by any prompt in this pack — see the
# per-lane `code_review.<lane>_verdict` fields the check's own LANE_STATUS
# fallback already reads directly from those lane beads).
#
# The VERDICT lookup below selected "last" over every bead sharing
# gc.root_bead_id + gc.attempt with a non-empty code_review.verdict, with no
# filter on WHICH bead should be authoritative. `bd list` ordering is not
# guaranteed to put apply-review-findings' write last, so the loop's own
# rollup ("approve") could win over apply-review-findings' real verdict
# ("done"). "approve" then falls through the done/approved/pass case
# unrecognized, and the loop dispatches a whole extra iteration even though
# apply-review-findings already closed as a no-op approval (found live:
# iteration 3 of root fk-nuy1h approved commit 487fb11 with 0 BLOCKING, the
# apply-review-findings pass fk-jgn8f recorded a no-op verdict=done, and the
# loop still fanned out a full iteration 4 against the byte-identical diff).
#
# Contract under test: `implementation-review-approved.sh` (GC_BEAD_ID = the
# review-loop's current-iteration body bead, GC_ITERATION = the attempt
# number) must resolve VERDICT from the apply-review-findings bead
# specifically (gc.step_id matching "<target>.apply-review-findings", derived
# from the body bead's own gc.step_id "<target>.con-voyage-review-loop"), not
# from any bead that merely shares gc.root_bead_id + gc.attempt.
#
# The `bd` CLI is stubbed: `bd show <id> --json` returns a registered bead by
# id, `bd list --all --metadata-field ... --json --limit=0` returns a fixed
# matches array — no real bd/gc/network involved (hermetic).
#
# Run:  bash tests/implementation-review-approved.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/checks/implementation-review-approved.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/implementation-review-approved-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Recording `bd` stub: `show <id>` returns the registered bead for <id> (or
# {} if unregistered, matching a real 404-ish empty lookup); `list ...`
# returns the fixed matches array for this case. Every invocation is also
# appended to STUB_BD_LOG, one space-joined argv per line (same convention as
# tests/cv-verify-review-approved.test.sh's gc stub).
cat > "${STUBDIR}/bd" <<'BD_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_BD_LOG:-/dev/null}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "show" ]; then
  id="${2:-}"
  python3 -c "
import json, sys
with open(sys.argv[2]) as f:
    registry = json.load(f)
print(json.dumps([registry.get(sys.argv[1], {})]))
" "$id" "${SELF_DIR}/registry.json"
  exit 0
fi

if [ "${1:-}" = "list" ]; then
  cat "${SELF_DIR}/matches.json" 2>/dev/null || printf '[]'
  exit 0
fi

exit 0
BD_STUB
chmod +x "${STUBDIR}/bd"

BD_LOG="${SANDBOX}/bd.log"
: > "$BD_LOG"
export STUB_BD_LOG="$BD_LOG"

FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

# bead_json ID METADATA_JSON -> one bead JSON object {"id":ID,"metadata":{...}}
bead_json() {
  local id="$1" meta="$2"
  python3 -c "
import json, sys
print(json.dumps({'id': sys.argv[1], 'metadata': json.loads(sys.argv[2])}))
" "$id" "$meta"
}

# write_fixtures ROOT_BEAD_JSON BODY_BEAD_JSON MATCHES_BEAD_JSON... -> wires
# up the registry (for `bd show`) and matches array (for `bd list`) the stub
# reads from disk.
write_fixtures() {
  local root_bead="$1" body_bead="$2"
  shift 2
  python3 -c "
import json, sys
beads = [json.loads(a) for a in sys.argv[1:]]
registry = {b['id']: b for b in beads}
print(json.dumps(registry))
" "$root_bead" "$body_bead" "$@" > "${STUBDIR}/registry.json"
  python3 -c "
import json, sys
print(json.dumps([json.loads(a) for a in sys.argv[1:]]))
" "$@" > "${STUBDIR}/matches.json"
}

run_check() {
  # run_check GC_BEAD_ID GC_ITERATION
  OUT="$(GC_BEAD_ID="$1" GC_ITERATION="$2" PATH="${STUBDIR}:${PATH}" "$SCRIPT" 2>&1)"
  RC=$?
}

OUT=""
RC=0

# ===========================================================================
# CASE 1 — THE BUG SCENARIO: apply-review-findings closed this attempt as a
# no-op approval (code_review.verdict=done on ITS OWN bead), but the
# review-loop's own per-iteration body bead independently carries a
# same-named code_review.verdict=approve (the lane rollup, not the
# done|iterate vocabulary). Must resolve from apply-review-findings and
# report approved (exit 0) — not dispatch another iteration.
# [reproduces root fk-nuy1h iteration 3->4: fk-jgn8f closed verdict=done,
# 0 BLOCKING, but the loop still fanned out iteration 4]
# ===========================================================================
start_case "1: apply-review-findings verdict=done wins over the loop body's own code_review.verdict=approve rollup"
ROOT1="$(bead_json wfroot-1 '{}')"
BODY1="$(bead_json loop-3 '{
  "gc.root_bead_id": "wfroot-1",
  "gc.step_id": "main.con-voyage-review-loop",
  "gc.attempt": "3",
  "gc.scope_role": "body",
  "code_review.verdict": "approve",
  "code_review.acceptance_verdict": "approve",
  "code_review.test_evidence_verdict": "approve",
  "code_review.simplicity_verdict": "approve"
}')"
APPLY1="$(bead_json apply-3 '{
  "gc.root_bead_id": "wfroot-1",
  "gc.attempt": "3",
  "gc.step_id": "main.apply-review-findings",
  "code_review.verdict": "done",
  "code_review.report_path": "/fake/review-fix-summary.md"
}')"
# Matches order deliberately puts the body bead's rollup AFTER
# apply-review-findings' own entry — bd list's return order is not
# guaranteed, and this is the adversarial order that actually shipped the
# live incident.
write_fixtures "$ROOT1" "$BODY1" "$APPLY1" "$BODY1"
run_check loop-3 3
assert_eq "0" "$RC" "exit 0 when apply-review-findings already approved this attempt"
if printf '%s' "$OUT" | grep -qi 'approved'; then pass "output reports approved"; else fail "output does not report approved: $OUT"; fi

# ===========================================================================
# CASE 2 — existing behavior preserved: BLOCKING findings remain, both the
# apply-review-findings bead and the loop body's rollup say iterate -> the
# loop must still dispatch another iteration (exit 1).
# ===========================================================================
start_case "2: apply-review-findings verdict=iterate still forces another iteration (BLOCKING preserved)"
ROOT2="$(bead_json wfroot-2 '{}')"
BODY2="$(bead_json loop-4 '{
  "gc.root_bead_id": "wfroot-2",
  "gc.step_id": "main.con-voyage-review-loop",
  "gc.attempt": "4",
  "gc.scope_role": "body",
  "code_review.verdict": "iterate",
  "code_review.acceptance_verdict": "iterate"
}')"
APPLY2="$(bead_json apply-4 '{
  "gc.root_bead_id": "wfroot-2",
  "gc.attempt": "4",
  "gc.step_id": "main.apply-review-findings",
  "code_review.verdict": "iterate"
}')"
write_fixtures "$ROOT2" "$BODY2" "$BODY2" "$APPLY2"
run_check loop-4 4
if [ "$RC" -ne 0 ]; then pass "exit non-zero when BLOCKING findings remain"; else fail "should require another iteration on verdict=iterate, got exit 0"; fi

# ===========================================================================
# CASE 3 — sanity/baseline: no colliding rollup on the body bead at all,
# apply-review-findings is the only bead with code_review.verdict. Confirms
# the fix's added scoping does not break the plain, non-colliding case.
# ===========================================================================
start_case "3: plain verdict=done with no rollup collision still approves"
ROOT3="$(bead_json wfroot-3 '{}')"
BODY3="$(bead_json loop-5 '{
  "gc.root_bead_id": "wfroot-3",
  "gc.step_id": "main.con-voyage-review-loop",
  "gc.attempt": "5",
  "gc.scope_role": "body"
}')"
APPLY3="$(bead_json apply-5 '{
  "gc.root_bead_id": "wfroot-3",
  "gc.attempt": "5",
  "gc.step_id": "main.apply-review-findings",
  "code_review.verdict": "done"
}')"
write_fixtures "$ROOT3" "$BODY3" "$BODY3" "$APPLY3"
run_check loop-5 5
assert_eq "0" "$RC" "exit 0 with a single unambiguous verdict=done"

# ===========================================================================
# CASE 4 — THE FALSE-APPROVAL DIRECTION (fk-hrbj7 LOW-2): the loop body's own
# code_review.verdict rollup says "done" while the real apply-review-findings
# bead says "iterate" (BLOCKING work still outstanding). CASE 2 above only
# covers "iterate" on both beads, which exits 1 either way and never
# exercises this direction. Pre-fix (9a5499e), unscoped "last" over bd list's
# unordered result could pick the body bead's "done" and falsely approve
# (exit 0) with real BLOCKING findings still open — the more consequential
# half of the original bug (cross-checked against live data: root fk-nuy1h
# attempt 4, loop body fk-z23in rollup=done vs. a real apply verdict
# elsewhere in the iterate class). Must resolve from apply-review-findings
# specifically and exit 1.
# ===========================================================================
start_case "4: apply-review-findings verdict=iterate is not shadowed by the loop body's own code_review.verdict=done rollup (false-approval direction)"
ROOT4="$(bead_json wfroot-4 '{}')"
BODY4="$(bead_json loop-6 '{
  "gc.root_bead_id": "wfroot-4",
  "gc.step_id": "main.con-voyage-review-loop",
  "gc.attempt": "6",
  "gc.scope_role": "body",
  "code_review.verdict": "done"
}')"
APPLY4="$(bead_json apply-6 '{
  "gc.root_bead_id": "wfroot-4",
  "gc.attempt": "6",
  "gc.step_id": "main.apply-review-findings",
  "code_review.verdict": "iterate"
}')"
# Matches order deliberately puts the body bead's done rollup AFTER
# apply-review-findings' own iterate entry — the same adversarial order as
# CASE 1, this time with the vocabulary that makes unscoped "last" resolve to
# a false approval instead of a wasted iteration.
write_fixtures "$ROOT4" "$BODY4" "$APPLY4" "$BODY4"
run_check loop-6 6
assert_eq "1" "$RC" "exit 1 when apply-review-findings verdict=iterate is shadowed by the loop body's code_review.verdict=done rollup"
if printf '%s' "$OUT" | grep -qi 'another iteration'; then pass "output reports another iteration needed"; else fail "output does not report another iteration needed: $OUT"; fi

# ===========================================================================
# CASE 5 — gc.step_id fallback diagnostic (fk-hrbj7 LOW-1): when the current
# bead's gc.step_id is absent or doesn't end in ".con-voyage-review-loop",
# APPLY_STEP_ID can't be derived, so VERDICT must resolve empty and the
# script falls back to the LANE_STATUS heuristic — never reading
# apply-review-findings' code_review.verdict directly (which would bypass
# the step-id scoping CASE 1/4 depend on). Confirms the fallback happens (via
# the new stderr diagnostic) and does not falsely approve even though the
# apply-review-findings-shaped bead here says "done".
# ===========================================================================
start_case "5: missing/mismatched gc.step_id logs a diagnostic and falls back to LANE_STATUS instead of falsely approving"
ROOT5="$(bead_json wfroot-5 '{}')"
BODY5="$(bead_json loop-7 '{
  "gc.root_bead_id": "wfroot-5",
  "gc.attempt": "7",
  "gc.scope_role": "body",
  "code_review.acceptance_verdict": "iterate",
  "code_review.test_evidence_verdict": "iterate",
  "code_review.simplicity_verdict": "iterate"
}')"
APPLY5="$(bead_json apply-7 '{
  "gc.root_bead_id": "wfroot-5",
  "gc.attempt": "7",
  "gc.step_id": "main.apply-review-findings",
  "code_review.verdict": "done"
}')"
write_fixtures "$ROOT5" "$BODY5" "$APPLY5" "$BODY5"
run_check loop-7 7
assert_eq "1" "$RC" "exit 1 from LANE_STATUS fallback, not a false approval via apply-review-findings' own verdict=done"
if printf '%s' "$OUT" | grep -qi "does not match expected"; then pass "diagnostic logged for step-id fallback"; else fail "missing step-id fallback diagnostic: $OUT"; fi
if printf '%s' "$OUT" | grep -qi 'another iteration'; then pass "output reports another iteration needed from LANE_STATUS"; else fail "output does not report another iteration needed: $OUT"; fi

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
