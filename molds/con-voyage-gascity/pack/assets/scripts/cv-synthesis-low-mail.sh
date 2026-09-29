#!/usr/bin/env bash
# cv-synthesis-low-mail.sh — send the LOW-only human-escalation mail that the
# con-voyage synthesize-review step must send before it closes (fk-8g9ue).
#
# WHY: {target}.synthesize-review.md has always said a LOW-only verdict (0
# BLOCKING, N LOW remaining) must "stop and surface the findings to the human
# facilitator; never silently accept LOWs" — but that was prose only.
# apply-review-findings only branches on BLOCKING, so a LOW-only cycle
# silently rolled straight to done/publish with nobody ever mailed, while the
# synthesis text itself often claimed the opposite ("the human escalation
# target has been mailed"). Reported twice in the field against real
# synthesis output (roots fk-sy5zb, fk-1du8z, fk-whmdb, fk-elkyf). This
# script makes the mail an actual side effect the step runs, instead of a
# promise an LLM pass could forget to keep.
#
# Usage:
#   cv-synthesis-low-mail.sh <synthesis-file> <root-bead-id> <work-bead-id> <pr-or-branch-label>
#
# Counts BLOCKING/LOW findings by counting the "### " sub-headings inside
# each synthesis document's "## ... BLOCKING findings" / "## ... LOW
# findings" section (falling back to top-level "- " bullets when a section
# has no sub-headings at all) — shape-agnostic by construction, since real
# synthesis documents disagree on the exact sub-heading text (see
# {target}.synthesize-review.md's required structure).
#
# Behavior:
#   BLOCKING > 0            -> no mail (iterate path owns that cycle)
#   BLOCKING == 0, LOW == 0 -> no mail (nothing to escalate)
#   BLOCKING == 0, LOW  > 0 -> mail the mayor, who owns the human
#                              conversation; also mail
#                              CV_LENS_ESCALATE_TARGET when it resolves to a
#                              distinct real mailbox (non-empty, not the same
#                              address as the mayor, not an unsubstituted
#                              "{...}" placeholder). Records the mail id(s) on
#                              the root bead as code_review.low_mail_sent,
#                              code_review.low_mail_id, and
#                              code_review.low_escalation_mail_id so the gate
#                              and publish can verify a mail actually went
#                              out.
#
# A mail owed but not actually sent (gc mail send fails, or returns no
# message id) is a hard failure — this script must never let the step close
# as if it had mailed someone when it did not.
#
# Environment:
#   GC                       gc binary to invoke (default: gc)
#   CV_MAYOR_ADDRESS          mayor's gc mail address (default: mayor)
#   CV_LENS_ESCALATE_TARGET   optional second recipient (formula var
#                             cv_lens_escalate_target)
#
# fk-7v3r/fk-t2fsa: bead/mail calls below intentionally omit --city/--rig —
# every caller's cwd is already inside the correct rig checkout when this
# script runs, same convention as con-voyage-lib.sh and
# cv-verify-review-approved.sh.
#
# Exit codes:
#   0 — no mail was owed, or every owed mail sent and metadata recorded.
#   1 — usage error, synthesis file unreadable or its finding counts could
#       not be determined, or a mail owed to be sent (or its metadata
#       record) failed or timed out.

set -uo pipefail

GC="${GC:-gc}"
CV_MAYOR_ADDRESS="${CV_MAYOR_ADDRESS:-mayor}"

# CV_LENS_STORE_TIMEOUT_SECONDS bounds every gc mail/bd store call below —
# same env var and digit-guard convention as con-voyage-review-watchdog.sh
# (fk-72l6i BLOCKING-3: this script's own store calls were the one call
# chain in this pack's store-call surface with no bounded failure mode, in
# the one script whose entire job is guaranteeing a human gets told).
CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
esac

# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

die() {
  echo "cv-synthesis-low-mail: $*" >&2
  exit 1
}

SYNTHESIS_FILE="${1:-}"
ROOT_ID="${2:-}"
WORK_BEAD="${3:-}"
PR_OR_BRANCH="${4:-}"

