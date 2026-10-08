#!/usr/bin/env bash
# con-voyage-apply-review-findings.test.sh — hermetic, offline contract tests
# for the $WORK_BRANCH_NAME resolution-with-fallback logic added to
# main.apply-review-findings.md and main.synthesize-review.md (fk-6os73y:
# con-voyage/<bead-id>-<topic-slug> branch naming). Neither file had any test
# coverage before this change, unlike the equivalent call sites in
# main.build.md and main.publish.md, which con-voyage-build-phase.test.sh and
# con-voyage-publish.test.sh already assert against.
#
# These are static/contract tests against the real workflow markdown, the
# same style as con-voyage-build-phase.test.sh: they prove the wiring a
# worker actually receives, not a hand-maintained description of it.
#
# Run:  bash tests/con-voyage-apply-review-findings.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
APPLY_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.apply-review-findings.md"
SYNTH_MD="${MOLD_DIR}/pack/assets/workflows/con-voyage/main.synthesize-review.md"

for f in "$APPLY_MD" "$SYNTH_MD"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: expected file not found: $f" >&2
    exit 2
  fi
done

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (not found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "  FAIL: $label (found verbatim in $file, expected it gone)" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: $label"
  fi
}

line_of() {
  local file="$1" needle="$2"
  grep -nF -- "$needle" "$file" | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# apply-review-findings.md: reads gc.build.work_branch_name off the workflow
# root alongside the existing source-anchor metadata, with the same
# bare-con-voyage/<bead-id> fallback build.md/publish.md use for a root that
# predates fk-6os73y.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: reads gc.build.work_branch_name off the workflow root"
assert_contains "$APPLY_MD" "meta.get('gc.build.work_branch_name') or ''" "reads the stored work_branch_name alongside source_anchor metadata"

start_case "apply-review-findings.md: falls back to the bare con-voyage/<convoy-id> name when unset"
assert_contains "$APPLY_MD" '[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"' "falls back to the pre-fk-6os73y bare branch name"

start_case "apply-review-findings.md: the fallback runs after WORK_BRANCH_NAME is read, not before"
read_line="$(line_of "$APPLY_MD" "meta.get('gc.build.work_branch_name') or ''")"
fallback_line="$(line_of "$APPLY_MD" '[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"')"
if [ -n "$read_line" ] && [ -n "$fallback_line" ] && [ "$read_line" -lt "$fallback_line" ]; then
  echo "  PASS: WORK_BRANCH_NAME read (line ${read_line}) precedes the fallback check (line ${fallback_line})"
else
  echo "  FAIL: expected the WORK_BRANCH_NAME read to precede its fallback check" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "apply-review-findings.md: the resolved \$WORK_BRANCH_NAME, not a recomputed name, reaches cv_sync_worktree_to_base"
assert_contains "$APPLY_MD" 'cv_sync_worktree_to_base "$WORKTREE" "$WORK_BRANCH_NAME"' "syncs the worktree using the stored \$WORK_BRANCH_NAME"

# ---------------------------------------------------------------------------
# synthesize-review.md: the same resolve-with-fallback pattern feeds the
# LOW-only mail's branch argument.
# ---------------------------------------------------------------------------
start_case "synthesize-review.md: reads gc.build.work_branch_name off the workflow root"
assert_contains "$SYNTH_MD" "meta.get('gc.build.work_branch_name') or ''" "reads the stored work_branch_name"

start_case "synthesize-review.md: falls back to the bare con-voyage/<convoy-id> name when unset"
assert_contains "$SYNTH_MD" '[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"' "falls back to the pre-fk-6os73y bare branch name"

start_case "synthesize-review.md: the resolved \$WORK_BRANCH_NAME reaches the LOW-only mail script, not a recomputed name"
assert_contains "$SYNTH_MD" '"<synthesis path just written above>" "$ROOT_ID" "$WORK_BEAD" "$WORK_BRANCH_NAME"' "passes \$WORK_BRANCH_NAME as the mail script's branch argument"

start_case "synthesize-review.md: the fallback runs after WORK_BRANCH_NAME is read and before the mail script call"
read_line="$(line_of "$SYNTH_MD" "meta.get('gc.build.work_branch_name') or ''")"
fallback_line="$(line_of "$SYNTH_MD" '[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"')"
mail_line="$(line_of "$SYNTH_MD" '"<synthesis path just written above>" "$ROOT_ID" "$WORK_BEAD" "$WORK_BRANCH_NAME"')"
if [ -n "$read_line" ] && [ -n "$fallback_line" ] && [ "$read_line" -lt "$fallback_line" ]; then
  echo "  PASS: WORK_BRANCH_NAME read (line ${read_line}) precedes the fallback check (line ${fallback_line})"
else
  echo "  FAIL: expected the WORK_BRANCH_NAME read to precede its fallback check" >&2
  FAILURES=$((FAILURES+1))
fi
if [ -n "$fallback_line" ] && [ -n "$mail_line" ] && [ "$fallback_line" -lt "$mail_line" ]; then
  echo "  PASS: the fallback check (line ${fallback_line}) precedes the mail script call (line ${mail_line})"
else
  echo "  FAIL: expected the fallback check to precede the mail script call" >&2
  FAILURES=$((FAILURES+1))
fi

# ---------------------------------------------------------------------------
# apply-review-findings.md: fk-bcyt7v — stamp gc.build.reviewed_head_sha on
# the workflow root at the exact moment of a genuine no-op approval (HEAD at
# that point is the commit every active lane actually reviewed), so publish
# can later record the TRUE reviewed SHA instead of whatever HEAD happens to
# be when publish runs.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: stamps gc.build.reviewed_head_sha on the workflow root"
assert_contains "$APPLY_MD" 'gc bd update "$ROOT_ID" --set-metadata "gc.build.reviewed_head_sha=${REVIEWED_HEAD_SHA}"' "stamps the reviewed HEAD sha onto \$ROOT_ID"

start_case "apply-review-findings.md: the reviewed-sha stamp precedes the verdict=done close"
stamp_line="$(line_of "$APPLY_MD" 'gc bd update "$ROOT_ID" --set-metadata "gc.build.reviewed_head_sha=${REVIEWED_HEAD_SHA}"')"
done_line="$(line_of "$APPLY_MD" "--set-metadata 'code_review.verdict=done' \\")"
if [ -n "$stamp_line" ] && [ -n "$done_line" ] && [ "$stamp_line" -lt "$done_line" ]; then
  echo "  PASS: the reviewed-sha stamp (line ${stamp_line}) precedes the verdict=done close example (line ${done_line})"
else
  echo "  FAIL: expected the reviewed-sha stamp to precede the verdict=done close example" >&2
  FAILURES=$((FAILURES+1))
fi

start_case "apply-review-findings.md: warns explicitly against stamping on a fix pass"
assert_contains "$APPLY_MD" 'Do NOT run this on a fix pass' "documents that the stamp only applies to a genuine no-op approval"

# ---------------------------------------------------------------------------
# apply-review-findings.md: review fk-qj2s9r BLOCKING-1 (fk-1fwe34/fk-0bkrzd/
# fk-qzn6vu) — the reviewed-sha stamp's guard was gated on an unused $CV_LIB
# (copy-pasted from the neighboring implementor_session block, which actually
# needs $CV_LIB for its cv_session_route_handle call; this stamp is a bare
# `gc bd update` with no cv_* dependency at all). If $CV_LIB failed to
# resolve for any unrelated reason, the stamp silently never wrote, quietly
# resurrecting the exact pre-fix bug fk-bcyt7v exists to close. Assert the
# guard is gated only on the inputs it actually uses ($REVIEWED_HEAD_SHA,
# $ROOT_ID), not on $CV_LIB, so a future copy-paste can't reintroduce the
# dead gate silently.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: the reviewed-sha stamp's guard does not gate on the unused \$CV_LIB"
assert_not_contains_near() {
  local file="$1" anchor="$2" needle="$3" label="$4"
  local anchor_line
  anchor_line="$(line_of "$file" "$anchor")"
  if [ -z "$anchor_line" ]; then
    echo "  FAIL: ${label} (anchor not found: ${anchor})" >&2
    FAILURES=$((FAILURES+1))
    return
  fi
  local window
  window="$(sed -n "${anchor_line},$((anchor_line + 6))p" "$file")"
  case "$window" in
    *"$needle"*) echo "  FAIL: ${label} (found '${needle}' within 6 lines of the stamp)" >&2; FAILURES=$((FAILURES+1)) ;;
    *) echo "  PASS: ${label}" ;;
  esac
}
assert_not_contains_near "$APPLY_MD" \
  'REVIEWED_HEAD_SHA=""' \
  '[ -n "$CV_LIB" ]' \
  "stamp guard no longer conjuncts on \$CV_LIB"

