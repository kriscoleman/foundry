#!/usr/bin/env bash
# cv-pause.sh — operator pause/resume toggles for con-voyage's autonomous,
# token-heavy PR-monitor features.
#
# Usage:
#   cv-pause.sh pause     <feature> [reason...]
#   cv-pause.sh resume    <feature>
#   cv-pause.sh status    [feature]
#   cv-pause.sh is-paused <feature>     exit 0 = paused, 1 = running
#
# Features:
#   self-heal       The autonomous CI-repair loop. While paused:
#                     - con-voyage-pr-watch PART A / PART A-native mint and
#                       dispatch no con-voyage-ci-repair work;
#                     - con-voyage-repair-watchdog re-dispatches nothing;
#                     - con-voyage-ci-repair-guard closes every open,
#                       unclaimed con-voyage-ci-repair step bead as
#                       "dropped: self-heal paused" (this is what stops the
#                       native [[github.pr_monitor]]'s own repair mints).
#                   A repair a worker has already claimed runs to completion.
#   comment-repair  con-voyage-pr-watch PART B: routing PR review comments
#                   (and finding triggers) to the implementor for autonomous
#                   fixes. While paused nothing is routed AND nothing is marked
#                   seen, so comments left during the pause are routed on the
#                   first cycle after resume rather than silently dropped.
#
# Each feature is one flag file, "<CV_PAUSE_DIR>/cv-<feature>.paused". The
# flag is CITY-wide (CV_PAUSE_DIR defaults to "${GC_CITY:-.}/.gc", the same
# city-root .gc convention con-voyage-askuserquestion-watchdog uses), so one
# command pauses the feature for every rig. It takes effect on each order's
# next cycle; no restart or re-cast is needed. Run from the city root, e.g.:
#
#   packs/con-voyage/assets/scripts/cv-pause.sh pause self-heal "token budget"
#   packs/con-voyage/assets/scripts/cv-pause.sh resume self-heal
#
# Orders read the flag with `cv-pause.sh is-paused <feature>`. Nothing is
# paused by default: no flag file means the feature runs.

set -uo pipefail

CV_PAUSE_DIR="${CV_PAUSE_DIR:-${GC_CITY:-.}/.gc}"
CV_PAUSE_FEATURES="self-heal comment-repair"

usage() {
  cat >&2 <<'EOF'
usage: cv-pause.sh pause <feature> [reason...]
       cv-pause.sh resume <feature>
       cv-pause.sh status [feature]
       cv-pause.sh is-paused <feature>
features: self-heal, comment-repair
EOF
  exit 2
}

flag_path() { printf '%s/cv-%s.paused' "$CV_PAUSE_DIR" "$1"; }

require_feature() {
  case " ${CV_PAUSE_FEATURES} " in
    *" ${1:-} "*) [ -n "${1:-}" ] && return 0 ;;
  esac
  [ -n "${1:-}" ] && echo "cv-pause: unknown feature '${1}'" >&2
  usage
}

print_status() {
  local feature="$1" flag
  flag="$(flag_path "$feature")"
  if [ -f "$flag" ]; then
    echo "${feature}: PAUSED ($(tr '\n' ' ' < "$flag" | sed 's/ *$//'))"
  else
    echo "${feature}: RUNNING"
  fi
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  pause)
    require_feature "${1:-}"
    feature="$1"; shift
    reason="$*"
    mkdir -p "$CV_PAUSE_DIR" || exit 1
    flag="$(flag_path "$feature")"
    printf 'paused_at=%s\npaused_by=%s\nreason=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-unknown}" "${reason:-none given}" \
      > "${flag}.tmp" && mv -f "${flag}.tmp" "$flag" || exit 1
    echo "cv-pause: ${feature} PAUSED (takes effect on each order's next cycle)"
    ;;
  resume)
    require_feature "${1:-}"
    rm -f "$(flag_path "$1")" || exit 1
    echo "cv-pause: ${1} RUNNING"
    ;;
  status)
    if [ -n "${1:-}" ]; then
      require_feature "$1"
      print_status "$1"
    else
      for f in $CV_PAUSE_FEATURES; do print_status "$f"; done
    fi
    ;;
  is-paused)
    require_feature "${1:-}"
    [ -f "$(flag_path "$1")" ]
    ;;
  *)
    usage
    ;;
esac