if [ -z "$SYNTHESIS_FILE" ] || [ -z "$ROOT_ID" ] || [ -z "$WORK_BEAD" ] || [ -z "$PR_OR_BRANCH" ]; then
  die "usage: cv-synthesis-low-mail.sh <synthesis-file> <root-bead-id> <work-bead-id> <pr-or-branch-label>"
fi
[ -f "$SYNTHESIS_FILE" ] || die "synthesis file not found: $SYNTHESIS_FILE"

# Count BLOCKING/LOW findings by how many "### " sub-headings sit inside
# each "## ... BLOCKING findings ..." / "## ... LOW findings ..." section
# (bounded by the next top-level "## " heading or EOF) — shape-agnostic by
# construction, so it does not matter whether a real doc numbers findings
# "### BLOCKING-<n>", "### <n>. [lane] ...", or "### B<n>"/"### L<n>" (the
# old `grep -c '^### BLOCKING-'` missed every shape but the first, silently
# counting 0 on real approve-verdict docs like fk-elkyf's — reintroducing
# the exact "nobody told" bug this script exists to close). An explicit
# "None."/"N/A" section body is 0 findings; a section with a plain top-level
# "- " bullet list (no sub-headings at all) counts bullets instead.
# Anything else with real content is unparseable, and — unlike the old
# `grep -c ... || true`, which folded a genuine read error into the same
# silent "0" as "no match" — this refuses to guess 0; it fails loud, the
# same fail-safe stance REQ-005 already takes for a mail that was owed but
# never actually sent.
CV_COUNTS="$(python3 - "$SYNTHESIS_FILE" <<'PYEOF'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()

def heading_subject(line):
    # "## 2. BLOCKING findings (...)" / "## BLOCKING findings (...)" -> the
    # heading's own subject text, stripping "## " and an optional ordinal
    # prefix. A match must be the heading's actual subject, not merely a
    # substring anywhere in it — an "## Overall verdict: ... 4 LOW findings"
    # summary line (a real shape, e.g. fk-elkyf's doc) mentions "LOW findings"
    # in passing without being that section, and must not match.
    m = re.match(r'^##\s+(?:\d+\.\s*)?(.*)$', line)
    return m.group(1) if m else None

def section_lines(label):
    out = []
    in_section = False
    for line in lines:
        if re.match(r'^##\s', line):
            if in_section:
                break
            subject = heading_subject(line)
            in_section = bool(subject) and subject.startswith(label)
            continue
        if in_section:
            out.append(line)
    return out, in_section

def count_section(label):
    sec, found = section_lines(label)
    if not found:
        return None
    # Structured content wins first: a real synthesis can prose-explain a
    # zero verdict ("None. Zero BLOCKING findings from any of the 6 active
    # lanes.", e.g. fk-elkyf's actual doc) or list, in either order, so check
    # for actual findings before falling back to the empty/None-prefix zero
    # case rather than requiring the body be nothing but "None.".
    subheads = [l for l in sec if re.match(r'^###\s', l)]
    if subheads:
        return len(subheads)
    bullets = [l for l in sec if re.match(r'^-\s', l)]
    if bullets:
        return len(bullets)
    body = "\n".join(sec).strip()
    if not body or re.match(r'(?i)^[\s*_]*(none|n/a)\b', body):
        return 0
    return -1

def emit(name, value):
    if value is None:
        print(f"{name}=NOSECTION")
    elif value == -1:
        print(f"{name}=UNPARSEABLE")
    else:
        print(f"{name}={value}")

blocking = count_section("BLOCKING findings")
low = count_section("LOW findings")
emit("BLOCKING_COUNT", blocking)
emit("LOW_COUNT", low)

