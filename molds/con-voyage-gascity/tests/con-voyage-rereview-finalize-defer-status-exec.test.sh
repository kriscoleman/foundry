#!/usr/bin/env bash
# con-voyage-rereview-finalize-defer-status-exec.test.sh — hermetic, offline
# EXECUTION test for the "Fold in any deferred ci-repair status" fence in
# main.rereview-finalize.md (review fk-drbqfj BLOCKING-1, iteration 4).
#
# WHY: con-voyage-ci-repair-defer-status-wiring.test.sh is pure grep/assert
# against the markdown source text, so it can prove the fold-in call site
# exists but cannot prove the fence actually resolves its inputs at runtime.
# Each ```bash fence in a con-voyage step .md runs as its own independent
# shell (already documented and fixed twice elsewhere in this exact pack —
# main.apply-review-findings.md's pause block) — the fold-in fence originally
# referenced $CV_LIB/$FINALIZE_KEY/$ROOT_ID assigned only in the earlier
# "Resolve this run's inputs" fence, so in real execution $CV_LIB was always
# empty, the read was never attempted, and the deferred ci-repair status
# (REQ-003) was a silent no-op despite every textual wiring test passing. A
# grep test cannot catch a variable that is textually present but out of
# scope at runtime; only executing the fence can.
#
# This test extracts the real fenced bash block from the real workflow file
# and runs it in a hermetic subshell with CV_LIB/FINALIZE_KEY/ROOT_ID all
# deliberately unset (simulating the fence running on its own, as it does in
# production), a stubbed `gc` that answers `bd show` for the step/root beads,
# and a real pending-status file pre-seeded via con-voyage-lib.sh's own
# cv_defer_status_append. It asserts the fence actually reads the deferred
# status and writes it to ci-repair-status.md.
#
# review fk-7bmhlz LOW-5 (code-review/native-language fk-202t44): the
# fold-in fence now PEEKS the pending-status record (cv_defer_status_peek)
# rather than destructively clearing it (cv_defer_status_read_and_clear) —
# clearing now happens only in the later "Post the round's ONE aggregated
# review comment" fence, and only once that post is confirmed. CASE 1 below
# asserts the record SURVIVES this fence (the opposite of its pre-fix
# assertion); CASE 3/4 cover the posting fence's own clear-on-success /
# leave-on-failure behavior.
#
# Run:  bash tests/con-voyage-rereview-finalize-defer-status-exec.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REREVIEW_FINALIZE_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.rereview-finalize.md"
REAL_LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

for f in "$REREVIEW_FINALIZE_MD" "$REAL_LIB"; do
  [ -f "$f" ] || { echo "FATAL: file under test not found: $f" >&2; exit 2; }
done

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

# Extracts the first ```bash ... ``` fence that appears after the
# "## Fold in any deferred ci-repair status" header.
extract_fold_in_fence() {
  awk '
    /^## Fold in any deferred ci-repair status/ { found=1 }
    found && /^```bash/ { infence=1; next }
    infence && /^```/ { exit }
    infence { print }
  ' "$REREVIEW_FINALIZE_MD"
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FENCE_BODY="$WORKDIR/fence-body.sh"
extract_fold_in_fence > "$FENCE_BODY"

if [ ! -s "$FENCE_BODY" ]; then
  echo "FATAL: could not extract the fold-in fence from ${REREVIEW_FINALIZE_MD} — header text may have changed" >&2
  exit 2
fi

ISOLATED_DIR="$WORKDIR/isolated"
mkdir -p "$ISOLATED_DIR"
mkdir -p "$ISOLATED_DIR/packs/con-voyage/assets/scripts"
ln -s "$REAL_LIB" "$ISOLATED_DIR/packs/con-voyage/assets/scripts/con-voyage-lib.sh"

ROOT_ID_VAL="fk-root"
FINALIZE_KEY_VAL="cv-finalize-owner-repo-42"
CV_BUILD_DIR="${ISOLATED_DIR}/.gc/build/${ROOT_ID_VAL}"
mkdir -p "$CV_BUILD_DIR"

STUB_DIR="$WORKDIR/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gc" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "bd" ] && [ "\$2" = "show" ]; then
  id="\$3"
  case "\$id" in
    fk-bead)
      echo '{"id":"fk-bead","metadata":{"gc.root_bead_id":"${ROOT_ID_VAL}"}}'
      ;;
    "${ROOT_ID_VAL}")
      echo '{"id":"${ROOT_ID_VAL}","metadata":{"gc.var.finalize_key":"${FINALIZE_KEY_VAL}"}}'
      ;;
    *)
      echo '{}'
      ;;
  esac
  exit 0