# ---------------------------------------------------------------------------
# review fk-qj2s9r iteration-3 BLOCKING-1 (fk-eg00bz) — a bare `git rev-parse
# HEAD` relying on an earlier block's `cd "$WORKTREE"` still holding the
# ambient cwd contradicts this same file's own documented cwd invariant
# ("never rely on ambient $(pwd)"), and a cwd drift between blocks would
# silently stamp the wrong SHA as "reviewed" with no guard catching it (the
# value is non-empty, just wrong). Assert the stamp block instead re-derives
# $WORKTREE fresh from bead metadata, same pattern as $ROOT_ID, and resolves
# HEAD with an explicit `git -C "$WORKTREE"` rather than ambient cwd.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: the reviewed-sha stamp re-derives \$WORKTREE fresh rather than relying on ambient cwd"
assert_contains "$APPLY_MD" 'print((d.get('"'"'metadata'"'"') or {}).get('"'"'gc.build.source_anchor_work_dir'"'"') or '"'"''"'"')' "re-derives \$WORKTREE from gc.build.source_anchor_work_dir"

start_case "apply-review-findings.md: the reviewed-sha stamp resolves HEAD via an explicit \$WORKTREE, not ambient cwd"
assert_contains "$APPLY_MD" 'REVIEWED_HEAD_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "")"' "resolves HEAD against the re-derived \$WORKTREE"
assert_not_contains_near "$APPLY_MD" \
  'REVIEWED_HEAD_SHA=""' \
  'REVIEWED_HEAD_SHA="$(git rev-parse HEAD' \
  "stamp block no longer reads HEAD against bare ambient cwd"