# Cross-check against YAML frontmatter counts when a synthesis doc carries
# them — cheap, deterministic belt-and-suspenders; skipped entirely for
# older/plain docs with no frontmatter.
fm_match = re.match(r'^---\n(.*?)\n---\n', text, re.S)
if fm_match:
    fm = fm_match.group(1)
    if blocking is not None and blocking != -1:
        m = re.search(r'^blocking_count:\s*(\d+)', fm, re.M)
        if m and int(m.group(1)) != blocking:
            print(f"BLOCKING_MISMATCH={m.group(1)}")
    if low is not None and low != -1:
        m = re.search(r'^low_count:\s*(\d+)', fm, re.M)
        if m and int(m.group(1)) != low:
            print(f"LOW_MISMATCH={m.group(1)}")
PYEOF
)" || die "failed to parse ${SYNTHESIS_FILE} for BLOCKING/LOW counts"

BLOCKING_COUNT="$(printf '%s\n' "$CV_COUNTS" | sed -n 's/^BLOCKING_COUNT=//p')"
LOW_COUNT="$(printf '%s\n' "$CV_COUNTS" | sed -n 's/^LOW_COUNT=//p')"
BLOCKING_MISMATCH="$(printf '%s\n' "$CV_COUNTS" | sed -n 's/^BLOCKING_MISMATCH=//p')"
LOW_MISMATCH="$(printf '%s\n' "$CV_COUNTS" | sed -n 's/^LOW_MISMATCH=//p')"

case "$BLOCKING_COUNT" in
  NOSECTION) die "${SYNTHESIS_FILE} has no '## ... BLOCKING findings' section — cannot determine verdict" ;;
  UNPARSEABLE) die "${SYNTHESIS_FILE}'s BLOCKING findings section has content but no recognized finding shape (### sub-heading or top-level '-' bullet) — refusing to guess 0" ;;
  ''|*[!0-9]*) die "${SYNTHESIS_FILE}: could not determine a BLOCKING count" ;;
esac
case "$LOW_COUNT" in
  NOSECTION) die "${SYNTHESIS_FILE} has no '## ... LOW findings' section — cannot determine verdict" ;;
  UNPARSEABLE) die "${SYNTHESIS_FILE}'s LOW findings section has content but no recognized finding shape (### sub-heading or top-level '-' bullet) — refusing to guess 0" ;;
  ''|*[!0-9]*) die "${SYNTHESIS_FILE}: could not determine a LOW count" ;;
esac
[ -z "$BLOCKING_MISMATCH" ] || die "${SYNTHESIS_FILE} frontmatter claims blocking_count=${BLOCKING_MISMATCH} but ${BLOCKING_COUNT} BLOCKING sub-heading(s) were actually parsed — refusing to trust a self-inconsistent doc"
[ -z "$LOW_MISMATCH" ] || die "${SYNTHESIS_FILE} frontmatter claims low_count=${LOW_MISMATCH} but ${LOW_COUNT} LOW sub-heading(s) were actually parsed — refusing to trust a self-inconsistent doc"

if [ "$BLOCKING_COUNT" -gt 0 ]; then
  echo "cv-synthesis-low-mail: ${BLOCKING_COUNT} BLOCKING finding(s) present — iterate path owns escalation, no LOW mail"
  exit 0
fi

if [ "$LOW_COUNT" -eq 0 ]; then
  echo "cv-synthesis-low-mail: 0 BLOCKING / 0 LOW — nothing to escalate"
  exit 0
fi

# Build the mail body: a short header, then one summary row per ### LOW-<n>
# section (its title plus the first couple of detail lines that follow it —
# in every real synthesis document these are the Lanes/File:line bullets),
# then a pointer to the full synthesis and the proceed/send-back ask.
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

{
  echo "LOW-only con-voyage review: work bead ${WORK_BEAD}, ${PR_OR_BRANCH} — ${LOW_COUNT} LOW finding(s), 0 BLOCKING."
  echo ""
  python3 - "$SYNTHESIS_FILE" <<'PYEOF'
import re
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()

sections = []
current = None
for line in lines:
    if re.match(r'^### LOW-', line):
        if current is not None:
            sections.append(current)
        current = [line]
    elif re.match(r'^#{2,3}\s', line):
        if current is not None:
            sections.append(current)
        current = None
    elif current is not None:
        current.append(line)
if current is not None:
    sections.append(current)

for sec in sections:
    title = sec[0].lstrip('#').strip()
    detail_lines = [l.strip(' -') for l in sec[1:] if l.strip()][:2]
    print(f"- {title}")
    for d in detail_lines:
        print(f"    {d}")
PYEOF
  echo ""
  echo "Full synthesis: ${SYNTHESIS_FILE}"
  echo ""
  echo "No BLOCKING findings — these are LOW only. Reply to proceed (publish as-is) or send back for another iteration."
} > "$BODY_FILE"

