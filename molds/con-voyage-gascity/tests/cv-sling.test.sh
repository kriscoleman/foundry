#!/usr/bin/env bash
# cv-sling.test.sh — hermetic, offline test for the optional per-city cap on
# concurrent con-voyages (cv-sling.sh) and the queue-drain order that honors it.
#
#   Given no cap is configured (the default),
#   When  the facilitator starts a con-voyage with `cv-sling.sh start`,
#   Then  it is exactly `gc sling <target> <bead> --on con-voyage ...`, with no
#         store queries and nothing queued, however many journeys are active.
#
#   Given the city caps concurrent con-voyages at N (con-voyage.toml
#         [con_voyage] max_concurrent = N, or CV_MAX_CONCURRENT),
#   When  fewer than N con-voyage workflow roots are open, Then it slings.
#   When  N are already open, Then it slings nothing and QUEUES the start
#         (FIFO, one record per work bead, argv kept verbatim).
#   When  the active count can't be determined, Then it fails closed: queue.
#
#   Given starts are queued,
#   When  con-voyage-queue-drain runs, Then it slings the oldest queued starts
#         while slots are free (all of them once the cap is lifted), mails the
#         mayor for each, and leaves the rest queued. A sling that keeps
#         failing is moved aside to failed/ and the mayor is mailed.
#
# Run:  bash tests/cv-sling.test.sh   (exit 0 => all passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PACK_DIR="${MOLD_DIR}/pack"
SLING="${PACK_DIR}/assets/scripts/cv-sling.sh"
ORDER="${PACK_DIR}/orders/con-voyage-queue-drain.toml"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-sling-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
start_case() { echo; echo "=== CASE: $1 ==="; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qE -- "$2"; then pass "$3"; else fail "$3 (no match for /$2/)"; fi; }
assert_not_contains() { if printf '%s' "$1" | grep -qE -- "$2"; then fail "$3 (unexpected match for /$2/)"; else pass "$3"; fi; }

# ---------------------------------------------------------------------------
# gc stub. Every call is logged to $STUB_STATE/gc.log. Store contents come
# from files in $STUB_STATE:
#   rigs.json            `gc rig list --json` output (default: no rigs)
#   bdlist-<store>.json  `bd list` output for --rig <store>, or "city"
#   bdfail               when present, every `bd list` prints nothing, exit 1
#   slingfail            when present, `gc sling` exits 1
# Each successful sling's argv is appended to slings.log, one arg per line,
# each sling terminated by a "--END--" line.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_STATE}/gc.log"
store="city"
while [ $# -gt 0 ]; do
  case "$1" in
    --city) shift 2 ;;
    --rig) store="$2"; shift 2 ;;
    *) break ;;
  esac
done
case "${1:-}" in
  rig)
    if [ -f "${STUB_STATE}/rigs.json" ]; then cat "${STUB_STATE}/rigs.json"; else printf '{"rigs":[]}'; fi
    ;;
  bd)
    [ "${2:-}" = "list" ] || exit 0
    [ -f "${STUB_STATE}/bdfail" ] && exit 1
    if [ -f "${STUB_STATE}/bdlist-${store}.json" ]; then cat "${STUB_STATE}/bdlist-${store}.json"; else printf '[]'; fi
    ;;
  sling)
    [ -f "${STUB_STATE}/slingfail" ] && { echo "stub: sling failed" >&2; exit 1; }
    shift
    for a in "$@"; do printf '%s\n' "$a" >> "${STUB_STATE}/slings.log"; done
    printf '%s\n' "--END--" >> "${STUB_STATE}/slings.log"
    ;;
  mail)
    printf '%s\n' "$*" >> "${STUB_STATE}/mail.log"
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# new_city NAME — fresh city root + stub state. Sets CITY/STATE.
new_city() {
  CITY="${SANDBOX}/city-$1"
  STATE="${SANDBOX}/state-$1"
  mkdir -p "${CITY}/.gc" "$STATE"
  : > "${STATE}/gc.log"; : > "${STATE}/slings.log"; : > "${STATE}/mail.log"
}

