#!/usr/bin/env bash
# con-voyage-askuserquestion-watchdog.sh — city-wide interactive-prompt-stall
# watchdog (fk-o9ntx: item 2/DETECT of fk-6kvnt's proposal).
#
# ROOT CAUSE (see fk-6kvnt for the full incident writeup): a headless worker
# session can still call an interactive prompt tool (e.g. Claude Code's
# AskUserQuestion). Nobody watches its pane, so the session blocks forever —
# SEEN 2026-09-25: a raw --no-formula bead sat stuck for ~20 minutes until the
# mayor happened to peek it by hand. fk-6kvnt shipped the prevention text
# (every con-voyage-dispatched worker is told never to call an interactive
# prompt tool) plus the detection PRIMITIVE cv_text_has_interactive_prompt_stall
# in con-voyage-lib.sh, but wiring a LIVE watchdog around that primitive was
# split out to this bead on purpose: fk-6kvnt's prevention text only reaches
# con-voyage-dispatched steps, so a core gc.implementation-worker on a raw
# bead (do-work's own formula — exactly what stalled on 2026-09-25) gets no
# prevention at all. A watchdog that scans EVERY live session in the city,
# regardless of formula or template, also covers that gap.
#
# ALGORITHM, per active (non-mayor) session in `gc session list`:
#   - peek the session's last rendered pane frame and classify it with
#     cv_text_has_interactive_prompt_stall.
#   - not stuck -> clear any tracked state for this session (a future stall
#     needs two fresh consecutive sightings again, same as a session hitting
#     its first-ever stall).
#   - stuck, and the captured frame differs from the last tracked one for
#     this session (a NEW question, or the first sighting ever) -> record it,
#     take no action yet. A single sighting must not page anyone: `gc session
#     peek` captures the LAST RENDERED FRAME, which can be stale, and a
#     prompt that resolves on its own between watchdog cycles should never
#     generate mail.
#   - stuck, same frame as last tracked, not yet alerted -> this is the
#     SECOND consecutive sighting of the SAME question: mail the mayor once
#     (session id, template, bead if known, the captured prompt, and the
#     unblock command) and mark this (session, frame) alerted.
#   - stuck, same frame as last tracked, already alerted -> no duplicate.
#
# The dedup key is (session id, frame content), not session id alone: a
# session answered on one question can later stall on a DIFFERENT question,
# and that later stall must alert independently instead of being silently
# suppressed by the earlier alert.
#
# STATE: one small `key=value` file per session under CV_ASKQ_STATE_DIR
# (default: the city's own .gc dir). This watchdog scans the whole city, not
# one rig, so its state belongs at the same scope `gc session list` already
# operates at — unlike the rig-scoped fk-mr07 fix, which applies to
# per-PR/per-rig watchdogs such as con-voyage-repair-watchdog.sh. No bd bead
# backs a live session pane the way a review-lane bead backs
# con-voyage-review-watchdog.sh's bookkeeping, so this watchdog needs its own
# state file, similar in shape to con-voyage-repair-watchdog.sh's.
#
# The mayor is never a candidate session: it legitimately uses interactive
# prompts with a human at the terminal (see fk-6kvnt), so the same footer on
# the mayor's own pane is not a bug.
#
# Environment / configuration (all optional with sane defaults):
#
#   GC                     Path to the gc binary (default: gc)
#   GC_CITY                City root passed to gc (default: current directory)
#   CV_ASKQ_STATE_DIR      Dedup state directory
#                          (default: "$GC_CITY/.gc/cv-askuserquestion-watchdog")
#   CV_ASKQ_MAIL_TARGET    Mail recipient on a confirmed stall (default: mayor)
#   CV_ASKQ_PEEK_LINES     Lines of pane history to capture per session
#                          (default: 50)
#   CV_ASKQ_STORE_TIMEOUT_SECONDS  Wall-clock bound on each gc call (this host
#                          has no `timeout(1)`; see cv_with_timeout in
#                          con-voyage-lib.sh). Default: 30.
#
# Exit codes:
#   0 — completed (some, all, or none of the candidate sessions needed action)
#   Non-zero — fatal setup error (gc/python3 missing, state dir uncreatable)
#
# The order controller treats any non-zero exit as a transient failure and
# retries on the next cooldown interval.
#
# Requires: bash 4+, gc CLI, python3.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GC_CITY="${GC_CITY:-.}"
CV_ASKQ_STATE_DIR="${CV_ASKQ_STATE_DIR:-${GC_CITY}/.gc/cv-askuserquestion-watchdog}"
CV_ASKQ_MAIL_TARGET="${CV_ASKQ_MAIL_TARGET:-mayor}"
CV_ASKQ_PEEK_LINES="${CV_ASKQ_PEEK_LINES:-50}"
CV_ASKQ_STORE_TIMEOUT_SECONDS="${CV_ASKQ_STORE_TIMEOUT_SECONDS:-30}"

