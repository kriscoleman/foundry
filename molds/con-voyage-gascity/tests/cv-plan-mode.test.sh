#!/usr/bin/env bash
# cv-plan-mode.test.sh — hermetic, offline test for con-voyage plan mode: a
# planning phase that kicks off every journey before the first TDD round, on
# by default, which a city can turn off.
#
#   Given no setting anywhere (the default),
#   When  a journey resolves its plan mode,
#   Then  it is ON.
#
#   Given the city commits con-voyage.toml with [con_voyage] plan_mode = false,
#   When  a journey resolves its plan mode,
#   Then  it is OFF, unless that journey was slung with --var plan_mode=true.
#
#   Given CV_PLAN_MODE is set, Then it overrides the file but not the journey.
#   Given an unreadable or invalid value, Then it warns and falls through
#         (ultimately to ON: an invalid opt-out never silently skips planning).
#
#   Given the plan step skipped itself (plan mode off, or a pre-built branch),
#   When  its gate check runs, Then it passes without an artifact.
#   Given the plan step ran, Then the gate validates the gc.build.plan.v1
#         artifact like every other build-artifact gate.
#
#   And the formula wires {target}.plan between prepare-build and build.
#
# Run:  bash tests/cv-plan-mode.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PACK_DIR="${MOLD_DIR}/pack"
PLAN_MODE="${PACK_DIR}/assets/scripts/cv-plan-mode.sh"
PLAN_READY="${PACK_DIR}/assets/scripts/checks/plan-ready.sh"
FORMULA="${PACK_DIR}/formulas/con-voyage.formula.toml"
PLAN_MD="${PACK_DIR}/assets/workflows/con-voyage/main.plan.md"
BUILD_MD="${PACK_DIR}/assets/workflows/con-voyage/main.build.md"

for f in "$PLAN_MODE" "$PLAN_READY" "$FORMULA" "$PLAN_MD" "$BUILD_MD"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: expected file not found: $f" >&2
    exit 1
  fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-plan-mode-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
