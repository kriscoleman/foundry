#!/usr/bin/env bash
# cv-review-lane-worktree.test.sh — hermetic, offline test for per-lane review
# worktree isolation (fk-q659).
#
# THE BUG: every con-voyage review lane for a work item shares ONE mutable
# worktree (the source anchor's recorded work_dir). A lane doing
# mutate-run-revert verification races another lane's concurrent build/test in
# the same directory, producing a false BLOCKING or false-negative finding.
#
# THE FIX under test: cv-review-lane-worktree.sh gives each lane its own
# throwaway linked git worktree, checked out at the exact commit the source
# anchor is sitting on, so lane-local mutation can never be observed by
# another lane.
#
#   acquire <source-work-dir> <lane-id>  — create-or-reuse a lane worktree,
#                                           refreshed to source's current HEAD.
#   sweep <source-work-dir>              — remove every lane worktree for that
#                                           source (post-cycle hygiene).
#
# HOW IT WORKS: real, local git repos under a temp sandbox (git init is fully
# offline) — no stubs needed, git's own worktree/checkout/clean behavior is
# exactly what is under test.
#
# Run:  bash tests/cv-review-lane-worktree.test.sh   (exit 0 => all passed)

set -uo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-review-lane-worktree.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

REAL_GIT="$(command -v git)" || { echo "FATAL: git not found on PATH" >&2; exit 2; }

# Recording `gc` stub for sweep's lane-liveness check (fk-vqzpq9): for
# `bd show <id> --json` it echoes STUB_BDSHOW_JSON_<id, dashes->underscores>
# verbatim, mirroring the stub convention in con-voyage-lib.test.sh. Lives on
# a PATH prefix only swapped in for the specific sweep calls that need it, so
# every other command in this file keeps using the real `git`/environment.
FAKE_GC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test-gc.XXXXXX")"
cat > "${FAKE_GC_DIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
if [ "$1" = "bd" ] && [ "$2" = "show" ]; then
  id="$3"
  var="STUB_BDSHOW_JSON_${id//-/_}"
  printf '%s' "${!var:-}"
  exit 0
fi
exit 1
GC_STUB
chmod +x "${FAKE_GC_DIR}/gc"
# A PATH with git and bash but deliberately no gc binary, for the "status
# can't be resolved at all" case. bash and git/dirname/basename/tr/sed can
# live in different directories (e.g. homebrew bash vs. /usr/bin git on
# macOS), and homebrew's bin also happens to hold the REAL gc — so this
# isolates bash into its own directory rather than reusing bash's real
# parent dir wholesale.
NO_GC_BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test-nogc.XXXXXX")"
ln -s "$(command -v bash)" "${NO_GC_BIN_DIR}/bash"
NO_GC_PATH="${NO_GC_BIN_DIR}:$(dirname "$REAL_GIT"):/usr/bin:/bin"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test.XXXXXX")"
# Canonicalize: on macOS, $TMPDIR resolves under a symlink (/var ->
# /private/var). The script under test always returns realpath'd worktree
# paths (to match `git worktree list`'s own output), so path assertions below
# must compare against the same canonicalized form, not the raw mktemp path.
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
cleanup() { rm -rf "$SANDBOX" "${FAKE_GC_DIR:-}" "${NO_GC_BIN_DIR:-}"; }
trap cleanup EXIT

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

git_c() { git -C "$1" -c user.email=test@example.com -c user.name="Test" "${@:2}"; }

mk_repo() {
  local repo="${SANDBOX}/$1"
  mkdir -p "$repo"
  git_c "$repo" init -q -b main
  printf 'placeholder\n' > "$repo/README.md"
  git_c "$repo" add README.md
  git_c "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

run_script() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

OUT=""
RC=0

# ===========================================================================
# CASE 1 — acquire on a fresh source worktree creates a sibling lane worktree,
#   detached at the source's current HEAD, with matching file content.
# ===========================================================================
start_case "1: acquire creates a sibling lane worktree at source HEAD"
REPO1="$(mk_repo repo1)"
SRC1="${SANDBOX}/repo1-src"
git_c "$REPO1" worktree add -q --detach "$SRC1" HEAD
run_script acquire "$SRC1" "lane-acceptance"
assert_eq "0" "$RC" "acquire exits 0"
LANE1="$OUT"
if [ -d "$LANE1" ]; then pass "lane worktree directory exists at ${LANE1}"; else fail "lane worktree directory missing (got '${LANE1}')"; fi
case "$LANE1" in
  "${SANDBOX}/repo1-src--review-lane-acceptance") pass "lane worktree path follows the <src>--review-<lane-id> convention" ;;
  *) fail "unexpected lane worktree path: ${LANE1}" ;;
