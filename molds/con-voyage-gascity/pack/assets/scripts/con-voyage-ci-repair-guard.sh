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
# # it and take any GitHub action. It fails closed on any unresolved         #
# # AUTHOR. Infra failures (`bd list` / `bd show`) do NOT fail closed here:  #
# # they skip this sweep and defer to Step 0's in-workflow re-gate, since a  #
# # store lock or transient CLI error must not silently close a bead we      #
# # could not even inspect. (`bd list` and the drop_bead close get a bounded #
# # retry so a transient store lock does not turn a real drop into a no-op.) #
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
# BANNER COMPLIANCE SCAN (C4 backstop, layered on top of cv-pr-comment.sh):
# for every KEPT bead (the operator's own PR), this script also reads that
# PR's comments and flags — fail-loud, on stderr — any comment authored by
# CV_PR_AUTHOR that does not lead with the mandatory machine-identity banner.
# This is a READ-ONLY scan: it can't tell a bot comment that skipped the
# banner apart from a genuine remark the human typed (both are authored by
# the same PAT-backed login), so it never edits or deletes a comment, and a
# finding never changes this script's own exit code.
#
# Environment / configuration (all optional with sane defaults):
#
#   GC              Path to the gc binary (default: gc)
#   GH              Path to the gh binary (default: gh)
#   GC_CITY         City root passed to gc (default: current directory)
#   CV_AUTHOR_GATE  Feature toggle for the whole author gate:
#                     enabled   (DEFAULT) — fail-closed author scoping below.
#                     disabled  — explicit opt-in to work ALL PRs regardless of
#                                 author (native [[github.pr_monitor]] parity).
#                                 This is the ONLY value that yields "work all";
#                                 an empty CV_PR_AUTHOR never does (see below).
#                   Any other/unrecognized value is treated as `enabled`
#                   (fail closed on ambiguity). Default ENABLED deliberately
#                   diverges from the native monitor's "all PRs" default — ours
#                   defaults gated because of a prior org-removal incident.
#   CV_PR_AUTHOR    The author allow-list, consulted only when CV_AUTHOR_GATE is
#                   enabled. Same knob as con-voyage-pr-watch.sh and the
#                   con-voyage-ci-repair formula's cv_pr_author var. Defaults to
#                   the authenticated gh login. If the gate is ENABLED and this
#                   cannot be resolved, the script FAILS CLOSED (exit 1) before
#                   inspecting any bead — an empty allow-list DROPS everything,
#                   it is NEVER interpreted as "work all" (that requires the
#                   explicit CV_AUTHOR_GATE=disabled opt-in).
#
# Precedence: CV_AUTHOR_GATE decides IF the gate runs; CV_PR_AUTHOR decides
# WHICH author it allows once it does. disabled short-circuits before
# CV_PR_AUTHOR is even resolved, so the two are fully decoupled.
#
# Exit codes:
#   0 — completed (zero, one, or more beads inspected/dropped), OR gate disabled
#   Non-zero — fatal setup error, or (gate enabled) unresolved CV_PR_AUTHOR
#              (fail closed)
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
# Author-gate feature toggle. Default ENABLED (fail-closed author scoping).
# Only the literal, case-insensitive value "disabled" turns the gate off;
# EVERYTHING else — including a typo or an empty string — is treated as
# "enabled" so an accidental/garbled value can never silently open the gate.
CV_AUTHOR_GATE="${CV_AUTHOR_GATE:-enabled}"

# ---------------------------------------------------------------------------
# FEATURE TOGGLE — author gate on/off.
#
# When explicitly DISABLED, this guard becomes a complete no-op: it takes no
# action, so every open con-voyage-ci-repair bead is left for a worker to claim
# regardless of author (native [[github.pr_monitor]] "all PRs" parity). This is
# the ONLY code path that yields "work all"; an empty/unset CV_PR_AUTHOR under
# the enabled gate below does NOT — it fails closed and drops everything.
#
# Case-insensitive compare, exact literal "disabled" only. This runs before the
# gc/gh/python3 preflight on purpose: a disabled gate does nothing, so it must
# not hard-require those tools just to no-op.
# ---------------------------------------------------------------------------
gate_lc=$(printf '%s' "$CV_AUTHOR_GATE" | tr '[:upper:]' '[:lower:]')
if [ "$gate_lc" = "disabled" ]; then
  echo "con-voyage-ci-repair-guard: author gate DISABLED (CV_AUTHOR_GATE=disabled) — leaving ALL con-voyage-ci-repair beads for workers regardless of author (native-parity opt-in)"
  echo "con-voyage-ci-repair-guard: done"
  exit 0