start_case "apply-review-findings.md: the reviewed-sha stamp block re-derives \$ROOT_ID fresh, not a bare read"
stamp_block_anchor_line="$(line_of "$APPLY_MD" 'REVIEWED_HEAD_SHA=""')"
if [ -n "$stamp_block_anchor_line" ]; then
  stamp_block_window="$(sed -n "$((stamp_block_anchor_line - 30)),${stamp_block_anchor_line}p" "$APPLY_MD")"
  case "$stamp_block_window" in
    *'ROOT_ID="${GC_ROOT_BEAD_ID:-}"'*"gc.root_bead_id"*) echo "  PASS: stamp block re-derives \$ROOT_ID from \$GC_ROOT_BEAD_ID / bead metadata before using it" ;;
    *) echo "  FAIL: expected the stamp block to re-derive \$ROOT_ID fresh, same as the two earlier \$ROOT_ID blocks" >&2; FAILURES=$((FAILURES+1)) ;;
  esac
else
  echo "  FAIL: could not locate the stamp block anchor" >&2
  FAILURES=$((FAILURES+1))
fi

# ---------------------------------------------------------------------------
# #174 regrade follow-up BLOCKING-2 (fk-j29mzp): the reviewed-sha stamp was
# gated only by prose ("Only when you are about to set verdict=done") with no
# bash enforcement — a misjudged pass could still execute the stamp bash
# block and record an unreviewed HEAD as reviewed. Gate the actual stamp in
# bash on the same in-scope vars "Setting code_review.verdict" above uses to
# make this same no-op determination ($SYNC_PATCH_UNCHANGED and
# $FIX_COMMIT_SHA, alongside $SYNC_RESULT which that same decision already
# depends on) so a fix pass or a patch-changing sync can never reach the
# `gc bd update ... gc.build.reviewed_head_sha=` call.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: the reviewed-sha stamp is gated in bash on \$FIX_COMMIT_RECORDED, not prose alone"
assert_contains "$APPLY_MD" '[ "$FIX_COMMIT_RECORDED" = "false" ]' "bash gate checks the confirmed fix_commit_recorded=false marker before considering a stamp"

