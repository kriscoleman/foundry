#!/usr/bin/env bash
# con-voyage-orphan-sweep.test.sh — hermetic test for con-voyage-orphan-
# sweep.sh (fk-yli8qd, mitigates engine re-mint fk-ruuy6): the gascity engine
# keeps minting review-loop iterations (ralph/scope bodies, then review
# lanes) AFTER a workflow root closes. This order is a pack-side cooldown
# mitigation: each tick, it finds every still-open bead under an already-
# CLOSED workflow root and closes it leaf-first (lane/step -> scope-check ->
# scope -> ralph -> workflow-finalize), so the engine finds nothing left to
# re-mint from. Open roots and their descendants are never touched.
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
        printf '%s' "${STUB_BDLIST_JSON:-[]}"
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
# CASE 3 — leaf-first ordering: lane/step, scope-check, scope, workflow
#   (ralph), workflow-finalize under the SAME closed root close in that
#   relative order.
# ===========================================================================
start_case "3: descendants close leaf-first: lane -> scope-check -> scope -> ralph -> workflow-finalize"
: > "$GC_LOG"
export STUB_BDLIST_JSON="[$(bead_json fk-wff fk-rootC workflow-finalize),$(bead_json fk-ralph fk-rootC workflow),$(bead_json fk-scope fk-rootC scope),$(bead_json fk-schk fk-rootC scope-check),$(bead_json fk-lane3 fk-rootC "")]"
export_show "fk-rootC" "closed" "abandoned: whole tree closed"
out="$(GC="${STUBDIR}/gc" STUB_GC_LOG="$GC_LOG" "$SCRIPT" 2>&1)"
rc=$?
assert_eq "0" "$rc" "script exits 0"
order="$(grep -oE 'bd close fk-(lane3|schk|scope|ralph|wff) ' "$GC_LOG" | awk '{print $3}')"
expected="fk-lane3
fk-schk
fk-scope
fk-ralph
fk-wff"
assert_eq "$expected" "$order" "all five descendants close in leaf-first order"
unset STUB_BDLIST_JSON STUB_BDSHOW_JSON_fk_rootC

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

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
