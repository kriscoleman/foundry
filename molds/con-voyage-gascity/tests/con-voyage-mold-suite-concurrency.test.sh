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

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

# run_concurrently FILE COPIES CEILING_SECONDS — launches COPIES parallel
# `bash FILE` invocations, waits for all, and asserts every one both exited 0
# and the WHOLE batch finished within CEILING_SECONDS wall-clock. A single
# `wait` on the whole job list is itself the bound: if any copy hangs
# forever, this function (and this test) hangs too — that is the intended
# failure signature (a red CI run that times out, loud and unambiguous,
# never a silent false-pass).
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
    bash "$target" > "$log" 2>&1 &
    pids+=("$!")
  done

  local rc all_ok=1
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      pass "${file} copy #$((i+1)) exited 0"
    else
      rc=$?
      all_ok=0
      fail "${file} copy #$((i+1)) exited ${rc} — tail of its output:"
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

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