SUBJECT="LOW-only: ${WORK_BEAD} ${PR_OR_BRANCH} — ${LOW_COUNT} LOW"

send_mail() {
  local to="$1"
  local out rc
  out="$(cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" mail send "$to" -s "$SUBJECT" -m "$(cat "$BODY_FILE")" --json 2>&1)"
  rc=$?
  if [ "$rc" -eq 124 ]; then
    die "gc mail send to ${to} timed out after ${CV_LENS_STORE_TIMEOUT_SECONDS}s"
  elif [ "$rc" -ne 0 ]; then
    die "gc mail send to ${to} failed: ${out}"
  fi
  printf '%s' "$out" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('')
    raise SystemExit(0)
msg = d.get('message') or {}
print(msg.get('id') or '')
" 2>/dev/null
}

MAIL_ID="$(send_mail "$CV_MAYOR_ADDRESS")"
[ -n "$MAIL_ID" ] || die "gc mail send to ${CV_MAYOR_ADDRESS} returned no message id"

cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" bd update "$ROOT_ID" \
  --set-metadata 'code_review.low_mail_sent=true' \
  --set-metadata "code_review.low_mail_id=${MAIL_ID}" \
  >/dev/null 2>&1
MAYOR_UPDATE_RC=$?
if [ "$MAYOR_UPDATE_RC" -eq 124 ]; then
  die "recording code_review.low_mail_id on ${ROOT_ID} timed out after ${CV_LENS_STORE_TIMEOUT_SECONDS}s"
elif [ "$MAYOR_UPDATE_RC" -ne 0 ]; then
  die "failed to record code_review.low_mail_id on ${ROOT_ID}"
fi

echo "cv-synthesis-low-mail: mailed ${CV_MAYOR_ADDRESS} (id ${MAIL_ID}) — ${LOW_COUNT} LOW, 0 BLOCKING"

ESCALATE="${CV_LENS_ESCALATE_TARGET:-}"
case "$ESCALATE" in
  '')
    echo "cv-synthesis-low-mail: no escalation target configured — skipping distinct-mailbox mail"
    ;;
  "$CV_MAYOR_ADDRESS")
    echo "cv-synthesis-low-mail: escalation target same as mayor (${CV_MAYOR_ADDRESS}) — skipping duplicate mail"
    ;;
  \{*\})
    echo "cv-synthesis-low-mail: escalation target is an unresolved {var} placeholder (${ESCALATE}) — skipping, not a real mailbox"
    ;;
  *)
    ESCALATION_MAIL_ID="$(send_mail "$ESCALATE")"
    if [ -n "$ESCALATION_MAIL_ID" ]; then
      cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" "$GC" bd update "$ROOT_ID" \
        --set-metadata "code_review.low_escalation_mail_id=${ESCALATION_MAIL_ID}" \
        >/dev/null 2>&1
      ESCALATION_UPDATE_RC=$?
      if [ "$ESCALATION_UPDATE_RC" -eq 124 ]; then
        echo "note: recording code_review.low_escalation_mail_id on ${ROOT_ID} timed out after ${CV_LENS_STORE_TIMEOUT_SECONDS}s (continuing)"
      elif [ "$ESCALATION_UPDATE_RC" -ne 0 ]; then
        echo "note: failed to record code_review.low_escalation_mail_id on ${ROOT_ID} (continuing)"
      fi
      echo "cv-synthesis-low-mail: mailed ${ESCALATE} (id ${ESCALATION_MAIL_ID})"
    else
      die "gc mail send to ${ESCALATE} returned no message id"
    fi
    ;;
esac

exit 0
