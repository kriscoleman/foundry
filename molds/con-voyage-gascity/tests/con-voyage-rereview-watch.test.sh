#!/usr/bin/env bash
# con-voyage-rereview-watch.test.sh — hermetic, offline tests for fk-pubvq:
# con-voyage-rereview-watch.sh, the post-publish re-review trigger that
# closes the gap where a human-feedback or ci-repair bead pushes a new,
# code-changing commit to an already-published con-voyage PR with no review
# lane ever re-running against it (live evidence: replicatedhq/vandoor#10589).
#
# HOW IT WORKS: real local git repos for the patch-id comparison (mirrors
# con-voyage-sync-base.test.sh's mk_repo/git_c pattern — git's own
# fetch/checkout/patch-id behavior is exactly what's under test there), and
# recording STUB `gh`/`gc` executables for everything else (PR state, mail,
# bd create/sling/set-state), the same idiom con-voyage-ci-repair-guard.test.sh
# and con-voyage-pr-watch.test.sh use.
#
# Run:  bash tests/con-voyage-rereview-watch.test.sh   (exit 0 => all passed)

set -uo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-rereview-watch.sh"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"

for f in "$SCRIPT" "$LIB"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: required file not found at ${f}" >&2
    exit 2
  fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-rereview-watch-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then pass "${desc} (=${actual})"; else fail "${desc}: expected '${expected}', got '${actual}'"; fi
}
assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
    *"$needle"*) pass "$desc" ;;
    *) fail "${desc}: expected to find '${needle}'" ;;
  esac
}
assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
    *"$needle"*) fail "${desc}: did NOT expect to find '${needle}'" ;;
    *) pass "$desc" ;;
  esac
}

# ---------------------------------------------------------------------------
# mk_repo NAME / git_c DIR ARGS... — local git fixture helpers (mirrors
# con-voyage-sync-base.test.sh).
# ---------------------------------------------------------------------------
mk_repo() {
  local name="$1"
  local dir="${SANDBOX}/${name}"
  git init -q -b main "$dir" >/dev/null
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  printf 'hello\n' > "${dir}/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "chore: initial commit"
  printf '%s' "$dir"
}
git_c() { local dir="$1"; shift; git -C "$dir" "$@"; }

# ---------------------------------------------------------------------------
# gh stub — serves `pr view <n> --repo R --json state,headRefOid,headRefName`.
# Keyed by STUB_GH_STATE_<n>/STUB_GH_HEAD_<n>/STUB_GH_BRANCH_<n>.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GH_LOG}"
sub="${1:-}"
case "$sub" in
  pr)
    prsub="${2:-}"
    num="${3:-}"
    if [ "$prsub" = "view" ]; then
      eval "state=\"\${STUB_GH_STATE_${num}:-}\""
      eval "head=\"\${STUB_GH_HEAD_${num}:-}\""
      eval "branch=\"\${STUB_GH_BRANCH_${num}:-}\""
      if [ -z "$state" ]; then exit 1; fi
      printf '{"state":"%s","headRefOid":"%s","headRefName":"%s"}\n' "$state" "$head" "$branch"
      exit 0
    fi
    ;;
esac
exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

# ---------------------------------------------------------------------------
# gc stub — records every call. `bd create` returns a fixed id (STUB_GC_NEW_BEAD_ID,
# default "rc-seed1"). `sling`/`mail send`/`bd set-state` always succeed and
# are recorded; `mail send ... --json` prints a fake message id.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG}"

args=("$@")
i=0
if [ "${args[0]:-}" = "--city" ]; then i=2; fi
if [ "${args[$i]:-}" = "--rig" ]; then i=$((i+2)); fi
sub="${args[$i]:-}"
sub2="${args[$((i+1))]:-}"

if [ "$sub" = "bd" ] && [ "$sub2" = "create" ]; then
  printf '%s\n' "${STUB_GC_NEW_BEAD_ID:-rc-seed1}"
  exit 0
fi
if [ "$sub" = "bd" ] && [ "$sub2" = "set-state" ]; then
  if [ -n "${STUB_GC_SETSTATE_SLEEP:-}" ]; then
    sleep "$STUB_GC_SETSTATE_SLEEP"
  fi
  exit 0
fi
if [ "$sub" = "bd" ] && [ "$sub2" = "show" ]; then
  id="${args[$((i+2))]:-}"
  depcount=0
  if [ -n "${STUB_GC_DEPCOUNT_DIR:-}" ] && [ -f "${STUB_GC_DEPCOUNT_DIR}/${id}" ]; then
    depcount="$(cat "${STUB_GC_DEPCOUNT_DIR}/${id}")"
  fi
  printf '{"dependent_count": %s}\n' "$depcount"
  exit 0
fi
if [ "$sub" = "bd" ] && [ "$sub2" = "close" ]; then
  exit 0
fi
if [ "$sub" = "sling" ]; then
  if [ -n "${STUB_GC_SLING_SLEEP:-}" ]; then
    sleep "$STUB_GC_SLING_SLEEP"
  fi
  if [ "${STUB_GC_SLING_FAIL:-0}" = "1" ]; then
    echo "sling failed (stub)" >&2
    exit 1
  fi
  exit 0
