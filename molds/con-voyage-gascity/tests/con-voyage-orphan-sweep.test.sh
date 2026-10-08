#!/usr/bin/env bash
# con-voyage-orphan-sweep.test.sh — hermetic test for con-voyage-orphan-
# sweep.sh (fk-yli8qd, mitigates engine re-mint fk-ruuy6): the gascity engine
# keeps minting review-loop iterations (ralph/scope bodies, then review
# lanes) AFTER a workflow root closes. This order is a pack-side cooldown
# mitigation: each tick, it finds every still-open bead under an already-
# CLOSED workflow root and closes it leaf-first (lane/step -> scope-check ->
# scope -> ralph -> workflow-finalize), so the engine finds nothing left to
# re-mint from. Open roots and their descendants are never touched. A
# candidate that is pinned or dependency/gate-blocked (bead_pinned_or_blocked,
# con-voyage-lib.sh) is also left untouched rather than force-closed (review
# fk-gypn9m BLOCKING-1).
#
# Run:  bash tests/con-voyage-orphan-sweep.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-orphan-sweep.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

start_case "con-voyage-orphan-sweep.sh is committed executable"
mode="$(git -C "$MOLD_DIR" ls-files -s -- "pack/assets/scripts/con-voyage-orphan-sweep.sh" | awk '{print $1}')"
assert_eq "100755" "$mode" "git-tracked file mode is 100755"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-orphan-sweep-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv (one line per call) and answers:
#   bd list --has-metadata-key gc.root_bead_id --json --limit 0 -> STUB_BDLIST_JSON
#   bd list --pinned --json                                     -> STUB_PINNED_JSON (default []);
#                                                                   STUB_PINNED_FETCH_FAIL=1 makes the call fail
#   bd blocked --json                                           -> STUB_BLOCKED_JSON (default []; orphan-sweep
#                                                                   itself never calls this any more — see case 10)
#   bd show <id> --json                                         -> STUB_BDSHOW_JSON_<id, -/./ -> _>
#   bd update <id> ...                                          -> STUB_BDUPDATE_FAIL_<id> gates failure
#   bd close <id> ...                                           -> STUB_BDCLOSE_FAIL_<id> gates failure
#   mail send ...                                               -> STUB_MAIL_SEND_FAIL gates failure
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GC_LOG:-/dev/null}"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }

args=("$@")
i=0
while :; do
  case "${args[$i]:-}" in
    --city|--rig) i=$((i+2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"
case "$sub" in
  bd)
    bdsub="${args[$((i+1))]:-}"
    case "$bdsub" in
      list)
        is_pinned_query=0
        for a in "${args[@]}"; do
          [ "$a" = "--pinned" ] && is_pinned_query=1
        done
        if [ "$is_pinned_query" = "1" ]; then
          if [ "${STUB_PINNED_FETCH_FAIL:-0}" = "1" ]; then
            exit 1
          fi
          printf '%s' "${STUB_PINNED_JSON:-[]}"
        else
          if [ "${STUB_CANDIDATES_HANG:-0}" = "1" ]; then
            sleep "${STUB_HANG_SECONDS:-20}"
          fi
          printf '%s' "${STUB_BDLIST_JSON:-[]}"
        fi
        exit 0
        ;;
      blocked)
        printf '%s' "${STUB_BLOCKED_JSON:-[]}"
        exit 0
        ;;
      show)
        id="${args[$((i+2))]:-}"
        var="STUB_BDSHOW_JSON_$(sanitize "$id")"
        printf '%s' "${!var:-}"
        exit 0
        ;;
      update)
        id="${args[$((i+2))]:-}"
        var="STUB_BDUPDATE_FAIL_$(sanitize "$id")"
        [ "${!var:-0}" = "1" ] && exit 1
        exit 0
        ;;
      close)
        id="${args[$((i+2))]:-}"
        var="STUB_BDCLOSE_FAIL_$(sanitize "$id")"
        [ "${!var:-0}" = "1" ] && exit 1
        exit 0
        ;;
    esac
    exit 0
    ;;
  mail)
    mailsub="${args[$((i+1))]:-}"
    if [ "$mailsub" = "send" ]; then
      if [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ]; then
        echo "gc mail send: failed to deliver (simulated)" >&2
        exit 1
      fi
      printf '{"message":{"id":"msg-1"}}'
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