fi

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
if [[ "$CV_PR_AUTHOR" =~ ^[[:space:]]*$ ]]; then
  CV_PR_AUTHOR="$("$GH" api user --jq .login 2>/dev/null || true)"
fi

if [[ "$CV_PR_AUTHOR" =~ ^[[:space:]]*$ ]]; then
  echo "con-voyage-ci-repair-guard: FATAL: CV_PR_AUTHOR is empty/unresolved." >&2
  echo "con-voyage-ci-repair-guard: author-scoping is mandatory — refusing to inspect any bead." >&2
  echo "con-voyage-ci-repair-guard: set CV_PR_AUTHOR explicitly (e.g. CV_PR_AUTHOR=kriscoleman)" >&2
  echo "con-voyage-ci-repair-guard: or ensure 'gh api user --jq .login' resolves." >&2
  exit 1
fi
echo "con-voyage-ci-repair-guard: author gate ENABLED — guarding con-voyage-ci-repair beads, author-scoped to '${CV_PR_AUTHOR}'"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# retry — run a command up to 3 times, short sleep between attempts, so a
# transient store lock (Dolt) does not turn a fail-closed action into a silent
# no-op. Returns the command's exit status from its last attempt. Honors
# GUARD_RETRY_ATTEMPTS / GUARD_RETRY_SLEEP overrides (tests set these to 1/0 to
# stay fast). The number of attempts a fake gc records is what proves the retry
# actually fired.
retry() {
  local attempts="${GUARD_RETRY_ATTEMPTS:-3}"
  local sleep_s="${GUARD_RETRY_SLEEP:-1}"
  local n=1 rc=0
  while :; do
    # Run the command directly and capture ITS status immediately. (Do NOT wrap
    # in `if "$@"; then`: a failed condition makes the `if` compound exit 0, so
    # a following `rc=$?` would read 0, not the command's real failure.)
    "$@"
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$n" -ge "$attempts" ] && return "$rc"
    n=$((n + 1))
    sleep "$sleep_s" 2>/dev/null || true
  done
}