fi
if [ "$sub" = "mail" ]; then
  printf '{"message":{"id":"msg-1"}}\n'
  exit 0
fi
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

export PATH="${STUBDIR}:${PATH}"
export STUB_GH_LOG="${SANDBOX}/gh.log"
export STUB_GC_LOG="${SANDBOX}/gc.log"
export GH="${STUBDIR}/gh"
export GC="${STUBDIR}/gc"
export CV_PR_AUTHOR="kriscoleman"
export CV_REREVIEW_RIG="testrig"
export GC_CITY="${SANDBOX}/city"
mkdir -p "$GC_CITY"

run_watch() {
  : > "$STUB_GH_LOG"
  : > "$STUB_GC_LOG"
  CV_STATE_DIR="$STATE_DIR" CV_REPO_CACHE_DIR="$REPO_CACHE_DIR" bash "$SCRIPT" 2>&1
}

STATE_DIR="${SANDBOX}/state"
REPO_CACHE_DIR="${SANDBOX}/repo-cache"
mkdir -p "$STATE_DIR" "$REPO_CACHE_DIR"

# ===========================================================================
# Shared fixture: a local "GitHub" upstream + a pre-seeded non-bare clone
# standing in for the script's own repo-cache (same path shape
# repo_cache_dir() computes: "<owner>-<repo>" under CV_REPO_CACHE_DIR).
# ===========================================================================
REPO_FULL="acme-owner/acme-repo"
UPSTREAM="${SANDBOX}/upstream.git"
git init -q -b main --bare "$UPSTREAM"
SRC="$(mk_repo src)"
git_c "$SRC" remote add origin "$UPSTREAM"
git_c "$SRC" push -q -u origin main
BASE_SHA="$(git_c "$SRC" rev-parse main)"

# The PR's own branch — main itself never advances again in this fixture
# (classify_head_change resolves the CURRENT default base, origin/main, as
# the shared anchor for isolating "whose own commits" on both old and new
# head; main must stay put here the same way a repo's real trunk does while
# a feature branch is still open).
git_c "$SRC" checkout -q -b feature-branch

# Round-1 published head: one real feature commit.
printf 'v1\n' > "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "feat: original change"
PUBLISHED_HEAD="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q -u origin feature-branch

CACHE_DIR="${REPO_CACHE_DIR}/$(printf '%s' "$REPO_FULL" | tr '/' '-')"
git clone -q "$UPSTREAM" "$CACHE_DIR"

write_finalize() {
  local key="$1" work_bead="$2" last_phase="$3" last_head="$4" round="$5" rereview_root="$6"
  local pr_number="${7:-42}"
  {
    printf 'work_bead=%s\n' "$work_bead"
    printf 'convoy_id=%s\n' "fk-convoy1"
    printf 'repo_full=%s\n' "$REPO_FULL"
    printf 'pr_number=%s\n' "$pr_number"
    printf 'pr_author=%s\n' "kriscoleman"
    printf 'implementor_session=%s\n' "testrig/gc.implementation-worker"
    printf 'last_phase=%s\n' "$last_phase"
    printf 'root_bead_id=%s\n' "fk-root1"
    printf 'roster_vars=%s\n' "enable_sre=true,code_lens=con-voyage.cv-go-principal-engineer"
    printf 'last_reviewed_head_sha=%s\n' "$last_head"
    printf 'review_round=%s\n' "$round"
    printf 'rereview_root_bead_id=%s\n' "$rereview_root"
  } > "${STATE_DIR}/${key}.finalize"
}

# ===========================================================================
# CASE 1: head unchanged (CI-only re-run / nothing new) -> no-op
# ===========================================================================
start_case "1: PR head unchanged -> no re-review, no sling"
write_finalize "cv-finalize-case1" "fk-work1" "awaiting_merge" "$PUBLISHED_HEAD" "1" ""
export STUB_GH_STATE_42="OPEN" STUB_GH_HEAD_42="$PUBLISHED_HEAD" STUB_GH_BRANCH_42="feature-branch"
out1="$(run_watch)"
assert_contains "$out1" "head unchanged" "diagnostic reports head unchanged"
gc_log1="$(cat "$STUB_GC_LOG")"
assert_not_contains "$gc_log1" "sling" "no gc sling call for an unchanged head"
assert_not_contains "$gc_log1" "mail" "no mayor mail for an unchanged head"

# ===========================================================================
# CASE 2: head changed but patch content is IDENTICAL (e.g. a force-push
# re-landing the same diff) -> treated as rebase-only, bookkeeping advances,
# no re-review triggered.
# ===========================================================================
start_case "2: new head is a content-identical replay -> advance bookkeeping, no re-review"
git_c "$SRC" reset -q --hard "$BASE_SHA"
printf 'v1\n' > "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "feat: original change (recommitted)"
REPLAY_HEAD="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q -f origin feature-branch