esac
if [ -f "${LANE1}/README.md" ]; then pass "lane worktree has the source's checked-out files"; else fail "lane worktree is missing README.md"; fi
src_head="$(git_c "$SRC1" rev-parse HEAD)"
lane_head="$(git_c "$LANE1" rev-parse HEAD)"
assert_eq "$src_head" "$lane_head" "lane worktree is detached at the source's HEAD commit"

# ===========================================================================
# CASE 2 — acquire is idempotent: a second call with the same source+lane-id
#   returns the SAME path and does not error.
# ===========================================================================
start_case "2: acquire is idempotent for the same source and lane-id"
run_script acquire "$SRC1" "lane-acceptance"
assert_eq "0" "$RC" "second acquire exits 0"
assert_eq "$LANE1" "$OUT" "second acquire returns the same lane worktree path"

# ===========================================================================
# CASE 3 — TRUE ISOLATION: two different lanes on the same source get two
#   DIFFERENT worktrees, and a mutation in one is never visible in the other.
#   This is the property that actually fixes fk-q659.
# ===========================================================================
start_case "3: two lanes on the same source are fully isolated from each other"
run_script acquire "$SRC1" "lane-test-evidence"
assert_eq "0" "$RC" "acquire for a second lane exits 0"
LANE2="$OUT"
if [ "$LANE1" != "$LANE2" ]; then pass "lane-acceptance and lane-test-evidence got different worktrees"; else fail "two different lane-ids collided on the same worktree path"; fi
# Simulate lane-acceptance's mutate-run-revert: transiently edit a shared file.
printf 'mutated by lane-acceptance\n' >> "${LANE1}/README.md"
if grep -q 'mutated by lane-acceptance' "${LANE2}/README.md" 2>/dev/null; then
  fail "lane-test-evidence's copy observed lane-acceptance's in-flight edit — isolation is broken"
else
  pass "lane-test-evidence's copy is unaffected by lane-acceptance's in-flight edit"
fi
if grep -q 'mutated by lane-acceptance' "${SRC1}/README.md" 2>/dev/null; then
  fail "the shared source work_dir was mutated by a lane edit — isolation is broken"
else
  pass "the shared source work_dir is untouched by the lane edit"
fi

# ===========================================================================
# CASE 4 — RE-RUN MECHANICS: acquire refreshes an existing lane worktree to
#   the source's NEW commit and wipes leftover mutation state from a prior
#   review cycle (dirty/untracked files), instead of silently reusing stale
#   content.
# ===========================================================================
start_case "4: acquire refreshes a reused lane worktree to the source's current HEAD and cleans it"
printf 'left over from a previous cycle'\''s mutate-run-revert\n' > "${LANE1}/leftover.txt"
printf 'round 2 change\n' > "${SRC1}/round2.txt"
git_c "$SRC1" add round2.txt
git_c "$SRC1" commit -q -m "round 2: apply-review-findings fix"
new_src_head="$(git_c "$SRC1" rev-parse HEAD)"
run_script acquire "$SRC1" "lane-acceptance"
assert_eq "0" "$RC" "re-acquire after a new source commit exits 0"
assert_eq "$LANE1" "$OUT" "re-acquire still returns the same deterministic lane path"
refreshed_lane_head="$(git_c "$LANE1" rev-parse HEAD)"
assert_eq "$new_src_head" "$refreshed_lane_head" "re-acquired lane worktree is detached at the source's NEW HEAD"
if [ -f "${LANE1}/round2.txt" ]; then pass "re-acquired lane worktree has round 2's new file"; else fail "re-acquired lane worktree is missing round2.txt"; fi
if [ -f "${LANE1}/leftover.txt" ]; then fail "re-acquire left a prior cycle's untracked mutation on disk"; else pass "re-acquire wiped the prior cycle's leftover untracked file"; fi

# ===========================================================================
# CASE 5 — lane-id sanitization: unsafe characters never escape the
#   worktrees/ parent directory or produce a path outside the convention.
# ===========================================================================
start_case "5: acquire sanitizes an unsafe lane-id"
run_script acquire "$SRC1" "../../etc/lane"
assert_eq "0" "$RC" "acquire with an unsafe lane-id still exits 0 (sanitized, not rejected)"
case "$OUT" in
  "${SANDBOX}/repo1-src--review-"*)
    case "$OUT" in
      *".."*) fail "sanitized lane worktree path still contains '..': ${OUT}" ;;
      *"/etc/"*) fail "sanitized lane worktree path escaped into /etc: ${OUT}" ;;
      *) pass "unsafe lane-id was sanitized into a safe sibling path: ${OUT}" ;;
    esac
    ;;
  *) fail "sanitized lane worktree path is not a sibling of the source: ${OUT}" ;;
esac