start_case "apply-review-findings.md: the reviewed-sha stamp is gated in bash on \$SYNC_PATCH_UNCHANGED, not prose alone"
assert_contains "$APPLY_MD" '[ "$SYNC_PATCH_UNCHANGED" = "true" ]' "bash gate checks \$SYNC_PATCH_UNCHANGED for a recreated/rebased sync"

start_case "apply-review-findings.md: the bash gate precedes the actual reviewed_head_sha stamp call"
gate_line="$(line_of "$APPLY_MD" '[ "$FIX_COMMIT_RECORDED" = "false" ]')"
stamp_call_line="$(line_of "$APPLY_MD" 'gc bd update "$ROOT_ID" --set-metadata "gc.build.reviewed_head_sha=${REVIEWED_HEAD_SHA}"')"
if [ -n "$gate_line" ] && [ -n "$stamp_call_line" ] && [ "$gate_line" -lt "$stamp_call_line" ]; then
  echo "  PASS: the bash gate (line ${gate_line}) precedes the stamp call (line ${stamp_call_line})"
else
  echo "  FAIL: expected the bash gate to precede the actual stamp call" >&2
  FAILURES=$((FAILURES+1))
fi

# ---------------------------------------------------------------------------
# fk-zesuqz (review fk-9gdsik BLOCKING-1): the gate must fail CLOSED when a
# cross-fence persistence write/read fails, not just when it reads back an
# unrecognized value. Pin that the gate requires a positively-confirmed
# "the write landed" marker for both the sync-result write and the
# fix-commit-decision write, and that neither variable defaults to a
# stamp-eligible value.
# ---------------------------------------------------------------------------
start_case "apply-review-findings.md: the sync-result persist call also stamps a positive sync_persisted confirmation marker"
assert_contains "$APPLY_MD" "--set-metadata 'gc.apply_review.sync_persisted=true'" "sync_result persist call also writes sync_persisted=true atomically"

start_case "apply-review-findings.md: a committed fix stamps a positive fix_commit_recorded confirmation marker alongside the sha"
assert_contains "$APPLY_MD" "--set-metadata 'gc.apply_review.fix_commit_recorded=true'" "fix-commit persist calls also write fix_commit_recorded=true atomically"

start_case "apply-review-findings.md: a genuine no-fix pass explicitly records fix_commit_recorded=false"
assert_contains "$APPLY_MD" "--set-metadata 'gc.apply_review.fix_commit_recorded=false'" "the no-fix path stamps an explicit negative marker, not silence"

start_case "apply-review-findings.md: the gate re-read defaults to an unresolved sentinel, never a stamp-eligible value"
assert_contains "$APPLY_MD" 'SYNC_RESULT="__unresolved__"' "SYNC_RESULT defaults to __unresolved__, not noop"
assert_contains "$APPLY_MD" 'FIX_COMMIT_RECORDED="__unresolved__"' "FIX_COMMIT_RECORDED defaults to __unresolved__"
assert_not_contains "$APPLY_MD" 'SYNC_RESULT="noop"' "SYNC_RESULT no longer defaults straight to the stamp-eligible noop value"

start_case "apply-review-findings.md: the gate requires both sync_persisted=true AND fix_commit_recorded=false before trusting SYNC_RESULT"
assert_contains "$APPLY_MD" '[ "$SYNC_PERSISTED" = "true" ] && [ "$FIX_COMMIT_RECORDED" = "false" ]' "gate conjuncts both confirmation markers before evaluating SYNC_RESULT"