write_finalize "cv-finalize-case2" "fk-work2" "awaiting_merge" "$PUBLISHED_HEAD" "1" ""
export STUB_GH_STATE_42="OPEN" STUB_GH_HEAD_42="$REPLAY_HEAD" STUB_GH_BRANCH_42="feature-branch"
out2="$(run_watch)"
assert_contains "$out2" "content-identical replay" "diagnostic reports a content-identical replay"
gc_log2="$(cat "$STUB_GC_LOG")"
assert_not_contains "$gc_log2" "sling" "no gc sling call for a content-identical replay"
assert_not_contains "$gc_log2" "mail" "no mayor mail for a content-identical replay"
rec2="$(cat "${STATE_DIR}/cv-finalize-case2.finalize")"
assert_contains "$rec2" "last_reviewed_head_sha=${REPLAY_HEAD}" "bookkeeping advanced to the new (replay) head"
assert_contains "$rec2" "review_round=1" "review_round NOT incremented for a non-triggering replay"
if grep -qx "rereview_root_bead_id=" "${STATE_DIR}/cv-finalize-case2.finalize"; then
  pass "rereview_root_bead_id stays empty for a non-triggering replay"
else
  fail "rereview_root_bead_id stays empty for a non-triggering replay: got $(grep rereview_root_bead_id "${STATE_DIR}/cv-finalize-case2.finalize")"
fi

# cases 1/2's own records are fully exercised and no longer needed. Remove
# them before case 3 (fk-marojd's one-dispatch-per-sweep budget, added below,
# means a stray OLD record that ALSO now looks "changed" relative to the
# shared PR#42 fixture head would steal the single dispatch slot a later
# case's assertions expect to see for ITS OWN record).
rm -f "${STATE_DIR}/cv-finalize-case1.finalize" "${STATE_DIR}/cv-finalize-case2.finalize"

# ===========================================================================
# CASE 3: head changed with a REAL new patch -> triggers a re-review round
# ===========================================================================
start_case "3: a genuinely new code change -> mail mayor, sling con-voyage-rereview, update finalize record"
printf 'v2 - a real fix\n' >> "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "fix: address human PR feedback"
CHANGED_HEAD="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q origin feature-branch

write_finalize "cv-finalize-case3" "fk-work3" "awaiting_merge" "$REPLAY_HEAD" "1" ""
export STUB_GH_STATE_42="OPEN" STUB_GH_HEAD_42="$CHANGED_HEAD" STUB_GH_BRANCH_42="feature-branch"
export STUB_GC_NEW_BEAD_ID="rc-seed42"
out3="$(run_watch)"
assert_contains "$out3" "TRIGGER" "diagnostic reports a trigger"
assert_contains "$out3" "dispatched re-review round 2" "diagnostic reports round 2 dispatched"
gc_log3="$(cat "$STUB_GC_LOG")"
assert_contains "$gc_log3" "mail send mayor -s RE-REVIEW PENDING:" "mayor mailed RE-REVIEW PENDING"
assert_contains "$gc_log3" "sling testrig/gc.run-operator rc-seed42 --on con-voyage-rereview" "sling invoked with the pre-created seed bead"
assert_contains "$gc_log3" "--var repo=${REPO_FULL}" "sling carries repo var"
assert_contains "$gc_log3" "--var pr=42" "sling carries pr var"
assert_contains "$gc_log3" "--var review_round=2" "sling carries incremented review_round"
assert_contains "$gc_log3" "--var enable_sre=true" "sling carries the ORIGINAL roster var (enable_sre)"
assert_contains "$gc_log3" "bd set-state fk-work3 cv=re_reviewing" "work bead parked at cv=re_reviewing"
rec3="$(cat "${STATE_DIR}/cv-finalize-case3.finalize")"
assert_contains "$rec3" "last_reviewed_head_sha=${CHANGED_HEAD}" "finalize record advances to the new head"
assert_contains "$rec3" "review_round=2" "finalize record's review_round incremented"
assert_contains "$rec3" "rereview_root_bead_id=rc-seed42" "finalize record carries the new round's seed bead id"
assert_contains "$rec3" "last_phase=re_reviewing" "finalize record's last_phase set to re_reviewing"
if [ -d "${STATE_DIR}/.locks/cv-finalize-case3.lock" ]; then
  fail "dedup lock released after a successful dispatch (case3)"
else
  pass "dedup lock released after a successful dispatch (case3)"
fi

# ===========================================================================
# CASE 4: a re-review round is already in flight -> never a second dispatch,
# regardless of the current head.
# ===========================================================================
start_case "4: re-review already in flight -> no duplicate dispatch"
write_finalize "cv-finalize-case4" "fk-work4" "re_reviewing" "$REPLAY_HEAD" "2" "rc-already-running"
export STUB_GH_STATE_42="OPEN" STUB_GH_HEAD_42="$CHANGED_HEAD" STUB_GH_BRANCH_42="feature-branch"
out4="$(run_watch)"
assert_contains "$out4" "already in flight" "diagnostic reports an in-flight round"
gh_log4="$(cat "$STUB_GH_LOG")"
# cv-finalize-case3 from the prior case is STILL in the state dir (each case's
# fixture persists), so case3's own pr view call is expected in this log;
# assert instead that NO additional sling happened for case4 specifically by
# checking gc log has exactly as many sling lines as case3 alone produced.
gc_log4="$(cat "$STUB_GC_LOG")"
sling_count4="$(printf '%s\n' "$gc_log4" | grep -c 'sling testrig' || true)"
assert_eq "0" "$sling_count4" "no NEW sling call this cycle (case4's own record never reaches the sling path)"