# set_cap N — write the city's committed setting file.
set_cap() {
  printf '[con_voyage]\nmax_concurrent = %s\n' "$1" > "${CITY}/con-voyage.toml"
}

# root ID STATUS FORMULA CREATED — one bd list row for a workflow root.
root() {
  printf '{"id":"%s","status":"%s","created_at":"%s","metadata":{"gc.kind":"workflow","gc.formula_name":"%s"}}' \
    "$1" "$2" "$4" "$3"
}

# store NAME ROW... — write a bd list JSON array for one store.
store() {
  local name="$1"; shift
  local IFS=,
  printf '[%s]' "$*" > "${STATE}/bdlist-${name}.json"
}

# run CMD... — run CMD from the city root with the stub on PATH; sets OUT/RC.
run() {
  OUT="$(cd "$CITY" && env -u CV_MAX_CONCURRENT -u CV_QUEUE_DIR \
    PATH="${STUBDIR}:${PATH}" GC="${STUBDIR}/gc" GC_CITY="$CITY" \
    STUB_STATE="$STATE" "$@" 2>&1)"
  RC=$?
}

sling_count() { grep -c -- '^--END--$' "${STATE}/slings.log"; }
queue_count() { find "${CITY}/.gc/cv-queue" -maxdepth 1 -name '*.sling' 2>/dev/null | wc -l | tr -d ' '; }

if [ ! -f "$SLING" ]; then
  echo "FATAL: ${SLING} not found" >&2
  exit 1
fi

# ===========================================================================
start_case "1: no cap configured — start is a plain gc sling --on con-voyage, nothing queried or queued"
new_city 1
store city "$(root hq-1 in_progress con-voyage 2026-10-01T00:00:00Z)" "$(root hq-2 open con-voyage 2026-10-01T00:00:01Z)"
run bash "$SLING" start myrig/gc.implementation-worker fk-abc --var push=true --var open_pr=true
assert_eq "0" "$RC" "start exits 0"
assert_eq "1" "$(sling_count)" "slung exactly once"
assert_eq "myrig/gc.implementation-worker
fk-abc
--on
con-voyage
--var
push=true
--var
open_pr=true
--END--" "$(cat "${STATE}/slings.log")" "argv is <target> <bead> --on con-voyage <extra args...>"
assert_not_contains "$(cat "${STATE}/gc.log")" "bd list|rig list" "no store queries when uncapped"
assert_eq "0" "$(queue_count)" "nothing queued"

# ===========================================================================
start_case "2: cap 1, nothing active — slings"
new_city 2
set_cap 1
store city "$(root hq-9 closed con-voyage 2026-10-01T00:00:00Z)" "$(root hq-8 in_progress con-voyage-ci-repair 2026-10-01T00:00:00Z)" "$(root hq-7 open con-voyage-review-escort 2026-10-01T00:00:00Z)"
run bash "$SLING" start rig/worker fk-1
assert_eq "0" "$RC" "start exits 0"
assert_eq "1" "$(sling_count)" "slung: closed roots and other formulas don't count"
assert_contains "$OUT" "active 0/1" "reports the count against the cap"

# ===========================================================================
start_case "3: cap 1, one con-voyage active in a rig store — queued, not slung"
new_city 3
set_cap 1
printf '{"rigs":[{"name":"hq","hq":true},{"name":"alpha"}]}' > "${STATE}/rigs.json"
store alpha "$(root al-1 in_progress con-voyage 2026-10-01T00:00:00Z)"
run bash "$SLING" start alpha/worker fk-2 --var enable_cv_sre=true
assert_eq "0" "$RC" "a queued start still exits 0"
assert_eq "0" "$(sling_count)" "nothing slung"
assert_contains "$OUT" "QUEUED" "says it was queued"
assert_contains "$OUT" "active 1/1" "names the count that blocked it"
assert_eq "1" "$(queue_count)" "one queue record"
assert_contains "$(cat "${STATE}/gc.log")" "--rig alpha bd list" "queried the rig's own store"

