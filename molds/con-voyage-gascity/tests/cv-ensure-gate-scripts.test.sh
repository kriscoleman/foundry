#!/usr/bin/env bash
# cv-ensure-gate-scripts.test.sh — hermetic, offline test for the self-healing
# gate-check-script seeder (fk-6i53).
#
# WHY: con-voyage's review-loop and finalize gates are graph.v2 `mode = "exec"`
# checks that reference `.gc/scripts/checks/*.sh` BY PATH, resolved relative to
# the rig root. Those scripts were never shipped by the pack — they only
# existed as hand-placed copies in some rigs (foundry-kc) and not others
# (vandoor, kots, knuckles). A rig missing them hits a controller-level path
# resolution error and the whole review loop goes gc.control_quarantined
# (fk-6i53). cv-ensure-gate-scripts.sh closes that gap: it ships the check
# scripts as pack assets and seeds a rig's `.gc/scripts/checks/` from them
# on every con-voyage setup step run, so the path always resolves.
#
# Contract under test:
#   cv-ensure-gate-scripts.sh <rig-root>
#   - Seeds any MISSING `.gc/scripts/checks/<name>.sh` in <rig-root> from this
#     script's own sibling `checks/` assets directory, setting the exec bit.
#   - "Ensure" means present AND current (fk-6z17l): a STALE destination
#     script (content differs from the pack's current copy) is replaced
#     atomically, with the previous content backed up to `<name>.sh.prev`.
#     A destination whose content already matches the pack is left
#     untouched and gets no backup file.
#   - Fails loudly (exit 1, no partial writes) if the source assets are
#     missing/empty (a broken pack) or <rig-root> is not a directory, instead
#     of silently doing nothing and letting the gate fail later with a
#     confusing controller error.
#
# HOW IT WORKS: real temp directories under a sandbox — pure filesystem
# operations, no gc/bd/network involved, so this is hermetic by construction.
#
# Run:  bash tests/cv-ensure-gate-scripts.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-ensure-gate-scripts.sh"
SOURCE_CHECKS_DIR="${MOLD_DIR}/pack/assets/scripts/checks"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-ensure-gate-scripts-test.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

run_script() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

OUT=""
RC=0

# ===========================================================================
# CASE 1 — fresh rig (no .gc at all): seeds both shipped scripts, executable.
# ===========================================================================
start_case "1: fresh rig gets both scripts seeded, executable, content matches source"
RIG1="${SANDBOX}/rig1"
mkdir -p "$RIG1"
run_script "$RIG1"
assert_eq "0" "$RC" "exit 0 on fresh seed"
DEST1="${RIG1}/.gc/scripts/checks"
for f in build-artifact-valid.sh implementation-review-approved.sh; do
  if [ -f "${DEST1}/${f}" ]; then pass "${f} was seeded"; else fail "${f} was NOT seeded"; fi
  if [ -x "${DEST1}/${f}" ]; then pass "${f} is executable"; else fail "${f} is NOT executable"; fi
  if diff -q "${SOURCE_CHECKS_DIR}/${f}" "${DEST1}/${f}" >/dev/null 2>&1; then
    pass "${f} content matches pack source"
  else
    fail "${f} content does NOT match pack source"
  fi
done

# ===========================================================================
# CASE 2 — rig with a STALE seeded script (differs from the pack's current
# content): replaced, with the previous content backed up (fk-6z17l).
# "Ensure" means "present AND current" — a pack upgrade must reach a rig that
# was seeded once, not be silently stuck at whatever version first landed.
# ===========================================================================
start_case "2: a stale seeded script is replaced, previous content backed up"
RIG2="${SANDBOX}/rig2"
mkdir -p "${RIG2}/.gc/scripts/checks"
STALE_CONTENT='#!/usr/bin/env bash
echo "stale pre-fk-w31l7 copy"
'
printf '%s' "$STALE_CONTENT" > "${RIG2}/.gc/scripts/checks/implementation-review-approved.sh"
chmod +x "${RIG2}/.gc/scripts/checks/implementation-review-approved.sh"
run_script "$RIG2"
assert_eq "0" "$RC" "exit 0 when a stale script already exists"
if diff -q "${SOURCE_CHECKS_DIR}/implementation-review-approved.sh" "${RIG2}/.gc/scripts/checks/implementation-review-approved.sh" >/dev/null 2>&1; then
  pass "stale implementation-review-approved.sh was replaced with the current pack content"
else
  fail "stale implementation-review-approved.sh was NOT replaced"
fi
if [ -x "${RIG2}/.gc/scripts/checks/implementation-review-approved.sh" ]; then
  pass "replaced implementation-review-approved.sh is executable"
else
  fail "replaced implementation-review-approved.sh is NOT executable"
fi
BACKUP2="${RIG2}/.gc/scripts/checks/implementation-review-approved.sh.prev"
if [ -f "$BACKUP2" ] && printf '%s' "$STALE_CONTENT" | cmp -s - "$BACKUP2"; then
  pass "the stale content was backed up to implementation-review-approved.sh.prev before replacement"
