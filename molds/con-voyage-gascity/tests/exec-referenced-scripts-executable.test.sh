#!/usr/bin/env bash
# exec-referenced-scripts-executable.test.sh — every pack script an order
# runs directly (exec = "$PACK_DIR/assets/scripts/<x>.sh") must be committed
# mode 100755. `ailloy cast` preserves the source git mode, so a script
# checked in at 644 silently ships non-executable into every recast rig and
# the order that execs it fails at runtime (fk-4gqm0: the live repl_city HQ
# only worked because someone hand-chmod+x'd it, uncommitted).
#
# Driven off the orders' OWN exec = lines, not a hand-maintained file list,
# so a newly added order/script at 644 fails this test by name instead of
# shipping a blind spot.
#
# Run:  bash tests/exec-referenced-scripts-executable.test.sh   (exit 0 => pass)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PACK_DIR="${MOLD_DIR}/pack"
ORDERS_DIR="${PACK_DIR}/orders"

if [ ! -d "$ORDERS_DIR" ]; then
  echo "FATAL: orders dir not found at ${ORDERS_DIR}" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

start_case "every order's exec= script is committed mode 100755"

# Extract exec = "$PACK_DIR/assets/scripts/<relative>" targets from every
# order file, resolve each to a real path under pack/, and check its git
# mode via ls-files (not a filesystem stat, which a local chmod could mask).
while IFS= read -r rel_path; do
  [ -n "$rel_path" ] || continue
  real_path="${PACK_DIR}/${rel_path}"
  if [ ! -f "$real_path" ]; then
    echo "  FAIL: exec target ${rel_path} referenced by an order does not exist at ${real_path}" >&2
    FAILURES=$((FAILURES+1))
    continue
  fi
  mode="$(cd "$MOLD_DIR" && git ls-files -s -- "pack/${rel_path}" | awk '{print $1}')"
  if [ "$mode" = "100755" ]; then
    echo "  PASS: ${rel_path} is 100755"
  else
    echo "  FAIL: ${rel_path} is committed mode '${mode:-<untracked>}', not 100755 — a recast will ship it non-executable" >&2
    FAILURES=$((FAILURES+1))
  fi
done < <(grep -hoE '\$PACK_DIR/assets/scripts/[A-Za-z0-9._/-]+' "${ORDERS_DIR}"/*.toml | sed -E 's#\$PACK_DIR/##' | sort -u)

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
