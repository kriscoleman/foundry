#!/usr/bin/env bash
# cv-timeout.sh SECONDS CMD [ARGS...] — run CMD with a wall-clock bound, as a
# standalone executable.
#
# WHY A SEPARATE FILE: con-voyage-lib.sh's own `cv_with_timeout` function
# carries this exact algorithm, but some callers (main.rereview-seed.md's
# CV_LIB-unresolved fallback, review fk-xfewni BLOCKING LOW-7) need a bounded
# call PRECISELY in the situation where sourcing con-voyage-lib.sh has
# already failed — they cannot call a function that lives in the file they
# just established is unavailable. Those callers resolve THIS file directly
# by path (same convention the rereview-seed fallback already uses for
# cv-worktree-prep.sh's CV_GUARD — a sibling script in the same assets/
# directory, found independently of whether con-voyage-lib.sh itself
# resolved), instead of hand-rolling their own lesser timeout loop.
#
# Semantics match cv_with_timeout exactly: CMD's stdout/stderr pass through
# unchanged; exit status is CMD's own if it finishes within SECONDS, or 124
# if it had to be killed (the same convention GNU coreutils' `timeout` uses).
# A malformed or non-positive SECONDS runs CMD with NO bound at all
# (fail-open on bad config, never a guessed default).
#
# Portable poll+kill (no `timeout(1)`, no background watcher of its own — see
# con-voyage-lib.sh's cv_with_timeout doc comment for why: a sibling
# sleep-then-kill subshell can outlive the bound itself if killed mid-sleep).
# Hardened against the same three bugs cv_with_timeout's own history found:
#   - locale: the poll interval is built with `printf`'s locale-safe decimal
#     formatting, never `awk %.3f` (a comma-decimal LC_NUMERIC breaks that).
#   - octal: SECONDS is read with a `10#` base-10 prefix so a leading-zero
#     value ("010") is never C-style-octal-misparsed.
#   - zsh: the poll-interval `local` is declared once, outside the loop —
#     redeclaring an already-local var inside a loop makes zsh print it to
#     stdout as an inspection form instead of silently reassigning it.
#
# KNOWN LIMITATION: signals CMD's own PID plus its DIRECT children (via
# `pgrep -P`, when available) — not a full process-tree kill. Matches
# cv_with_timeout's own documented limitation.

set -u

secs="${1:-}"; shift || true
case "$secs" in
  *[!0-9]*|'') secs="" ;;
esac
if [ -z "$secs" ] || [ "$secs" -le 0 ]; then
  exec "$@"
fi

"$@" &
cmd_pid=$!

waited_ms=0
poll_ms=50
secs_ms=$((10#$secs * 1000))
poll_s=""

while kill -0 "$cmd_pid" 2>/dev/null; do
  if [ "$waited_ms" -ge "$secs_ms" ]; then
    if command -v pgrep >/dev/null 2>&1; then
      for child_pid in $(pgrep -P "$cmd_pid" 2>/dev/null); do
        kill -TERM "$child_pid" 2>/dev/null
      done
    fi
    kill -TERM "$cmd_pid" 2>/dev/null
    wait "$cmd_pid" 2>/dev/null
    exit 124
  fi
  printf -v poll_s '%d.%03d' $((poll_ms / 1000)) $((poll_ms % 1000))
  sleep "$poll_s"
  waited_ms=$((waited_ms + poll_ms))
  poll_ms=$((poll_ms * 2))
  [ "$poll_ms" -gt 1000 ] && poll_ms=1000
done
wait "$cmd_pid" 2>/dev/null
exit "$?"