fi
echo "gc-stub: unexpected invocation: \$*" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gc"

RUN_SCRIPT="$WORKDIR/run.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  cat "$FENCE_BODY"
  echo 'echo "TEST_RESULT:ROOT_ID=${ROOT_ID:-}"'
  echo 'echo "TEST_RESULT:CV_LIB_EMPTY=$([ -z "${CV_LIB:-}" ] && echo yes || echo no)"'
  echo 'echo "TEST_RESULT:CV_DEFERRED_STATUS_START"'
  echo 'printf '"'"'%s\n'"'"' "${CV_DEFERRED_STATUS:-}"'
  echo 'echo "TEST_RESULT:CV_DEFERRED_STATUS_END"'
} > "$RUN_SCRIPT"
chmod +x "$RUN_SCRIPT"

run_fence() {
  (
    cd "$ISOLATED_DIR" && \
    env -i \
      PATH="${STUB_DIR}:/usr/bin:/bin" \
      HOME="${HOME:-/tmp}" \
      GC_BEAD_ID="fk-bead" \
      GC_CITY="$ISOLATED_DIR" \
      GC_RIG_ROOT="$ISOLATED_DIR" \
      bash "$RUN_SCRIPT" 2>&1
  )
}

# ===========================================================================
# CASE 1 — a deferred status pending for this PR's finalize key is actually
# read, cleared, and folded into ci-repair-status.md, even though CV_LIB,
# FINALIZE_KEY, and ROOT_ID are all unset on entry to this fence (simulating
# it running as its own shell, independent of the earlier "Resolve this run's
# inputs" fence).
# ===========================================================================
start_case "the fold-in fence reads+clears a real deferred status with no inputs carried over from an earlier fence"

source "$REAL_LIB"
export CV_STATE_DIR="${ISOLATED_DIR}/.gc/cv-pr-watch"
cv_defer_status_append "$FINALIZE_KEY_VAL" "ci-repair: rebased PR branch onto origin/main, no human decision needed" \
  || { echo "FATAL: could not seed a deferred status via cv_defer_status_append" >&2; exit 2; }
PENDING_FILE="${CV_STATE_DIR}/${FINALIZE_KEY_VAL}.pending-status"
[ -f "$PENDING_FILE" ] || { echo "FATAL: expected ${PENDING_FILE} to exist after seeding" >&2; exit 2; }

OUTPUT="$(run_fence)"
RUN_EXIT=$?
echo "$OUTPUT"

if [ "$RUN_EXIT" -ne 0 ]; then
  fail "the extracted fold-in fence exited non-zero (${RUN_EXIT})"
fi

if printf '%s\n' "$OUTPUT" | grep -qF "TEST_RESULT:ROOT_ID=${ROOT_ID_VAL}"; then
  pass "ROOT_ID is re-derived to the real workflow root (${ROOT_ID_VAL}) inside this fence, not left empty"
else
  fail "expected ROOT_ID to resolve to ${ROOT_ID_VAL} inside the fence (got: $(printf '%s\n' "$OUTPUT" | grep 'TEST_RESULT:ROOT_ID=' || echo '<missing>'))"
fi

if printf '%s\n' "$OUTPUT" | grep -qF "TEST_RESULT:CV_LIB_EMPTY=no"; then
  pass "CV_LIB is resolved inside the fence, not left empty"
else
  fail "expected CV_LIB to resolve to a real path inside the fence (this is the regression: an empty \$CV_LIB skips the read entirely)"
fi

DEFERRED_BLOCK="$(printf '%s\n' "$OUTPUT" | awk '/TEST_RESULT:CV_DEFERRED_STATUS_START/{f=1;next}/TEST_RESULT:CV_DEFERRED_STATUS_END/{f=0}f')"
if printf '%s' "$DEFERRED_BLOCK" | grep -qF "ci-repair: rebased PR branch onto origin/main"; then
  pass "the fence actually read the deferred status text"
else
  fail "expected the seeded deferred status text, got: ${DEFERRED_BLOCK}"
fi

if [ -f "$PENDING_FILE" ]; then
  pass "the pending-status file survives the fold-in fence (fk-7bmhlz LOW-5: peeked, not cleared — cleared only after a confirmed post)"