# ===========================================================================
# CASE 6 — validation errors: missing lane-id, missing source dir, a relative
#   source path, and a non-git source directory are all hard errors.
# ===========================================================================
start_case "6: acquire validates its arguments"
run_script acquire "$SRC1"
if [ "$RC" -ne 0 ]; then pass "acquire fails with no lane-id"; else fail "expected non-zero exit with no lane-id"; fi
run_script acquire
if [ "$RC" -ne 0 ]; then pass "acquire fails with no arguments"; else fail "expected non-zero exit with no arguments"; fi
run_script acquire "repo1-src" "lane-x"
if [ "$RC" -ne 0 ]; then pass "acquire fails on a relative source path"; else fail "expected non-zero exit for a relative source path"; fi
NOTGIT="${SANDBOX}/not-a-repo"
mkdir -p "$NOTGIT"
run_script acquire "$NOTGIT" "lane-x"
if [ "$RC" -ne 0 ]; then pass "acquire fails on a non-git source directory"; else fail "expected non-zero exit for a non-git source directory"; fi

# ===========================================================================
# CASE 7 — sweep removes every lane worktree for a source, and only those.
# ===========================================================================
start_case "7: sweep removes this source's lane worktrees and leaves everything else"
OTHER_REPO="$(mk_repo repo-other)"
OTHER_SRC="${SANDBOX}/repo-other-src"
git_c "$OTHER_REPO" worktree add -q --detach "$OTHER_SRC" HEAD
run_script acquire "$OTHER_SRC" "lane-acceptance"
assert_eq "0" "$RC" "acquire on an unrelated source exits 0"
OTHER_LANE="$OUT"
# Both of SRC1's lanes report closed, so a plain sweep (no --force) reaps them.
ORIG_PATH="$PATH"
export STUB_BDSHOW_JSON_lane_acceptance='[{"status":"closed"}]'
export STUB_BDSHOW_JSON_lane_test_evidence='[{"status":"closed"}]'
PATH="${FAKE_GC_DIR}:${ORIG_PATH}"
run_script sweep "$SRC1"
PATH="$ORIG_PATH"
unset STUB_BDSHOW_JSON_lane_acceptance STUB_BDSHOW_JSON_lane_test_evidence
assert_eq "0" "$RC" "sweep exits 0"
if [ -d "$LANE1" ]; then fail "sweep left ${LANE1} on disk"; else pass "sweep removed ${LANE1}"; fi
if [ -d "$LANE2" ]; then fail "sweep left ${LANE2} on disk"; else pass "sweep removed ${LANE2}"; fi
if [ -d "$SRC1" ]; then pass "sweep left the source work_dir itself untouched"; else fail "sweep removed the source work_dir itself — must never happen"; fi
if [ -d "$OTHER_LANE" ]; then pass "sweep left an unrelated source's lane worktree untouched"; else fail "sweep incorrectly removed an unrelated source's lane worktree"; fi
if git_c "$OTHER_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then pass "unrelated source worktree is still a valid git worktree"; else fail "unrelated source worktree was corrupted by sweep"; fi

# ===========================================================================
# CASE 8 — sweep with no matching lane worktrees is a clean no-op.
# ===========================================================================
start_case "8: sweep is a clean no-op when there is nothing to remove"
run_script sweep "$SRC1"
assert_eq "0" "$RC" "sweep exits 0 even with nothing left to sweep"

# ===========================================================================
# CASE 9 — unknown subcommand is rejected.
# ===========================================================================
start_case "9: unknown subcommand is rejected"
run_script frobnicate "$SRC1"
if [ "$RC" -ne 0 ]; then pass "unknown subcommand exits non-zero"; else fail "expected non-zero exit for an unknown subcommand"; fi

# ===========================================================================
# CASE 10 — fk-iw972: the reuse-guard check in cmd_acquire must not falsely
#   refuse a valid, already-acquired lane worktree when 'git worktree list
#   --porcelain | grep -qxF ...' races a downstream SIGPIPE under `pipefail`.
#
#   ROOT CAUSE (corrected diagnosis, 3rd occurrence, 2026-10-03): this is NOT
#   a locking race. cmd_acquire's reuse-guard pipes a live 'git worktree list
#   --porcelain' directly into 'grep -qxF'. grep -q exits the instant it finds
#   its match; if git is still mid-write on later output when grep's reader
#   end closes, git's next write() gets SIGPIPE, and under 'set -o pipefail'
#   that nonzero exit status wins over grep's own successful (0) exit code —
#   turning a CORRECT match into cmd_acquire reporting "exists but is not a
#   worktree of ..." and dying. It correlates with concurrent lane count only
#   because more worktrees means more trailing porcelain output after the
#   match, making the race more likely — not because of any actual mutual
#   exclusion problem.
#
#   REPRODUCTION: a fake 'git' shimmed onto PATH intercepts only the exact
#   'git -C <src> worktree list --porcelain' invocation cmd_acquire's
#   reuse-guard makes. It runs the REAL git first (so the genuine matching
#   "worktree <lane_dir>" line is really there, at its natural early
#   position), then appends several MB of synthetic trailing porcelain-shaped
#   padding — far more than grep will ever read once it finds the real match
#   and exits. This deterministically forces the same SIGPIPE-after-match race
#   production hit under real concurrent lane load, without needing an actual
#   multi-process race or hundreds of real 'git worktree add' calls.
# ===========================================================================
start_case "10: acquire's reuse-guard must not falsely refuse on a SIGPIPE/pipefail race in 'git worktree list --porcelain | grep -q'"