start_case() { echo; echo "=== CASE: $1 ==="; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qE -- "$2"; then pass "$3"; else fail "$3 (no match for /$2/)"; fi; }
assert_file_contains() { if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3 (not found verbatim in $1)"; fi; }

CITY="${SANDBOX}/city"
mkdir -p "$CITY"

# resolve [JOURNEY] — run `cv-plan-mode.sh resolve` from the city; sets OUT
# (stdout), ERR (stderr) and RC. Extra env goes in RESOLVE_ENV.
resolve() {
  local errf="${SANDBOX}/resolve.err"
  OUT="$(cd "$CITY" && env -u CV_PLAN_MODE -u CV_CON_VOYAGE_CONFIG GC_CITY="$CITY" ${RESOLVE_ENV:-} \
    bash "$PLAN_MODE" resolve "$@" 2>"$errf")"
  RC=$?
  ERR="$(cat "$errf")"
}

set_city() { printf '[con_voyage]\n%s\n' "$1" > "${CITY}/con-voyage.toml"; }

# ===========================================================================
start_case "1: nothing configured — plan mode is ON"
rm -f "${CITY}/con-voyage.toml"
resolve
assert_eq "0" "$RC" "resolve exits 0"
assert_eq "on" "$OUT" "default is on"
assert_contains "$ERR" "source: default" "names the default as the source"

start_case "1b: an empty journey value means 'inherit', not off"
resolve ""
assert_eq "on" "$OUT" "empty journey var inherits the default"

# ===========================================================================
start_case "2: city opts out in con-voyage.toml"
set_city 'plan_mode = false'
resolve
assert_eq "off" "$OUT" "plan_mode = false turns it off"
assert_contains "$ERR" "con-voyage.toml" "names the file as the source"

start_case "2b: the file shares [con_voyage] with other settings (max_concurrent)"
set_city $'max_concurrent = 2\nplan_mode = false'
resolve
assert_eq "off" "$OUT" "reads plan_mode alongside max_concurrent"

start_case "2c: plan_mode = true in the file is on"
set_city 'plan_mode = true'
resolve
assert_eq "on" "$OUT" "explicit true is on"

start_case "2d: a file without plan_mode is the default"
set_city 'max_concurrent = 1'
resolve
assert_eq "on" "$OUT" "absent key is on"

# ===========================================================================
start_case "3: a journey var beats the city setting, both ways"
set_city 'plan_mode = false'
resolve true
assert_eq "on" "$OUT" "--var plan_mode=true re-enables planning for one journey"
assert_contains "$ERR" "source: journey" "names the journey var as the source"
set_city 'plan_mode = true'
resolve false
assert_eq "off" "$OUT" "--var plan_mode=false skips planning for one journey"
for v in off no 0 OFF; do
  resolve "$v"
  assert_eq "off" "$OUT" "journey value '$v' is off"
done
for v in on yes 1 TRUE; do
  resolve "$v"
  assert_eq "on" "$OUT" "journey value '$v' is on"
done

# ===========================================================================
start_case "4: CV_PLAN_MODE overrides the file, not the journey"
set_city 'plan_mode = true'
RESOLVE_ENV="CV_PLAN_MODE=false" resolve
assert_eq "off" "$OUT" "env off beats file on"
assert_contains "$ERR" "source: CV_PLAN_MODE" "names the env var as the source"
RESOLVE_ENV="CV_PLAN_MODE=false" resolve true
assert_eq "on" "$OUT" "journey on beats env off"

start_case "4b: CV_CON_VOYAGE_CONFIG points at another file"
printf '[con_voyage]\nplan_mode = false\n' > "${SANDBOX}/other.toml"
rm -f "${CITY}/con-voyage.toml"
RESOLVE_ENV="CV_CON_VOYAGE_CONFIG=${SANDBOX}/other.toml" resolve
assert_eq "off" "$OUT" "reads the overridden settings path"

# ===========================================================================
start_case "5: invalid values warn and fall through to ON"
set_city 'plan_mode = "sometimes"'
resolve
assert_eq "on" "$OUT" "a non-boolean file value is not an opt-out"
assert_contains "$ERR" "WARNING.*plan_mode" "and warns"
printf 'this is [not toml\n' > "${CITY}/con-voyage.toml"
resolve
assert_eq "on" "$OUT" "an unparseable file is not an opt-out"
assert_contains "$ERR" "WARNING" "and warns"
rm -f "${CITY}/con-voyage.toml"
resolve maybe
assert_eq "on" "$OUT" "an invalid journey value falls through"
assert_contains "$ERR" "WARNING.*maybe" "and warns with the bad value"

start_case "6: misuse fails with usage"
OUT="$(bash "$PLAN_MODE" bogus 2>&1)"; RC=$?
assert_eq "2" "$RC" "unknown subcommand exits 2"

# ===========================================================================
# plan-ready.sh — the plan step's gate. bd stub serves `bd show <id> --json`
# from $STUB_STATE/<id>.json.
# ===========================================================================
cat > "${STUBDIR}/bd" <<'BD_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_STATE}/bd.log"
[ "${1:-}" = "show" ] || exit 0
f="${STUB_STATE}/${2}.json"
[ -f "$f" ] || exit 1
cat "$f"
BD_STUB
chmod +x "${STUBDIR}/bd"

STATE="${SANDBOX}/state"
mkdir -p "$STATE"
CHECKS="${SANDBOX}/rig/.gc/scripts/checks"
mkdir -p "$CHECKS"
cp "${PACK_DIR}/assets/scripts/checks/"*.sh "$CHECKS/"
cp "${PACK_DIR}/assets/scripts/validate_build_artifact.py" "${SANDBOX}/rig/.gc/scripts/"
mkdir -p "${SANDBOX}/rig/schemas/build"
cp "${PACK_DIR}/assets/schemas/build/"*.yaml "${SANDBOX}/rig/schemas/build/"

# step_bead ID ROOT — the plan step's bead, carrying its gate metadata.
step_bead() {
  printf '{"id":"%s","metadata":{"gc.root_bead_id":"%s","gc.build.artifact_schema":"gc.build.plan.v1","gc.build.artifact_path_keys":"gc.build.plan_path"}}' \
    "$1" "$2" > "${STATE}/$1.json"
}
# root_bead ID META_JSON
root_bead() { printf '{"id":"%s","metadata":%s}' "$1" "$2" > "${STATE}/$1.json"; }

gate() {
  OUT="$(cd "${SANDBOX}/rig" && PATH="${STUBDIR}:${PATH}" STUB_STATE="$STATE" GC_BEAD_ID="$1" \
    bash "${CHECKS}/plan-ready.sh" 2>&1)"
  RC=$?
}

start_case "7: a skipped plan step passes its gate with no artifact"
step_bead st-1 rt-1
root_bead rt-1 '{"gc.plan.skipped":"true","gc.plan.skip_reason":"plan mode off (source: con-voyage.toml)"}'
gate st-1
assert_eq "0" "$RC" "gate passes"
assert_contains "$OUT" "skipped" "says the plan was skipped"

start_case "7b: a plan step that ran but recorded no artifact fails its gate"
root_bead rt-1 '{}'
gate st-1
assert_eq "1" "$RC" "gate fails"
assert_contains "$OUT" "gc.build.plan_path" "names the missing artifact key"

start_case "7c: a valid gc.build.plan.v1 artifact passes the gate"
PLAN_FILE="${SANDBOX}/rig/.gc/build/rt-1/plan.md"
mkdir -p "$(dirname "$PLAN_FILE")"
cat > "$PLAN_FILE" <<'PLAN'
---
schema: gc.build.plan.v1
workflow: {id: rt-1, formula: con-voyage}
methodology: {pack: con-voyage-gascity, name: con-voyage}
producer: {formula: con-voyage, stage: plan, attempt: 1}
status: approved
trace:
  upstream:
    - path: beads/fk-1
      hash: bead:fk-1
      ids: [AC-001]
  coverage:
    - id: AC-001
      status: covered
---

## Summary

Add the thing.

## Current System

The thing is missing.

## Proposed Implementation

Add it.

## Non-Goals

Everything else.

## Verification

bash tests/thing.test.sh

| ID | Status |
| --- | --- |
| AC-001 | covered |
PLAN
root_bead rt-1 "{\"gc.build.plan_path\":\"${PLAN_FILE}\"}"
gate st-1
assert_eq "0" "$RC" "gate passes"
assert_contains "$OUT" "build artifact valid" "validated by the shared build-artifact gate"

start_case "7d: an invalid plan artifact fails the gate"
sed -i 's/^## Non-Goals$/## Goals/' "$PLAN_FILE"
gate st-1
assert_eq "1" "$RC" "gate fails"
assert_contains "$OUT" "Non-Goals" "names the missing section"

# ===========================================================================
start_case "8: formula wiring — plan runs between prepare-build and build"
assert_file_contains "$FORMULA" 'id = "{target}.plan"' "plan node is declared"
assert_file_contains "$FORMULA" '[vars.plan_mode]' "plan_mode var is declared"
plan_block="$(awk '/^id = "\{target\}\.plan"$/{f=1} f&&/^\[\[template\]\]/{exit} f' "$FORMULA")"
assert_contains "$plan_block" 'needs = \["\{target\}\.prepare-build"\]' "plan needs prepare-build"
assert_contains "$plan_block" '"gc.run_target" = "\{implementation_target\}"' "plan runs on the implementor"
assert_contains "$plan_block" '"gc.build.artifact_schema" = "gc.build.plan.v1"' "plan declares the plan schema"
assert_contains "$plan_block" '"gc.build.artifact_path_keys" = "gc.build.plan_path"' "plan records gc.build.plan_path"
assert_contains "$plan_block" 'path = "\.gc/scripts/checks/plan-ready\.sh"' "plan is gated by plan-ready.sh"
assert_contains "$plan_block" 'description_file = "\.\./assets/workflows/con-voyage/main\.plan\.md"' "plan points at main.plan.md"
build_block="$(awk '/^id = "\{target\}\.build"$/{f=1} f&&/^\[\[template\]\]/{exit} f' "$FORMULA")"
assert_contains "$build_block" 'needs = \["\{target\}\.prepare-build", "\{target\}\.plan"\]' "build needs both prepare-build and plan"
plan_default="$(awk '/^\[vars\.plan_mode\]/{f=1;next} f&&/^default/{print; exit}' "$FORMULA")"
assert_eq 'default = ""' "$plan_default" "the journey var defaults to empty (inherit the city setting, on by default)"
if [ -x "$PLAN_MODE" ] && [ -x "$PLAN_READY" ]; then pass "new scripts are executable"; else fail "cv-plan-mode.sh and plan-ready.sh must be executable"; fi

start_case "9: the plan step resolves its mode through cv-plan-mode.sh and skips on a pre-built branch"
assert_file_contains "$PLAN_MD" 'cv-plan-mode.sh' "plan step calls cv-plan-mode.sh"
assert_file_contains "$PLAN_MD" 'gc.var.plan_mode' "plan step reads the journey var from the workflow root"
assert_file_contains "$PLAN_MD" 'gc.build.short_circuited' "plan step checks for a pre-built branch"
assert_file_contains "$PLAN_MD" 'gc.plan.skipped=true' "plan step records a skip on the workflow root"
assert_file_contains "$PLAN_MD" 'gc.build.plan_path' "plan step records its artifact path"
assert_file_contains "$PLAN_MD" 'INVEST' "plan step evaluates the work against INVEST"
assert_file_contains "$PLAN_MD" 'Given' "plan step expresses acceptance as BDD"

start_case "10: the build step implements against the plan"
assert_file_contains "$BUILD_MD" 'gc.build.plan_path' "build reads the plan path"
assert_file_contains "$BUILD_MD" 'Con-voyage: plan the change' "build checks the plan step's outcome by its title"
assert_file_contains "$FORMULA" 'title = "Con-voyage: plan the change"' "and that title matches the formula"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED: ${FAILURES} assertion(s)" >&2
  exit 1
fi
echo "ALL CASES PASSED"
