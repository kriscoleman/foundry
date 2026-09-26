#!/usr/bin/env bash
# model-tiers.test.sh — hermetic, offline test pinning the pack's model-tier
# architecture (see README.md "Model tiers").
#
# THE CONTRACT BEING PINNED:
#   1. Every cv-* reviewer agent binds to one of the three pack-shipped tier
#      providers — cv-review-light, cv-review-standard, or
#      cv-review-intensive — never to a bare model name or a city-defined
#      provider the pack cannot guarantee exists (the pre-tier pack pinned
#      `provider = "opus"`, which silently required every consuming city to
#      define an `opus` provider).
#   2. pack.toml declares ALL THREE tier providers, each based on
#      builtin:claude with a concrete default model, so the pack is
#      self-contained AND claude-first: casting it into any city yields
#      working reviewers with no city changes and no opencode account
#      required. The shipped defaults are the claude side of the three-tier
#      equivalency (haiku<->minimax-m3, sonnet<->glm-5p3-flash,
#      opus<->kimi-k3) — see README.md "Model tiers" for the opt-in
#      opencode + fireworks mode a city can switch to instead.
#   3. The tier split is INTENTIONAL, not accidental — lens membership in
#      each tier is pinned explicitly so a drive-by edit moving a lens
#      across tiers is a visible, reviewable decision.
#   4. The con-voyage-rate-limit-lookout order ships pointed at its script but
#      OPT-IN by default (trigger = "manual") — the circuit breaker only
#      ever fires once a city deliberately overrides its trigger back to
#      "cooldown". Fallback pools stay wired to the opencode equivalents of
#      the claude tiers (opus<->large, sonnet<->medium, haiku<->small)
#      regardless of mode, since the breaker's whole job is failing claude
#      over to opencode.
#
# Everything here is a DEFAULT — a city may rebind a tier to any provider/
# model by redeclaring the provider in city.toml, or opt into the pack's
# opencode + fireworks mode wholesale. This test pins the pack's shipped
# defaults only.
#
# Run:  bash tests/model-tiers.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PACK_DIR="${MOLD_DIR}/pack"

if [ ! -f "${PACK_DIR}/pack.toml" ]; then
  echo "FATAL: pack.toml not found at ${PACK_DIR}/pack.toml" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

# ---------------------------------------------------------------------------
start_case "every cv-* reviewer agent binds to a declared tier provider"
# ---------------------------------------------------------------------------
agent_count=0
for agent_toml in "${PACK_DIR}"/agents/*/agent.toml; do
  [ -f "$agent_toml" ] || continue
  agent_count=$((agent_count+1))
  name="$(basename "$(dirname "$agent_toml")")"
  provider="$(grep -E '^provider *=' "$agent_toml" | head -1 | sed -E 's/^provider *= *"([^"]+)".*/\1/')"
  case "$provider" in
    cv-review-intensive|cv-review-standard|cv-review-light)
      pass "${name} -> ${provider}" ;;
    *)
      fail "${name} has provider '${provider}' (expected cv-review-intensive, cv-review-standard, or cv-review-light)" ;;
  esac
done
if [ "$agent_count" -eq 0 ]; then
  echo "FATAL: no agents found under ${PACK_DIR}/agents" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
start_case "the tier split is intentional (pinned lens membership)"
# ---------------------------------------------------------------------------
EXPECTED_INTENSIVE="cv-api-platform-contract cv-code-reviewer cv-data-db-engineer cv-frontend-principal-engineer cv-go-principal-engineer cv-security-reviewer"
EXPECTED_STANDARD="cv-compliance-privacy cv-dev-ex-reviewer cv-founder-cto cv-product-owner cv-qa-test-engineer cv-sre-reliability"
EXPECTED_LIGHT="cv-design-ux cv-documentation cv-marketing cv-standards-janitor"

check_membership() {
  local tier="$1" expected="$2"
  for name in $expected; do
    file="${PACK_DIR}/agents/${name}/agent.toml"
    if [ ! -f "$file" ]; then
      fail "${name}: missing agent.toml (expected in ${tier})"
      continue
    fi
    if grep -qE "^provider *= *\"${tier}\"" "$file"; then
      pass "${name} in ${tier}"
    else
      fail "${name} expected in ${tier}"
    fi
  done
}
check_membership cv-review-intensive "$EXPECTED_INTENSIVE"
check_membership cv-review-standard "$EXPECTED_STANDARD"
check_membership cv-review-light "$EXPECTED_LIGHT"