# ===========================================================================
# CASE 5: author mismatch -> skip entirely, fail closed
# ===========================================================================
start_case "5: author mismatch -> skip (fail closed)"
{
  printf 'work_bead=fk-work5\n'
  printf 'convoy_id=fk-convoy5\n'
  printf 'repo_full=%s\n' "$REPO_FULL"
  printf 'pr_number=43\n'
  printf 'pr_author=someone-else\n'
  printf 'implementor_session=\n'
  printf 'last_phase=awaiting_merge\n'
  printf 'root_bead_id=fk-root5\n'
  printf 'roster_vars=\n'
  printf 'last_reviewed_head_sha=%s\n' "$PUBLISHED_HEAD"
  printf 'review_round=1\n'
  printf 'rereview_root_bead_id=\n'
} > "${STATE_DIR}/cv-finalize-case5.finalize"
out5="$(run_watch)"
assert_contains "$out5" "SKIP" "case5 record is skipped"
assert_contains "$out5" "author scoping" "skip reason names author scoping"

# ===========================================================================
# CASE 6: PR already MERGED/CLOSED -> con-voyage-finalize.sh's job, not ours
# ===========================================================================
start_case "6: PR state is not OPEN -> skip, no dispatch"
write_finalize "cv-finalize-case6" "fk-work6" "awaiting_merge" "$PUBLISHED_HEAD" "1" ""
export STUB_GH_STATE_42="MERGED" STUB_GH_HEAD_42="$CHANGED_HEAD" STUB_GH_BRANCH_42="feature-branch"
out6="$(run_watch)"
assert_contains "$out6" "PR not OPEN" "diagnostic reports PR is not OPEN"
# STUB_GH_STATE_42 is left at "MERGED" from here on so every pr-42 record
# above (cases 1-6) stays permanently skipped in every later sweep below —
# the timeout/recovery cases need a sweep where ONLY their own PR is live,
# so they use a separate PR number (44) instead of fighting case1-6's
# leftover records for this script's one-dispatch-per-sweep budget.

# ===========================================================================
# CASE 7 (fk-marojd acceptance 1): a sling slower than the quick STORE
# timeout but still under its OWN, larger CV_REREVIEW_SLING_TIMEOUT_SECONDS
# bound -> the round still dispatches and the root is recorded. This is the
# literal bug: before the fix, every sling here was wrapped in the 30s store
# bound and killed before it could ever finish.
# ===========================================================================
start_case "7: sling slower than the store timeout but under its own sling timeout -> still dispatches"
printf 'v3 - case7 change\n' >> "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "fix: case7 change"
HEAD7="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q origin feature-branch

write_finalize "cv-finalize-case7" "fk-work7" "awaiting_merge" "$CHANGED_HEAD" "2" "" "44"
export STUB_GH_STATE_44="OPEN" STUB_GH_HEAD_44="$HEAD7" STUB_GH_BRANCH_44="feature-branch"
export STUB_GC_NEW_BEAD_ID="rc-seed7"
export CV_LENS_STORE_TIMEOUT_SECONDS=1
export CV_REREVIEW_SLING_TIMEOUT_SECONDS=3
export STUB_GC_SLING_SLEEP=1.5
out7="$(run_watch)"
assert_contains "$out7" "dispatched re-review round 3" "round dispatched despite a sling slower than the store timeout"
rec7="$(cat "${STATE_DIR}/cv-finalize-case7.finalize")"
assert_contains "$rec7" "rereview_root_bead_id=rc-seed7" "finalize record carries the new root after a slow-but-successful sling"
if [ -f "${STATE_DIR}/cv-finalize-case7.rereview-pending" ]; then
  fail "no leftover pending marker after a successful sling"
else
  pass "no leftover pending marker after a successful sling"
fi
unset STUB_GC_SLING_SLEEP

# ===========================================================================
# CASE 8 (fk-marojd acceptance 2): a sling that exceeds its OWN sling
# timeout -> the first sweep names the timeout/duration, leaves the seed
# pending (ambiguous, not a confirmed failure) and does NOT record a root;
# the second sweep finds it never attached, closes it as orphaned, and mints
# exactly one fresh seed instead of leaving two beads open.
# ===========================================================================
start_case "8: sling exceeds its own sling timeout -> timeout logged, seed left pending, no root recorded"
printf 'v4 - case8 change\n' >> "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "fix: case8 change"
HEAD8="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q origin feature-branch

