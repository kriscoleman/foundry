#!/usr/bin/env bash
# con-voyage-assistant-scaffolding.test.sh — hermetic unit tests for the
# shared prerequisite layer the three city assistants (Marshal, Scribe,
# Custodian — fk-apujks, see .claude/plans/con-voyage-assistants.md "Shared
# scaffolding") will all build on. None of the three assistants exist yet;
# this suite covers only the two primitives this bead adds to
# con-voyage-lib.sh:
#
#   cv_assistant_enabled NAME       — the [con_voyage.assistants] feature
#                                      flag, pack-default false, overridable
#                                      per rig, independently per assistant.
#   cv_write_handoff_note / cv_read_handoff_note — the mail-to-self
#                                      suspend/resume handoff-note pair that
#                                      mirrors the mayor's own existing
#                                      HIGH-context handoff idiom.
#
# HOW IT WORKS (no network, no real gc, no real bd): the lib is `source`d
# directly (it defines functions only, per its own header comment — no
# side effects at source time). A recording `gc` stub on PATH serves canned
# `mail send`/`mail inbox`/`mail read` JSON bodies and records every
# invocation to STUB_GC_LOG. cv_assistant_enabled is exercised against real
# TOML files written into a sandbox (python3's stdlib tomllib, not a stub —
# this is the one thing worth testing against the real parser).
#
# Run:  bash tests/con-voyage-assistant-scaffolding.test.sh   (exit 0 => pass)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${MOLD_DIR}/pack/assets/scripts/con-voyage-lib.sh"
PACK_DEFAULTS="${MOLD_DIR}/pack/assets/config/con-voyage-assistants.defaults.toml"

if [ ! -f "$LIB" ]; then
  echo "FATAL: lib under test not found at ${LIB}" >&2
  exit 2
fi

if [ ! -f "$PACK_DEFAULTS" ]; then
  echo "FATAL: pack default config not found at ${PACK_DEFAULTS}" >&2
  exit 2
fi

if ! python3 -c "import tomllib" 2>/dev/null; then
  echo "SKIP: python3 has no tomllib (needs 3.11+); cannot exercise cv_assistant_enabled" >&2
  exit 0
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-assistant-scaffold-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
RIG_ROOT="${SANDBOX}/rig"
export STUB_GC_LOG="${SANDBOX}/gc.log"
mkdir -p "$STUBDIR" "$RIG_ROOT/.gc" "$RIG_ROOT/.beads"
: > "$STUB_GC_LOG"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Recording `gc` stub. `mail send <to> -s SUBJ -m BODY --json` records the
# sent (to, subject, body) into STUB_INBOX_JSON-style files under $SANDBOX so
# a later `mail inbox --json` / `mail read <id> --json` in the SAME test case
# can read it back — genuinely round-tripping the write/read pair rather than
# asserting against canned fixtures, since no real gc JSON shape exists yet to
# fixture against (this is new ground, unlike the lookout/pr-watch stubs that
# mirror an already-observed real shape).
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

MAILDIR="${STUB_MAILDIR:?STUB_MAILDIR not set}"
mkdir -p "$MAILDIR"

if [ "$1" = "mail" ]; then
  shift
  case "$1" in
    send)
      shift
      to="$1"; shift
      subject=""
      body=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -s|--subject) subject="$2"; shift 2 ;;
          -m|--message) body="$2"; shift 2 ;;
          --json) shift ;;
          *) shift ;;
        esac
      done
      if [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ]; then
        echo "stub: mail send forced failure" >&2
        exit 1
      fi
      id="msg-$(( $(ls "$MAILDIR" 2>/dev/null | wc -l) + 1 ))"
      python3 -c "
import json, sys
json.dump({'to': sys.argv[1], 'subject': sys.argv[2], 'body': sys.argv[3]}, open(sys.argv[4], 'w'))
" "$to" "$subject" "$body" "${MAILDIR}/${id}.json"
      printf '{"message": {"id": "%s"}}\n' "$id"
      exit 0
      ;;
    inbox)
      if [ "${STUB_MAIL_INBOX_FAIL:-0}" = "1" ]; then
        echo "stub: mail inbox forced failure" >&2
        exit 1
      fi
      python3 -c "
import json, os, sys
maildir = sys.argv[1]
messages = []
for name in sorted(os.listdir(maildir)):
    if not name.endswith('.json'):
        continue
    with open(os.path.join(maildir, name)) as fh:
        rec = json.load(fh)
    messages.append({'id': name[:-5], 'subject': rec['subject'], 'body': rec['body']})
