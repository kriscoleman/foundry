#!/usr/bin/env bash
# cv-verify-model-mode.sh — post-recast/post-edit drift check for the pack's
# claude/opencode reviewer model tiers (README.md "Model tiers").
#
# WHY: the opt-in opencode + fireworks mode lives ENTIRELY in the city's own
# city.toml (README.md "Switching to opencode + fireworks mode") — ailloy
# cannot patch city.toml, so casting/recasting the pack itself can never
# touch it (verified empirically: an existing city.toml, opencode overrides
# included, comes out byte-identical after `ailloy cast`). But city.toml has
# no pack-side backup — if anything ELSE ever rewrites it wholesale (a
# config-normalizing tool, a manual edit, a botched merge), the three tier
# overrides are gone with no warning, and reviewers silently fall back to the
# pack's claude defaults. This script makes that drift LOUD instead of
# silent: point it at the mode a city expects and it confirms all three
# tiers actually resolve there right now.
#
# Usage:
#   cv-verify-model-mode.sh <claude|opencode>
#
# Exit codes:
#   0 — all three tiers (cv-review-light/-standard/-intensive) resolve to the
#       expected mode. Prints one OK line per tier.
#   1 — usage error, a tier isn't resolvable at all (pack not imported for
#       this city?), or at least one tier resolved to a DIFFERENT mode than
#       expected. Prints the drifted/missing tier(s) and points back at the
#       README section for the expected mode's ready-to-paste block.
#
# Environment:
#   GC        gc binary to invoke (default: gc)
#   GC_CITY   city directory passed to every --city call (default: .)
#
# Requires: bash 4+, gc CLI (or a stub honoring the same --city config
# explain --provider --json contract), python3.

set -uo pipefail

GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"

TIERS="cv-review-light cv-review-standard cv-review-intensive"

die() {
  echo "cv-verify-model-mode: BLOCKED — $*"
  exit 1
}

MODE="${1:-}"
case "$MODE" in
  claude|opencode) ;;
  *) die "usage: cv-verify-model-mode.sh <claude|opencode> (got '${MODE}')" ;;
esac

FAILURES=0
for tier in $TIERS; do
  RAW="$("$GC" --city "$GC_CITY" config explain --provider "$tier" --json 2>/dev/null || true)"
  if [ -z "$RAW" ]; then
    echo "cv-verify-model-mode: BLOCKED — ${tier}: not resolvable (is the pack imported for this city?)"
    FAILURES=$((FAILURES+1))
    continue
  fi

  RESULT="$(printf '%s' "$RAW" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print('parse_error\tcould not parse gc config explain output as JSON')
    raise SystemExit(0)
if not data.get('ok'):
    msg = (data.get('error') or {}).get('message') or 'unknown error'
    print(f'not_resolvable\t{msg}')
    raise SystemExit(0)
ancestor = data.get('builtin_ancestor') or '<unknown>'
print(f'ancestor\t{ancestor}')
" 2>/dev/null || true)"

  if [ -z "$RESULT" ]; then
    echo "cv-verify-model-mode: BLOCKED — ${tier}: could not evaluate (python parse failed)"
    FAILURES=$((FAILURES+1))
    continue
  fi

  CODE="${RESULT%%$'\t'*}"
  DETAIL="${RESULT#*$'\t'}"

  case "$CODE" in
    ancestor)
      if [ "$DETAIL" = "$MODE" ]; then
        echo "cv-verify-model-mode: OK — ${tier} -> ${DETAIL}"
      else
        echo "cv-verify-model-mode: BLOCKED — ${tier} resolved to '${DETAIL}', expected '${MODE}' (see README.md \"Model tiers\")"
        FAILURES=$((FAILURES+1))
      fi
      ;;
    not_resolvable)
      echo "cv-verify-model-mode: BLOCKED — ${tier}: not resolvable (${DETAIL})"
      FAILURES=$((FAILURES+1))
      ;;
    *)
      echo "cv-verify-model-mode: BLOCKED — ${tier}: ${DETAIL}"
      FAILURES=$((FAILURES+1))
      ;;
  esac
done

[ "$FAILURES" -eq 0 ] || exit 1
exit 0
