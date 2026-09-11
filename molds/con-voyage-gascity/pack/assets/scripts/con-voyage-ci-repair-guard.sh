#!/usr/bin/env bash
# con-voyage-ci-repair-guard.sh — defense-in-depth author gate for
# con-voyage-ci-repair beads (layer 2 of 3; see HARD INVARIANT below).
#
# ############################################################################
# # HARD INVARIANT — AUTHOR SCOPING                                          #
# #                                                                          #
# # A con-voyage-ci-repair bead can be minted for ANY PR by three different  #
# # paths: the native [[github.pr_monitor]] (--create-repair-beads has no    #
# # author filter), con-voyage-pr-watch.sh (already author-scoped), or a     #
# # manual mis-sling. This script is the BACKSTOP: it sweeps every OPEN      #
# # con-voyage-ci-repair step bead, resolves the PR's real author, and       #
# # closes any bead whose author != CV_PR_AUTHOR BEFORE a worker can claim   #
# # it and take any GitHub action. It fails closed on any unresolved input.  #
# #                                                                          #
# # A third, independent gate (Step 0 in {target}.ci-repair.md) re-verifies  #
# # the same invariant inside the workflow itself, in case this sweep loses  #
# # a race against a worker claiming the bead first.                        #
# ############################################################################
#
# This script takes exactly one kind of write action: closing a bead via
# `gc bd update --notes` + `gc bd close`. It NEVER runs `gh run rerun`,
# `git push`, `gh pr comment`, `gh pr review`, or `gc sling` — those all
# belong to the implementor workflow, which this script only ever prevents
# from starting on a non-operator PR.
#
# Environment / configuration (all optional with sane defaults):
#
#   GC              Path to the gc binary (default: gc)
#   GH              Path to the gh binary (default: gh)
#   GC_CITY         City root passed to gc (default: current directory)
#   CV_PR_AUTHOR    REQUIRED (author-scoping). Same knob as
#                   con-voyage-pr-watch.sh and the con-voyage-ci-repair
#                   formula's cv_pr_author var. Defaults to the authenticated
#                   gh login. If it cannot be resolved, the script FAILS
#                   CLOSED (exit 1) before inspecting any bead.
#
# Exit codes:
#   0 — completed (zero, one, or more beads inspected/dropped)
#   Non-zero — fatal setup error or unresolved CV_PR_AUTHOR (fail closed)
#
# Requires: bash 4+, gh CLI (authenticated), gc CLI, python3.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GH="${GH:-gh}"
GC_CITY="${GC_CITY:-.}"
CV_PR_AUTHOR="${CV_PR_AUTHOR:-}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-ci-repair-guard: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi

if ! command -v "$GH" >/dev/null 2>&1; then
  echo "con-voyage-ci-repair-guard: ERROR: gh CLI not found at '${GH}'. Install github.com/cli/cli." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-ci-repair-guard: ERROR: python3 not found; required for JSON parsing." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the CV_PR_AUTHOR gh-login default (guarded against set -e), then
# FAIL CLOSED if it is still unresolved. Mirrors con-voyage-pr-watch.sh
# exactly: an unscoped guard would be unable to tell an operator bead from a
# stranger's, so it must refuse to touch ANY bead rather than guess.
# ---------------------------------------------------------------------------
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  CV_PR_AUTHOR="$("$GH" api user --jq .login 2>/dev/null || true)"
fi

if [ -z "${CV_PR_AUTHOR// /}" ]; then
  echo "con-voyage-ci-repair-guard: FATAL: CV_PR_AUTHOR is empty/unresolved." >&2
  echo "con-voyage-ci-repair-guard: author-scoping is mandatory — refusing to inspect any bead." >&2
  echo "con-voyage-ci-repair-guard: set CV_PR_AUTHOR explicitly (e.g. CV_PR_AUTHOR=kriscoleman)" >&2
  echo "con-voyage-ci-repair-guard: or ensure 'gh api user --jq .login' resolves." >&2
  exit 1
fi
echo "con-voyage-ci-repair-guard: guarding con-voyage-ci-repair beads, author-scoped to '${CV_PR_AUTHOR}'"

# ---------------------------------------------------------------------------
# Find every OPEN con-voyage-ci-repair step bead — the bead a worker actually
# claims and acts on (the workflow root bead carries the formula name, but
# the step bead is what `gc hook --claim` hands to a worker).
#
# Deliberately NOT filtered by gc.step_id or gc.step_ref. Empirically cooking
# this formula in a scratch store shows gc.step_id is UNSET on the compiled
# step bead for this flat, single-step v2 recipe — only gc.step_ref is set,
# and only as `<formula-name>.<step-id>` for this shape (nested/looped v2
# formulas, e.g. this very review workflow, render gc.step_ref with no
# formula-name prefix at all). Neither key has a form stable enough to filter
# a `bd list` query on, so this sweep instead casts the widest reliable net —
# every OPEN bead compiled by any graph.v2 formula (gc.root_bead_id is set on
# all of them) — and leaves ALL real gating to the per-root
# `gc.formula_name == con-voyage-ci-repair` check below, which depends only
# on the formula name string, not on compiler-internal step-id conventions.
#
# This is a full sweep on EVERY invocation, not scoped to whichever bead the
# triggering bead.created event named — `bd list --json` always returns a
# bare array (never a single bare object), so no per-item shape branch is
# needed. --limit 0 is mandatory: bd list defaults to 50 results, and silently
# dropping beads past the 50th would defeat the entire point of this guard.
# ---------------------------------------------------------------------------
steps_json=$("$GC" --city "$GC_CITY" bd list --status open --has-metadata-key gc.root_bead_id --limit 0 --json 2>/dev/null) || {
  echo "con-voyage-ci-repair-guard: WARNING: bd list failed; skipping this sweep" >&2
  exit 0
}

