#!/usr/bin/env bash
# con-voyage-scribe.sh — friction-logging assistant (fk-ohjjjb / fk-g24r /
# foundry#48, see .claude/plans/con-voyage-assistants.md "Scribe").
# Lightweight by design: no monitoring loop of its own. Woken by mail from
# Marshal or the mayor when a friction point is identified, this library
# automates the manual "file a hardening bead for this" step:
#   1. Dedup check — skip filing anything that already matches an existing
#      bead/issue.
#   2. Routing rule — pack-general friction (a bug/gap in the mold/pack
#      itself, reusable across any city) -> kriscoleman/foundry as a GitHub
#      issue; city-specific friction (this rig's own repo/config/process) ->
#      the city rig (repl_city) as a bead. Default to pack-general unless the
#      friction text names a repl_city-only concern (OPERATOR DECISION
#      2026-10-03, Slack thread 1791062681.636319: confirmed default).
#   3. Title/body formatting — a thin deterministic pass turning freeform
#      friction text into a Conventional-Commit-style title and an
#      INVEST-shaped body.
#
# This file defines functions only — no side effects at source time, same
# contract as con-voyage-lib.sh. Source it, then call scribe_file_friction.
#
# Shares no state with Custodian's own dedup-search helper (fk-x4ohn4) yet —
# that consolidation is tracked separately; this is Scribe's own first cut.

# scribe_route_target TEXT — print "foundry" or "repl_city" for where a
# friction point described by TEXT should be filed. Defaults to "foundry"
# (pack-general) unless TEXT names an explicit repl_city-only/city-specific
# concern, per the confirmed operator default.
scribe_route_target() {
  local text="$1"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *repl_city*|*repl-city*|*"this rig"*|*"city rig"*|*"city-specific"*|*"city specific"*|*"this city"*)
      printf 'repl_city' ;;
    *)
      printf 'foundry' ;;
  esac
}

# scribe_format_title TEXT — print a Conventional-Commit-style title derived
# from freeform friction TEXT: whitespace/newlines collapsed to single
# spaces, a type prefix chosen by keyword (fix:/feat:/chore:), trailing
# periods stripped, and the whole thing capped at 72 characters.
scribe_format_title() {
  local text="$1"
  local collapsed
  collapsed="$(printf '%s' "$text" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  collapsed="${collapsed%.}"
  local lower
  lower="$(printf '%s' "$collapsed" | tr '[:upper:]' '[:lower:]')"
  local prefix="chore"
  case "$lower" in
    *bug*|*fail*|*broke*|*error*|*crash*|*regress*) prefix="fix" ;;
    *" add "*|*feature*|*"new "*|*introduce*) prefix="feat" ;;
  esac
  local max=72
  local body_max=$(( max - ${#prefix} - 2 ))
  if [ "${#collapsed}" -gt "$body_max" ]; then
    collapsed="${collapsed:0:$((body_max - 1))}…"
  fi
  printf '%s: %s' "$prefix" "$collapsed"
}

# scribe_format_body TEXT — print an INVEST-shaped body wrapping freeform
# friction TEXT under a "## Problem" section.
scribe_format_body() {
  local text="$1"
  cat <<EOF
## Problem

${text}

## INVEST

- Independent: scoped to this friction point only.
- Negotiable: the exact fix approach is left open to the implementor.
- Valuable: removes a concrete, observed friction point.
- Estimable: a single, bounded change.
- Small: addressable in one focused PR.
- Testable: a regression test should reproduce the friction before the fix.
EOF
}

# scribe_dedup_match QUERY [GH_REPO] — search for an existing bead
# (bd list --title-contains) and, when GH_REPO is given, an existing GitHub
# issue (gh issue list --search) matching QUERY. Prints the first match as
# "bd:<id>" or "gh:<repo>#<number>", or nothing when neither source has a
# match. Always returns 0 — a lookup failure (bd/gh not found, malformed
# JSON) is treated as "no match found", never a hard error, so a transient
# search failure can never silently block a real dedup but also never
# crashes the caller.
scribe_dedup_match() {
  local query="$1" gh_repo="${2:-}"
  local bd_bin="${BD:-bd}" gh_bin="${GH:-gh}"
  [ -n "$query" ] || return 0

  local bd_json bd_id
  bd_json="$("$bd_bin" list --title-contains "$query" --all --json 2>/dev/null)"
  bd_id="$(printf '%s' "$bd_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if isinstance(data, dict):
    data = data.get('issues') or []
if not isinstance(data, list):
    data = []
for item in data:
    if isinstance(item, dict) and item.get('id'):
        print(item['id'])
        break
" 2>/dev/null)"
  if [ -n "$bd_id" ]; then
    printf 'bd:%s' "$bd_id"
    return 0
  fi

  if [ -n "$gh_repo" ]; then
    local gh_json gh_number
    gh_json="$("$gh_bin" issue list --repo "$gh_repo" --search "$query" --state all --json number,title 2>/dev/null)"
    gh_number="$(printf '%s' "$gh_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for item in data:
    if isinstance(item, dict) and item.get('number'):
        print(item['number'])
        break
" 2>/dev/null)"
    if [ -n "$gh_number" ]; then
      printf 'gh:%s#%s' "$gh_repo" "$gh_number"
      return 0
    fi
  fi

  return 0
}

# scribe_file_friction TEXT [--route foundry|repl_city] [--gh-repo REPO] —
# the end-to-end flow: dedup check, routing decision, title/body formatting,
# then filing via gh issue create (foundry) or bd create (repl_city). Prints
# "DEDUP:<match>" and does nothing else when a dedup match is found; prints
# the underlying gh/bd command's own output on an actual filing. --route
# forces a target instead of the default pack-general-unless-city-specific
# heuristic; --gh-repo overrides the default foundry repo
# (kriscoleman/foundry).
scribe_file_friction() {
  local text="" route="auto" gh_repo="${CV_SCRIBE_GH_REPO:-kriscoleman/foundry}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --route) route="$2"; shift 2 ;;
      --gh-repo) gh_repo="$2"; shift 2 ;;
      *) text="$1"; shift ;;
    esac
  done
  [ "$route" = "auto" ] && route="$(scribe_route_target "$text")"

  local title
  title="$(scribe_format_title "$text")"

  local dedup_repo=""
  [ "$route" = "foundry" ] && dedup_repo="$gh_repo"
  local existing
  existing="$(scribe_dedup_match "$title" "$dedup_repo")"
  if [ -n "$existing" ]; then
    printf 'DEDUP:%s\n' "$existing"
    return 0
  fi

  local body
  body="$(scribe_format_body "$text")"

  if [ "$route" = "foundry" ]; then
    local gh_bin="${GH:-gh}"
    "$gh_bin" issue create --repo "$gh_repo" --title "$title" --body "$body"
  else
    local bd_bin="${BD:-bd}"
    "$bd_bin" create --title "$title" --description "$body" --type chore
  fi
}