print(json.dumps({'messages': messages}))
" "$MAILDIR"
      exit 0
      ;;
    read)
      shift
      id="$1"
      if [ "${STUB_MAIL_READ_FAIL:-0}" = "1" ]; then
        echo "stub: mail read forced failure" >&2
        exit 1
      fi
      f="${MAILDIR}/${id}.json"
      if [ ! -f "$f" ]; then
        echo "{}"
        exit 0
      fi
      python3 -c "
import json, sys
rec = json.load(open(sys.argv[1]))
print(json.dumps({'message': {'id': sys.argv[2], 'subject': rec['subject'], 'body': rec['body']}}))
" "$f" "$id"
      exit 0
      ;;
    archive)
      shift
      for id in "$@"; do
        rm -f "${MAILDIR}/${id}.json"
      done
      exit 0
      ;;
  esac
fi

exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"
export PATH="${STUBDIR}:${PATH}"
export GC="gc"

PASS=0
FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${desc}: expected [${expected}] got [${actual}]"
  fi
}

# ===========================================================================
# cv_assistant_enabled — pack default (no rig override file at all)
# ===========================================================================
(
  unset GC_RIG_ROOT
  cd "$SANDBOX" || exit 1
  export GC_CITY="${SANDBOX}/city"
  mkdir -p "${GC_CITY}/packs/con-voyage/assets/config"
  cp "$PACK_DEFAULTS" "${GC_CITY}/packs/con-voyage/assets/config/con-voyage-assistants.defaults.toml"
  source "$LIB" >/dev/null 2>&1
  for name in marshal scribe custodian; do
    val="$(cv_assistant_enabled "$name")"
    echo "PACK_DEFAULT:${name}:${val}"
  done
) > "${SANDBOX}/pack_default.out"
while IFS=: read -r _tag name val; do
  assert_eq "pack default ${name} is suspended" "false" "$val"
done < "${SANDBOX}/pack_default.out"

# ===========================================================================
# cv_assistant_enabled — rig override flips ONE assistant independently
# ===========================================================================
cat > "${RIG_ROOT}/.gc/con-voyage-assistants.toml" <<'EOF'
[con_voyage.assistants]
marshal = true
EOF
(
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  export GC_CITY="${SANDBOX}/city"
  source "$LIB" >/dev/null 2>&1
  for name in marshal scribe custodian; do
    val="$(cv_assistant_enabled "$name")"
    echo "RIG_OVERRIDE:${name}:${val}"
  done
) > "${SANDBOX}/rig_override.out"
while IFS=: read -r _tag name val; do
  if [ "$name" = "marshal" ]; then
    assert_eq "rig override flips marshal on" "true" "$val"
  else
    assert_eq "rig override leaves ${name} off (independent flags)" "false" "$val"
  fi
done < "${SANDBOX}/rig_override.out"

# ===========================================================================
# cv_write_handoff_note / cv_read_handoff_note — suspend/resume round trip
# ===========================================================================
(
  export GC_SESSION_ID="test-session-marshal"
  export STUB_MAILDIR="${SANDBOX}/maildir-roundtrip"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  cv_write_handoff_note "marshal" "digest.log:offset=482" "fk-xyz12:closed-abandoned" "resume the bead-sweep from the saved offset"
  echo "WRITE_RC:$?"
  { IFS= read -r feed; IFS= read -r bead; IFS= read -r next; } < <(cv_read_handoff_note "marshal")
  printf 'FEED:%s\n' "${feed:-}"
  printf 'BEAD:%s\n' "${bead:-}"
  printf 'NEXT:%s\n' "${next:-}"
) > "${SANDBOX}/roundtrip.out" 2>"${SANDBOX}/roundtrip.err"
cat "${SANDBOX}/roundtrip.out"
WRITE_RC="$(grep '^WRITE_RC:' "${SANDBOX}/roundtrip.out" | cut -d: -f2)"
FEED="$(grep '^FEED:' "${SANDBOX}/roundtrip.out" | cut -d: -f2-)"
BEAD="$(grep '^BEAD:' "${SANDBOX}/roundtrip.out" | cut -d: -f2-)"
NEXT="$(grep '^NEXT:' "${SANDBOX}/roundtrip.out" | cut -d: -f2-)"
assert_eq "write succeeds" "0" "$WRITE_RC"
assert_eq "round trip preserves feed position" "digest.log:offset=482" "$FEED"
assert_eq "round trip preserves owned-bead status" "fk-xyz12:closed-abandoned" "$BEAD"
assert_eq "round trip preserves next action" "resume the bead-sweep from the saved offset" "$NEXT"

