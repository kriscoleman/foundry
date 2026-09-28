#!/usr/bin/env bash
# con-voyage-mold-suite-concurrency.test.sh — fk-0f459: proves the two test
# files reported to pile up stuck processes under concurrent con-voyage
# review-lane sweeps (con-voyage-stacked-pr-base.test.sh and
# con-voyage-pr-watch.test.sh — seen first-hand by two different workers on
# 2026-09-26, root fk-2yhob and the fk-4q6ib builder) stay BOUNDED when run
# concurrently with themselves, instead of hanging indefinitely.
#
# ROOT CAUSE (confirmed first-hand, this bead): con-voyage-stacked-pr-base's
# cv_ensure_branch_based_on ran a real `git fetch` with no wall-clock bound.
# Reproduced directly: `sample` on a stuck run showed bash blocked in its own
# command_substitute -> read_comsub -> read() on a pipe, i.e. waiting on a
# slow/stalled `git` child that simply hadn't returned yet. Fixed in
# con-voyage-lib.sh by wrapping that fetch in the pack's existing
# cv_with_timeout primitive (CV_BASE_BRANCH_FETCH_TIMEOUT_SECONDS, default
# 30s) — see the dedicated unit case in con-voyage-stacked-pr-base.test.sh.
#
# con-voyage-pr-watch.test.sh, by contrast, never calls real git/network at
# all (gh and gc are both fully stubbed local scripts) — there is no single
# unbounded external call to bound. Its own slowdown under this same
# investigation (a standalone run took ~5 minutes wall-clock, 22% CPU
# utilization, on this heavily-loaded multi-agent dev box) is generic
# CPU/fork-scheduling contention, not a specific shared-lock/deadlock bug in
# its own code — it always finished (exit 0), just slowly. This smoke test
# still exercises it under self-concurrency so a REAL future regression
# (e.g. a newly-added blocking call) is still caught, but the ceiling below
# is deliberately generous rather than tight, since "slow under a loaded
# shared box" is expected and NOT the failure mode this test guards against
# — an unbounded hang is.
#
# This is the concurrency smoke test called out in fk-0f459's own acceptance
# criteria: run the full suite (represented here by its two previously-stuck
# files) with itself running more than once at a time, and assert every copy
# finishes within a bound instead of piling up stuck processes.
#
# Run:  bash tests/con-voyage-mold-suite-concurrency.test.sh
#       (exit 0 => every concurrent copy of every guarded file finished
#       within its bound; ALL CASES PASSED)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
if [ ! -f "$LIB" ]; then
  echo "FATAL: required file not found at ${LIB}" >&2
  exit 2
fi
# shellcheck source=../pack/assets/scripts/con-voyage-lib.sh
source "$LIB"

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

# run_concurrently FILE COPIES CEILING_SECONDS — launches COPIES parallel
# `bash FILE` invocations, waits for all, and asserts every one both exited 0
# and the WHOLE batch finished within CEILING_SECONDS wall-clock.
#
# fk-b055p B2: each copy is individually wrapped in cv_with_timeout(CEILING),
# not just bash directly. The aggregate elapsed<=ceiling check below used to
# be the ONLY bound, but it only runs AFTER `wait` returns — which never
# happens if a copy is genuinely stuck (the exact failure mode this test
# exists to catch). A single `wait` on the whole job list is still the outer
# bound in spirit, but now each copy backstops itself: a reintroduced hang
# gets killed and reported as a normal (124) failure of this test, instead of
# wedging this test — and any CI job or review lane running it — indefinitely.
run_concurrently() {
  local file="$1" copies="$2" ceiling="$3"
  local target="${TEST_DIR}/${file}"
  if [ ! -f "$target" ]; then
    fail "${file}: test file not found at ${target}"
    return
  fi

  local pids=() logs=() i
  local sandbox
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/cv-suite-concurrency.XXXXXX")"

  local before after elapsed
  before=$(date +%s)
  for i in $(seq 1 "$copies"); do
    local log="${sandbox}/${file}.${i}.log"
    logs+=("$log")
    ( cv_with_timeout "$ceiling" bash "$target" > "$log" 2>&1 ) &
    pids+=("$!")
  done

  local rc all_ok=1
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      pass "${file} copy #$((i+1)) exited 0"
    else
      rc=$?
      all_ok=0
      if [ "$rc" -eq 124 ]; then
        fail "${file} copy #$((i+1)) was killed after exceeding its ${ceiling}s bound (hung, not just slow) — tail of its output:"
      else
        fail "${file} copy #$((i+1)) exited ${rc} — tail of its output:"
      fi
      tail -15 "${logs[$i]}" >&2
    fi
  done
  after=$(date +%s)
  elapsed=$((after - before))

  if [ "$elapsed" -le "$ceiling" ]; then
    pass "${copies}x concurrent ${file} finished in ${elapsed}s (ceiling ${ceiling}s) — bounded, not left to hang"
  else
    fail "${copies}x concurrent ${file} took ${elapsed}s, exceeding the ${ceiling}s ceiling"
  fi
  [ "$all_ok" -eq 1 ] || fail "${file}: at least one concurrent copy did not exit cleanly"

  rm -rf "$sandbox"
}