step_pairs=$(printf '%s' "$steps_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in (data or []):
    sid = item.get('id', '') or ''
    root = (item.get('metadata') or {}).get('gc.root_bead_id', '') or ''
    if sid and root:
        print(sid + '\t' + root)
" 2>/dev/null || true)

if [ -z "$step_pairs" ]; then
  echo "con-voyage-ci-repair-guard: no open con-voyage-ci-repair beads found"
  exit 0
fi

# ---------------------------------------------------------------------------
# Inspect each candidate step bead via its workflow root (pr/repo formula
# vars live on the root, not the step — see gc.var.pr / gc.var.repo).
# ---------------------------------------------------------------------------
while IFS="$(printf '\t')" read -r step_id root_id; do
  [ -n "$step_id" ] || continue
  [ -n "$root_id" ] || continue

  root_json=$("$GC" --city "$GC_CITY" bd show "$root_id" --json 2>/dev/null) || {
    echo "con-voyage-ci-repair-guard: WARNING: bd show failed for root ${root_id} (step ${step_id})" >&2
    root_json=""
  }

  root_fields=$(printf '%s' "$root_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print('\t\t')
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    print('\t\t')
    raise SystemExit(0)
meta = data.get('metadata') or {}
formula = meta.get('gc.formula_name', '') or ''
pr = meta.get('gc.var.pr', '') or ''
repo = meta.get('gc.var.repo', '') or ''
print(formula + '\t' + pr + '\t' + repo)
" 2>/dev/null || printf '\t\t')

  IFS="$(printf '\t')" read -r formula_name pr repo <<< "$root_fields"

  # Defensive: only act on beads whose root really is a con-voyage-ci-repair
  # workflow. A step bead named "ci-repair" from an unrelated formula (if one
  # ever exists) is left completely untouched — not our bead to police.
  if [ "$formula_name" != "con-voyage-ci-repair" ]; then
    echo "con-voyage-ci-repair-guard: skipping ${step_id} (root ${root_id} formula='${formula_name:-<unresolved>}', not con-voyage-ci-repair)"
    continue
  fi

  # FAIL CLOSED: if we cannot even resolve which PR this bead is about, we
  # cannot prove it belongs to the operator. Better to drop it than to leave
  # an unverifiable bead sitting open for a worker to claim.
  if [ -z "$pr" ] || [ -z "$repo" ]; then
    echo "con-voyage-ci-repair-guard: DROP ${step_id} (root ${root_id}) — pr/repo unresolved from root metadata (fail closed)" >&2
    "$GC" --city "$GC_CITY" bd update "$step_id" --notes "dropped: not authored by operator (pr/repo metadata unresolved on root ${root_id})" >/dev/null 2>&1 || true
    "$GC" --city "$GC_CITY" bd close "$step_id" --reason "dropped: not authored by operator" >/dev/null 2>&1 || true
    continue
  fi

  pr_author=$("$GH" pr view "$pr" --repo "$repo" --json author --jq '.author.login' 2>/dev/null || echo "")

  # AUTHOR FILTER — exact, case-sensitive match only. Anything that is not
  # exactly CV_PR_AUTHOR (including an unresolved/empty author) is dropped.
  if [ -z "${pr_author// /}" ] || [ "$pr_author" != "$CV_PR_AUTHOR" ]; then
    echo "con-voyage-ci-repair-guard: DROP ${step_id} (${repo}#${pr}, author='${pr_author:-<unresolved>}' != '${CV_PR_AUTHOR}') — closing before a worker can act"
    "$GC" --city "$GC_CITY" bd update "$step_id" --notes "dropped: not authored by operator (pr_author='${pr_author:-<unresolved>}', CV_PR_AUTHOR='${CV_PR_AUTHOR}')" >/dev/null 2>&1 || true
    "$GC" --city "$GC_CITY" bd close "$step_id" --reason "dropped: not authored by operator" >/dev/null 2>&1 || true
  else
    echo "con-voyage-ci-repair-guard: KEEP ${step_id} (${repo}#${pr}, author='${pr_author}') — leaving for worker"
  fi
done <<< "$step_pairs"

echo "con-voyage-ci-repair-guard: done"