else
  fail "the pending-status file was removed by the fold-in fence, but it should only be PEEKED here, not cleared"
fi

if [ -f "${CV_BUILD_DIR}/ci-repair-status.md" ] && grep -qF "ci-repair: rebased PR branch onto origin/main" "${CV_BUILD_DIR}/ci-repair-status.md"; then
  pass "the deferred status was written to ci-repair-status.md under the build artifact root"
else
  fail "expected ${CV_BUILD_DIR}/ci-repair-status.md to contain the deferred status text"
fi

# ===========================================================================
# CASE 2 — when nothing was deferred, the fence must not fail and must write
# no ci-repair-status.md (the common case — most rounds have no ci-repair
# activity at all).
# ===========================================================================
start_case "the fold-in fence is a clean no-op when nothing was deferred"

rm -f "${CV_BUILD_DIR}/ci-repair-status.md"
# fk-7bmhlz LOW-5: CASE 1 above now only PEEKS, so the pending-status file
# from CASE 1 is still on disk — clear it here to simulate what the posting
# fence would have done once CASE 1's post was confirmed, so this case
# genuinely exercises "nothing deferred" rather than re-reading CASE 1's
# leftover record.
rm -f "$PENDING_FILE"

OUTPUT_NOOP="$(run_fence)"
RUN_EXIT_NOOP=$?
echo "$OUTPUT_NOOP"

if [ "$RUN_EXIT_NOOP" -ne 0 ]; then
  fail "the extracted fold-in fence exited non-zero on the no-op path (${RUN_EXIT_NOOP})"
else
  pass "the fence exits 0 when there is nothing deferred"
fi

if [ -f "${CV_BUILD_DIR}/ci-repair-status.md" ]; then
  fail "ci-repair-status.md should not have been written when nothing was deferred"
else
  pass "no ci-repair-status.md is written when nothing was deferred"
fi

# ===========================================================================
# CASE 3/4 — the "Post the round's ONE aggregated review comment" fence's own
# clear-on-confirmed-post / leave-on-failure behavior (review fk-7bmhlz
# LOW-5). This fence's own PR_NUMBER/REPO_FULL/CV_LIB/CV_PACK_ROOT inputs are
# supplied directly here (how a real dispatch gets them into this fence is a
# separate, already-flagged concern — this test isolates and proves only the
# NEW clear-on-confirm logic this fix adds).
# ===========================================================================
extract_posting_fence() {
  awk '
    /^## Post the round.s ONE aggregated review comment/ { found=1 }
    found && /^```bash/ { infence=1; next }
    infence && /^```/ { exit }
    infence { print }
  ' "$REREVIEW_FINALIZE_MD"
}

POSTING_FENCE_BODY="$WORKDIR/posting-fence-body.sh"
extract_posting_fence > "$POSTING_FENCE_BODY"
if [ ! -s "$POSTING_FENCE_BODY" ]; then
  echo "FATAL: could not extract the posting fence from ${REREVIEW_FINALIZE_MD} — header text may have changed" >&2
  exit 2
fi
# The real dispatching agent replaces this prose placeholder with the
# assembled manifest's actual path before running the fence; left literal,
# the unquoted "<path" is bash input redirection from a file named "path",
# not a value, and aborts the fence before it ever reaches comment-aggregate.
sed -i.bak 's#<path to the assembled JSON manifest, round=\$REVIEW_ROUND>#"'"$WORKDIR"'/manifest.json"#' "$POSTING_FENCE_BODY"
rm -f "${POSTING_FENCE_BODY}.bak"
echo '{}' > "${WORKDIR}/manifest.json"

cat > "$STUB_DIR/cv-pr-comment.sh" <<'CVBINSTUB'
#!/usr/bin/env bash
if [ "$1" = "comment-aggregate" ]; then
  if [ "${STUB_CV_PR_COMMENT_SUCCEED:-1}" = "1" ]; then
    echo "stub: posted aggregate comment"
    exit 0
  else
    echo "stub: simulated comment-aggregate failure" >&2
    exit 1
  fi
fi
echo "cv-pr-comment.sh-stub: unexpected invocation: $*" >&2
exit 1
CVBINSTUB
chmod +x "$STUB_DIR/cv-pr-comment.sh"
ln -sf "$STUB_DIR/cv-pr-comment.sh" "$ISOLATED_DIR/packs/con-voyage/assets/scripts/cv-pr-comment.sh"

