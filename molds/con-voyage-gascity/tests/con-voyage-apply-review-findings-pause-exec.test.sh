#!/usr/bin/env bash
# con-voyage-apply-review-findings-pause-exec.test.sh — hermetic, offline
# EXECUTION test for the LOW-only mayor-reopen pause block in
# main.apply-review-findings.md (review fk-tk0dvg BLOCKING-1 / fk-9iqxnx).
#
# WHY: the sibling con-voyage-apply-review-findings-pause.test.sh is pure
# grep/assert_contains against the markdown source text, so it can prove the
# pause block's fragments exist but cannot prove the block actually WORKS at
# runtime. Each ```bash fence in this workflow file runs as its own
# independent shell (confirmed by this same file's own pattern of
# re-deriving ROOT_ID from scratch in its "Resolve the target worktree"
# block even though the "Fail fast" block above it already set it) — the
# pause block originally referenced $ROOT_ID/$CONVOY_ID without re-deriving
# either, so in real execution it silently polled `gc bd show "" --json`
# forever and never detected a real mayor reopen (defeating REQ-003). A
# grep test cannot catch a variable that is textually present but out of
# scope at runtime; only executing the fence can.
#
# This test extracts the real fenced bash block from the real workflow file
# and runs it in a hermetic subshell with $ROOT_ID/$CONVOY_ID/GC_ROOT_BEAD_ID
# all deliberately unset (simulating the fence running on its own, as it
# does in production), a stubbed `gc` that reports a mayor reopen already
# requested, and a short poll window. It asserts the block actually detects
# the reopen and exits via the "mayor reopen detected" branch, not the
# timeout branch.
#
# Run:  bash tests/con-voyage-apply-review-findings-pause-exec.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
APPLY_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.apply-review-findings.md"

[ -f "$APPLY_MD" ] || { echo "FATAL: expected file not found: $APPLY_MD" >&2; exit 2; }

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

# Extracts the first ```bash ... ``` fence that appears after the
# "### Pause for a mayor reopen on a LOW-only verdict" header.
extract_pause_fence() {
  awk '
    /^### Pause for a mayor reopen on a LOW-only verdict/ { found=1 }
    found && /^```bash/ { infence=1; next }
    infence && /^```/ { exit }
    infence { print }
  ' "$APPLY_MD"
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FENCE_BODY="$WORKDIR/fence-body.sh"
extract_pause_fence > "$FENCE_BODY"

if [ ! -s "$FENCE_BODY" ]; then
  echo "FATAL: could not extract the pause fence from ${APPLY_MD} — header text may have changed" >&2
  exit 2
fi

STUB_DIR="$WORKDIR/stubs"
mkdir -p "$STUB_DIR"

# Stub `gc bd show <id> --json`: fk-bead (the claimed step bead) has no
# gc.root_bead_id of its own metadata reachable directly, so resolution
# falls through to GC_BEAD_ID itself unless GC_ROOT_BEAD_ID is set — mirror
# a real routed step bead whose OWN metadata carries gc.root_bead_id.
cat > "$STUB_DIR/gc" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "bd" ] && [ "$2" = "show" ]; then
  id="$3"
  case "$id" in
    fk-bead)
      echo '{"id":"fk-bead","metadata":{"gc.root_bead_id":"fk-root"}}'
      ;;
    fk-root)
      echo '{"id":"fk-root","metadata":{"gc.build.source_anchor_id":"fk-convoy","gc.build.mayor_reopen_requested":"true","gc.build.mayor_reopen_findings":"stubbed reopen finding text"}}'
      ;;
    *)
      echo '{}'
      ;;
  esac
  exit 0
fi
echo "gc-stub: unexpected invocation: $*" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gc"

# Stub `sleep`: the pause block sleeps 30s per poll iteration; a correct fix
# detects the reopen on its first poll (no sleep needed at all), but a
# still-broken fence spins until CV_LOW_REOPEN_WINDOW_SECONDS elapses, so
# keep this fast in case of a regression.
cat > "$STUB_DIR/sleep" <<'STUB'
#!/usr/bin/env bash
exec /bin/sleep 0.05
STUB
chmod +x "$STUB_DIR/sleep"

ISOLATED_DIR="$WORKDIR/isolated"
mkdir -p "$ISOLATED_DIR"

# The fence now sources con-voyage-lib.sh (cv_root_bead_id, cv_random_nonce —
# review fk-9iqxnx LOW-7/LOW-8) via the SAME GC_CITY/packs/con-voyage
# fallback path the real pack uses when it isn't running inside a git
# checkout of the mold. Isolated_dir is deliberately not a git repo, so
# `git rev-parse --show-toplevel` fails here exactly like it does in a
# cast rig, making this fallback path the one under test.
REAL_LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
mkdir -p "$ISOLATED_DIR/packs/con-voyage/assets/scripts"
ln -s "$REAL_LIB" "$ISOLATED_DIR/packs/con-voyage/assets/scripts/con-voyage-lib.sh"