# ===========================================================================
# cv_read_handoff_note — no note for a DIFFERENT assistant name in the same
# inbox returns nothing (never cross-matches another assistant's note)
# ===========================================================================
(
  export GC_SESSION_ID="test-session-marshal"
  export STUB_MAILDIR="${SANDBOX}/maildir-roundtrip"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  out="$(cv_read_handoff_note "scribe")"
  [ -z "$out" ] && echo "COUNT:0" || echo "COUNT:nonzero"
) > "${SANDBOX}/no_cross_match.out"
COUNT="$(grep '^COUNT:' "${SANDBOX}/no_cross_match.out" | cut -d: -f2)"
assert_eq "a different assistant's name finds no note in the same inbox" "0" "$COUNT"

# ===========================================================================
# cv_write_handoff_note — a send failure is reported, not swallowed silently
# ===========================================================================
(
  export GC_SESSION_ID="test-session-marshal"
  export STUB_MAILDIR="${SANDBOX}/maildir-fail"
  export STUB_MAIL_SEND_FAIL="1"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  cv_write_handoff_note "marshal" "x" "y" "z"
  echo "RC:$?"
) > "${SANDBOX}/send_fail.out" 2>/dev/null
SEND_FAIL_RC="$(grep '^RC:' "${SANDBOX}/send_fail.out" | cut -d: -f2)"
assert_eq "a failed send returns non-zero, not silently swallowed" "1" "$SEND_FAIL_RC"

# ===========================================================================
# LOW-1 (fk-apujks review): cv_assistant_config_bool with python3 missing
# from PATH must behave deterministically -- print nothing, warn to stderr,
# and return 0 -- never leak bash's "command not found" exit 127.
# ===========================================================================
(
  TMP_CFG="${SANDBOX}/low1.toml"
  cat > "$TMP_CFG" <<'EOF'
[con_voyage.assistants]
marshal = true
EOF
  unset GC_RIG_ROOT
  source "$LIB" >/dev/null 2>&1
  PATH="${STUBDIR}" command -v python3 >/dev/null 2>&1 && echo "SKIP: python3 still reachable on the trimmed PATH" || true
  out="$(PATH="${STUBDIR}" cv_assistant_config_bool "$TMP_CFG" "marshal" 2>"${SANDBOX}/low1.err")"
  rc=$?
  echo "OUT:${out}"
  echo "RC:${rc}"
) > "${SANDBOX}/low1.out"
LOW1_OUT="$(grep '^OUT:' "${SANDBOX}/low1.out" | cut -d: -f2-)"
LOW1_RC="$(grep '^RC:' "${SANDBOX}/low1.out" | cut -d: -f2)"
assert_eq "python3-missing: prints nothing (not a guess)" "" "$LOW1_OUT"
assert_eq "python3-missing: returns 0, not a leaked 127" "0" "$LOW1_RC"
if grep -q "python3 not found" "${SANDBOX}/low1.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: python3-missing: warns to stderr naming python3 as the cause"
fi

# ===========================================================================
# LOW-2 (fk-apujks review): a present-but-non-bool flag value (a quoted
# string "true" instead of a real TOML boolean) must not silently be
# treated as absent -- it must warn, naming the key, and still fail soft
# (print nothing, so the caller's fallback chain decides, same as today).
# ===========================================================================
(
  TMP_CFG="${SANDBOX}/low2.toml"
  cat > "$TMP_CFG" <<'EOF'
[con_voyage.assistants]
marshal = "true"
EOF
  source "$LIB" >/dev/null 2>&1
  out="$(cv_assistant_config_bool "$TMP_CFG" "marshal" 2>"${SANDBOX}/low2.err")"
  echo "OUT:${out}"
) > "${SANDBOX}/low2.out"
LOW2_OUT="$(grep '^OUT:' "${SANDBOX}/low2.out" | cut -d: -f2-)"
assert_eq "non-bool value: still fails soft (prints nothing, not a guessed value)" "" "$LOW2_OUT"
if grep -q "marshal" "${SANDBOX}/low2.err" && grep -q "not a boolean" "${SANDBOX}/low2.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: non-bool value: warns to stderr naming the key as not a boolean"
fi

