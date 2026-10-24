#!/usr/bin/env bash
# cv-plan-mode.sh — decide whether a con-voyage journey starts with its
# planning phase.
#
# Usage:
#   cv-plan-mode.sh resolve [journey-value]
#
# Prints "on" or "off" on stdout and "plan mode: <on|off> (source: <where>)"
# on stderr. The plan step passes the journey's own `plan_mode` formula var
# (gc.var.plan_mode on the workflow root) as journey-value.
#
# PLAN MODE IS ON BY DEFAULT. A city opts out by committing a con-voyage.toml
# at its root (the same file that carries the optional concurrency cap):
#
#   [con_voyage]
#   plan_mode = false
#
# Precedence, highest first:
#   1. journey-value      `--var plan_mode=true|false` at sling time
#   2. CV_PLAN_MODE       environment override, handy for a one-off
#   3. con-voyage.toml    [con_voyage] plan_mode (path: CV_CON_VOYAGE_CONFIG,
#                         default $GC_CITY/con-voyage.toml)
#   4. default            on
#
# Accepted values: true/false, on/off, yes/no, 1/0 (any case); TOML booleans
# in the file. An empty value means "not set here". Anything else warns and
# falls through to the next source, so a typo never silently skips planning.
# Changes take effect on the next journey's plan step; no restart or re-cast.

set -uo pipefail

GC_CITY="${GC_CITY:-.}"
CV_CON_VOYAGE_CONFIG="${CV_CON_VOYAGE_CONFIG:-${GC_CITY}/con-voyage.toml}"

usage() {
  echo "usage: cv-plan-mode.sh resolve [journey-value]" >&2
  exit 2
}

# normalize VALUE — print on/off, nothing for empty, or return 1 when invalid.
normalize() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    '') return 0 ;;
    true|on|yes|1) echo on ;;
    false|off|no|0) echo off ;;
    *) return 1 ;;
  esac
}

# read_config — print [con_voyage].plan_mode as on/off, nothing when the file
# or key is absent, or "!<detail>" when present but unusable.
read_config() {
  [ -f "$CV_CON_VOYAGE_CONFIG" ] || return 0
  python3 - "$CV_CON_VOYAGE_CONFIG" <<'PY' 2>/dev/null
import sys
try:
    import tomllib
except ImportError:
    print('!python3 has no tomllib')
    sys.exit(0)
try:
    with open(sys.argv[1], 'rb') as fh:
        data = tomllib.load(fh)
except Exception as exc:
    print('!unparseable (%s)' % exc)
    sys.exit(0)
val = (data.get('con_voyage') or {}).get('plan_mode')
if val is None:
    sys.exit(0)
if isinstance(val, bool):
    print('on' if val else 'off')
elif isinstance(val, str):
    print(val)
else:
    print('!%r' % (val,))
PY
}

cmd_resolve() {
  local mode raw
  if [ -n "${1:-}" ]; then
    if mode="$(normalize "$1")"; then
      echo "plan mode: ${mode} (source: journey plan_mode var)" >&2
      echo "$mode"; return 0
    fi
    echo "cv-plan-mode: WARNING: journey plan_mode var is not a boolean (got $1); ignoring it" >&2
  fi
  if [ -n "${CV_PLAN_MODE:-}" ]; then
    if mode="$(normalize "$CV_PLAN_MODE")"; then
      echo "plan mode: ${mode} (source: CV_PLAN_MODE)" >&2
      echo "$mode"; return 0
    fi
    echo "cv-plan-mode: WARNING: CV_PLAN_MODE is not a boolean (got ${CV_PLAN_MODE}); ignoring it" >&2
  fi
  raw="$(read_config)"
  if [ -n "$raw" ]; then
    case "$raw" in
      '!'*) echo "cv-plan-mode: WARNING: plan_mode in ${CV_CON_VOYAGE_CONFIG} is unusable: ${raw#!}; ignoring it" >&2 ;;
      *)
        if mode="$(normalize "$raw")" && [ -n "$mode" ]; then
          echo "plan mode: ${mode} (source: ${CV_CON_VOYAGE_CONFIG})" >&2
          echo "$mode"; return 0
        fi
        echo "cv-plan-mode: WARNING: plan_mode in ${CV_CON_VOYAGE_CONFIG} is not a boolean (got ${raw}); ignoring it" >&2
        ;;
    esac
  fi
  echo "plan mode: on (source: default)" >&2
  echo on
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  resolve) cmd_resolve "$@" ;;
  *) usage ;;
esac