run_script acquire "$SRC1" "lane-pipefail"
assert_eq "0" "$RC" "baseline acquire (no shim) exits 0"
LANE_PF="$OUT"

FAKE_BIN="${SANDBOX}/fake-bin"
mkdir -p "$FAKE_BIN"
PADFILE="${SANDBOX}/porcelain-padding.txt"
yes "worktree /fake/padding-for-fk-iw972
HEAD 0000000000000000000000000000000000000000
detached
" | head -c 3000000 > "$PADFILE"

cat > "${FAKE_BIN}/git" <<SHIM
#!/usr/bin/env bash
# Test-only shim (fk-iw972): intercept ONLY the reuse-guard's exact
# 'worktree list --porcelain' call; every other git invocation (rev-parse,
# checkout, clean, worktree add, ...) passes straight through unmodified.
if [ "\$1" = "-C" ] && [ "\$3" = "worktree" ] && [ "\$4" = "list" ] && [ "\$5" = "--porcelain" ]; then
  "${REAL_GIT}" "\$@"
  cat "${PADFILE}"
else
  exec "${REAL_GIT}" "\$@"
fi
SHIM
chmod +x "${FAKE_BIN}/git"

ORIG_PATH="$PATH"
PATH="${FAKE_BIN}:${PATH}"
run_script acquire "$SRC1" "lane-pipefail"
PATH="$ORIG_PATH"

assert_eq "0" "$RC" "acquire's reuse-guard survives a SIGPIPE/pipefail race on a true match (fk-iw972)"
assert_eq "$LANE_PF" "$OUT" "acquire still returns the correct, already-existing lane worktree path despite the race"

# ===========================================================================
# CASE 11 — fk-vqzpq9 / fk-ekufmt: sweep must never reap a still-active
#   lane's worktree. Only closed lanes are removed; an open/in_progress lane
#   is skipped and reported, not torn down — even with --force. --force only
#   additionally reaps a lane whose status could NOT be resolved at all (see
#   CASE 12); a lane bead that genuinely resolves to a non-closed status is a
#   live sibling and must never be swept, exactly the scenario that reaped a
#   live lane on fk-ekufmt when a finding regrade reopened it mid-synthesis.
# ===========================================================================
start_case "11: sweep skips a still-open/in_progress lane and only reaps closed lanes"
REPO3="$(mk_repo repo3)"
SRC3="${SANDBOX}/repo3-src"
git_c "$REPO3" worktree add -q --detach "$SRC3" HEAD
run_script acquire "$SRC3" "lane-closed-one"
assert_eq "0" "$RC" "acquire for the closed lane exits 0"
LANE_CLOSED="$OUT"
run_script acquire "$SRC3" "lane-open-one"
assert_eq "0" "$RC" "acquire for the open lane exits 0"
LANE_OPEN="$OUT"

ORIG_PATH="$PATH"
export STUB_BDSHOW_JSON_lane_closed_one='[{"status":"closed"}]'
export STUB_BDSHOW_JSON_lane_open_one='[{"status":"in_progress"}]'
PATH="${FAKE_GC_DIR}:${ORIG_PATH}"
run_script sweep "$SRC3"
PATH="$ORIG_PATH"
unset STUB_BDSHOW_JSON_lane_closed_one STUB_BDSHOW_JSON_lane_open_one

assert_eq "0" "$RC" "sweep exits 0 with a mix of closed and open lanes"
if [ -d "$LANE_CLOSED" ]; then fail "sweep left the CLOSED lane's worktree on disk: ${LANE_CLOSED}"; else pass "sweep removed the closed lane's worktree"; fi
if [ -d "$LANE_OPEN" ]; then pass "sweep SKIPPED the still-open lane's worktree"; else fail "sweep incorrectly removed an open/in_progress lane's worktree — would reap a live review (fk-vqzpq9)"; fi
case "$OUT" in
  *"skip"*"lane-open-one"*) pass "sweep reported the skipped lane in its output" ;;
  *) fail "sweep did not report skipping the open lane; output: ${OUT}" ;;
esac

# --force must NOT reap a lane whose status genuinely resolves to
# open/in_progress (fk-ekufmt: this is exactly the "live sibling reaped by
# the synthesize-review --force sweep" incident).
ORIG_PATH="$PATH"
export STUB_BDSHOW_JSON_lane_open_one='[{"status":"in_progress"}]'
PATH="${FAKE_GC_DIR}:${ORIG_PATH}"
run_script sweep "$SRC3" --force
PATH="$ORIG_PATH"
unset STUB_BDSHOW_JSON_lane_open_one
assert_eq "0" "$RC" "sweep --force exits 0"
if [ -d "$LANE_OPEN" ]; then pass "sweep --force left a known-open lane's worktree alone — never reaps a live sibling"; else fail "sweep --force reaped a lane whose bead genuinely resolved to in_progress — this is the fk-ekufmt live-sibling-reaped bug"; fi

