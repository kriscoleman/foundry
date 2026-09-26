#!/usr/bin/env bash
# render-placeholder-braces.test.sh — hermetic, offline test that every
# graph.v2 description_file asset in this pack uses the renderer's REAL
# single-brace token syntax (`{var}`), not a Go-template-looking `{{var}}`.
#
# Why this matters (fk-0yrc0): a formula-dispatched description_file's bare
# `{{var}}` token is NOT substituted whole. The live renderer matches the
# inner single-brace pattern and swaps only that, leaving the outer literal
# braces behind — confirmed directly from a real dispatched bead
# (foundry-kc/gc.implementation-worker-2 closing fk-3h4ax, 2026-09-25): the
# stored bead description read `(review {{convoy_id}})` in the template and
# rendered as `(review {fk-gnryc})` in the actual bead body — stray braces
# both sides, not a clean substitution. The correct, working form used
# throughout this pack for real functional substitution is single-brace
# (e.g. `id = "{target}.build"`, `metadata = { "gc.run_target" =
# "{implementation_target}" }` in con-voyage.formula.toml).
#
# `{{var}}` is legitimate in two places in this pack, both formula.toml
# compile-time mechanisms distinct from per-step description_file token
# substitution:
#   1. A `condition` field (graph.v2's compile-time presence/equality test,
#      e.g. `condition = """{{enable_dev_ex}}"""` in con-voyage.formula.toml).
#   2. A native `[[steps]]` (graph.v2, `[requires] formula_compiler`) step's
#      `gc.run_target` metadata value, when it references a formula var.
#      fk-5foqz: the single-brace form here (as this file originally, and
#      incorrectly, recommended) is NEVER resolved by the compiler for a
#      `[[steps]]`-authored step — confirmed by `gc formula show` leaving it
#      untouched, and by every `gc.run_target` test fixture bundled in the
#      installed `gc` binary itself expecting double-brace for this exact
#      field (`strings` on `gc`: `assertEqual(...["gc.run_target"],
#      "{{implementation_target}}")`, repeated across half a dozen fixtures,
#      never single-brace). con-voyage.formula.toml's `main.build` step looks
#      similar but is authored via the different `[[template]]` macro
#      construct, whose own `{var}` expansion at show/cook time is unrelated
#      to `[[steps]]` metadata templating — this is why the two constructs
#      need opposite brace styles for the "same-looking" field.
#      `formula-v2-run-target.test.sh` owns this specific invariant in
#      detail; this suite's CASE 3 only carves out the narrow exception so it
#      does not fight that suite over the same field.
# This suite never touches formula.toml condition fields; it only sweeps
# description_file assets (where no such mechanism exists) plus, in CASE 3,
# a narrow check of formula.toml metadata fields for the historical bug class.
#
# Two independent checks:
#   1. RENDER — simulate the confirmed real substitution rule against the
#      originally-reported line and assert the output has no stray brace
#      around the substituted id (fails on the pre-fix template, passes on
#      the fixed one).
#   2. SWEEP — discover every description_file from the formulas' OWN
#      description_file lists (not a hand-maintained list, same pattern as
#      agents-contract.test.sh) and assert none contains a bare `{{name}}`
#      token, so a future regression anywhere in the mold fails here instead
#      of shipping a silently-broken bead body.
#
# Run:  bash tests/render-placeholder-braces.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

# ---------------------------------------------------------------------------
# Simulates the renderer's REAL, confirmed behavior: a literal, non-nested
# `{name}` substring match-and-replace. Given "$@" as NAME=VALUE pairs, swaps
# every `{NAME}` occurrence in the template with VALUE. Applied to a
# `{{name}}` (double-brace) input, this reproduces the real bug: it matches
# the INNER `{name}` substring and leaves the outer literal braces behind —
# exactly what fk-3h4ax's stored bead body showed.
# ---------------------------------------------------------------------------
render_single_brace() {
  local out="$1"; shift
  local pair name value
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    out="${out//\{${name}\}/${value}}"
  done
  printf '%s' "$out"
}

# ===========================================================================
# CASE 1 — render the originally-reported line, both pre-fix and post-fix
# ===========================================================================
start_case "apply-review-findings commit example renders with no stray braces"

PRE_FIX_LINE='git commit -m "fix: <brief description of the review fix> (review {{convoy_id}})"'
POST_FIX_FILE="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.apply-review-findings.md"

if [ ! -f "$POST_FIX_FILE" ]; then
  echo "FATAL: template under test not found at ${POST_FIX_FILE}" >&2
  exit 2
fi

post_fix_line="$(grep -F 'git commit -m "fix: <brief description of the review fix>' "$POST_FIX_FILE")"

pre_fix_rendered="$(render_single_brace "$PRE_FIX_LINE" "convoy_id=fk-sbr3z")"
post_fix_rendered="$(render_single_brace "$post_fix_line" "convoy_id=fk-sbr3z")"

case "$pre_fix_rendered" in
  *'{fk-sbr3z}'*)
    pass "pre-fix template reproduces the reported bug when rendered (stray braces: ${pre_fix_rendered})" ;;
  *)
    fail "expected the PRE-FIX fixture to reproduce stray braces around the id — test fixture is wrong (got: ${pre_fix_rendered})" ;;
esac

case "$post_fix_rendered" in
  *'{fk-sbr3z}'*)
    fail "current template still renders with a stray brace around the id: ${post_fix_rendered}" ;;
  *'fk-sbr3z'*)
    pass "current template renders cleanly: ${post_fix_rendered}" ;;
  *)
    fail "current template did not substitute convoy_id at all: ${post_fix_rendered}" ;;