# ===========================================================================
# LOW-4 (fk-apujks review): cv_read_handoff_note logs one stderr line on
# EVERY failure branch -- empty/failed inbox, no subject match, failed
# read, and an unparsable body -- instead of some branches failing silent.
# ===========================================================================
# Branch 1: gc mail inbox itself fails/times out.
(
  export GC_SESSION_ID="test-session-low4"
  export STUB_MAILDIR="${SANDBOX}/maildir-low4-inbox-fail"
  export STUB_MAIL_INBOX_FAIL="1"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  out="$(cv_read_handoff_note "marshal" 2>"${SANDBOX}/low4_inbox_fail.err")"
  echo "OUT:${out}"
) > "${SANDBOX}/low4_inbox_fail.out"
assert_eq "LOW-4 branch 1 (inbox fails): no output" "" "$(grep '^OUT:' "${SANDBOX}/low4_inbox_fail.out" | cut -d: -f2-)"
if grep -q "no handoff note found for marshal" "${SANDBOX}/low4_inbox_fail.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: LOW-4 branch 1 (inbox fails): logs a stderr line"
fi

# Branch 2: inbox has messages, but none for this NAME.
(
  export GC_SESSION_ID="test-session-low4"
  export STUB_MAILDIR="${SANDBOX}/maildir-low4-no-match"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  cv_write_handoff_note "scribe" "a" "b" "c" >/dev/null 2>&1
  out="$(cv_read_handoff_note "marshal" 2>"${SANDBOX}/low4_no_match.err")"
  echo "OUT:${out}"
) > "${SANDBOX}/low4_no_match.out"
assert_eq "LOW-4 branch 2 (no subject match): no output" "" "$(grep '^OUT:' "${SANDBOX}/low4_no_match.out" | cut -d: -f2-)"
if grep -q "no handoff note found for marshal" "${SANDBOX}/low4_no_match.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: LOW-4 branch 2 (no subject match): logs a stderr line"
fi

# Branch 3: gc mail read fails/times out.
(
  export GC_SESSION_ID="test-session-low4"
  export STUB_MAILDIR="${SANDBOX}/maildir-low4-read-fail"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  cv_write_handoff_note "marshal" "a" "b" "c" >/dev/null 2>&1
  export STUB_MAIL_READ_FAIL="1"
  out="$(cv_read_handoff_note "marshal" 2>"${SANDBOX}/low4_read_fail.err")"
  echo "OUT:${out}"
) > "${SANDBOX}/low4_read_fail.out"
assert_eq "LOW-4 branch 3 (read fails): no output" "" "$(grep '^OUT:' "${SANDBOX}/low4_read_fail.out" | cut -d: -f2-)"
if grep -q "failed to read handoff note" "${SANDBOX}/low4_read_fail.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: LOW-4 branch 3 (read fails): logs a stderr line"
fi

# Branch 4: the message exists but its body has none of the expected fields.
(
  export GC_SESSION_ID="test-session-low4"
  export STUB_MAILDIR="${SANDBOX}/maildir-low4-unparsable"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  mkdir -p "$STUB_MAILDIR"
  python3 -c "
import json
json.dump({'to': 'self', 'subject': 'con-voyage marshal handoff', 'body': 'this body has no recognized fields at all'}, open('${STUB_MAILDIR}/msg-1.json', 'w'))
"
  source "$LIB" >/dev/null 2>&1
  out="$(cv_read_handoff_note "marshal" 2>"${SANDBOX}/low4_unparsable.err")"
  echo "OUT:${out}"
) > "${SANDBOX}/low4_unparsable.out"
assert_eq "LOW-4 branch 4 (unparsable body): no output" "" "$(grep '^OUT:' "${SANDBOX}/low4_unparsable.out" | cut -d: -f2-)"
if grep -q "did not parse" "${SANDBOX}/low4_unparsable.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: LOW-4 branch 4 (unparsable body): logs a stderr line"
fi

