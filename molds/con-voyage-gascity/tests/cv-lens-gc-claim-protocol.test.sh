#!/usr/bin/env bash
# cv-lens-gc-claim-protocol.test.sh — hermetic, offline test that every
# con-voyage review lens inherits gascity's standard worker startup-claim
# protocol (fk-famif).
#
# ROOT CAUSE: the cv-* lens prompts never told a pool session how to get its
# work — zero mentions of `gc hook --claim` anywhere in pack/agents/cv-*/. A
# haiku/sonnet session slung into one of these roles only claims its routed
# bead if the model improvises; left to the prompt alone, it sits idle
# ("what should I evaluate?"). gascity's own first-party role workers avoid
# this by opening every prompt with a Startup Claim Protocol that runs
# `gc hook --claim --json` first and drains cleanly on no work.
#
# FIX (GC-METH-012, the gascity-packs derived-pack contract — see
# tests/test_derived_pack_compatibility.py and
# tests/test_formula_assets.py::test_third_party_agents_include_gc_claim_protocol
# in the pinned gascity-packs checkout, city.toml sha 3b3b89f2011e06d84459aa7-
# bea1552382f13930a): don't hand-write a claim section. Every third-party
# agent prompt includes the shared fragment by reference exactly once
# (`{{ template "gc-role-worker" . }}`), and the pack vendors a byte-identical
# copy of gascity's roles/prompts/shared/gc-role-worker.md.tmpl at
# pack/template-fragments/gc-role-worker.template.md. This suite asserts both
# halves of that contract, the same DRY-by-reference way
# cv-code-lens-hardening.test.sh asserts the code-lens hardening fragment.
#
# The byte-identity check is against a vendored sha256 checksum file
# (gc-role-worker.upstream.sha256) recording the upstream gascity-packs sha
# and source path, not a live read of the gc pack cache — CI has no gc cache
# and must stay hermetic/offline.
#
# Run:  bash tests/cv-lens-gc-claim-protocol.test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
AGENTS_DIR="${MOLD_DIR}/pack/agents"
FRAGMENT="${MOLD_DIR}/pack/template-fragments/gc-role-worker.template.md"
CHECKSUM_FILE="${MOLD_DIR}/pack/template-fragments/gc-role-worker.upstream.sha256"
INCLUDE_TOKEN='{{ template "gc-role-worker" . }}'

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

start_case "the vendored fragment exists and defines the named template"
if [ ! -f "$FRAGMENT" ]; then
  echo "  FAIL: fragment not found at $FRAGMENT" >&2
  FAILURES=$((FAILURES+1))
else
  if grep -qF '{{ define "gc-role-worker" -}}' "$FRAGMENT"; then
    echo "  PASS: fragment defines the gc-role-worker named template"
  else
    echo "  FAIL: fragment does not open with {{ define \"gc-role-worker\" -}}" >&2
    FAILURES=$((FAILURES+1))
  fi
  if grep -qF '`gc hook --claim --json` is the only permitted discovery source' "$FRAGMENT"; then
    echo "  PASS: fragment carries the Startup Claim Protocol text"
  else
    echo "  FAIL: fragment is missing the Startup Claim Protocol text" >&2
    FAILURES=$((FAILURES+1))
  fi
fi

start_case "the fragment is byte-identical to the pinned gascity-packs upstream source"
if [ ! -f "$CHECKSUM_FILE" ]; then
  echo "  FAIL: checksum/provenance file not found at $CHECKSUM_FILE" >&2
  FAILURES=$((FAILURES+1))
elif [ ! -f "$FRAGMENT" ]; then
  echo "  FAIL: cannot checksum a fragment that does not exist" >&2
  FAILURES=$((FAILURES+1))
else
  recorded_sha="$(grep -oE '^[0-9a-f]{64}' "$CHECKSUM_FILE" | head -1)"
  if [ -z "$recorded_sha" ]; then
    echo "  FAIL: no sha256 hash found in $CHECKSUM_FILE" >&2
    FAILURES=$((FAILURES+1))
  else
    actual_sha="$(sha256_of "$FRAGMENT")"
    if [ "$actual_sha" = "$recorded_sha" ]; then
      echo "  PASS: fragment sha256 matches the recorded upstream checksum ($actual_sha)"
    else
      echo "  FAIL: fragment sha256 ($actual_sha) does not match recorded upstream checksum ($recorded_sha) — fragment drifted from gascity-packs source" >&2
      FAILURES=$((FAILURES+1))
    fi
  fi
  if grep -q 'gascity-packs' "$CHECKSUM_FILE" && grep -q 'gascity/roles/prompts/shared/gc-role-worker.md.tmpl' "$CHECKSUM_FILE"; then
    echo "  PASS: checksum file records upstream source repo and path"
  else
    echo "  FAIL: checksum file is missing upstream provenance (source repo/path)" >&2
    FAILURES=$((FAILURES+1))
  fi
fi

start_case "every cv-* lens prompt includes the shared claim-protocol fragment by reference, exactly once"
lens_count=0
for agent_dir in "${AGENTS_DIR}"/cv-*; do
  [ -d "$agent_dir" ] || continue
  lens_count=$((lens_count+1))
  lens="$(basename "$agent_dir")"
  prompt="${agent_dir}/prompt.template.md"
  if [ ! -f "$prompt" ]; then
    echo "  FAIL: ${lens} has no prompt.template.md" >&2
    FAILURES=$((FAILURES+1))
    continue
  fi
  occurrences="$(grep -oF "$INCLUDE_TOKEN" "$prompt" | wc -l | tr -d ' ')"
  if [ "$occurrences" -eq 1 ]; then
    echo "  PASS: ${lens} includes the gc-role-worker fragment exactly once"
  else
    echo "  FAIL: ${lens} includes the gc-role-worker fragment ${occurrences} time(s), expected exactly 1" >&2
    FAILURES=$((FAILURES+1))
  fi
done

if [ "$lens_count" -eq 0 ]; then
  echo "FATAL: discovered zero cv-* lens agents under ${AGENTS_DIR} — glob broken?" >&2
  exit 2
fi
echo "  (checked ${lens_count} cv-* lens agents)"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