# ===========================================================================
# CASE 12 — an unresolvable lane bead status (no gc on PATH at all) must fail
#   SAFE: skip, do not reap. --force still reaps regardless.
# ===========================================================================
start_case "12: sweep treats an unresolvable lane bead status as still active (fail safe)"
REPO4="$(mk_repo repo4)"
SRC4="${SANDBOX}/repo4-src"
git_c "$REPO4" worktree add -q --detach "$SRC4" HEAD
run_script acquire "$SRC4" "lane-unknown"
assert_eq "0" "$RC" "acquire for the unknown-status lane exits 0"
LANE_UNKNOWN="$OUT"

ORIG_PATH="$PATH"
PATH="$NO_GC_PATH"
run_script sweep "$SRC4"
PATH="$ORIG_PATH"
assert_eq "0" "$RC" "sweep exits 0 even when lane status cannot be resolved at all"
if [ -d "$LANE_UNKNOWN" ]; then pass "sweep left the worktree alone when the lane's bead status could not be resolved"; else fail "sweep reaped a lane worktree despite being unable to confirm it was closed"; fi

ORIG_PATH="$PATH"
PATH="$NO_GC_PATH"
run_script sweep "$SRC4" --force
PATH="$ORIG_PATH"
if [ -d "$LANE_UNKNOWN" ]; then fail "sweep --force left the unknown-status lane's worktree on disk"; else pass "sweep --force reaps regardless of unresolved status"; fi

# ===========================================================================
# CASE 13 — fk-o0f68q BLOCKING-1: a hanging `gc bd show` (lock contention,
#   store outage) must not hang `sweep` forever. `lane_bead_state`'s
#   `bead_status` call is wrapped in `cv_with_timeout`; pin that wiring with a
#   `gc` stub that never returns, under a short
#   CV_LENS_STORE_TIMEOUT_SECONDS, and assert `sweep` still returns promptly
#   and treats the unresolved lane as still active (skip, don't reap).
# ===========================================================================
start_case "13: sweep bounds a hanging store lookup and skips the lane, rather than hanging forever (fk-o0f68q)"
HANG_GC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test-hang.XXXXXX")"
cat > "${HANG_GC_DIR}/gc" <<'HANG_GC_STUB'
#!/usr/bin/env bash
if [ "$1" = "bd" ] && [ "$2" = "show" ]; then
  sleep 3600
  exit 0
fi
exit 1
HANG_GC_STUB
chmod +x "${HANG_GC_DIR}/gc"

REPO5="$(mk_repo repo5)"
SRC5="${SANDBOX}/repo5-src"
git_c "$REPO5" worktree add -q --detach "$SRC5" HEAD
run_script acquire "$SRC5" "lane-hanging-store"
assert_eq "0" "$RC" "acquire for the hanging-store lane exits 0"
LANE_HANGING="$OUT"

ORIG_PATH="$PATH"
PATH="${HANG_GC_DIR}:${ORIG_PATH}"
export CV_LENS_STORE_TIMEOUT_SECONDS=1
hang_start=$(date +%s)
run_script sweep "$SRC5"
hang_elapsed=$(( $(date +%s) - hang_start ))
unset CV_LENS_STORE_TIMEOUT_SECONDS
PATH="$ORIG_PATH"

assert_eq "0" "$RC" "sweep exits 0 even when the store lookup hangs"
if [ "$hang_elapsed" -lt 30 ]; then
  pass "sweep returned promptly (${hang_elapsed}s), bounded by the timeout, instead of hanging"
else
  fail "sweep took ${hang_elapsed}s against a hanging store call — cv_with_timeout wiring is broken"
fi
if [ -d "$LANE_HANGING" ]; then pass "sweep left the unresolved (hung-lookup) lane's worktree alone"; else fail "sweep reaped a lane whose status lookup timed out — fail-open, not fail-safe"; fi

# A malformed/empty CV_LENS_STORE_TIMEOUT_SECONDS must fall back to the 30s
# default rather than disabling the bound outright (`cv_with_timeout` treats
# an empty/non-numeric value as "no timeout").
ORIG_PATH="$PATH"
PATH="${HANG_GC_DIR}:${ORIG_PATH}"
export CV_LENS_STORE_TIMEOUT_SECONDS="not-a-number"
coerce_start=$(date +%s)
run_script sweep "$SRC5"
coerce_elapsed=$(( $(date +%s) - coerce_start ))
unset CV_LENS_STORE_TIMEOUT_SECONDS
PATH="$ORIG_PATH"
assert_eq "0" "$RC" "sweep exits 0 with a malformed CV_LENS_STORE_TIMEOUT_SECONDS"
if [ -d "$LANE_HANGING" ]; then pass "sweep still left the lane alone under the coerced default timeout"; else fail "sweep reaped the lane under a malformed timeout value"; fi
if [ "$coerce_elapsed" -ge 30 ] && [ "$coerce_elapsed" -lt 90 ]; then
  pass "malformed CV_LENS_STORE_TIMEOUT_SECONDS coerced to the 30s default (${coerce_elapsed}s)"