start_case "3b: queuing the same work bead again is a no-op"
run bash "$SLING" start alpha/worker fk-2 --var enable_cv_sre=true
assert_eq "0" "$RC" "exits 0"
assert_contains "$OUT" "already queued" "says it is already queued"
assert_eq "1" "$(queue_count)" "still one queue record"

start_case "3c: status shows the cap, the active journeys, and the queue"
run bash "$SLING" status
assert_eq "0" "$RC" "status exits 0"
assert_contains "$OUT" "max_concurrent: 1" "shows the cap"
assert_contains "$OUT" "active: 1" "shows the active count"
assert_contains "$OUT" "al-1" "lists the active root"
assert_contains "$OUT" "queued: 1" "shows the queue length"
assert_contains "$OUT" "fk-2" "lists the queued work bead"

# ===========================================================================
start_case "4: drain at cap dispatches nothing"
run bash "$SLING" drain
assert_eq "0" "$RC" "drain exits 0"
assert_eq "0" "$(sling_count)" "nothing slung while at cap"
assert_eq "1" "$(queue_count)" "record kept"

start_case "4b: drain after the active journey finishes slings the queued start verbatim"
run bash "$SLING" start alpha/worker fk-3 --var "title=a b; touch ${SANDBOX}/pwned"
assert_eq "2" "$(queue_count)" "second start queued behind the first"
store alpha "$(root al-1 closed con-voyage 2026-10-01T00:00:00Z)"
run bash "$SLING" drain
assert_eq "0" "$RC" "drain exits 0"
assert_eq "1" "$(sling_count)" "exactly one slot, exactly one sling"
assert_eq "alpha/worker
fk-2
--on
con-voyage
--var
enable_cv_sre=true
--END--" "$(cat "${STATE}/slings.log")" "the OLDEST queued start, argv verbatim"
assert_eq "1" "$(queue_count)" "the newer start stays queued"
assert_contains "$(cat "${STATE}/mail.log")" "mail send mayor .*fk-2" "mayor mailed about the dequeued start"

start_case "4c: raising the cap lets drain dispatch more; argv never reaches a shell"
: > "${STATE}/slings.log"
store alpha "$(root al-2 in_progress con-voyage 2026-10-02T00:00:00Z)"
set_cap 2
run bash "$SLING" drain
assert_eq "1" "$(sling_count)" "one free slot under the raised cap, one sling"
assert_eq "0" "$(queue_count)" "queue empty"
assert_contains "$(cat "${STATE}/slings.log")" "^title=a b; touch ${SANDBOX}/pwned$" "an arg with spaces and ; is passed as ONE argv entry"
if [ -e "${SANDBOX}/pwned" ]; then fail "a queued arg was executed by a shell"; else pass "queued args are never evaluated"; fi

# ===========================================================================
start_case "5: lifting the cap drains every queued start"
new_city 5
set_cap 1
store city "$(root hq-1 in_progress con-voyage 2026-10-01T00:00:00Z)"
run bash "$SLING" start w fk-a
run bash "$SLING" start w fk-b
run bash "$SLING" start w fk-c
assert_eq "3" "$(queue_count)" "three queued"
rm -f "${CITY}/con-voyage.toml"
run bash "$SLING" drain
assert_eq "3" "$(sling_count)" "all three slung once uncapped"
assert_eq "0" "$(queue_count)" "queue empty"
assert_eq "fk-a fk-b fk-c" "$(awk 'prev=="w"{printf "%s%s", sep, $0; sep=" "} {prev=$0}' "${STATE}/slings.log")" "FIFO order"

# ===========================================================================
start_case "6: unknown active count fails closed"
new_city 6
set_cap 3
: > "${STATE}/bdfail"
run bash "$SLING" start w fk-x
assert_eq "0" "$(sling_count)" "nothing slung when the store can't be read"
assert_eq "1" "$(queue_count)" "queued instead"
assert_contains "$OUT" "could not count" "says why"
run bash "$SLING" drain
assert_eq "0" "$(sling_count)" "drain dispatches nothing while the count is unknown"
assert_eq "1" "$(queue_count)" "record kept"