POSTING_STUB_DIR="$WORKDIR/stubs-posting"
mkdir -p "$POSTING_STUB_DIR"
cat > "$POSTING_STUB_DIR/gc" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "mail" ] && [ "\$2" = "send" ]; then
  echo "MAIL \$*" >> "${WORKDIR}/mail.log"
  exit 0
fi
if [ "\$1" = "bd" ] && [ "\$2" = "show" ]; then
  id="\$3"
  case "\$id" in
    "${ROOT_ID_VAL}")
      echo '{"id":"${ROOT_ID_VAL}","metadata":{"gc.var.finalize_key":"${FINALIZE_KEY_VAL}"}}'
      ;;
    *)
      echo '{}'
      ;;
  esac
  exit 0
fi
echo "gc-posting-stub: unexpected invocation: \$*" >&2
exit 1
STUB
chmod +x "$POSTING_STUB_DIR/gc"

POSTING_RUN_SCRIPT="$WORKDIR/posting-run.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  cat "$POSTING_FENCE_BODY"
} > "$POSTING_RUN_SCRIPT"
chmod +x "$POSTING_RUN_SCRIPT"

run_posting_fence() {
  (
    cd "$ISOLATED_DIR" && \
    env -i \
      PATH="${POSTING_STUB_DIR}:/usr/bin:/bin" \
      HOME="${HOME:-/tmp}" \
      GC_BEAD_ID="fk-bead" \
      GC_ROOT_BEAD_ID="$ROOT_ID_VAL" \
      GC_CITY="$ISOLATED_DIR" \
      GC_RIG_ROOT="$ISOLATED_DIR" \
      CV_LIB="${ISOLATED_DIR}/packs/con-voyage/assets/scripts/con-voyage-lib.sh" \
      CV_PACK_ROOT="${ISOLATED_DIR}/packs/con-voyage" \
      PR_NUMBER="42" \
      REPO_FULL="owner/repo" \
      REVIEW_ROUND="2" \
      STUB_CV_PR_COMMENT_SUCCEED="$1" \
      bash "$POSTING_RUN_SCRIPT" 2>&1
  )
}

start_case "the posting fence clears the deferred ci-repair pending-status once the aggregate comment post is CONFIRMED"
CV_STATE_DIR="${ISOLATED_DIR}/.gc/cv-pr-watch"
source "$REAL_LIB"
export CV_STATE_DIR
cv_defer_status_append "$FINALIZE_KEY_VAL" "ci-repair: a second deferred status, for the posting-fence cases" \
  || { echo "FATAL: could not seed a deferred status for the posting-fence cases" >&2; exit 2; }
POSTING_PENDING_FILE="${CV_STATE_DIR}/${FINALIZE_KEY_VAL}.pending-status"
[ -f "$POSTING_PENDING_FILE" ] || { echo "FATAL: expected ${POSTING_PENDING_FILE} to exist after seeding" >&2; exit 2; }

POSTING_OUT_OK="$(run_posting_fence "1")"
echo "$POSTING_OUT_OK"
if [ -f "$POSTING_PENDING_FILE" ]; then
  fail "the pending-status file still exists after a CONFIRMED successful post — it should have been cleared"
else
  pass "the pending-status file was cleared once the aggregate comment post was confirmed successful"
fi

start_case "the posting fence leaves the deferred ci-repair pending-status untouched when the aggregate comment post FAILS"
cv_defer_status_append "$FINALIZE_KEY_VAL" "ci-repair: a third deferred status, for the failed-post case" \
  || { echo "FATAL: could not re-seed a deferred status for the failed-post case" >&2; exit 2; }
[ -f "$POSTING_PENDING_FILE" ] || { echo "FATAL: expected ${POSTING_PENDING_FILE} to exist after re-seeding" >&2; exit 2; }

POSTING_OUT_FAIL="$(run_posting_fence "0")"
echo "$POSTING_OUT_FAIL"
if [ -f "$POSTING_PENDING_FILE" ]; then
  pass "the pending-status file survives a FAILED post — not silently discarded, available for the next round to re-peek"
else
  fail "the pending-status file was removed even though the post FAILED — this is exactly the data-loss fk-7bmhlz LOW-5 flags"
fi
rm -f "$POSTING_PENDING_FILE"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