else
  fail "malformed CV_LENS_STORE_TIMEOUT_SECONDS did not coerce to ~30s (took ${coerce_elapsed}s)"
fi
rm -rf "$HANG_GC_DIR"

# ===========================================================================
# CASE 14 — fk-o0f68q LOW-5: the store-lookup timeout must be a budget shared
#   across the whole sweep call, not re-applied per lane. Three lanes all
#   backed by a hanging `gc`, with a 2s timeout: the OLD per-lane behavior
#   would take ~3 x 2s = 6s+; the fix must bound the whole sweep to roughly
#   one timeout, since the budget is exhausted after the first lane and every
#   later lane is treated as unresolved without paying its own full timeout.
# ===========================================================================
start_case "14: sweep bounds its TOTAL store-lookup time across multiple slow lanes to one shared budget, not N x per-lane timeout (fk-o0f68q LOW-5)"
HANG_GC_DIR2="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test-hang2.XXXXXX")"
cat > "${HANG_GC_DIR2}/gc" <<'HANG_GC_STUB2'
#!/usr/bin/env bash
if [ "$1" = "bd" ] && [ "$2" = "show" ]; then
  sleep 3600
  exit 0
fi
exit 1
HANG_GC_STUB2
chmod +x "${HANG_GC_DIR2}/gc"

REPO6="$(mk_repo repo6)"
SRC6="${SANDBOX}/repo6-src"
git_c "$REPO6" worktree add -q --detach "$SRC6" HEAD
run_script acquire "$SRC6" "lane-slow-a"
assert_eq "0" "$RC" "acquire for slow lane a exits 0"
LANE_SLOW_A="$OUT"
run_script acquire "$SRC6" "lane-slow-b"
assert_eq "0" "$RC" "acquire for slow lane b exits 0"
LANE_SLOW_B="$OUT"
run_script acquire "$SRC6" "lane-slow-c"
assert_eq "0" "$RC" "acquire for slow lane c exits 0"
LANE_SLOW_C="$OUT"

ORIG_PATH="$PATH"
PATH="${HANG_GC_DIR2}:${ORIG_PATH}"
export CV_LENS_STORE_TIMEOUT_SECONDS=2
budget_start=$(date +%s)
run_script sweep "$SRC6"
budget_elapsed=$(( $(date +%s) - budget_start ))
unset CV_LENS_STORE_TIMEOUT_SECONDS
PATH="$ORIG_PATH"

assert_eq "0" "$RC" "sweep exits 0 across three slow lanes"
if [ "$budget_elapsed" -lt 5 ]; then
  pass "sweep over 3 slow lanes took ${budget_elapsed}s, bounded by ONE shared budget, not 3x the per-lane timeout"
else
  fail "sweep over 3 slow lanes took ${budget_elapsed}s — the per-lane timeout is being paid separately by each lane instead of a shared budget"
fi
if [ -d "$LANE_SLOW_A" ] && [ -d "$LANE_SLOW_B" ] && [ -d "$LANE_SLOW_C" ]; then
  pass "all three unresolved-status lanes were left alone"
else
  fail "sweep reaped an unresolved-status lane without --force"
fi
rm -rf "$HANG_GC_DIR2"

# ===========================================================================
# CASE 15 — review LOW-2: cmd_sweep's canonicalize-failure message must name
#   the path that actually failed to canonicalize, not a stale `$1` (after
#   this function's own `shift`, `$1` no longer holds the source path — it
#   holds whatever optional flag followed it, e.g. "--force", or is empty).
#   Reproduced by forcing canonicalize_dir's own `cd` to fail on a path that
#   passed the earlier existence/git-worktree check (the directory vanishes
#   out from under sweep, same shape as a lane worktree torn down by a
#   concurrent sweep mid-run), with "--force" trailing it as the real
#   production call shape — then asserting the error names the source path,
#   never the literal trailing flag.
# ===========================================================================
start_case "15: sweep's canonicalize-failure message names the real failed path, not a stale \$1 (review LOW-2)"
REPO7="$(mk_repo repo7)"
VANISHING_SRC="${SANDBOX}/repo7-src"
git_c "$REPO7" worktree add -q --detach "$VANISHING_SRC" HEAD
FAKE_GIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test-vanish.XXXXXX")"
cat > "${FAKE_GIT_DIR}/git" <<VANISH_SHIM
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "rev-parse" ] && [ "\$4" = "--is-inside-work-tree" ]; then
  "${REAL_GIT}" "\$@"
  rc=\$?
  rm -rf "${VANISHING_SRC}"
  exit "\$rc"