# A malformed override must never silently break the peek/timeout bounds —
# same fail-safe posture as every other malformed-field guard in this pack
# (see con-voyage-repair-watchdog.sh's CV_STALL_SECONDS/CV_MAX_ATTEMPTS).
case "$CV_ASKQ_PEEK_LINES" in
  *[!0-9]*|'') CV_ASKQ_PEEK_LINES="50" ;;
esac
case "$CV_ASKQ_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_ASKQ_STORE_TIMEOUT_SECONDS="30" ;;
esac

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-askuserquestion-watchdog: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-askuserquestion-watchdog: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

# shellcheck source=con-voyage-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/con-voyage-lib.sh"

if ! mkdir -p "$CV_ASKQ_STATE_DIR" 2>/dev/null; then
  echo "con-voyage-askuserquestion-watchdog: ERROR: cannot create state dir '${CV_ASKQ_STATE_DIR}'" >&2
  exit 1
fi

echo "con-voyage-askuserquestion-watchdog: mail_target=${CV_ASKQ_MAIL_TARGET} peek_lines=${CV_ASKQ_PEEK_LINES} state_dir=${CV_ASKQ_STATE_DIR}"

# ---------------------------------------------------------------------------
# bead_for_session RIG SESSION_NAME — best-effort: print the id of the
# in_progress bead currently assigned to SESSION_NAME in RIG's store, or
# nothing if unknown/unresolvable. Never fatal — a session doing raw
# --no-formula work, or a lookup that fails/hangs, is still a valid mail
# candidate with an empty bead field.
# ---------------------------------------------------------------------------
bead_for_session() {
  local rig="$1" session_name="$2"
  [ -n "${session_name// /}" ] || return 0
  local json
  if [ -n "${rig// /}" ]; then
    json="$(cv_with_timeout "$CV_ASKQ_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" --rig "$rig" bd list --assignee "$session_name" --status in_progress -n 1 --json 2>/dev/null)"
  else
    json="$(cv_with_timeout "$CV_ASKQ_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" bd list --assignee "$session_name" --status in_progress -n 1 --json 2>/dev/null)"
  fi
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(d, list):
    d = d[0] if d else {}
if isinstance(d, dict):
    print(d.get('id') or '')
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Discovery: every ACTIVE session in the city, excluding the mayor's own (see
# header — the mayor legitimately uses interactive prompts itself).
# ---------------------------------------------------------------------------
SESSIONS_JSON="$(cv_with_timeout "$CV_ASKQ_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" session list --state active --json 2>/dev/null)"
[ -n "$SESSIONS_JSON" ] || SESSIONS_JSON='{"sessions":[]}'

# filter_sessions_json — read one `session list --json` object from stdin,
# print candidate TSV rows (one per line, 0x1f-separated fields: id, name,
# template, session_name, rig). SECURITY (defense-in-depth, same posture as
# con-voyage-review-watchdog.sh's filter_lanes_json): every field is
# session-derived text, so strip embedded newlines/SEP before joining a row —
# otherwise a forged value could smuggle a phantom row or corrupt column
# alignment, steering a later `gc session nudge`/mail send at an
# attacker-chosen id.
SESSIONS_TSV="$(printf '%s' "$SESSIONS_JSON" | python3 -c "
import json, sys
SEP = '\x1f'
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    raise SystemExit(0)
for s in sessions:
    if not isinstance(s, dict):
        continue
    if s.get('template') == 'mayor':
        continue
    sid = s.get('id') or ''
    if not sid:
        continue
    row = [sid, s.get('name') or '', s.get('template') or '', s.get('session_name') or '', s.get('rig') or '']
    row = [f.replace('\n', ' ').replace('\r', ' ').replace(SEP, ' ') for f in row]
    print(SEP.join(row))
" 2>/dev/null)"

if [ -z "$SESSIONS_TSV" ]; then
  echo "con-voyage-askuserquestion-watchdog: no active sessions found"
  exit 0
fi

# state_path SESSION_ID — the dedup state file for one session. Session ids
# are gc-minted short tokens (e.g. "rc-bswsq"); no extra sanitization is
# needed for a safe filename component.
state_path() {
  printf '%s/%s.state' "$CV_ASKQ_STATE_DIR" "$1"
}

while IFS=$'\x1f' read -r sess_id sess_name sess_template sess_session_name sess_rig; do
  [ -n "$sess_id" ] || continue

  PEEK_JSON="$(cv_with_timeout "$CV_ASKQ_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" session peek "$sess_id" --json --lines "$CV_ASKQ_PEEK_LINES" 2>/dev/null)"
  pane_text="$(printf '%s' "$PEEK_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get('output') or '' if isinstance(d, dict) else '')