write_finalize "cv-finalize-case8" "fk-work8" "awaiting_merge" "$HEAD7" "3" "" "44"
export STUB_GH_STATE_44="OPEN" STUB_GH_HEAD_44="$HEAD8" STUB_GH_BRANCH_44="feature-branch"
export STUB_GC_NEW_BEAD_ID="rc-seed8a"
export CV_LENS_STORE_TIMEOUT_SECONDS=1
export CV_REREVIEW_SLING_TIMEOUT_SECONDS=2
export STUB_GC_SLING_SLEEP=5
out8a="$(run_watch)"
assert_contains "$out8a" "timed out after 2s" "diagnostic names the sling timeout value"
assert_contains "$out8a" "ran ~" "diagnostic names the observed duration"
rec8a="$(cat "${STATE_DIR}/cv-finalize-case8.finalize")"
if grep -qx "rereview_root_bead_id=" "${STATE_DIR}/cv-finalize-case8.finalize"; then
  pass "rereview_root_bead_id stays empty after a sling timeout"
else
  fail "rereview_root_bead_id stays empty after a sling timeout: got $(grep rereview_root_bead_id "${STATE_DIR}/cv-finalize-case8.finalize")"
fi
if [ -f "${STATE_DIR}/cv-finalize-case8.rereview-pending" ]; then
  pass "pending marker recorded after a sling timeout"
else
  fail "pending marker recorded after a sling timeout"
fi
pending8="$(cat "${STATE_DIR}/cv-finalize-case8.rereview-pending")"
assert_contains "$pending8" "seed_bead_id=rc-seed8a" "pending marker names the timed-out seed bead"
gc_log8a="$(cat "$STUB_GC_LOG")"
assert_not_contains "$gc_log8a" "bd close rc-seed8a" "a mere timeout does not close the seed bead yet (ambiguous, not confirmed)"

start_case "8b: next sweep finds the pending seed never attached -> closes it as orphaned, mints a fresh seed"
export STUB_GC_NEW_BEAD_ID="rc-seed8b"
export STUB_GC_SLING_SLEEP=0
out8b="$(run_watch)"
assert_contains "$out8b" "never attached; closing it as orphaned" "orphan seed closed on the next sweep"
gc_log8b="$(cat "$STUB_GC_LOG")"
assert_contains "$gc_log8b" "bd close rc-seed8a" "bd close called on the confirmed-orphaned seed bead"
rec8b="$(cat "${STATE_DIR}/cv-finalize-case8.finalize")"
assert_contains "$rec8b" "rereview_root_bead_id=rc-seed8b" "fresh seed recorded as root once the orphan is cleared"
if [ -f "${STATE_DIR}/cv-finalize-case8.rereview-pending" ]; then
  fail "no leftover pending marker after recovering from an orphan"
else
  pass "no leftover pending marker after recovering from an orphan"
fi
unset STUB_GC_SLING_SLEEP

# ===========================================================================
# CASE 9 (fk-marojd acceptance 3): a timed-out sling that LATER actually
# attached server-side (observed live: a manual retry of the identical
# formula took ~96s and succeeded) -> the next sweep must record that root
# instead of slinging a second time or minting a second seed.
# ===========================================================================
start_case "9: a timed-out sling later attaches server-side -> next sweep records it, does not sling again"
printf 'v5 - case9 change\n' >> "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "fix: case9 change"
HEAD9="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q origin feature-branch

write_finalize "cv-finalize-case9" "fk-work9" "awaiting_merge" "$HEAD8" "1" "" "44"
export STUB_GH_STATE_44="OPEN" STUB_GH_HEAD_44="$HEAD9" STUB_GH_BRANCH_44="feature-branch"
export STUB_GC_NEW_BEAD_ID="rc-seed9"
export CV_LENS_STORE_TIMEOUT_SECONDS=1
export CV_REREVIEW_SLING_TIMEOUT_SECONDS=2
export STUB_GC_SLING_SLEEP=5
out9a="$(run_watch)"
assert_contains "$out9a" "timed out after 2s" "case9 sweep 1: reports the sling timeout"
if [ -f "${STATE_DIR}/cv-finalize-case9.rereview-pending" ]; then
  pass "case9 sweep 1: pending marker recorded"
else
  fail "case9 sweep 1: pending marker recorded"
fi

mkdir -p "${SANDBOX}/depcounts"
printf '1\n' > "${SANDBOX}/depcounts/rc-seed9"
export STUB_GC_DEPCOUNT_DIR="${SANDBOX}/depcounts"
export STUB_GC_SLING_SLEEP=0
out9b="$(run_watch)"
assert_contains "$out9b" "completed server-side; recording it instead of dispatching again" "case9 sweep 2: recovers the backgrounded result"
gc_log9b="$(cat "$STUB_GC_LOG")"
assert_not_contains "$gc_log9b" "sling testrig" "case9 sweep 2: does not call gc sling again"
assert_not_contains "$gc_log9b" "bd create" "case9 sweep 2: does not mint a second seed bead"
rec9b="$(cat "${STATE_DIR}/cv-finalize-case9.finalize")"
assert_contains "$rec9b" "rereview_root_bead_id=rc-seed9" "case9 sweep 2: finalize record carries the recovered seed as root"
if [ -f "${STATE_DIR}/cv-finalize-case9.rereview-pending" ]; then
  fail "case9 sweep 2: no leftover pending marker after recovery"
