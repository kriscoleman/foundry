#!/usr/bin/env bash
# formula-v2-run-target.test.sh — hermetic, offline test guarding against a
# graph.v2-native formula ([[steps]] + [requires] formula_compiler) using the
# wrong brace syntax for a var-templated `gc.run_target` metadata value.
#
# Root cause (fk-5foqz): con-voyage-ci-repair.formula.toml is the only pack
# formula declaring `[requires] formula_compiler = ">=2.0.0"` and authoring
# its step with the native `[[steps]]` construct (every other formula in this
# pack, e.g. con-voyage.formula.toml, uses the higher-level `[[template]]`
# macro construct instead, which compiles/expands its own `{var}` tokens at
# `gc formula show`/cook time). Commit 71c3def converted this step's
# `gc.run_target` from `"{{implementation_target}}"` to `"{implementation_target}"`,
# reasoning by analogy from a real, but DIFFERENT, bug: a description_file
# body's `{{var}}` token rendering incorrectly at bead-dispatch time
# (fk-3h4ax, single-brace `{var}` is the correct fix there). But a
# `[[steps]]` step's `metadata` map is a distinct, compile-time Go-template
# substitution pass, not the per-bead description_file renderer — and for
# that pass, double-brace `{{var}}` is the only syntax the compiler ever
# resolves.
#
# Evidence (`strings` on the installed `gc` binary's own bundled test
# fixtures, /opt/homebrew/Cellar/gascity/*/bin/gc): every graph.v2 `[[steps]]`
# formula test asserting a var-templated `gc.run_target` value expects
# double-brace, e.g.:
#   assertEqual(step_by_id["implement"]["metadata"]["gc.run_target"], "{{implementation_target}}")
#   assertEqual(do_work_item["steps"][0]["metadata"]["gc.run_target"], "{{implementation_target}}")
#   assertEqual(same["metadata"]["gc.run_target"], "{{implementation_target}}")
# No such fixture ever expects the single-brace form. Independently,
# `gc formula show con-voyage-ci-repair` (both with and without `--var`)
# reproduces the live failure: it leaves the single-brace
# `"{implementation_target}"` completely unresolved in the compiled step
# metadata, unlike `[[template]]`-authored formulas (e.g. con-voyage's
# `main.build` step), which resolve their `{var}`-templated `gc.run_target`
# to a concrete route at show/cook time regardless of brace style used in
# their own, unrelated `[[template]]` mechanism. The single-brace form on a
# `[[steps]]` step reaches the runtime target resolver unsubstituted, which
# fails with `step %s: unknown formulas v2 target %q` on every dispatch —
# this broke every con-voyage-ci-repair PR repair for ~25h (fk-5foqz).
#
# This suite hermetically encodes the confirmed invariant so no future
# `[[steps]]`-authored formula can reintroduce the same un-instantiable
# combination without a real `gc` binary in CI (mold-validate.yml only
# installs `ailloy`, so this check simulates the confirmed resolver behavior
# instead of shelling to a real `gc formula show`).
#
# Run:  bash tests/formula-v2-run-target.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
FORMULAS_DIR="${MOLD_DIR}/pack/formulas"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

SINGLE_BRACE_VAR_PATTERN='^\{[a-zA-Z_][a-zA-Z0-9_.]*\}$'
DOUBLE_BRACE_VAR_PATTERN='^\{\{[a-zA-Z_][a-zA-Z0-9_.]*\}\}$'

# Returns 0 (true) if the given formula.toml declares a v2 compiler
# requirement ([requires] formula_compiler = ...), which graph-only
# constructs like [[steps]] must opt into.
declares_v2_requirement() {
  grep -qE '^\[requires\]' "$1" && grep -qE '^formula_compiler[[:space:]]*=' "$1"
}

# Returns 0 (true) if the given formula.toml authors its work via the native
# [[steps]] construct (as opposed to the [[template]] macro construct, which
# has its own working {var} compile-time expansion and is out of scope here).
uses_native_steps() {
  grep -qE '^\[\[steps\]\]' "$1"
}