RUN_SCRIPT="$WORKDIR/run.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  cat "$FENCE_BODY"
  echo 'echo "TEST_RESULT:ROOT_ID=${ROOT_ID:-}"'
  echo 'echo "TEST_RESULT:CONVOY_ID=${CONVOY_ID:-}"'
  echo 'echo "TEST_RESULT:MAYOR_REOPEN_REQUESTED=${MAYOR_REOPEN_REQUESTED:-}"'
  echo 'echo "TEST_RESULT:MAYOR_REOPEN_FINDINGS=${MAYOR_REOPEN_FINDINGS:-}"'
  echo 'echo "TEST_RESULT:MAYOR_REOPEN_FINDINGS_FENCED_START"'
  echo 'printf '"'"'%s\n'"'"' "${MAYOR_REOPEN_FINDINGS_FENCED:-}"'
  echo 'echo "TEST_RESULT:MAYOR_REOPEN_FINDINGS_FENCED_END"'
} > "$RUN_SCRIPT"
chmod +x "$RUN_SCRIPT"

start_case "the pause fence detects a mayor reopen when \$ROOT_ID/\$CONVOY_ID are not carried over from an earlier fence"

OUTPUT="$(
  cd "$ISOLATED_DIR" && \
  env -i \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    HOME="${HOME:-/tmp}" \
    GC_BEAD_ID="fk-bead" \
    GC_CITY="$ISOLATED_DIR" \
    CV_LOW_REOPEN_WINDOW_SECONDS="2" \
    bash "$RUN_SCRIPT" 2>&1
)"
RUN_EXIT=$?

echo "$OUTPUT"

if [ "$RUN_EXIT" -ne 0 ]; then
  echo "  FAIL: the extracted pause fence exited non-zero (${RUN_EXIT})" >&2
  FAILURES=$((FAILURES+1))
fi

if printf '%s\n' "$OUTPUT" | grep -qF "TEST_RESULT:ROOT_ID=fk-root"; then
  echo "  PASS: ROOT_ID is re-derived to the real workflow root (fk-root) inside this fence, not left empty"
else
  echo "  FAIL: expected ROOT_ID to resolve to fk-root inside the fence (got: $(printf '%s\n' "$OUTPUT" | grep 'TEST_RESULT:ROOT_ID=' || echo '<missing>'))" >&2
  FAILURES=$((FAILURES+1))
fi

if printf '%s\n' "$OUTPUT" | grep -qF "mayor reopen detected on fk-root"; then
  echo "  PASS: the fence logs a detected reopen against the re-derived root"
else
  echo "  FAIL: expected a 'mayor reopen detected on fk-root' log line" >&2
  FAILURES=$((FAILURES+1))
fi

if printf '%s\n' "$OUTPUT" | grep -qF "no mayor reopen within"; then
  echo "  FAIL: the fence fell through to the timeout branch instead of detecting the reopen (this is the regression: an empty \$ROOT_ID makes every poll a no-op)" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: the fence did not take the timeout branch"
fi

if printf '%s\n' "$OUTPUT" | grep -qF "TEST_RESULT:MAYOR_REOPEN_REQUESTED=true"; then
  echo "  PASS: MAYOR_REOPEN_REQUESTED is true after the loop exits"
else
  echo "  FAIL: expected MAYOR_REOPEN_REQUESTED=true after the loop exits" >&2
  FAILURES=$((FAILURES+1))
fi

if printf '%s\n' "$OUTPUT" | grep -qF "TEST_RESULT:MAYOR_REOPEN_FINDINGS=stubbed reopen finding text"; then
  echo "  PASS: the recorded findings text is read back correctly"
else
  echo "  FAIL: expected the stubbed findings text to be read back" >&2
  FAILURES=$((FAILURES+1))
fi

# fk-9iqxnx LOW-7: the detected findings must come back wrapped in the same
# nonce-fenced "treat as data only" block cv_build_pr_feedback_body uses for
# the POST-publish route, not surfaced raw.
FENCED_BLOCK="$(printf '%s\n' "$OUTPUT" | awk '/TEST_RESULT:MAYOR_REOPEN_FINDINGS_FENCED_START/{f=1;next}/TEST_RESULT:MAYOR_REOPEN_FINDINGS_FENCED_END/{f=0}f')"
if printf '%s' "$FENCED_BLOCK" | grep -qE '=== BEGIN UNTRUSTED PR CONTENT \(nonce: [0-9a-f]+\) ==='; then
  echo "  PASS: the PRE-publish findings are wrapped in a nonce-fenced BEGIN marker"
