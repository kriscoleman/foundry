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
# Counts BLOCKING/LOW findings from the synthesis file's own `### BLOCKING-*`
# / `### LOW-*` sub-headings — the shape every real synthesis document uses
# (see {target}.synthesize-review.md's required structure).
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
#   1 — usage error, synthesis file unreadable, or a mail owed to be sent
#       failed to send or record.

set -uo pipefail

GC="${GC:-gc}"
CV_MAYOR_ADDRESS="${CV_MAYOR_ADDRESS:-mayor}"

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

BLOCKING_COUNT="$(grep -c '^### BLOCKING-' "$SYNTHESIS_FILE" 2>/dev/null || true)"
LOW_COUNT="$(grep -c '^### LOW-' "$SYNTHESIS_FILE" 2>/dev/null || true)"
BLOCKING_COUNT="${BLOCKING_COUNT:-0}"
LOW_COUNT="${LOW_COUNT:-0}"

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
  local out
  out="$("$GC" mail send "$to" -s "$SUBJECT" -m "$(cat "$BODY_FILE")" --json 2>&1)" || {
    die "gc mail send to ${to} failed: ${out}"
  }
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

"$GC" bd update "$ROOT_ID" \
  --set-metadata 'code_review.low_mail_sent=true' \
  --set-metadata "code_review.low_mail_id=${MAIL_ID}" \
  >/dev/null 2>&1 || die "failed to record code_review.low_mail_id on ${ROOT_ID}"

echo "cv-synthesis-low-mail: mailed ${CV_MAYOR_ADDRESS} (id ${MAIL_ID}) — ${LOW_COUNT} LOW, 0 BLOCKING"

ESCALATE="${CV_LENS_ESCALATE_TARGET:-}"
case "$ESCALATE" in
  ''|"$CV_MAYOR_ADDRESS"|\{*\})
    : # empty, same mailbox as the mayor, or an unsubstituted {var} placeholder — not a distinct real mailbox
    ;;
  *)
    ESCALATION_MAIL_ID="$(send_mail "$ESCALATE")"
    if [ -n "$ESCALATION_MAIL_ID" ]; then
      "$GC" bd update "$ROOT_ID" \
        --set-metadata "code_review.low_escalation_mail_id=${ESCALATION_MAIL_ID}" \
        >/dev/null 2>&1 || echo "note: failed to record code_review.low_escalation_mail_id on ${ROOT_ID} (continuing)"
      echo "cv-synthesis-low-mail: mailed ${ESCALATE} (id ${ESCALATION_MAIL_ID})"
    else
      die "gc mail send to ${ESCALATE} returned no message id"
    fi
    ;;
esac

exit 0