else
  pass "case9 sweep 2: no leftover pending marker after recovery"
fi
unset STUB_GC_SLING_SLEEP STUB_GC_DEPCOUNT_DIR

# ===========================================================================
# CASE 10 (review fk-hbsmk BLOCKING-3): a confirmed (non-timeout) sling
# failure -> the seed bead is closed, the pending marker is cleared, and the
# finalize record's rereview_root_bead_id is NOT advanced (this is the exact
# path the bead's own title, "fix seed-bead leak", targets — a wrong id or
# reordered cleanup here would still report ALL CASES PASSED before this
# case existed).
# ===========================================================================
start_case "10: confirmed sling failure (not a timeout) -> seed closed, no root recorded, pending marker cleared"
printf 'v6 - case10 change\n' >> "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "fix: case10 change"
HEAD10="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q origin feature-branch

write_finalize "cv-finalize-case10" "fk-work10" "awaiting_merge" "$HEAD9" "1" "" "45"
export STUB_GH_STATE_45="OPEN" STUB_GH_HEAD_45="$HEAD10" STUB_GH_BRANCH_45="feature-branch"
export STUB_GC_NEW_BEAD_ID="rc-seed10"
export STUB_GC_SLING_FAIL=1
export CV_LENS_STORE_TIMEOUT_SECONDS=5
export CV_REREVIEW_SLING_TIMEOUT_SECONDS=5
out10="$(run_watch)"
assert_contains "$out10" "ERROR: gc sling con-voyage-rereview failed" "case10: reports a confirmed (non-timeout) sling failure"
gc_log10="$(cat "$STUB_GC_LOG")"
assert_contains "$gc_log10" "bd close rc-seed10 --reason gc sling con-voyage-rereview failed (exit 1)" "case10: seed bead closed with the confirmed-failure reason"
if grep -qx "rereview_root_bead_id=" "${STATE_DIR}/cv-finalize-case10.finalize"; then
  pass "case10: rereview_root_bead_id stays empty after a confirmed sling failure"
else
  fail "case10: rereview_root_bead_id stays empty after a confirmed sling failure: got $(grep rereview_root_bead_id "${STATE_DIR}/cv-finalize-case10.finalize")"
fi
if [ -f "${STATE_DIR}/cv-finalize-case10.rereview-pending" ]; then
  fail "case10: no leftover pending marker after a confirmed sling failure"
else
  pass "case10: no leftover pending marker after a confirmed sling failure"
fi
if [ -d "${STATE_DIR}/.locks/cv-finalize-case10.lock" ]; then
  fail "case10: dedup lock released after a confirmed sling failure"
else
  pass "case10: dedup lock released after a confirmed sling failure"
fi
unset STUB_GC_SLING_FAIL
# case10's own record never advances last_reviewed_head_sha (that's the
# behavior under test), so it would otherwise keep looking "changed" and
# steal later sweeps' one-dispatch-per-sweep budget. Retire it the same way
# case6 retires pr42 once its own assertions are done.
export STUB_GH_STATE_45="MERGED"

# ===========================================================================
# CASE 11 (review fk-hbsmk BLOCKING-4): two simultaneously-triggering
# .finalize records in ONE run_watch call -> only the first dispatches this
# sweep; the second logs the one-dispatch-per-sweep defer message and is NOT
# slung this cycle. A second sweep then dispatches the deferred record. Every
# other case above arranges exactly one triggering record per sweep, so
# dispatched_this_sweep never actually reached 1 while a second record was
# still waiting — a regression that silently dropped the gate (e.g. slinging
# both in the same sweep) would not have been caught before this case.
# ===========================================================================
start_case "11: two triggering records in one sweep -> only one dispatches, the other defers to the next sweep"
printf 'v7 - case11 change\n' >> "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "fix: case11 change"
HEAD11="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q origin feature-branch

write_finalize "cv-finalize-case11a" "fk-work11a" "awaiting_merge" "$HEAD10" "1" "" "46"
write_finalize "cv-finalize-case11b" "fk-work11b" "awaiting_merge" "$HEAD10" "1" "" "47"
export STUB_GH_STATE_46="OPEN" STUB_GH_HEAD_46="$HEAD11" STUB_GH_BRANCH_46="feature-branch"
export STUB_GH_STATE_47="OPEN" STUB_GH_HEAD_47="$HEAD11" STUB_GH_BRANCH_47="feature-branch"
export STUB_GC_NEW_BEAD_ID="rc-seed11a"
export CV_LENS_STORE_TIMEOUT_SECONDS=5
export CV_REREVIEW_SLING_TIMEOUT_SECONDS=10
out11a="$(run_watch)"
assert_contains "$out11a" "dispatched re-review round 2" "case11 sweep1: first record dispatches"
assert_contains "$out11a" "already dispatched one re-review round this sweep; deferring" "case11 sweep1: second record defers"
gc_log11a="$(cat "$STUB_GC_LOG")"
sling_count11a="$(printf '%s\n' "$gc_log11a" | grep -c 'sling testrig' || true)"
assert_eq "1" "$sling_count11a" "case11 sweep1: exactly one sling call this sweep"
rec11a="$(cat "${STATE_DIR}/cv-finalize-case11a.finalize")"
assert_contains "$rec11a" "rereview_root_bead_id=rc-seed11a" "case11 sweep1: first record records its own root"
rec11b="$(cat "${STATE_DIR}/cv-finalize-case11b.finalize")"
assert_contains "$rec11b" "last_reviewed_head_sha=${HEAD10}" "case11 sweep1: deferred record's bookkeeping unchanged"
if grep -qx "rereview_root_bead_id=" "${STATE_DIR}/cv-finalize-case11b.finalize"; then
  pass "case11 sweep1: deferred record has no root recorded yet"