fi
exec "${REAL_GIT}" "\$@"
VANISH_SHIM
chmod +x "${FAKE_GIT_DIR}/git"
ORIG_PATH="$PATH"
PATH="${FAKE_GIT_DIR}:${ORIG_PATH}"
run_script sweep "$VANISHING_SRC" --force
PATH="$ORIG_PATH"
rm -rf "$FAKE_GIT_DIR"
case "$OUT" in
  *"'${VANISHING_SRC}'"*) pass "canonicalize-failure message names the actual source path" ;;
  *) fail "canonicalize-failure message did not name the real source path; output: ${OUT}" ;;
esac
case "$OUT" in
  *"'--force'"*) fail "canonicalize-failure message leaked the trailing '--force' flag in place of the source path — stale \$1 bug" ;;
  *) pass "canonicalize-failure message never substitutes a trailing flag for the real source path" ;;
esac

# ===========================================================================
# CASE 16 — review fk-hbsmk/fk-9h3nwk BLOCKING-1/2: the literal compound
#   scenario the fix in cmd_sweep claims to close. The lane bead IS genuinely
#   in_progress (a live, still-running review), but at the moment `sweep
#   --force` runs, the status lookup itself fails to resolve (hangs/times
#   out) rather than timing out from a missing binary. The OLD code collapsed
#   "lookup attempted and failed" into the same empty-string sentinel as
#   "confirmed structurally absent", so --force reaped it outright. The fix
#   must not reap on a single inconclusive lookup — even a second attempt
#   that also fails must still leave the worktree alone.
# ===========================================================================
start_case "16: sweep --force never reaps a lane whose lookup genuinely fails/times out, even though the underlying lane is still in_progress (fk-hbsmk/fk-9h3nwk BLOCKING-1)"
HANG_GC_DIR3="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test-hang3.XXXXXX")"
cat > "${HANG_GC_DIR3}/gc" <<'HANG_GC_STUB3'
#!/usr/bin/env bash
if [ "$1" = "bd" ] && [ "$2" = "show" ]; then
  sleep 3600
  exit 0
fi
exit 1
HANG_GC_STUB3
chmod +x "${HANG_GC_DIR3}/gc"

REPO8="$(mk_repo repo8)"
SRC8="${SANDBOX}/repo8-src"
git_c "$REPO8" worktree add -q --detach "$SRC8" HEAD
run_script acquire "$SRC8" "lane-in-progress-but-unresolvable"
assert_eq "0" "$RC" "acquire for the compound-scenario lane exits 0"
LANE_COMPOUND="$OUT"

ORIG_PATH="$PATH"
PATH="${HANG_GC_DIR3}:${ORIG_PATH}"
export CV_LENS_STORE_TIMEOUT_SECONDS=1
compound_start=$(date +%s)
run_script sweep "$SRC8" --force
compound_elapsed=$(( $(date +%s) - compound_start ))
unset CV_LENS_STORE_TIMEOUT_SECONDS
PATH="$ORIG_PATH"
rm -rf "$HANG_GC_DIR3"

assert_eq "0" "$RC" "sweep --force exits 0 even when the lookup hangs twice"
if [ "$compound_elapsed" -lt 10 ]; then
  pass "sweep --force returned promptly (${compound_elapsed}s) despite two failed lookup attempts"
else
  fail "sweep --force took ${compound_elapsed}s against a hanging store call"
fi
if [ -d "$LANE_COMPOUND" ]; then
  pass "sweep --force left the genuinely in_progress lane's worktree alone despite an unresolvable lookup — the fk-hbsmk/fk-9h3nwk regression is fixed"
else
  fail "sweep --force reaped a lane whose status lookup only failed to resolve — this is the exact live-sibling-reap incident the fix claims to close"
fi

# ===========================================================================
# CASE 17 — review fk-hbsmk/fk-9h3nwk BLOCKING-1: the shared sweep budget
#   being exhausted means NO lookup was ever attempted for a later lane — not
#   "this lane is unresolvable". --force must never reap on budget
#   exhaustion alone, even though the OLD code's `state=""` sentinel at the
#   deadline check made it indistinguishable from a confirmed-absent lookup.
# ===========================================================================
start_case "17: sweep --force never reaps a lane purely because the shared sweep budget ran out before its lookup was attempted (fk-hbsmk/fk-9h3nwk BLOCKING-1)"
HANG_GC_DIR4="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test-hang4.XXXXXX")"
cat > "${HANG_GC_DIR4}/gc" <<'HANG_GC_STUB4'
#!/usr/bin/env bash
if [ "$1" = "bd" ] && [ "$2" = "show" ]; then
  sleep 3600
  exit 0