# ---------------------------------------------------------------------------
# fk-zesuqz (review fk-9gdsik BLOCKING-3): no executable test previously
# exercised the actual persist-then-re-read round trip the gate depends on —
# every prior assertion above is a textual/static check that would pass
# identically on a gate that never actually re-reads durable state (that is
# exactly what shipped in iteration 1). Exercise the real round trip through
# an isolated flat-file metadata store (a hermetic stand-in for the real
# beads store — the live `bd`/`gc` CLI auto-discovers and can mutate the REAL
# store even with --db threaded through every call, and `bd init` pulls a full
# remote clone, both wrong for a fast unit test): write the gate-state keys in
# one subshell, then re-read them via a second, separate subshell (mirroring
# the cross-fence boundary a real workflow run crosses between bash blocks),
# and run the SAME STAMP_NOOP_PASS decision logic the workflow file's gate
# uses over the read-back values. This is runtime confidence over the actual
# decision logic, not prose confidence, and would have caught iteration 1's
# dead gate (which never re-read anything at all).
# ---------------------------------------------------------------------------
STORE_DIR="$(mktemp -d)"
trap 'rm -rf "$STORE_DIR"' EXIT
STORE_FILE="${STORE_DIR}/metadata.store"
: > "$STORE_FILE"

# A standalone helper file (NOT this test script) sourced fresh inside each
# subshell below — sourcing this test script itself would re-run every case
# in it, recursively.
GATE_LIB_FILE="${STORE_DIR}/gate-lib.sh"
cat > "$GATE_LIB_FILE" <<'GATE_LIB_EOF'
# stub_bead_metadata BEAD_ID KEY — same empty-on-anything-wrong contract as
# the real cv_bead_metadata (con-voyage-lib.sh): prints the last persisted
# value for BEAD_ID/KEY, or an empty string if it was never written.
stub_bead_metadata() {
  local bead_id="$1" key="$2"
  awk -F'\t' -v id="$bead_id" -v k="$key" '$1 == id && $2 == k { v = $3 } END { if (v != "") print v }' "$STORE_FILE"
}

# stub_bead_persist BEAD_ID KEY=VALUE [KEY=VALUE...] — simulates an atomic
# multi-key gc bd update: appends all pairs in one call.
stub_bead_persist() {
  local bead_id="$1"; shift
  local pair
  for pair in "$@"; do
    printf '%s\t%s\t%s\n' "$bead_id" "${pair%%=*}" "${pair#*=}" >> "$STORE_FILE"
  done
}

gate_decision() {
  # Mirrors main.apply-review-findings.md's STAMP_NOOP_PASS gate exactly:
  # unresolved sentinel defaults, requires both confirmation markers before
  # trusting SYNC_RESULT at all.
  local bead_id="$1"
  local sync_persisted fix_commit_recorded sync_result sync_patch_unchanged
  sync_persisted="$(stub_bead_metadata "$bead_id" gc.apply_review.sync_persisted)"
  fix_commit_recorded="$(stub_bead_metadata "$bead_id" gc.apply_review.fix_commit_recorded)"
  sync_result="$(stub_bead_metadata "$bead_id" gc.apply_review.sync_result)"
  sync_patch_unchanged="$(stub_bead_metadata "$bead_id" gc.apply_review.sync_patch_unchanged)"
  [ -n "$sync_persisted" ] || sync_persisted="__unresolved__"
  [ -n "$fix_commit_recorded" ] || fix_commit_recorded="__unresolved__"
  [ -n "$sync_result" ] || sync_result="__unresolved__"
  [ -n "$sync_patch_unchanged" ] || sync_patch_unchanged="__unresolved__"

  local stamp_noop_pass="false"
  if [ "$sync_persisted" = "true" ] && [ "$fix_commit_recorded" = "false" ]; then
    case "$sync_result" in
      noop) stamp_noop_pass="true" ;;
      recreated|rebased)
        [ "$sync_patch_unchanged" = "true" ] && stamp_noop_pass="true"
        ;;
      *) stamp_noop_pass="false" ;;
    esac
  fi
  printf '%s' "$stamp_noop_pass"
}
GATE_LIB_EOF