else
  fail "case11 sweep1: deferred record has no root recorded yet: got $(grep rereview_root_bead_id "${STATE_DIR}/cv-finalize-case11b.finalize")"
fi
if [ -d "${STATE_DIR}/.locks/cv-finalize-case11b.lock" ]; then
  fail "case11 sweep1: dedup lock released after deferring to the next sweep"
else
  pass "case11 sweep1: dedup lock released after deferring to the next sweep"
fi

export STUB_GC_NEW_BEAD_ID="rc-seed11b"
out11b="$(run_watch)"
assert_contains "$out11b" "dispatched re-review round 2" "case11 sweep2: deferred record now dispatches"
gc_log11b="$(cat "$STUB_GC_LOG")"
assert_contains "$gc_log11b" "sling testrig/gc.run-operator rc-seed11b --on con-voyage-rereview" "case11 sweep2: deferred record's sling carries its own new seed"
rec11b2="$(cat "${STATE_DIR}/cv-finalize-case11b.finalize")"
assert_contains "$rec11b2" "rereview_root_bead_id=rc-seed11b" "case11 sweep2: deferred record now records its own root"

# ===========================================================================
# CASE 12 (review fk-k4gebi BLOCKING-2): a dedup_key lock already held by a
# concurrent run -> SKIP + no dispatch, not a silent proceed. Covers the
# acquire_lock failure branch at the top of the TRIGGER block, which no
# earlier case exercises (every prior triggering case runs with no
# pre-existing lock).
# ===========================================================================
start_case "12: dedup_key lock already held -> SKIP, no sling, no dispatch"
printf 'v8 - case12 change\n' >> "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "fix: case12 change"
HEAD12="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q origin feature-branch

write_finalize "cv-finalize-case12" "fk-work12" "awaiting_merge" "$HEAD11" "1" "" "48"
export STUB_GH_STATE_48="OPEN" STUB_GH_HEAD_48="$HEAD12" STUB_GH_BRANCH_48="feature-branch"
mkdir -p "${STATE_DIR}/.locks/cv-finalize-case12.lock"
export STUB_GC_NEW_BEAD_ID="rc-seed12"
out12="$(run_watch)"
assert_contains "$out12" "SKIP" "case12: diagnostic reports a skip"
assert_contains "$out12" "locked by a concurrent rereview-watch run" "case12: skip reason names the lock"
gc_log12="$(cat "$STUB_GC_LOG")"
assert_not_contains "$gc_log12" "sling testrig" "case12: no sling call while locked"
assert_not_contains "$gc_log12" "bd create" "case12: no seed bead minted while locked"
rec12="$(cat "${STATE_DIR}/cv-finalize-case12.finalize")"
assert_contains "$rec12" "last_reviewed_head_sha=${HEAD11}" "case12: bookkeeping unchanged while locked"
rm -rf "${STATE_DIR}/.locks/cv-finalize-case12.lock"
export STUB_GH_STATE_48="MERGED"

# ===========================================================================
# CASE 13 (review fk-k4gebi BLOCKING-1, this iteration's fix): the dedup
# lock's whole point is that every call held under it is bounded by
# CV_LENS_STORE_TIMEOUT_SECONDS/CV_REREVIEW_SLING_TIMEOUT_SECONDS, so
# CV_LOCK_STALE_SECONDS can never be stolen out from under a still-alive
# holder. A `bd set-state` that is NOT wrapped in cv_with_timeout breaks that
# invariant: against a slow/wedged store, the call (and the lock it holds)
# can run past CV_LOCK_STALE_SECONDS while the holder is still alive, so a
# concurrent sweep's acquire_lock judges the lock stale and steals it —
# double-dispatching the same PR+round. Small timeouts make a hang that
# exceeds the derived CV_LOCK_STALE_SECONDS cheap to simulate; asserting the
# run actually finishes (and releases the lock) well before that threshold
# elapses is only possible if set-state's own hang was cut short by
# cv_with_timeout, which is exactly what BLOCKING-1 required.
# ===========================================================================
start_case "13: bd set-state hang is bounded by cv_with_timeout, not left to outrun CV_LOCK_STALE_SECONDS"
printf 'v9 - case13 change\n' >> "${SRC}/feature.txt"
git_c "$SRC" add feature.txt
git_c "$SRC" commit -q -m "fix: case13 change"
HEAD13="$(git_c "$SRC" rev-parse HEAD)"
git_c "$SRC" push -q origin feature-branch

