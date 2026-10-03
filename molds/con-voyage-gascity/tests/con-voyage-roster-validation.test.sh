#!/usr/bin/env bash
# con-voyage-roster-validation.test.sh — hermetic unit tests for the roster-
# var validation helpers in con-voyage-lib.sh (fk-ed0c5).
#
# WHY: a misspelled `--var enable_sre_reliability=true` (the formula's real
# var is enable_sre) was silently accepted by gc sling, so the sre-review
# lane never dispatched (its condition is `{{enable_sre}}`, which stayed
# false) while the review context still claimed SRE was an active roster
# lens. These helpers give the workflow a way to (a) detect an unknown
# gc.var.enable_* name / unknown code_lens value against the formula's own
# declarations and (b) compute the roster that actually dispatched from the
# formula's real per-lane conditions, instead of guessing from var-name
# prefixes.
#
# cv_known_roster_vars / cv_known_lenses / cv_active_roster_vars read the
# REAL pack's formulas/con-voyage.formula.toml and agents/ directory (not a
# stub) via cv_pack_root, so these tests also lock in that the declared
# roster stays in sync with the formula as it evolves. cv_unknown_roster_vars
# / cv_unknown_code_lens additionally need a stubbed `bd show` for the root
# bead's metadata, using the same recording `gc` stub pattern as
# con-voyage-lib.test.sh.
#
# Run:  bash tests/con-voyage-roster-validation.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: lib under test not found at ${LIB}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-roster-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

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
if [ "${args[$i]:-}" = "bd" ] && [ "${args[$((i+1))]:-}" = "show" ]; then
  id="${args[$((i+2))]:-}"
  var="STUB_BDSHOW_JSON_${id//-/_}"
  printf '%s' "${!var:-}"
  exit 0
fi
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# shellcheck disable=SC2034  # consumed by con-voyage-lib.sh at call time
GC="${STUBDIR}/gc"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (expected [$expected], got [$actual])" >&2
    FAILURES=$((FAILURES+1))
  fi
}
assert_contains_word() {
  local haystack="$1" needle="$2" label="$3"
  local w
  for w in $haystack; do
    if [ "$w" = "$needle" ]; then
      echo "  PASS: $label"
      return 0
    fi
  done
  echo "  FAIL: $label (\"$needle\" not found in [$haystack])" >&2
  FAILURES=$((FAILURES+1))
}

# ===========================================================================
# CASE 1 — cv_known_roster_vars lists the real formula's declared enable_*
# roster vars (a sample of the always-present ones), and specifically does
# NOT include the misspelled "enable_sre_reliability" from the fk-ed0c5
# incident.
# ===========================================================================
start_case "1: cv_known_roster_vars reflects the real formula's declared roster vars"
KNOWN="$(GC="$GC" bash -c "source '$LIB'; cv_known_roster_vars" | tr '\n' ' ')"
assert_contains_word "$KNOWN" "enable_sre" "enable_sre is a known roster var"
assert_contains_word "$KNOWN" "enable_product_owner" "enable_product_owner is a known roster var"
if printf '%s\n' "$KNOWN" | grep -qw "enable_sre_reliability"; then
  echo "  FAIL: enable_sre_reliability must NOT be a known roster var (it was never declared)" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: enable_sre_reliability is correctly absent from the known roster vars"
fi

# ===========================================================================
# CASE 2 — cv_known_lenses lists the real agent directory's cv-* lenses,
# qualified with the con-voyage. run-target prefix.
# ===========================================================================
start_case "2: cv_known_lenses reflects the real agents/ directory"
LENSES="$(GC="$GC" bash -c "source '$LIB'; cv_known_lenses" | tr '\n' ' ')"
assert_contains_word "$LENSES" "con-voyage.cv-sre-reliability" "cv-sre-reliability is a known lens"
assert_contains_word "$LENSES" "con-voyage.cv-go-principal-engineer" "cv-go-principal-engineer is a known lens"