# _cv_suite_one_sweep PER_FILE_CEILING FILE... — runs every FILE sequentially,
# mirroring mold-validate.yml's own `for test_file in molds/*/tests/*.test.sh`
# loop. Exit status is the count of files that failed or were bounded out
# (0 = every file in this sweep passed).
#
# fk-b055p B1/B2: EACH file gets its own cv_with_timeout, rather than
# wrapping this whole multi-file sweep in one outer cv_with_timeout call.
# Verified directly: an outer-only wrap still makes the caller's `wait`
# return on schedule (so the test itself never hangs), but a real hang
# inside one of the swept files (e.g. a stalled git call one level below
# that file's own bash process) then sits TWO process levels below the
# timeout's tracked PID (sweep subshell -> that file's bash -> its own hung
# child) — past cv_with_timeout's documented one-level `pgrep -P` reach (see
# its own KNOWN LIMITATION comment) — so the grandchild is orphaned instead
# of killed, reproducing a smaller version of the exact bug this bead fixes.
# Wrapping each file individually keeps every bound at the same one-level
# depth run_concurrently above already relies on.
_cv_suite_one_sweep() {
  local per_file_ceiling="$1"; shift
  local errors=0 f
  for f in "$@"; do
    echo "==> $f"
    cv_with_timeout "$per_file_ceiling" bash "$f" || errors=$((errors+1))
  done
  return "$errors"
}

# run_full_suite_concurrently SWEEPS PER_FILE_CEILING TOTAL_CEILING — this is
# fk-0f459's own acceptance clause 1: "run the full suite twice in parallel"
# — not just the two files it named in isolation (those are covered by
# run_concurrently above). Each of SWEEPS parallel sweeps runs every OTHER
# test file in this directory sequentially (see _cv_suite_one_sweep), and
# TOTAL_CEILING bounds the whole batch via the same wait-based pattern
# run_concurrently uses.
#
# Excludes THIS file from the glob it fans out: mold-validate.yml's real
# sequential loop invokes this file exactly once, at its normal position, so
# it never recurses in CI either — a sweep that re-included itself would fan
# out 2 more sweeps from inside each of the first 2, recursing without bound.
run_full_suite_concurrently() {
  local sweeps="$1" per_file_ceiling="$2" total_ceiling="$3"
  local self_basename
  self_basename="$(basename "${BASH_SOURCE[0]}")"
  local -a suite_files=()
  local f
  for f in "${TEST_DIR}"/*.test.sh; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$self_basename" ] && continue
    suite_files+=("$f")
  done
  if [ "${#suite_files[@]}" -eq 0 ]; then
    fail "run_full_suite_concurrently: no test files found under ${TEST_DIR} (glob or self-exclusion bug?)"
    return
  fi

  local pids=() logs=() i
  local sandbox
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/cv-suite-concurrency-full.XXXXXX")"

  local before after elapsed
  before=$(date +%s)
  for i in $(seq 1 "$sweeps"); do
    local log="${sandbox}/full-sweep.${i}.log"
    logs+=("$log")
    ( _cv_suite_one_sweep "$per_file_ceiling" "${suite_files[@]}" ) > "$log" 2>&1 &
    pids+=("$!")
  done

  local rc all_ok=1
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      pass "full-suite sweep #$((i+1)) (${#suite_files[@]} files) exited 0"
    else
      rc=$?
      all_ok=0
      fail "full-suite sweep #$((i+1)) exited ${rc} (that many file(s) failed or were individually bounded out) — tail of its output:"
      tail -25 "${logs[$i]}" >&2
    fi
  done
  after=$(date +%s)
  elapsed=$((after - before))

  if [ "$elapsed" -le "$total_ceiling" ]; then
    pass "${sweeps}x concurrent full-suite sweep (${#suite_files[@]} files each) finished in ${elapsed}s (ceiling ${total_ceiling}s) — bounded, not left to hang"
  else
    fail "${sweeps}x concurrent full-suite sweep took ${elapsed}s, exceeding the ${total_ceiling}s ceiling"
  fi
  [ "$all_ok" -eq 1 ] || fail "full-suite sweep: at least one concurrent copy did not exit cleanly"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# The bug bead's own acceptance shape: "run each of the two named files 3x
# in parallel". Ceilings are generous — wide enough to absorb heavy ambient
# load on a shared dev box without flaking, tight enough that a genuine
# reintroduced unbounded hang (which blocks `wait` forever, not just slowly)
# still fails this test rather than running forever.
# ---------------------------------------------------------------------------
start_case "3x concurrent con-voyage-stacked-pr-base.test.sh stays bounded"
run_concurrently "con-voyage-stacked-pr-base.test.sh" 3 600

start_case "3x concurrent con-voyage-pr-watch.test.sh stays bounded"
run_concurrently "con-voyage-pr-watch.test.sh" 3 1800

# ---------------------------------------------------------------------------
# fk-b055p B1: the bug bead's OWN acceptance clause 1, literally — "run the
# full suite twice in parallel" — not just the two files it named. CI
# (mold-validate.yml) runs every molds/*/tests/*.test.sh file strictly
# sequentially, never concurrently, so nothing before this case gave standing
# protection against a suite-wide concurrent-hang regression from any file
# outside the two named above (including a future addition).
#
# PER_FILE_CEILING reuses the SAME 1800s bound already established and
# proven generous for pr-watch (the slowest known single file) above, rather
# than inventing a new number. TOTAL_CEILING is sized from a real measurement
# taken directly on this box: a single uncontended sequential sweep of all
# other files (excluding this one) — dominated by pr-watch alone at
# ~300-360s, with every other file finishing in low tens of seconds —
# totaled in the ~20-25 minute range; 3600s (60min) gives ~1.5-2x headroom
# over that for 2 CONCURRENT sweeps' extra contention, without being so loose
# it stops meaning anything (see mold-validate.yml's own job-level
# timeout-minutes, sized to comfortably cover this case's worst-case ceiling
# sum alongside the two existing cases above).
# ---------------------------------------------------------------------------
start_case "2x concurrent full-suite sweep stays bounded (fk-0f459 acceptance clause 1, literally)"
run_full_suite_concurrently 2 1800 3600

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