# drop_bead <step_id> <notes> — the single close path for a non-operator bead:
# leave a forensic drop-note, then close with the fixed reason. Both writes get
# a bounded retry so a transient store lock can't leave a stranger's control
# bead open. The `|| true` keeps a still-failing note from aborting the sweep,
# but the close is what actually enforces the gate — hence its own retry.
drop_bead() {
  local step_id="$1" notes="$2"
  retry "$GC" --city "$GC_CITY" bd update "$step_id" --notes "$notes" >/dev/null 2>&1 || true
  retry "$GC" --city "$GC_CITY" bd close  "$step_id" --reason "dropped: not authored by operator" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# scan_pr_comment_banners <repo> <pr> <author> — banner compliance scan
# (defense-in-depth for C4, the machine-identity invariant).
#
# con-voyage runs under the operator's GitHub PAT, so every comment it posts
# is indistinguishable, by author alone, from a real comment the human typed.
# cv-pr-comment.sh structurally prepends a fixed banner to everything IT
# posts, but that only covers posts made through it — this scan is the
# backstop that catches a banner-less operator-authored comment however it
# got there (a worker that bypassed the script, a stale pre-cv-pr-comment.sh
# code path, manual intervention, etc.).
#
# Deliberately a SCAN, not a gate: a banner-less comment authored by
# CV_PR_AUTHOR might be a real human remark (nothing wrong at all) or a bot
# comment that skipped the mandatory banner (a real policy violation) — this
# scan cannot tell those apart, so it never edits or deletes a comment. It
# only "flags fail-loud": an ERROR-level line on stderr naming the exact
# comment so a human can review it. It never changes this script's own exit
# code — a banner-scan finding is not a reason to treat the author-gate
# sweep itself as failed.
#
# Only called for KEPT beads (the operator's own PR) — a DROPped bead is not
# ours to inspect further than the author check already performed.
# ---------------------------------------------------------------------------
CV_BANNER_PREFIX='🤖 **Automated con-voyage agent**'

scan_pr_comment_banners() {
  local repo="$1" pr="$2" author="$3"
  local comments_json
  comments_json=$("$GH" api "repos/${repo}/issues/${pr}/comments" --paginate --jq '[.[] | {id: .id, login: .user.login, body: .body}]' 2>/dev/null) || {
    echo "con-voyage-ci-repair-guard: WARNING: could not fetch PR comments for ${repo}#${pr}; skipping banner scan" >&2
    return 0
  }

  local bad_ids
  bad_ids=$(printf '%s' "$comments_json" | CV_SCAN_AUTHOR="$author" python3 -c "
import json, os, sys

BANNER = '${CV_BANNER_PREFIX}'
author = os.environ.get('CV_SCAN_AUTHOR', '')
try:
    comments = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for c in (comments or []):
    login = c.get('login', '') or ''
    body = c.get('body', '') or ''
    if login == author and not body.startswith(BANNER):
        print(c.get('id', ''))
" 2>/dev/null)

  [ -n "$bad_ids" ] || return 0
  while IFS= read -r bad_id; do
    [ -n "$bad_id" ] || continue
    echo "con-voyage-ci-repair-guard: ERROR: banner-less operator-authored PR comment — ${repo}#${pr} comment id ${bad_id} (author='${author}') does not lead with the mandatory identity banner. This scan cannot distinguish a genuine human comment from a bot comment that skipped the banner — review comment ${bad_id} manually; no automated action is taken." >&2
  done <<< "$bad_ids"
}

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
# Bounded retry on the fetch itself: a transient store lock here would
# otherwise skip the whole sweep (fail-open on infra). This is still fail-open
# after the retries are exhausted — we defer to Step 0 rather than close beads
# we could not inspect — but we don't bail on the first hiccup.
steps_json=$(retry "$GC" --city "$GC_CITY" bd list --status open --has-metadata-key gc.root_bead_id --limit 0 --json 2>/dev/null) || {
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
        # \x1f (unit separator) — a non-whitespace delimiter so empty fields
        # survive the shell 'read' below instead of being collapsed (LOW-4).
        print(sid + '\x1f' + root)
" 2>/dev/null || true)

if [ -z "$step_pairs" ]; then
  echo "con-voyage-ci-repair-guard: no open con-voyage-ci-repair beads found"
  exit 0
fi

# ---------------------------------------------------------------------------
# Inspect each candidate step bead via its workflow root (pr/repo formula
# vars live on the root, not the step — see gc.var.pr / gc.var.repo).
# ---------------------------------------------------------------------------
while IFS=$'\x1f' read -r step_id root_id; do
  [ -n "$step_id" ] || continue
  [ -n "$root_id" ] || continue

  root_json=$("$GC" --city "$GC_CITY" bd show "$root_id" --json 2>/dev/null) || {
    echo "con-voyage-ci-repair-guard: WARNING: bd show failed for root ${root_id} (step ${step_id})" >&2
    root_json=""
  }

  # \x1f (unit separator) delimits the three root fields — a non-whitespace
  # separator so an empty middle field (e.g. pr set, repo missing) survives the
  # shell 'read' below instead of being collapsed, which would misreport which
  # field was actually empty in the fail-closed drop note (LOW-4).
  root_fields=$(printf '%s' "$root_json" | python3 -c "
import sys, json
SEP = '\x1f'
try:
    data = json.load(sys.stdin)
except Exception:
    print(SEP + SEP)
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    print(SEP + SEP)
    raise SystemExit(0)
meta = data.get('metadata') or {}
formula = meta.get('gc.formula_name', '') or ''
pr = meta.get('gc.var.pr', '') or ''
repo = meta.get('gc.var.repo', '') or ''
print(formula + SEP + pr + SEP + repo)
" 2>/dev/null || printf '\x1f\x1f')

  IFS=$'\x1f' read -r formula_name pr repo <<< "$root_fields"

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
    drop_bead "$step_id" "dropped: not authored by operator (pr/repo metadata unresolved on root ${root_id})"
    continue
  fi

  pr_author=$("$GH" pr view "$pr" --repo "$repo" --json author --jq '.author.login' 2>/dev/null || echo "")

  # AUTHOR FILTER — exact, case-sensitive match only. Anything that is not
  # exactly CV_PR_AUTHOR (including an unresolved/empty author) is dropped.
  if [[ "$pr_author" =~ ^[[:space:]]*$ ]] || [ "$pr_author" != "$CV_PR_AUTHOR" ]; then
    echo "con-voyage-ci-repair-guard: DROP ${step_id} (${repo}#${pr}, author='${pr_author:-<unresolved>}' != '${CV_PR_AUTHOR}') — closing before a worker can act"
    drop_bead "$step_id" "dropped: not authored by operator (pr_author='${pr_author:-<unresolved>}', CV_PR_AUTHOR='${CV_PR_AUTHOR}')"
  else
    echo "con-voyage-ci-repair-guard: KEEP ${step_id} (${repo}#${pr}, author='${pr_author}') — leaving for worker"
    scan_pr_comment_banners "$repo" "$pr" "$pr_author"
  fi
done <<< "$step_pairs"

echo "con-voyage-ci-repair-guard: done"