start_case "6b: an unreadable rig store also fails closed"
rm -f "${STATE}/bdfail"
printf '{"rigs":[{"name":"alpha"}]}' > "${STATE}/rigs.json"
cat > "${STUBDIR}/gc-rigfail" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --rig alpha bd list "*) exit 1 ;; esac
exec "$(dirname "$0")/gc" "$@"
EOF
chmod +x "${STUBDIR}/gc-rigfail"
run env GC="${STUBDIR}/gc-rigfail" bash "$SLING" drain
assert_eq "0" "$(sling_count)" "nothing dispatched when one rig store is unreadable"

# ===========================================================================
start_case "7: CV_MAX_CONCURRENT overrides the file; bad values warn and mean uncapped"
new_city 7
set_cap 5
store city "$(root hq-1 open con-voyage 2026-10-01T00:00:00Z)"
run env CV_MAX_CONCURRENT=1 bash "$SLING" start w fk-1
assert_eq "0" "$(sling_count)" "env cap 1 beats the file's 5"
assert_eq "1" "$(queue_count)" "queued"
set_cap '"lots"'
run bash "$SLING" start w fk-2
assert_eq "1" "$(sling_count)" "a non-integer cap is treated as uncapped"
assert_contains "$OUT" "WARNING.*max_concurrent" "and warns"
set_cap 0
run bash "$SLING" limit
assert_eq "0" "$OUT" "0 means uncapped"

# ===========================================================================
start_case "8: a sling that keeps failing is set aside and the mayor is told"
new_city 8
set_cap 1
store city "$(root hq-1 open con-voyage 2026-10-01T00:00:00Z)"
run bash "$SLING" start w fk-bad
store city
: > "${STATE}/slingfail"
run bash "$SLING" drain
assert_eq "1" "$(queue_count)" "kept after the first failure"
run bash "$SLING" drain
run bash "$SLING" drain
assert_eq "0" "$(queue_count)" "set aside after 3 failed attempts"
assert_eq "1" "$(find "${CITY}/.gc/cv-queue/failed" -name '*.sling' | wc -l | tr -d ' ')" "moved to failed/"
assert_contains "$(cat "${STATE}/mail.log")" "mail send mayor .*fk-bad" "mayor mailed"

start_case "8b: after a set-aside, new starts sling normally"
rm -f "${STATE}/slingfail"
run bash "$SLING" start w fk-good
assert_eq "1" "$(sling_count)" "uncapped slot -> slung directly"

# ===========================================================================
start_case "9: drain with an empty queue makes no gc calls"
new_city 9
set_cap 1
run bash "$SLING" drain
assert_eq "0" "$RC" "exits 0"
assert_eq "" "$(cat "${STATE}/gc.log")" "no gc calls"

# ===========================================================================
start_case "10: misuse fails with usage"
new_city 10
run bash "$SLING" start w
assert_eq "2" "$RC" "missing work bead exits 2"
run bash "$SLING" start w fk-1 --on do-work
assert_eq "2" "$RC" "--on is rejected (cv-sling always uses con-voyage)"
assert_eq "0" "$(sling_count)" "nothing slung"
run bash "$SLING" bogus
assert_eq "2" "$RC" "unknown subcommand exits 2"

# ===========================================================================
start_case "11: the drain order ships and runs the script on a cooldown"
if [ -f "$ORDER" ]; then pass "order file exists"; else fail "missing ${ORDER}"; fi
assert_contains "$(cat "$ORDER" 2>/dev/null)" 'exec = "\$PACK_DIR/assets/scripts/con-voyage-queue-drain.sh"' "execs con-voyage-queue-drain.sh"
assert_contains "$(cat "$ORDER" 2>/dev/null)" 'trigger = "cooldown"' "runs on a cooldown"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED: ${FAILURES} assertion(s)" >&2
  exit 1
fi
echo "ALL CASES PASSED"
