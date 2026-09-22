#!/usr/bin/env bash
# cv-verify-review-approved.sh — publish-time defense-in-depth guard (fk-6i53).
#
# WHY: con-voyage's publish step depends on `{target}.con-voyage-review-loop`
# via graph.v2 `needs = [...]`, which is satisfied by bead CLOSURE alone,
# regardless of the review loop's own gc.outcome. A controller-level gate
# error (e.g. a missing .gc/scripts/checks/implementation-review-approved.sh,
# fk-6i53) can close that bead with gc.outcome=fail while still leaving
# publish's dependency satisfied — a broken/missing gate silently reads
# downstream as "review approved" instead of "review never actually re-ran".
# This happened for real: PR #10494's review bead (va-9p08) closed with
# gc.outcome=fail, and the publish step (va-8bes) was still routed as if
# review had passed.
#
# This script re-derives the true verdict directly from the review-loop's own
# sibling bead instead of trusting graph dispatch, so publish.md can refuse to
# push/open a PR when the review was never actually approved — regardless of
# why the graph thinks the dependency is satisfied.
#
# Usage:
#   cv-verify-review-approved.sh <root-bead-id>
#
# <root-bead-id> is any bead id sharing the same gc.root_bead_id as the
# con-voyage workflow instance being published (publish's own claimed bead id
# works: every node in the same workflow instance shares one root).
#
# Exit codes:
#   0 — the "Run con-voyage review until approved" sibling bead (the
#       con-voyage-review-loop node) is closed with gc.outcome=pass. Safe to
#       publish. A one-line reason is printed either way.
#   1 — usage error, lookup failure, or the sibling bead is missing, still
#       open, or closed with any outcome other than pass. NOT safe to
#       publish — fails SAFE (blocks) rather than trusting graph dispatch.
#
# Environment:
#   GC        gc binary to invoke (default: gc)
#   GC_CITY   city directory passed to every --city call (default: .)
#
# Requires: bash 4+, gc CLI (or a stub honoring the same --city bd list --json
# contract), python3.

set -uo pipefail

GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"

die() {
  echo "cv-verify-review-approved: BLOCKED — $*"
  exit 1
}

ROOT_ID="${1:-}"
[ -n "$ROOT_ID" ] || die "usage: cv-verify-review-approved.sh <root-bead-id>"

MATCHES="$("$GC" --city "$GC_CITY" bd list --all --metadata-field "gc.root_bead_id=${ROOT_ID}" --json --limit=0 2>/dev/null || true)"
[ -n "$MATCHES" ] || die "bd list returned nothing for root ${ROOT_ID} — cannot verify the review outcome"

RESULT="$(printf '%s' "$MATCHES" | python3 -c "
import json, sys

LOOP_TITLE = 'Run con-voyage review until approved'

try:
    data = json.load(sys.stdin)
except Exception:
    print('lookup_error\tcould not parse bd list output as JSON')
    raise SystemExit(0)
if not isinstance(data, list):
    print('lookup_error\tbd list output was not a JSON array')
    raise SystemExit(0)

candidates = [
    d for d in data
    if isinstance(d, dict) and (d.get('title') or '') == LOOP_TITLE
]
if not candidates:
    print('missing\tno con-voyage-review-loop sibling bead found under this root')
    raise SystemExit(0)

candidates.sort(key=lambda d: d.get('updated_at') or '')
bead = candidates[-1]
bead_id = bead.get('id') or '<unknown id>'
status = bead.get('status') or ''
outcome = (bead.get('metadata') or {}).get('gc.outcome') or ''

if status != 'closed':
    print(f'not_closed\treview loop bead {bead_id} is still \"{status or \"open\"}\" (not closed)')
elif outcome != 'pass':
    print(f'bad_outcome\treview loop bead {bead_id} closed with gc.outcome={outcome or \"<empty>\"} (expected pass)')
else:
    print(f'approved\treview loop bead {bead_id} closed with gc.outcome=pass')
" 2>/dev/null || true)"

[ -n "$RESULT" ] || die "could not evaluate the review outcome (python parse failed)"

CODE="${RESULT%%$'\t'*}"
REASON="${RESULT#*$'\t'}"

if [ "$CODE" = "approved" ]; then
  echo "cv-verify-review-approved: OK — ${REASON}"
  exit 0
fi
die "${REASON:-unknown failure ($CODE)}"