else
  fail "no correct .prev backup of the stale content was kept"
fi
if [ -f "${RIG2}/.gc/scripts/checks/build-artifact-valid.sh" ]; then
  pass "the OTHER missing script (build-artifact-valid.sh) was still seeded"
else
  fail "build-artifact-valid.sh was not seeded alongside the stale-replaced one"
fi

# ===========================================================================
# CASE 3 — partial seed: a stale script is replaced, a missing one is added,
# neither disturbs the other.
# ===========================================================================
start_case "3: partial seed — a stale script is replaced, a missing one is added"
RIG3="${SANDBOX}/rig3"
mkdir -p "${RIG3}/.gc/scripts/checks"
printf 'placeholder\n' > "${RIG3}/.gc/scripts/checks/build-artifact-valid.sh"
run_script "$RIG3"
assert_eq "0" "$RC" "exit 0 on partial seed"
if diff -q "${SOURCE_CHECKS_DIR}/build-artifact-valid.sh" "${RIG3}/.gc/scripts/checks/build-artifact-valid.sh" >/dev/null 2>&1; then
  pass "stale build-artifact-valid.sh was replaced with the current pack content"
else
  fail "stale build-artifact-valid.sh was NOT replaced"
fi
BACKUP3="${RIG3}/.gc/scripts/checks/build-artifact-valid.sh.prev"
assert_eq "placeholder" "$(cat "$BACKUP3" 2>/dev/null)" "the stale placeholder was backed up to build-artifact-valid.sh.prev"
if diff -q "${SOURCE_CHECKS_DIR}/implementation-review-approved.sh" "${RIG3}/.gc/scripts/checks/implementation-review-approved.sh" >/dev/null 2>&1; then
  pass "missing implementation-review-approved.sh was seeded from pack source"
else
  fail "missing implementation-review-approved.sh was not seeded correctly"
fi

# ===========================================================================
# CASE 4 — second run against an already-fully-seeded, up-to-date rig is a
# clean no-op: content matches source, so nothing is replaced and no backup
# file is created (backups only happen when content actually changes).
# ===========================================================================
start_case "4: idempotent — re-running against an up-to-date rig changes nothing, writes no backup"
run_script "$RIG1"
assert_eq "0" "$RC" "exit 0 on idempotent re-run"
for f in build-artifact-valid.sh implementation-review-approved.sh; do
  if diff -q "${SOURCE_CHECKS_DIR}/${f}" "${DEST1}/${f}" >/dev/null 2>&1; then
    pass "${f} still matches pack source after re-run"
  else
    fail "${f} drifted from pack source after re-run"
  fi
  if [ -e "${DEST1}/${f}.prev" ]; then
    fail "${f}.prev backup should not exist when content already matched"
  else
    pass "no ${f}.prev backup was created for an already-current file"
  fi
done

# ===========================================================================
# CASE 5 — missing rig-root argument / not a directory: fails safe, no writes.
# ===========================================================================
start_case "5: usage error on missing/invalid rig-root argument"
run_script
if [ "$RC" -ne 0 ]; then pass "no-args exits non-zero"; else fail "no-args should fail, got exit 0"; fi

NOTADIR="${SANDBOX}/does-not-exist"
run_script "$NOTADIR"
if [ "$RC" -ne 0 ]; then
  pass "non-existent rig-root exits non-zero"
else
  fail "non-existent rig-root should fail, got exit 0"
fi
if [ -e "$NOTADIR" ]; then fail "script created something at a rig-root that should have been rejected"; else pass "no writes happened for an invalid rig-root"; fi

# ===========================================================================
# CASE 6 — broken pack (no source checks/ assets): fails loud, no partial write.
# ===========================================================================
start_case "6: fails loud when the pack itself ships no check scripts"
EMPTY_SCRIPT_DIR="${SANDBOX}/empty-pack/pack/assets/scripts"
mkdir -p "${EMPTY_SCRIPT_DIR}/checks_placeholder"
# Deliberately do NOT create a sibling 'checks' dir at all, and copy the
# script under test into this fake pack layout so it resolves an EMPTY/absent
# source dir relative to itself.
cp "$SCRIPT" "${EMPTY_SCRIPT_DIR}/cv-ensure-gate-scripts.sh"
RIG6="${SANDBOX}/rig6"
mkdir -p "$RIG6"
OUT="$(bash "${EMPTY_SCRIPT_DIR}/cv-ensure-gate-scripts.sh" "$RIG6" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then pass "missing source checks/ dir exits non-zero"; else fail "missing source checks/ dir should fail, got exit 0"; fi
if [ -d "${RIG6}/.gc" ]; then fail "partial .gc/ directory was created despite the failure"; else pass "no partial .gc/ directory was created"; fi

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