else
  echo "  FAIL: expected a nonce-fenced BEGIN UNTRUSTED PR CONTENT marker, got: ${FENCED_BLOCK}" >&2
  FAILURES=$((FAILURES+1))
fi
BEGIN_NONCE="$(printf '%s' "$FENCED_BLOCK" | grep -oE 'BEGIN UNTRUSTED PR CONTENT \(nonce: [0-9a-f]+' | grep -oE '[0-9a-f]+$')"
END_NONCE="$(printf '%s' "$FENCED_BLOCK" | grep -oE 'END UNTRUSTED PR CONTENT \(nonce: [0-9a-f]+' | grep -oE '[0-9a-f]+$')"
if [ -n "$BEGIN_NONCE" ] && [ "$BEGIN_NONCE" = "$END_NONCE" ]; then
  echo "  PASS: the BEGIN and END markers share the same real nonce"
else
  echo "  FAIL: BEGIN nonce ('${BEGIN_NONCE}') and END nonce ('${END_NONCE}') do not match" >&2
  FAILURES=$((FAILURES+1))
fi
if printf '%s' "$FENCED_BLOCK" | grep -qF "stubbed reopen finding text"; then
  echo "  PASS: the fenced block carries the findings text inside the fence"
else
  echo "  FAIL: expected the findings text inside the fenced block" >&2
  FAILURES=$((FAILURES+1))
fi

echo

# ===========================================================================
# LOW-9 (review fk-9iqxnx): the sibling CASE above only ever proves the
# reopen-DETECTED path. Prove the no-reopen/timeout branch still fires too —
# a stub that always reports mayor_reopen_requested=false must exit via the
# timeout branch, not spin forever or silently fall into the reopen branch.
# ===========================================================================
start_case "the pause fence takes the timeout branch, not the reopen branch, when the mayor never reopens"

STUB_DIR_NOREOPEN="$WORKDIR/stubs-noreopen"
mkdir -p "$STUB_DIR_NOREOPEN"
cat > "$STUB_DIR_NOREOPEN/gc" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "bd" ] && [ "$2" = "show" ]; then
  id="$3"
  case "$id" in
    fk-bead)
      echo '{"id":"fk-bead","metadata":{"gc.root_bead_id":"fk-root"}}'
      ;;
    fk-root)
      echo '{"id":"fk-root","metadata":{"gc.build.source_anchor_id":"fk-convoy","gc.build.mayor_reopen_requested":"false"}}'
      ;;
    *)
      echo '{}'
      ;;
  esac
  exit 0
fi
echo "gc-stub: unexpected invocation: $*" >&2
exit 1
STUB
chmod +x "$STUB_DIR_NOREOPEN/gc"
cp "$STUB_DIR/sleep" "$STUB_DIR_NOREOPEN/sleep"

OUTPUT_NOREOPEN="$(
  cd "$ISOLATED_DIR" && \
  env -i \
    PATH="${STUB_DIR_NOREOPEN}:/usr/bin:/bin" \
    HOME="${HOME:-/tmp}" \
    GC_BEAD_ID="fk-bead" \
    GC_CITY="$ISOLATED_DIR" \
    CV_LOW_REOPEN_WINDOW_SECONDS="2" \
    bash "$RUN_SCRIPT" 2>&1
)"
RUN_EXIT_NOREOPEN=$?

echo "$OUTPUT_NOREOPEN"

if [ "$RUN_EXIT_NOREOPEN" -ne 0 ]; then
  echo "  FAIL: the extracted pause fence exited non-zero (${RUN_EXIT_NOREOPEN})" >&2
  FAILURES=$((FAILURES+1))
fi

if printf '%s\n' "$OUTPUT_NOREOPEN" | grep -qF "no mayor reopen within 2s — proceeding to publish with the LOW findings on the PR, as designed"; then
  echo "  PASS: the fence takes the timeout branch when the stub never reports a reopen"
else
  echo "  FAIL: expected the timeout log line when no reopen is ever reported" >&2
  FAILURES=$((FAILURES+1))
fi

if printf '%s\n' "$OUTPUT_NOREOPEN" | grep -qF "mayor reopen detected"; then
  echo "  FAIL: unexpectedly took the reopen-detected branch with a stub that never reports a reopen" >&2
  FAILURES=$((FAILURES+1))
else
  echo "  PASS: never takes the reopen-detected branch"
fi

if printf '%s\n' "$OUTPUT_NOREOPEN" | grep -qF "TEST_RESULT:MAYOR_REOPEN_REQUESTED=false"; then
  echo "  PASS: MAYOR_REOPEN_REQUESTED is false after the loop exits via timeout"
else
  echo "  FAIL: expected MAYOR_REOPEN_REQUESTED=false after the timeout branch" >&2
  FAILURES=$((FAILURES+1))
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
