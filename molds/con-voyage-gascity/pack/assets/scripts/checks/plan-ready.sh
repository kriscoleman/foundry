#!/usr/bin/env bash
set -euo pipefail

# Gate for con-voyage's plan step. A plan step that skipped itself (plan mode
# off, or a pre-built branch with nothing left to plan) records
# gc.plan.skipped=true on the workflow root and has no artifact, so it passes
# here. Every other plan step is validated exactly like any producer stage:
# build-artifact-valid.sh against the step's gc.build.plan.v1 metadata.

fail() {
  echo "plan-ready-check: $*" >&2
  exit 1
}

BEAD_ID="${GC_BEAD_ID:-}"
[ -n "$BEAD_ID" ] || fail "GC_BEAD_ID is required"
command -v bd >/dev/null 2>&1 || fail "bd is required on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is required on PATH"

metadata_value() {
  printf '%s' "$1" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
metadata = data.get("metadata") if isinstance(data, dict) else None
value = metadata.get(sys.argv[1], "") if isinstance(metadata, dict) else ""
print(value if isinstance(value, str) else "")
' "$2"
}

SHOW_JSON="$(bd show "$BEAD_ID" --json 2>/dev/null)" || fail "bd show $BEAD_ID failed"
ROOT_ID="$(metadata_value "$SHOW_JSON" "gc.root_bead_id")"
ROOT_JSON="$SHOW_JSON"
if [ -n "$ROOT_ID" ] && [ "$ROOT_ID" != "$BEAD_ID" ]; then
  ROOT_JSON="$(bd show "$ROOT_ID" --json 2>/dev/null)" || fail "bd show $ROOT_ID failed"
fi

if [ "$(metadata_value "$ROOT_JSON" "gc.plan.skipped")" = "true" ]; then
  echo "plan skipped: $(metadata_value "$ROOT_JSON" "gc.plan.skip_reason")"
  exit 0
fi

exec bash "$(cd "$(dirname "$0")" && pwd)/build-artifact-valid.sh"