GC_LOG="${SANDBOX}/gc.log"

# bead_json ID ROOT_ID KIND -> one bd-list-shaped candidate row.
bead_json() {
  local id="$1" root="$2" kind="$3"
  printf '{"id":"%s","status":"open","metadata":{"gc.root_bead_id":"%s"%s}}' \
    "$id" "$root" "$( [ -n "$kind" ] && printf ',"gc.kind":"%s"' "$kind" )"
}

# show_json ID STATUS REASON -> exports the bd-show stub payload for ID.
export_show() {
  local id="$1" status="$2" reason="${3:-}"
  local var="STUB_BDSHOW_JSON_$(printf '%s' "$id" | tr -c 'A-Za-z0-9_' '_')"
  export "$var"="{\"id\":\"${id}\",\"status\":\"${status}\",\"close_reason\":\"${reason}\"}"
}

# ===========================================================================
# CASE 1 — a leaf bead under a CLOSED root is closed with the expected
#   metadata + force, and exactly one digest mail is sent.
# ===========================================================================
start_case "1: a leaf bead under a closed root is closed (metadata, then --force), one digest mail"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-lane1 fk-rootA "")]"
export_show "fk-rootA" "closed" "abandoned: superseded"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
if grep -qE 'bd update fk-lane1 .*gc\.outcome=skipped' "$GC_LOG" && grep -qE 'bd update fk-lane1 .*gc\.work_outcome=abandoned' "$GC_LOG"; then
  pass "fk-lane1 was stamped gc.outcome=skipped + gc.work_outcome=abandoned before close"
else
  fail "expected fk-lane1 to be stamped with skip/abandon metadata; log was:
$(cat "$GC_LOG")"
fi
if grep -qE 'bd close fk-lane1 .*--force' "$GC_LOG"; then
  pass "fk-lane1 was force-closed"
else
  fail "expected a --force close of fk-lane1; log was:
$(cat "$GC_LOG")"
fi
if grep -qE 'bd close fk-lane1 .*fk-rootA' "$GC_LOG"; then
  pass "the close reason names the closed root fk-rootA"
else
  fail "expected the close reason to name fk-rootA; log was:
$(cat "$GC_LOG")"
fi
assert_eq "1" "$(grep -c -E 'mail send mayor' "$GC_LOG")" "exactly one digest mail is sent"
if grep -qE 'mail send mayor .*ORPHAN SWEEP: closed 1.*fk-rootA' "$GC_LOG"; then
  pass "the digest mail reports the closed count and root id"
else
  fail "expected a digest mail naming the closed count and root; log was:
$(cat "$GC_LOG")"
fi
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootA

# ===========================================================================
# CASE 2 — a bead under an OPEN root is never touched; the root is never
#   closed either.
# ===========================================================================
start_case "2: a bead under an open root is left untouched"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-lane2 fk-rootB "")]"
export_show "fk-rootB" "in_progress" ""
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
if grep -qE 'bd close fk-lane2 ' "$GC_LOG"; then
  fail "fk-lane2 was closed even though its root is still open"
else
  pass "fk-lane2 under an open root was never closed"
fi
if grep -qE 'bd close fk-rootB ' "$GC_LOG"; then
  fail "the open root fk-rootB was closed"
else
  pass "the open root itself was never closed"
fi
assert_eq "0" "$(grep -c -E 'mail send' "$GC_LOG")" "no mail on a quiet tick"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootB

# ===========================================================================
# CASE 3 (review fk-gypn9m BLOCKING-2) — leaf-first ordering using the REAL
#   engine kind strings: lane/step, scope-check, scope, ralph (the live
#   engine's actual gc.kind for the workflow controller, not "workflow" —
#   iteration-1's "leaf-first (check)" trusted the script's own comment
#   instead of the real engine kind), workflow-finalize under the SAME
#   closed root close in that relative order. Every candidate here is ALSO
#   listed as `bd blocked` (BLOCKING-1 fix): dependency-blocked state is the
#   normal state of a workflow controller and must not be treated as a
#   human hold — they still close, in leaf-first order.
# ===========================================================================
start_case "3: descendants close leaf-first (real kind strings): lane -> scope-check -> scope -> ralph -> workflow-finalize"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-wff fk-rootC workflow-finalize),$(bead_json fk-ralph fk-rootC ralph),$(bead_json fk-scope fk-rootC scope),$(bead_json fk-schk fk-rootC scope-check),$(bead_json fk-lane3 fk-rootC "")]"
export_show "fk-rootC" "closed" "abandoned: whole tree closed"
export STUB_BLOCKED_JSON='[{"id":"fk-wff"},{"id":"fk-ralph"},{"id":"fk-scope"},{"id":"fk-schk"}]'
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
order="$(grep -oE 'bd close fk-(lane3|schk|scope|ralph|wff) ' "$GC_LOG" | awk '{print $3}')"
expected="fk-lane3
fk-schk
fk-scope
fk-ralph
fk-wff"
assert_eq "$expected" "$order" "all five descendants close in leaf-first order, dependency-blocked controllers included"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootC STUB_BLOCKED_JSON

# ===========================================================================
# CASE 3b (review fk-gypn9m BLOCKING-2) — a kind this script does not
#   recognize ranks LAST (fail-closed as a controller), not as a leaf, so it
#   never closes ahead of a real controller it might depend on.
# ===========================================================================
start_case "3b: an unrecognized kind ranks last, after workflow-finalize"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-lane3b fk-rootC3b ""),$(bead_json fk-wff3b fk-rootC3b workflow-finalize),$(bead_json fk-mystery3b fk-rootC3b some-future-kind)]"
export_show "fk-rootC3b" "closed" "abandoned"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
order="$(grep -oE 'bd close fk-(lane3b|wff3b|mystery3b) ' "$GC_LOG" | awk '{print $3}')"
expected="fk-lane3b
fk-wff3b
fk-mystery3b"
assert_eq "$expected" "$order" "the unrecognized kind closes last, after workflow-finalize"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootC3b

# ===========================================================================
# CASE 4 — a bead with no gc.root_bead_id is ignored (never dereferenced).
# ===========================================================================
start_case "4: a bead with no gc.root_bead_id is ignored"
: > "$GC_LOG"
export STUB_BDLIST_JSON='[{"id":"fk-norootbead","status":"open","metadata":{}}]'
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
if grep -qE '(show|close) fk-norootbead' "$GC_LOG"; then
  fail "a bead with no gc.root_bead_id was dereferenced"
else
  pass "a bead with no gc.root_bead_id is never dereferenced"
fi
unset STUB_BDLIST_JSON

# ===========================================================================
# CASE 5 — bounded: more than N candidates under a closed root -> only N
#   close this tick.
# ===========================================================================
start_case "5: more than N candidates -> only CV_ORPHAN_SWEEP_MAX_CLOSES close this tick"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-many1 fk-rootD ''),$(bead_json fk-many2 fk-rootD ''),$(bead_json fk-many3 fk-rootD '')]"
export_show "fk-rootD" "closed" "abandoned"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" CV_ORPHAN_SWEEP_MAX_CLOSES=2 "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
assert_eq "2" "$(grep -c -E 'bd close fk-many' "$GC_LOG")" "exactly MAX_CLOSES (2) candidates close this tick"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootD

