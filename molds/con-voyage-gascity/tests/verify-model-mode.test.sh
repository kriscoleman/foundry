#!/usr/bin/env bash
# verify-model-mode.test.sh — hermetic test for cv-verify-model-mode.sh
# (README.md "Model tiers" / "Switching to opencode + fireworks mode").
#
# THE CONTRACT BEING PINNED:
#   The opencode + fireworks mode lives entirely in the city's own city.toml
#   (ailloy cannot patch city.toml, so pack recasts can never restore it if
#   something else wipes it). cv-verify-model-mode.sh is the drift check: it
#   queries `gc config explain --provider <tier> --json` for all three
#   reviewer tiers and confirms builtin_ancestor matches the mode passed on
#   argv, so an accidental reversion to the pack's claude defaults is a loud,
#   scriptable failure instead of a silent one.
#
# A stub `gc` binary returns canned `config explain --provider --json` bodies
# keyed by STUB_PROVIDER_JSON_<tier_with_underscores>; an unset var makes the
# stub emit gc's real "provider not found" failure shape (exit 1), matching
# what happens live when a tier isn't wired at all.
#
# Run:  bash tests/verify-model-mode.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-verify-model-mode.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-verify-model-mode-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
provider=""
prev=""
for a in "$@"; do
  [ "$prev" = "--provider" ] && provider="$a"
  prev="$a"
done
var="STUB_PROVIDER_JSON_${provider//-/_}"
if [ -n "${!var:-}" ]; then
  printf '%s' "${!var}"
  exit 0
fi
printf '%s' '{"schema_version":"1","ok":false,"error":{"code":"command_failed","message":"gc config explain: no provider found","exit_code":1}}'
exit 1
GC_STUB
chmod +x "${STUBDIR}/gc"

GC="${STUBDIR}/gc"
export GC
GC_CITY="${SANDBOX}/city"
mkdir -p "$GC_CITY"
export GC_CITY

json_ancestor() {
  printf '{"ok":true,"builtin_ancestor":"%s","name":"x"}' "$1"
}

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

reset_stubs() {
  unset STUB_PROVIDER_JSON_cv_review_light
  unset STUB_PROVIDER_JSON_cv_review_standard
  unset STUB_PROVIDER_JSON_cv_review_intensive
}

# ---------------------------------------------------------------------------
start_case "all three tiers on claude -> verifying claude mode passes"
# ---------------------------------------------------------------------------
reset_stubs
export STUB_PROVIDER_JSON_cv_review_light; STUB_PROVIDER_JSON_cv_review_light="$(json_ancestor claude)"
export STUB_PROVIDER_JSON_cv_review_standard; STUB_PROVIDER_JSON_cv_review_standard="$(json_ancestor claude)"
export STUB_PROVIDER_JSON_cv_review_intensive; STUB_PROVIDER_JSON_cv_review_intensive="$(json_ancestor claude)"
if OUT="$(bash "$SCRIPT" claude 2>&1)"; then
  pass "exit 0 for matching claude mode"
else
  fail "expected exit 0, got failure: ${OUT}"
fi

# ---------------------------------------------------------------------------
start_case "all three tiers on opencode -> verifying opencode mode passes"
# ---------------------------------------------------------------------------
reset_stubs
export STUB_PROVIDER_JSON_cv_review_light; STUB_PROVIDER_JSON_cv_review_light="$(json_ancestor opencode)"
export STUB_PROVIDER_JSON_cv_review_standard; STUB_PROVIDER_JSON_cv_review_standard="$(json_ancestor opencode)"
export STUB_PROVIDER_JSON_cv_review_intensive; STUB_PROVIDER_JSON_cv_review_intensive="$(json_ancestor opencode)"
if OUT="$(bash "$SCRIPT" opencode 2>&1)"; then
  pass "exit 0 for matching opencode mode"
else
  fail "expected exit 0, got failure: ${OUT}"
fi

# ---------------------------------------------------------------------------
start_case "one tier drifted back to claude while expecting opencode -> fails loudly, names the tier"
# ---------------------------------------------------------------------------
reset_stubs
export STUB_PROVIDER_JSON_cv_review_light; STUB_PROVIDER_JSON_cv_review_light="$(json_ancestor claude)"
export STUB_PROVIDER_JSON_cv_review_standard; STUB_PROVIDER_JSON_cv_review_standard="$(json_ancestor opencode)"
export STUB_PROVIDER_JSON_cv_review_intensive; STUB_PROVIDER_JSON_cv_review_intensive="$(json_ancestor opencode)"
if OUT="$(bash "$SCRIPT" opencode 2>&1)"; then
  fail "expected non-zero exit on drift, got success: ${OUT}"
else
  case "$OUT" in
    *cv-review-light*claude*) pass "drift message names cv-review-light and its actual mode" ;;
    *) fail "drift message did not name the drifted tier: ${OUT}" ;;
  esac
fi

# ---------------------------------------------------------------------------
start_case "a tier that isn't resolvable at all is reported distinctly from a mode mismatch"
# ---------------------------------------------------------------------------
reset_stubs
export STUB_PROVIDER_JSON_cv_review_standard; STUB_PROVIDER_JSON_cv_review_standard="$(json_ancestor claude)"
export STUB_PROVIDER_JSON_cv_review_intensive; STUB_PROVIDER_JSON_cv_review_intensive="$(json_ancestor claude)"
# cv-review-light left unset -> stub returns gc's real "not found" shape
if OUT="$(bash "$SCRIPT" claude 2>&1)"; then
  fail "expected non-zero exit when a tier is unresolvable, got success: ${OUT}"
else
  case "$OUT" in
    *cv-review-light*"not resolvable"*) pass "unresolvable tier reported distinctly" ;;
    *) fail "unresolvable tier not reported clearly: ${OUT}" ;;
  esac
fi

# ---------------------------------------------------------------------------
start_case "invalid mode argument is a usage error"
# ---------------------------------------------------------------------------
reset_stubs
if OUT="$(bash "$SCRIPT" fireworks-direct 2>&1)"; then
  fail "expected non-zero exit for invalid mode, got success: ${OUT}"
else
  case "$OUT" in
    *usage*) pass "invalid mode rejected with a usage message" ;;
    *) fail "invalid mode did not produce a usage message: ${OUT}" ;;
  esac
fi

# ---------------------------------------------------------------------------
start_case "missing mode argument is a usage error"
# ---------------------------------------------------------------------------
reset_stubs
if OUT="$(bash "$SCRIPT" 2>&1)"; then
  fail "expected non-zero exit for missing mode, got success: ${OUT}"
else
  case "$OUT" in
    *usage*) pass "missing mode rejected with a usage message" ;;
    *) fail "missing mode did not produce a usage message: ${OUT}" ;;
  esac
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