# ===========================================================================
# CASE 3 — cv_unknown_roster_vars: the fk-ed0c5 incident scenario. A root
# bead carries gc.var.enable_sre_reliability (undeclared) instead of the real
# enable_sre. The helper must name it as unknown.
# ===========================================================================
start_case "3: cv_unknown_roster_vars flags an undeclared enable_* var (the fk-ed0c5 incident)"
export STUB_BDSHOW_JSON_fk_incident='{"id":"fk-incident","metadata":{"gc.var.enable_sre_reliability":"true","gc.var.push":"true"}}'
UNKNOWN="$(GC="$GC" bash -c "source '$LIB'; cv_unknown_roster_vars fk-incident")"
assert_eq "enable_sre_reliability" "$UNKNOWN" "names the undeclared var, ignoring non-roster vars like gc.var.push"

# ===========================================================================
# CASE 4 — cv_unknown_roster_vars: the correctly-spelled var produces no
# findings.
# ===========================================================================
start_case "4: cv_unknown_roster_vars is empty when only declared vars are set"
export STUB_BDSHOW_JSON_fk_correct='{"id":"fk-correct","metadata":{"gc.var.enable_sre":"true"}}'
UNKNOWN="$(GC="$GC" bash -c "source '$LIB'; cv_unknown_roster_vars fk-correct")"
assert_eq "" "$UNKNOWN" "no unknown vars when enable_sre is spelled correctly"

# ===========================================================================
# CASE 5 — cv_unknown_roster_vars: no roster vars set at all -> empty, not an
# error (floor-lanes-only sling).
# ===========================================================================
start_case "5: cv_unknown_roster_vars is empty when no roster vars are set"
export STUB_BDSHOW_JSON_fk_floor='{"id":"fk-floor","metadata":{"gc.var.push":"true"}}'
UNKNOWN="$(GC="$GC" bash -c "source '$LIB'; cv_unknown_roster_vars fk-floor")"
assert_eq "" "$UNKNOWN" "no unknown vars on a floor-lanes-only sling"

# ===========================================================================
# CASE 6 — cv_unknown_code_lens flags an unrecognized code_lens override but
# accepts a known one, and is empty when unset.
# ===========================================================================
start_case "6: cv_unknown_code_lens flags an unrecognized lens, accepts a known one"
export STUB_BDSHOW_JSON_fk_badlens='{"id":"fk-badlens","metadata":{"gc.var.code_lens":"con-voyage.cv-nonexistent-lens"}}'
assert_eq "con-voyage.cv-nonexistent-lens" "$(GC="$GC" bash -c "source '$LIB'; cv_unknown_code_lens fk-badlens")" "flags an unrecognized code_lens value"
export STUB_BDSHOW_JSON_fk_goodlens='{"id":"fk-goodlens","metadata":{"gc.var.code_lens":"con-voyage.cv-go-principal-engineer"}}'
assert_eq "" "$(GC="$GC" bash -c "source '$LIB'; cv_unknown_code_lens fk-goodlens")" "accepts a known code_lens value"
export STUB_BDSHOW_JSON_fk_nolens='{"id":"fk-nolens","metadata":{}}'
assert_eq "" "$(GC="$GC" bash -c "source '$LIB'; cv_unknown_code_lens fk-nolens")" "empty (not a finding) when code_lens is unset"

# ===========================================================================
# CASE 7 — cv_active_roster_vars reports a lane as active ONLY when the
# formula's own condition var (gc.var.enable_sre) is truthy — the
# misspelled-var scenario produces NO active SRE lane in the review context,
# matching what graph.v2 actually dispatched.
# ===========================================================================
start_case "7: cv_active_roster_vars reflects the formula's actual conditions, not var-name prefixes"
export STUB_BDSHOW_JSON_fk_incident2='{"id":"fk-incident2","metadata":{"gc.var.enable_sre_reliability":"true"}}'
ACTIVE="$(GC="$GC" bash -c "source '$LIB'; cv_active_roster_vars fk-incident2")"
assert_eq "" "$ACTIVE" "misspelled enable_sre_reliability does not activate the SRE lane title"

export STUB_BDSHOW_JSON_fk_correct2='{"id":"fk-correct2","metadata":{"gc.var.enable_sre":"true"}}'
ACTIVE2="$(GC="$GC" bash -c "source '$LIB'; cv_active_roster_vars fk-correct2")"
assert_eq "Con-voyage: SRE reliability review" "$ACTIVE2" "enable_sre=true activates the SRE lane title, read from the formula's own title field"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