# ===========================================================================
# CASE 6 — a quiet tick (no candidates at all) sends no mail and exits 0.
# ===========================================================================
start_case "6: a quiet tick with no candidates sends no mail"
: > "$GC_LOG"
export STUB_BDLIST_JSON='[]'
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
assert_eq "0" "$(grep -c -E 'mail send' "$GC_LOG")" "no mail on a quiet tick"
unset STUB_BDLIST_JSON

# ===========================================================================
# CASE 7 — a re-minted descendant under a root already swept once (same
#   root, new bead id) is picked up and closed on the NEXT tick too.
# ===========================================================================
start_case "7: a descendant re-minted after a previous sweep is closed on the next tick"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-remint fk-rootE '')]"
export_show "fk-rootE" "closed" "abandoned"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0 on the tick that finds the re-minted bead"
if grep -qE 'bd close fk-remint ' "$GC_LOG"; then
  pass "the re-minted descendant is closed"
else
  fail "expected the re-minted descendant fk-remint to be closed; log was:
$(cat "$GC_LOG")"
fi
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootE

# ===========================================================================
# CASE 8 — CV_ORPHAN_SWEEP_ENABLED=false disables the sweep entirely: no bd
#   calls at all, script still exits 0.
# ===========================================================================
start_case "8: CV_ORPHAN_SWEEP_ENABLED=false disables the sweep"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-disabled fk-rootF '')]"
export_show "fk-rootF" "closed" "abandoned"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" CV_ORPHAN_SWEEP_ENABLED=false "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0 when disabled"
assert_eq "0" "$(wc -l < "$GC_LOG" | tr -d ' ')" "no gc calls at all when disabled"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootF

# ===========================================================================
# CASE 9 (review fk-gypn9m BLOCKING-1) — a PINNED candidate under a closed
#   root is skipped: never stamped, never closed, left open for human review.
#   A pure-skip tick (nothing else closes) sends no digest mail.
# ===========================================================================
start_case "9: a pinned candidate under a closed root is skipped, not force-closed"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-pinned9 fk-rootG "")]"
export_show "fk-rootG" "closed" "abandoned"
export STUB_PINNED_JSON='[{"id":"fk-pinned9"}]'
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
if grep -qE 'SKIP \(pinned/blocked\) fk-pinned9' <<< "$out"; then
  pass "diagnostic reports the pinned skip for fk-pinned9"
else
  fail "expected a pinned-skip diagnostic for fk-pinned9; output was:
$out"
fi
if grep -qE 'bd update fk-pinned9 ' "$GC_LOG"; then
  fail "a pinned candidate was stamped with skip/abandon metadata"
else
  pass "a pinned candidate is never stamped"
fi
if grep -qE 'bd close fk-pinned9 ' "$GC_LOG"; then
  fail "a pinned candidate was force-closed"
else
  pass "a pinned candidate is never closed"
fi
assert_eq "0" "$(grep -c -E 'mail send' "$GC_LOG")" "no digest mail on a tick where everything was skipped"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootG STUB_PINNED_JSON

# ===========================================================================
# CASE 10 (review fk-gypn9m BLOCKING-1) — a dependency/gate-BLOCKED (`bd
#   blocked`) candidate is NOT a human hold; it is normal workflow-controller
#   state, and leaf-first ordering already sequences it correctly, so it
#   closes just like its non-blocked sibling. `bd blocked` is never even
#   consulted — STUB_BLOCKED_JSON is set here specifically to prove it has no
#   effect on the skip decision any more.
# ===========================================================================
start_case "10: a gate-blocked candidate is NOT skipped; it closes like its sibling, bd blocked is not consulted"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-lane10 fk-rootH ""),$(bead_json fk-blocked10 fk-rootH "")]"
export_show "fk-rootH" "closed" "abandoned"
export STUB_BLOCKED_JSON='[{"id":"fk-blocked10"}]'
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
if grep -qE 'bd close fk-lane10 .*--force' "$GC_LOG"; then
  pass "the sibling fk-lane10 closes"