write_finalize "cv-finalize-case13" "fk-work13" "awaiting_merge" "$HEAD12" "1" "" "49"
export STUB_GH_STATE_49="OPEN" STUB_GH_HEAD_49="$HEAD13" STUB_GH_BRANCH_49="feature-branch"
export STUB_GC_NEW_BEAD_ID="rc-seed13"
# A real git clone/fetch/diff per run_watch call already costs this suite a
# variable few seconds of fixed overhead unrelated to the lock (measured
# directly: case 3's run_watch alone takes several seconds with no stub
# delay at all, and varies run to run under load). That variance means
# comparing elapsed time against the derived CV_LOCK_STALE_SECONDS directly,
# or against a tight margin, is not a reliable signal on a loaded box.
# Instead, pick a stub sleep (30s) an order of magnitude larger than
# CV_LENS_STORE_TIMEOUT_SECONDS(1s) and assert the whole run finishes in a
# small fraction of that sleep: bounded by cv_with_timeout, the hang is
# killed at ~1-2s (poll-interval overhead) regardless of the stub sleep
# duration, so the run finishes in roughly baseline+2s; left unwrapped, the
# run would have to wait out the full 30s stub sleep on top of that same
# baseline — a difference no amount of system load noise can mask.
export STUB_GC_SETSTATE_SLEEP="30"
CASE13_START="$(date +%s)"
out13="$(CV_LENS_STORE_TIMEOUT_SECONDS=1 CV_REREVIEW_SLING_TIMEOUT_SECONDS=1 run_watch)"
CASE13_ELAPSED=$(( $(date +%s) - CASE13_START ))
unset STUB_GC_SETSTATE_SLEEP
assert_contains "$out13" "dispatched re-review round 2" "case13: diagnostic reports a trigger despite the slow set-state"
if [ "$CASE13_ELAPSED" -lt 20 ]; then
  pass "case13: whole run finished in ${CASE13_ELAPSED}s, far under the 30s stub sleep on bd set-state (the hang was bounded by cv_with_timeout)"
else
  fail "case13: run took ${CASE13_ELAPSED}s -- bd set-state was not bounded, and would stay held past CV_LOCK_STALE_SECONDS in production, letting a concurrent sweep steal the still-held lock"
fi
if [ -d "${STATE_DIR}/.locks/cv-finalize-case13.lock" ]; then
  fail "case13: dedup lock still held after the run finished"
else
  pass "case13: dedup lock released after the run finished"
fi
export STUB_GH_STATE_49="MERGED"

# ===========================================================================
# CASE 14 (review fk-2v5tdv BLOCKING-1, qa-test narrowed): case 13 only
# proves the lock survives correctly at today's default
# CV_REREVIEW_SLING_TIMEOUT_SECONDS/CV_LENS_STORE_TIMEOUT_SECONDS values and
# default (unset) CV_LOCK_STALE_SECONDS. It pins none of
# resolve_lock_stale_seconds's own behavior: a future refactor that silently
# shrinks the 6x multiplier back toward iteration-3's margin-free value, or
# that breaks the non-numeric-override guard, would pass case 13 (and the
# whole suite) unchanged. Source con-voyage-lib.sh directly (already done at
# the top of this file) and call resolve_lock_stale_seconds with controlled
# inputs instead of only exercising it indirectly through a full run_watch.
# ===========================================================================
start_case "14: resolve_lock_stale_seconds derives sling + 6*store with no override"
got14="$(bash -c "source '$LIB'; resolve_lock_stale_seconds \"\$1\" \"\$2\"" _ "100" "30")"
assert_eq "280" "$got14" "case14: derived value is sling_timeout + 6*store_timeout (100 + 6*30)"

start_case "15: resolve_lock_stale_seconds falls back to the derived value on a non-numeric override"
got15="$(bash -c "source '$LIB'; resolve_lock_stale_seconds \"\$1\" \"\$2\" \"\$3\"" _ "100" "30" "abc")"
assert_eq "280" "$got15" "case15: non-numeric override falls back to the derived value, not the literal string"
got15b="$(bash -c "source '$LIB'; resolve_lock_stale_seconds \"\$1\" \"\$2\" \"\$3\"" _ "100" "30" "")"
assert_eq "280" "$got15b" "case15: empty override falls back to the derived value"

start_case "16: resolve_lock_stale_seconds honors a valid numeric override"
got16="$(bash -c "source '$LIB'; resolve_lock_stale_seconds \"\$1\" \"\$2\" \"\$3\"" _ "100" "30" "900")"
assert_eq "900" "$got16" "case16: a valid all-digit override wins as-is over the derived value"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "${FAILURES} CASE(S) FAILED"
  exit 1
fi