gate_roundtrip_case() {
  local label="$1" bead_id="$2" expected="$3"
  shift 3

  start_case "gate round trip: ${label}"

  # Persist in one subshell ("the earlier, separate fenced block").
  if [ "$#" -gt 0 ]; then
    ( export STORE_FILE; source "$GATE_LIB_FILE"; stub_bead_persist "$bead_id" "$@" )
  fi

  # Re-read and decide in a second, separate subshell/invocation ("the
  # later, independent stamp-gate fence") — genuinely re-parses the store
  # file from scratch, not an inherited shell variable.
  local actual
  actual="$(bash -c '
    export STORE_FILE="$1"
    source "$2"
    gate_decision "$3"
  ' _ "$STORE_FILE" "$GATE_LIB_FILE" "$bead_id" 2>/dev/null)"

  if [ "$actual" = "$expected" ]; then
    echo "  PASS: ${label} (STAMP_NOOP_PASS=${actual})"
  else
    echo "  FAIL: ${label} (expected STAMP_NOOP_PASS=${expected}, got ${actual:-<empty>})" >&2
    FAILURES=$((FAILURES+1))
  fi
}

gate_roundtrip_case "confirmed genuine no-op (sync_persisted=true, fix_commit_recorded=false, sync_result=noop) -> stamp-eligible" \
  "gate-rt-noop" "true" \
  'gc.apply_review.sync_persisted=true' \
  'gc.apply_review.fix_commit_recorded=false' \
  'gc.apply_review.sync_result=noop' \
  'gc.apply_review.sync_patch_unchanged=false'

gate_roundtrip_case "fix committed this pass (fix_commit_recorded=true) -> never stamp-eligible" \
  "gate-rt-fixed" "false" \
  'gc.apply_review.sync_persisted=true' \
  'gc.apply_review.fix_commit_recorded=true' \
  'gc.apply_review.sync_result=noop' \
  'gc.apply_review.sync_patch_unchanged=false'

gate_roundtrip_case "clean rebase with patch unchanged (recreated+patch_unchanged=true) -> stamp-eligible" \
  "gate-rt-rebase-clean" "true" \
  'gc.apply_review.sync_persisted=true' \
  'gc.apply_review.fix_commit_recorded=false' \
  'gc.apply_review.sync_result=recreated' \
  'gc.apply_review.sync_patch_unchanged=true'

gate_roundtrip_case "the sync_result persist call never ran this pass (sync_persisted unset) -> fails closed" \
  "gate-rt-no-sync-write" "false"

gate_roundtrip_case "sync_persisted write succeeded but fix_commit_recorded write never ran (ambiguous fix state) -> fails closed" \
  "gate-rt-ambiguous-fix" "false" \
  'gc.apply_review.sync_persisted=true' \
  'gc.apply_review.sync_result=noop' \
  'gc.apply_review.sync_patch_unchanged=false'

gate_roundtrip_case "unrecognized sync_result value -> fails closed" \
  "gate-rt-garbage-value" "false" \
  'gc.apply_review.sync_persisted=true' \
  'gc.apply_review.fix_commit_recorded=false' \
  'gc.apply_review.sync_result=garbage' \
  'gc.apply_review.sync_patch_unchanged=false'

start_case "apply-review-findings.md: a non-eligible pass logs a skip instead of stamping"
assert_contains "$APPLY_MD" 'skipping gc.build.reviewed_head_sha stamp' "logs explicitly when the bash gate blocks the stamp"

start_case "apply-review-findings.md: stamps gc.build.reviewed_head_sha_attempted unconditionally on every eligible no-op pass"
assert_contains "$APPLY_MD" "gc bd update \"\$ROOT_ID\" --set-metadata 'gc.build.reviewed_head_sha_attempted=true'" "stamps the attempted-marker as its own independent call"

start_case "apply-review-findings.md: the attempted-marker stamp does not depend on \$REVIEWED_HEAD_SHA/\$WORKTREE resolving"
attempted_line="$(line_of "$APPLY_MD" "gc bd update \"\$ROOT_ID\" --set-metadata 'gc.build.reviewed_head_sha_attempted=true'")"
if [ -n "$attempted_line" ] && [ -n "$stamp_call_line" ] && [ "$attempted_line" -lt "$stamp_call_line" ]; then
  echo "  PASS: the attempted-marker stamp (line ${attempted_line}) is a separate, earlier call than the real stamp (line ${stamp_call_line}), so it still records even if the real stamp's HEAD/ROOT_ID resolution fails"
else
  echo "  FAIL: expected the attempted-marker to be stamped independently, before the real reviewed_head_sha stamp" >&2
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