else
  fail "expected fk-lane10 to close; log was:
$(cat "$GC_LOG")"
fi
if grep -qE 'bd close fk-blocked10 .*--force' "$GC_LOG"; then
  pass "the dependency-blocked candidate fk-blocked10 also closes (bd blocked is not a human-hold signal)"
else
  fail "expected fk-blocked10 to close despite being bd-blocked; log was:
$(cat "$GC_LOG")"
fi
if grep -qE '^bd blocked ' "$GC_LOG"; then
  fail "bd blocked was consulted, but it is no longer part of the skip decision"
else
  pass "bd blocked is never consulted by the orphan sweep"
fi
if grep -qE 'mail send mayor .*ORPHAN SWEEP: closed 2' "$GC_LOG"; then
  pass "digest mail reports both candidates closed"
else
  fail "expected the digest mail to report 2 closed; log was:
$(cat "$GC_LOG")"
fi
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootH STUB_BLOCKED_JSON

# ===========================================================================
# CASE 11 (review fk-gypn9m BLOCKING-2) — bd update (skip/abandon stamp)
#   fails: the close still proceeds and is still counted.
# ===========================================================================
start_case "11: bd update (metadata stamp) fails -> close still proceeds and is counted"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-lane11 fk-rootI "")]"
export_show "fk-rootI" "closed" "abandoned"
export STUB_BDUPDATE_FAIL_fk_lane11=1
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
if grep -qE 'WARNING: could not stamp metadata on fk-lane11' <<< "$out"; then
  pass "diagnostic reports the stamp failure"
else
  fail "expected a stamp-failure WARNING for fk-lane11; output was:
$out"
fi
if grep -qE 'bd close fk-lane11 .*--force' "$GC_LOG"; then
  pass "the close still proceeds despite the failed stamp"
else
  fail "expected fk-lane11 to still be closed; log was:
$(cat "$GC_LOG")"
fi
assert_eq "1" "$(grep -c -E 'mail send mayor .*ORPHAN SWEEP: closed 1' "$GC_LOG")" "the close is still counted toward the digest mail"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootI STUB_BDUPDATE_FAIL_fk_lane11

# ===========================================================================
# CASE 12 (review fk-gypn9m BLOCKING-2) — bd close --force fails for one of
#   two candidates: the failed one is NOT counted toward CLOSED_TOTAL, and
#   the digest mail reflects only the successful one.
# ===========================================================================
start_case "12: bd close --force fails for one of two candidates -> not counted, mail reflects only the successful one"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-lane12ok fk-rootJ ""),$(bead_json fk-lane12fail fk-rootJ "")]"
export_show "fk-rootJ" "closed" "abandoned"
export STUB_BDCLOSE_FAIL_fk_lane12fail=1
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
if grep -qE 'WARNING: bd close --force failed for fk-lane12fail' <<< "$out"; then
  pass "diagnostic reports the close failure for fk-lane12fail"
else
  fail "expected a close-failure WARNING for fk-lane12fail; output was:
$out"
fi
if grep -qE 'mail send mayor .*ORPHAN SWEEP: closed 1 under' "$GC_LOG"; then
  pass "digest mail counts only the successfully closed candidate (1), not the failed one"
else
  fail "expected the digest mail to report exactly 1 closed; log was:
$(cat "$GC_LOG")"
fi
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootJ STUB_BDCLOSE_FAIL_fk_lane12fail

# ===========================================================================
# CASE 13 (review fk-gypn9m BLOCKING-2) — the digest mail itself fails after
#   a successful sweep: the script still exits 0 and logs a warning rather
#   than mis-reporting status.
# ===========================================================================
start_case "13: digest mail fails after a successful sweep -> still exits 0, warning logged"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-lane13 fk-rootK "")]"
export_show "fk-rootK" "closed" "abandoned"
export STUB_MAIL_SEND_FAIL=1
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script still exits 0 when the digest mail fails"
if grep -qE 'WARNING: digest mail to mayor failed' <<< "$out"; then
  pass "diagnostic reports the digest mail failure"