fi
exit 1
HANG_GC_STUB4
chmod +x "${HANG_GC_DIR4}/gc"

REPO9="$(mk_repo repo9)"
SRC9="${SANDBOX}/repo9-src"
git_c "$REPO9" worktree add -q --detach "$SRC9" HEAD
run_script acquire "$SRC9" "lane-budget-a"
assert_eq "0" "$RC" "acquire for budget lane a exits 0"
LANE_BUDGET_A="$OUT"
run_script acquire "$SRC9" "lane-budget-b"
assert_eq "0" "$RC" "acquire for budget lane b exits 0"
LANE_BUDGET_B="$OUT"

ORIG_PATH="$PATH"
PATH="${HANG_GC_DIR4}:${ORIG_PATH}"
export CV_LENS_STORE_TIMEOUT_SECONDS=2
export CV_LANE_SWEEP_BUDGET_SECONDS=1
run_script sweep "$SRC9" --force
unset CV_LENS_STORE_TIMEOUT_SECONDS CV_LANE_SWEEP_BUDGET_SECONDS
PATH="$ORIG_PATH"
rm -rf "$HANG_GC_DIR4"

assert_eq "0" "$RC" "sweep --force exits 0 when the shared budget runs out mid-sweep"
case "$OUT" in
  *"budget exhausted"*) pass "sweep reported the budget-exhausted skip with its own distinct reason" ;;
  *) fail "sweep did not report a distinct budget-exhausted reason; output: ${OUT}" ;;
esac
if [ -d "$LANE_BUDGET_A" ] && [ -d "$LANE_BUDGET_B" ]; then
  pass "sweep --force left both budget-exhausted lanes alone instead of reaping them"
else
  fail "sweep --force reaped a lane whose lookup was never attempted due to budget exhaustion"
fi

# ===========================================================================
# CASE 18 — review fk-9h3nwk QA/test-engineering BLOCKING-1: the fix's own
#   headline POSITIVE capability — a first lookup that fails/is inconclusive,
#   followed by a second, independently-timed retry that DOES resolve
#   "closed" — must still reap the worktree. Cases 16/17 only cover the
#   negative paths (both attempts fail, or budget exhausted before any
#   attempt); none of them exercise the retry actually succeeding. A
#   regression here (e.g. `state2` compared against the wrong value, or the
#   retry reusing the first failed result instead of re-invoking
#   `lane_bead_state`) would silently stop ever reaping a lane that only
#   resolves on its second lookup, leaking worktrees forever.
# ===========================================================================
start_case "18: sweep --force reaps a lane whose FIRST lookup fails but whose retry resolves closed (fk-9h3nwk BLOCKING-1 positive path)"
RETRY_GC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cv-review-lane-wt-test-retry.XXXXXX")"
RETRY_COUNTER="${RETRY_GC_DIR}/count"
printf '0' > "$RETRY_COUNTER"
cat > "${RETRY_GC_DIR}/gc" <<RETRY_GC_STUB
#!/usr/bin/env bash
if [ "\$1" = "bd" ] && [ "\$2" = "show" ]; then
  count="\$(cat "${RETRY_COUNTER}")"
  count=\$((count + 1))
  printf '%s' "\$count" > "${RETRY_COUNTER}"
  if [ "\$count" -eq 1 ]; then
    # first attempt: a real lookup was made but came back unusable.
    exit 1
  fi
  # second (retry) attempt: resolves cleanly to closed.
  printf '%s' '[{"status":"closed"}]'
  exit 0
fi
exit 1
RETRY_GC_STUB
chmod +x "${RETRY_GC_DIR}/gc"

REPO10="$(mk_repo repo10)"
SRC10="${SANDBOX}/repo10-src"
git_c "$REPO10" worktree add -q --detach "$SRC10" HEAD
run_script acquire "$SRC10" "lane-retry-resolves-closed"
assert_eq "0" "$RC" "acquire for the retry-resolves-closed lane exits 0"
LANE_RETRY="$OUT"

ORIG_PATH="$PATH"
PATH="${RETRY_GC_DIR}:${ORIG_PATH}"
run_script sweep "$SRC10" --force
PATH="$ORIG_PATH"
rm -rf "$RETRY_GC_DIR"

assert_eq "0" "$RC" "sweep --force exits 0 when the first lookup fails and the retry resolves closed"
case "$OUT" in
  *"confirmed closed on second attempt after an initial lookup failure"*)
    pass "sweep reported the second-attempt-confirmed-closed reason, not the failed-twice skip branch" ;;
  *)
    fail "sweep did not report the second-attempt-confirmed-closed reason; output: ${OUT}" ;;
esac
if [ -d "$LANE_RETRY" ]; then
  fail "sweep --force left the lane worktree on disk even though the retry resolved closed — the fk-9h3nwk positive path is broken"
else
  pass "sweep --force reaped the lane worktree once the retry confirmed closed"
fi

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