esac

# ===========================================================================
# CASE 2 — sweep every formula-dispatched description_file for the bug class
# ===========================================================================
start_case "no description_file asset contains a bare {{var}} token"

BUG_PATTERN='\{\{[a-zA-Z_][a-zA-Z0-9_.]*\}\}'
node_count=0

for formula in "${MOLD_DIR}"/pack/formulas/*.toml; do
  formula_dir="$(dirname "$formula")"
  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    node_count=$((node_count + 1))
    asset="${formula_dir}/${rel_path}"
    if [ ! -f "$asset" ]; then
      fail "$(basename "$formula"): $(basename "$rel_path") — description_file does not exist"
      continue
    fi
    if grep -qE "$BUG_PATTERN" "$asset"; then
      hit="$(grep -noE "$BUG_PATTERN" "$asset" | head -1)"
      fail "$(basename "$formula"): $(basename "$rel_path") — contains a double-brace token (${hit}); use single-brace {var}"
    else
      pass "$(basename "$formula"): $(basename "$rel_path") — no double-brace tokens"
    fi
  done < <(grep -oE 'description_file *= *"[^"]+"' "$formula" | sed -E 's/description_file *= *"([^"]+)"/\1/')
done

if [ "$node_count" -eq 0 ]; then
  echo "FATAL: discovered zero description_file entries across pack/formulas/*.toml — parser broken?" >&2
  exit 2
fi
echo "  (swept ${node_count} formula-dispatched description_file assets)"

# ===========================================================================
# CASE 3 — no formula.toml metadata field uses the double-brace bug form,
# EXCEPT a native [[steps]]+v2 step's gc.run_target (fk-5foqz: the only field
# where double-brace is the correct, compiler-resolved form — see the header
# comment and formula-v2-run-target.test.sh for the full evidence). The
# condition-field mechanism is a separate, legitimate use of {{var}} and must
# be left untouched too — this asserts all three cases.
# ===========================================================================
start_case "formula.toml metadata fields use single-brace substitution (run_target on a [[steps]]+v2 formula excepted); condition fields keep double-brace"

metadata_bug_hits=0
for formula in "${MOLD_DIR}"/pack/formulas/*.toml; do
  is_v2_steps=false
  if grep -qE '^\[requires\]' "$formula" && grep -qE '^formula_compiler[[:space:]]*=' "$formula" \
      && grep -qE '^\[\[steps\]\]' "$formula"; then
    is_v2_steps=true
  fi

  if grep -nE '"gc\.[a-zA-Z_.]+"[[:space:]]*=[[:space:]]*"\{\{[a-zA-Z_]' "$formula" >/tmp/rpb-metadata-hits.$$ 2>/dev/null; then
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      if [ "$is_v2_steps" = true ] && [[ "$hit" == *'"gc.run_target"'* ]]; then
        pass "$(basename "$formula") — double-braced gc.run_target on a [[steps]]+v2 formula (expected, compiler-resolved form): ${hit}"
      else
        metadata_bug_hits=$((metadata_bug_hits + 1))
        fail "$(basename "$formula") has a double-braced metadata value: ${hit}"
      fi
    done < /tmp/rpb-metadata-hits.$$
  fi
  rm -f /tmp/rpb-metadata-hits.$$
done
[ "$metadata_bug_hits" -eq 0 ] && pass "no formula.toml metadata field uses an unexpected double-braced value"

condition_field_count=0
for formula in "${MOLD_DIR}"/pack/formulas/*.toml; do
  n="$(grep -cE '^condition = """\{\{[a-zA-Z_]' "$formula" 2>/dev/null || true)"
  condition_field_count=$((condition_field_count + ${n:-0}))
done
if [ "$condition_field_count" -gt 0 ]; then
  pass "condition-field {{var}} presence/equality tests are still intact (${condition_field_count} found) — legitimate mechanism left untouched"
else
  fail "expected at least one condition = \"\"\"{{var}}\"\"\" field (con-voyage.formula.toml roster toggles) — did the sweep touch a legitimate mechanism?"
fi

# ===========================================================================
# CASE 4 — no shipped workflow asset filename still carries a literal
# `{target}` placeholder (fk-4q6ib). gc resolves `{target}` in a formula's
# `id` field at cook time (confirmed empirically: a real dispatched bead's
# gc.step_id came out `main.build`, not `{target}.build`) and applies the
# identical resolution when it computes the "Resolved prompt file" path it
# reports for a too-large-to-inline description_file (confirmed: that same
# bead's reported path was `.../main.build.md`). But this pack's `pack/`
# output is cast with `process: false` (README: "Authoring note: the pack is
# a raw pass-through") — ailloy copies every file byte-for-byte, including
# its NAME, so a file still literally named `{target}.build.md` on disk can
# never match the `main.build.md` gc actually looks for. This is a
# filesystem-naming invariant, independent of any one formula.toml's current
# content, so it also catches a new asset added later with the old habit.
# ===========================================================================
start_case "no workflow asset filename still contains a literal {target} placeholder"

stray_names=0
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  case "$base" in
    *'{target}'*)
      fail "asset ships with a literal {target} in its filename: ${f#"${MOLD_DIR}"/} — gc resolves {target} to the real target (e.g. 'main') before computing the path it looks for; this filename can never match"
      stray_names=$((stray_names + 1))
      ;;
  esac
done < <(find "${MOLD_DIR}/pack/assets/workflows" -type f -print0)

[ "$stray_names" -eq 0 ] && pass "no workflow asset filename contains a literal {target}"

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