else
  fail "expected a digest-mail-failure WARNING; output was:
$out"
fi
if grep -qE 'bd close fk-lane13 .*--force' "$GC_LOG"; then
  pass "the close itself still happened before the mail failure"
else
  fail "expected fk-lane13 to have been closed; log was:
$(cat "$GC_LOG")"
fi
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootK STUB_MAIL_SEND_FAIL

# ===========================================================================
# CASE 14 (review fk-gypn9m BLOCKING-3) — the pinned set is fetched exactly
#   ONCE per tick, not once per candidate: a tick with several candidates
#   under a closed root issues a single `bd list --pinned` call.
# ===========================================================================
start_case "14: bd list --pinned is fetched exactly once per tick, regardless of candidate count"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-many14a fk-rootL ''),$(bead_json fk-many14b fk-rootL ''),$(bead_json fk-many14c fk-rootL '')]"
export_show "fk-rootL" "closed" "abandoned"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
assert_eq "3" "$(grep -c -E 'bd close fk-many14' "$GC_LOG")" "all three candidates close"
assert_eq "1" "$(grep -c -E 'bd list --pinned' "$GC_LOG")" "bd list --pinned is called exactly once this tick"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootL

# ===========================================================================
# CASE 15 (review fk-gypn9m BLOCKING-3) — when the one-time pinned-set fetch
#   itself fails, the tick fails SAFE: every candidate is treated as pinned
#   and left open, rather than force-closing blind.
# ===========================================================================
start_case "15: a failed bd list --pinned fetch fails safe (treats every candidate as pinned this tick)"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-lane15 fk-rootM '')]"
export_show "fk-rootM" "closed" "abandoned"
export STUB_PINNED_FETCH_FAIL=1
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
if grep -qE 'bd close fk-lane15 ' "$GC_LOG"; then
  fail "fk-lane15 was closed despite the pinned-set fetch failing"
else
  pass "fk-lane15 is left open when the pinned-set fetch fails (fail-safe)"
fi
if grep -qE 'WARNING: bd list --pinned lookup failed' <<< "$out"; then
  pass "diagnostic reports the pinned-fetch failure"
else
  fail "expected a pinned-fetch-failure WARNING; output was:
$out"
fi
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootM STUB_PINNED_FETCH_FAIL

echo
# ===========================================================================
# LOW-8 (review fk-gypn9m, re-graded BLOCKING): the initial candidate-
# enumeration `bd list` call must be bounded by cv_with_timeout like the
# script's other two store calls (pinned lookup, digest mail), not left to
# hang the whole tick on a slow store.
# ===========================================================================
start_case "LOW-8: a hung candidate-enumeration bd list is bounded, not left to hang the tick"
: > "$GC_LOG"
export STUB_CANDIDATES_HANG=1 STUB_HANG_SECONDS=20
START_TS=$(date +%s)
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" CV_LENS_STORE_TIMEOUT_SECONDS=1 "$SCRIPT" 2>&1)"
rc=$?
END_TS=$(date +%s)
elapsed=$((END_TS - START_TS))
assert_eq "0" "$rc" "script exits 0 despite a hung candidate-list call"
if [ "$elapsed" -lt 10 ]; then
  pass "the hung candidate-list call was killed well before its own 20s hang finished (elapsed ${elapsed}s)"
else
  fail "the run took ${elapsed}s — the timeout did not bound the candidate-list call"
fi
assert_eq "0" "$(grep -c -E 'mail send' "$GC_LOG")" "no digest mail on a tick that degraded to no-candidates"
unset STUB_CANDIDATES_HANG STUB_HANG_SECONDS

if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