" 2>/dev/null)"

  state_file="$(state_path "$sess_id")"

  if ! cv_text_has_interactive_prompt_stall "$pane_text"; then
    rm -f "$state_file"
    echo "con-voyage-askuserquestion-watchdog: OK ${sess_id} (${sess_template}) — no interactive-prompt stall"
    continue
  fi

  frame_hash="$(printf '%s' "$pane_text" | python3 -c "
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])
" 2>/dev/null)"

  prev_hash=""
  prev_alerted="0"
  if [ -f "$state_file" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do
      case "$k" in
        frame_hash) prev_hash="$v" ;;
        alerted) prev_alerted="$v" ;;
      esac
    done < "$state_file"
  fi
  case "$prev_alerted" in
    1) ;;
    *) prev_alerted="0" ;;
  esac

  if [ "$frame_hash" != "$prev_hash" ]; then
    { printf 'frame_hash=%s\n' "$frame_hash"; printf 'alerted=0\n'; } > "$state_file"
    echo "con-voyage-askuserquestion-watchdog: STUCK (first sighting) ${sess_id} (${sess_template}) — waiting for a second consecutive sighting before alerting"
    continue
  fi

  if [ "$prev_alerted" = "1" ]; then
    echo "con-voyage-askuserquestion-watchdog: SKIP ${sess_id} (${sess_template}) — already alerted for this stuck prompt"
    continue
  fi

  bead_id="$(bead_for_session "$sess_rig" "$sess_session_name")"
  [ -n "$bead_id" ] || bead_id="(none known)"

  subject="con-voyage watchdog: session ${sess_id} (${sess_template}) is stuck on an interactive prompt"
  # The pane capture is handed over verbatim rather than parsed into separate
  # "question"/"options" fields: `gc session peek` returns a raw terminal
  # frame (box-drawing characters, wrapped lines), and this pack has no
  # primitive for reliably splitting that back into structured fields — the
  # full excerpt already contains both, and is exactly what a human doing the
  # same diagnosis by hand (as the mayor did on 2026-09-25) would read.
  body="$(cat <<EOF
Session ${sess_id} (${sess_name}, template ${sess_template}) has shown the same interactive-prompt stall for two consecutive watchdog cycles. Bead: ${bead_id}.

Unblock command (pick the option, then run):
  gc session nudge ${sess_id} <option-number> --delivery immediate

Captured prompt (last ${CV_ASKQ_PEEK_LINES} lines of the session pane):
${pane_text}
EOF
)"

  if cv_with_timeout "$CV_ASKQ_STORE_TIMEOUT_SECONDS" "$GC" --city "$GC_CITY" mail send "$CV_ASKQ_MAIL_TARGET" -s "$subject" -m "$body" 2>&1; then
    { printf 'frame_hash=%s\n' "$frame_hash"; printf 'alerted=1\n'; } > "$state_file"
    echo "con-voyage-askuserquestion-watchdog: ALERT ${sess_id} (${sess_template}) — mailed ${CV_ASKQ_MAIL_TARGET}"
  else
    echo "con-voyage-askuserquestion-watchdog: WARNING: mail to ${CV_ASKQ_MAIL_TARGET} failed for ${sess_id}; will retry next cycle" >&2
  fi
done <<< "$SESSIONS_TSV"

exit 0