# ===========================================================================
# LOW-5 (fk-apujks review): no unbounded self-mailbox growth. Two
# cv_write_handoff_note calls for the SAME NAME leave two messages in the
# mailbox; one cv_read_handoff_note call must archive the OLDER one, so
# the mailbox never accumulates every past handoff note.
# ===========================================================================
(
  export GC_SESSION_ID="test-session-low5"
  export STUB_MAILDIR="${SANDBOX}/maildir-low5"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  cv_write_handoff_note "marshal" "first" "b1" "n1" >/dev/null 2>&1
  cv_write_handoff_note "marshal" "second" "b2" "n2" >/dev/null 2>&1
  before="$(ls "$STUB_MAILDIR" | wc -l | tr -d ' ')"
  # Command substitution (not process substitution) so this shell fully
  # waits for cv_read_handoff_note's post-print archive step to finish
  # before checking the "after" mailbox state below -- a `< <(...)` here
  # would race ahead as soon as the three lines are read, before the
  # function's trailing `gc mail archive` call actually completes.
  note_out="$(cv_read_handoff_note "marshal")"
  feed="$(printf '%s\n' "$note_out" | sed -n '1p')"
  after="$(ls "$STUB_MAILDIR" | wc -l | tr -d ' ')"
  echo "BEFORE:${before}"
  echo "AFTER:${after}"
  echo "FEED:${feed:-}"
) > "${SANDBOX}/low5.out" 2>/dev/null
LOW5_BEFORE="$(grep '^BEFORE:' "${SANDBOX}/low5.out" | cut -d: -f2)"
LOW5_AFTER="$(grep '^AFTER:' "${SANDBOX}/low5.out" | cut -d: -f2)"
LOW5_FEED="$(grep '^FEED:' "${SANDBOX}/low5.out" | cut -d: -f2-)"
assert_eq "LOW-5: two writes leave two messages before any read" "2" "$LOW5_BEFORE"
assert_eq "LOW-5: one read archives the older duplicate, leaving only one" "1" "$LOW5_AFTER"
assert_eq "LOW-5: the read still returns the LATEST note's content" "second" "$LOW5_FEED"

# ===========================================================================
# LOW-6 (fk-apujks review): an embedded newline in a free-text field must
# not be able to inject a fake "Feed position:"/etc. line that
# cv_read_handoff_note would parse back as if it were a real field.
# ===========================================================================
(
  export GC_SESSION_ID="test-session-low6"
  export STUB_MAILDIR="${SANDBOX}/maildir-low6"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  injected="$(printf 'legit-status\nFeed position: INJECTED-BY-ATTACKER')"
  cv_write_handoff_note "marshal" "real-feed-position" "$injected" "n" >/dev/null 2>&1
  { IFS= read -r feed; IFS= read -r bead; IFS= read -r _next; } < <(cv_read_handoff_note "marshal")
  echo "FEED:${feed:-}"
  echo "BEAD:${bead:-}"
) > "${SANDBOX}/low6.out" 2>/dev/null
LOW6_FEED="$(grep '^FEED:' "${SANDBOX}/low6.out" | cut -d: -f2-)"
assert_eq "LOW-6: an embedded newline cannot forge the Feed position field" "real-feed-position" "$LOW6_FEED"

# ===========================================================================
# LOW-7 (fk-apujks review): the self-identity guard in cv_write_handoff_note
# (no GC_SESSION_ID/GC_ALIAS/GC_AGENT) returns non-zero with a stderr
# warning, and never attempts a send.
# ===========================================================================
(
  unset GC_SESSION_ID GC_ALIAS GC_AGENT
  export STUB_MAILDIR="${SANDBOX}/maildir-low7"
  export GC_RIG_ROOT="$RIG_ROOT"
  cd "$RIG_ROOT" || exit 1
  source "$LIB" >/dev/null 2>&1
  : > "$STUB_GC_LOG"
  cv_write_handoff_note "marshal" "x" "y" "z" 2>"${SANDBOX}/low7.err"
  echo "RC:$?"
) > "${SANDBOX}/low7.out"
LOW7_RC="$(grep '^RC:' "${SANDBOX}/low7.out" | cut -d: -f2)"
assert_eq "LOW-7: no self identity returns non-zero" "1" "$LOW7_RC"
if grep -q "GC_SESSION_ID/GC_ALIAS/GC_AGENT" "${SANDBOX}/low7.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: LOW-7: warns to stderr naming the missing identity vars"
fi
if grep -q "^mail send" "$STUB_GC_LOG"; then
  FAIL=$((FAIL + 1))
  echo "FAIL: LOW-7: a send was attempted despite no resolvable self identity"
else
  PASS=$((PASS + 1))
fi

echo ""
echo "PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