# ---------------------------------------------------------------------------
start_case "pack.toml declares all three tier providers on builtin:claude with default models"
# ---------------------------------------------------------------------------
# Parse the real TOML (python3 tomllib) — grep-based block extraction is too
# fragile around nested [providers.<tier>.option_defaults] sub-tables.
# Unlike the opt-in opencode mode (README.md "Model tiers"), builtin:claude's
# haiku/sonnet/opus aliases are already known choices in gc's builtin catalog,
# so — unlike opencode's fireworks pins — no options_schema re-declaration is
# needed here.
check_provider_block() {
  local tier="$1" model="$2"
  result="$(python3 - "$tier" "$model" "${PACK_DIR}/pack.toml" <<'PY'
import sys, tomllib
tier, model, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'rb') as fh:
    data = tomllib.load(fh)
prov = (data.get('providers') or {}).get(tier)
if prov is None:
    print('missing')
    raise SystemExit(0)
if prov.get('base') != 'builtin:claude':
    print('bad-base:' + str(prov.get('base')))
    raise SystemExit(0)
if (prov.get('option_defaults') or {}).get('model') != model:
    print('bad-model:' + str((prov.get('option_defaults') or {}).get('model')))
    raise SystemExit(0)
print('ok')
PY
)"
  case "$result" in
    ok)                    pass "[providers.${tier}] claude tier, model=${model}" ;;
    missing)               fail "pack.toml missing [providers.${tier}]" ;;
    bad-base:*|bad-model:*) fail "[providers.${tier}] ${result}" ;;
    *)                     fail "[providers.${tier}] unexpected parse result: ${result}" ;;
  esac
}
check_provider_block cv-review-intensive "opus"
check_provider_block cv-review-standard "sonnet"
check_provider_block cv-review-light "haiku"

# ---------------------------------------------------------------------------
start_case "the con-voyage-rate-limit-lookout order ships, city-scoped, with fallback pools wired"
# ---------------------------------------------------------------------------
ORDER="${PACK_DIR}/orders/con-voyage-rate-limit-lookout.toml"
if [ ! -f "$ORDER" ]; then
  fail "orders/con-voyage-rate-limit-lookout.toml missing"
else
  if grep -qF 'exec = "$PACK_DIR/assets/scripts/con-voyage-rate-limit-lookout.sh"' "$ORDER"; then
    pass "order execs the lookout script"
  else
    fail "order does not exec con-voyage-rate-limit-lookout.sh"
  fi
  if grep -qE '^scope *= *"city"' "$ORDER"; then
    pass "order is city-scoped (one lookout per city, not per rig)"
  else
    fail "order must be scope = \"city\" — per-rig instances would duplicate handoffs"
  fi
  if grep -qE '^trigger *= *"manual"' "$ORDER"; then
    pass "order defaults to trigger = \"manual\" (opt-in — a city overrides to \"cooldown\" to enable)"
  else
    fail "order must default to trigger = \"manual\" so the circuit breaker is opt-in, not default-on"
  fi
  if grep -qF 'CV_LOOKOUT_FALLBACK_LARGE_POOL = "kimi-k3"' "$ORDER"; then
    pass "large fallback pool default is kimi-k3 (opus-equivalent)"
  else
    fail "large fallback pool default mismatch"
  fi
  if grep -qF 'CV_LOOKOUT_FALLBACK_MEDIUM_POOL = "glm-5p3-flash"' "$ORDER"; then
    pass "medium fallback pool default is glm-5p3-flash (sonnet-equivalent)"
  else
    fail "medium fallback pool default mismatch"
  fi
  if grep -qF 'CV_LOOKOUT_FALLBACK_SMALL_POOL = "minimax-m3"' "$ORDER"; then
    pass "small fallback pool default is minimax-m3 (haiku-equivalent)"
  else
    fail "small fallback pool default mismatch"
  fi
  if [ -f "${PACK_DIR}/assets/scripts/con-voyage-rate-limit-lookout.sh" ]; then
    pass "lookout script exists at the order's exec path"
  else
    fail "lookout script missing at assets/scripts/con-voyage-rate-limit-lookout.sh"
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