# Prints every `metadata = { ... }` line's value for the "gc.run_target" key,
# one per line, for the given formula.toml.
run_target_values() {
  grep -oE '"gc\.run_target"[[:space:]]*=[[:space:]]*"[^"]*"' "$1" \
    | sed -E 's/^"gc\.run_target"[[:space:]]*=[[:space:]]*"([^"]*)"$/\1/'
}

# ===========================================================================
# CASE 1 — regression fixture: the exact pre-fix shape must be caught
# ===========================================================================
start_case "a [[steps]]+v2 formula with a single-brace var run_target is flagged"

FIXTURE="$(mktemp)"
cat > "$FIXTURE" <<'EOF'
formula = "fixture-v2-bug"

[requires]
formula_compiler = ">=2.0.0"

[[steps]]
id = "do-thing"
metadata = { "gc.run_target" = "{implementation_target}" }
EOF

if declares_v2_requirement "$FIXTURE" && uses_native_steps "$FIXTURE"; then
  bad=0
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    if [[ "$value" =~ $SINGLE_BRACE_VAR_PATTERN ]]; then
      bad=1
    fi
  done < <(run_target_values "$FIXTURE")
  if [ "$bad" -eq 1 ]; then
    pass "fixture (single-brace var run_target on a [[steps]]+v2 formula) correctly detected as broken"
  else
    fail "fixture should have been detected as broken but was not"
  fi
else
  fail "fixture's own shape ([[steps]] + [requires]) was not detected — test harness is broken"
fi
rm -f "$FIXTURE"

# ===========================================================================
# CASE 2 — the same var syntax, double-braced, is fine on a [[steps]]+v2 formula
# ===========================================================================
start_case "a [[steps]]+v2 formula with a double-brace var run_target is not flagged"

FIXTURE2="$(mktemp)"
cat > "$FIXTURE2" <<'EOF'
formula = "fixture-v2-ok"

[requires]
formula_compiler = ">=2.0.0"

[[steps]]
id = "do-thing"
metadata = { "gc.run_target" = "{{implementation_target}}" }
EOF

bad2=0
while IFS= read -r value; do
  [ -n "$value" ] || continue
  if [[ "$value" =~ $SINGLE_BRACE_VAR_PATTERN ]]; then
    bad2=1
  fi
done < <(run_target_values "$FIXTURE2")
if [ "$bad2" -eq 0 ]; then
  pass "fixture2 (double-brace var run_target) correctly not flagged"
else
  fail "fixture2 (double-brace var run_target) was incorrectly flagged"
fi
rm -f "$FIXTURE2"

# ===========================================================================
# CASE 3 — sweep every real pack formula for the broken combination
# ===========================================================================
start_case "no [[steps]]+v2 pack formula uses a single-brace var run_target"

formula_count=0
for formula in "${FORMULAS_DIR}"/*.formula.toml; do
  [ -f "$formula" ] || continue
  formula_count=$((formula_count + 1))
  name="$(basename "$formula")"

  if ! { declares_v2_requirement "$formula" && uses_native_steps "$formula"; }; then
    pass "$name — not a [[steps]]+v2 formula, this rule does not apply"
    continue
  fi

  bad_values=""
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    if [[ "$value" =~ $SINGLE_BRACE_VAR_PATTERN ]]; then
      bad_values="${bad_values}${value}, "
    fi
  done < <(run_target_values "$formula")

  if [ -n "$bad_values" ]; then
    fail "$name is a [[steps]]+v2 formula with a single-brace var gc.run_target (${bad_values%, }) — the compiler never resolves this form and every dispatch will hit 'unknown formulas v2 target'; use double-brace {{var}}"
  else
    pass "$name — [[steps]]+v2 formula uses only concrete or double-brace gc.run_target values"
  fi
done

if [ "$formula_count" -eq 0 ]; then
  echo "FATAL: discovered zero formulas under ${FORMULAS_DIR} — parser broken?" >&2
  exit 2
fi
echo "  (swept ${formula_count} pack formula(s))"

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
