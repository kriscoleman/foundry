#!/usr/bin/env bash
# con-voyage-pr-watch.sh — GitHub PR monitoring driver
#
# ############################################################################
# # HARD INVARIANT — AUTHOR SCOPING                                          #
# #                                                                          #
# # This monitor MUST only ever act on PRs authored by the single           #
# # configured user CV_PR_AUTHOR (default: the authenticated gh login).      #
# # It NEVER creates a repair bead for, and NEVER routes comments from, a    #
# # PR authored by anyone else.                                             #
# #                                                                          #
# # Rationale: an earlier unfiltered version acted on 43 PRs it did not own  #
# # across other people's repos and got the operator removed from the org.   #
# # Both duties below are author-scoped, and the script FAILS CLOSED (exits  #
# # non-zero before any GitHub work) if CV_PR_AUTHOR cannot be resolved.     #
# #                                                                          #
# # The native [[github.pr_monitor]] config cannot express an author filter  #
# # and `gc github pr backfill` has no --author flag, so author-scoping is   #
# # enforced HERE, in this script, which is the sole runtime driver of the   #
# # monitor (the native poll_interval is inert without it).                  #
# ############################################################################
#
# Drives two monitoring duties:
#
#   PART A: CI-failure repair (AUTHOR-SCOPED)
#     Runs `gc github pr backfill --json` (REPORT-ONLY, no --create-repair-beads)
#     against all configured [[github.pr_monitor]] blocks, then DROPS every PR
#     not authored by CV_PR_AUTHOR, and creates a deduped repair bead only for
#     each surviving actionable PR. This script is what actually invokes the
#     backfill on a recurring basis — without it the native monitor never fires
#     (poll_interval is inert at runtime).
#
#     NOTE: we deliberately do NOT use `gc github pr backfill
#     --create-repair-beads`, because that native path creates a repair bead
#     for EVERY actionable PR regardless of author (it has no author filter).
#     Using the report-only JSON + our own per-PR author check + our own bead
#     creation is the only way to guarantee the author-scoping invariant.
#
#   PART B: Human PR-comment routing (best-effort polling)
#     The native [[github.pr_monitor]] watches CI checks and merge-state ONLY.
#     It does NOT watch human PR review comments or issue comments. This script
#     bridges that gap by polling open PRs for new human feedback and routing
#     it to the con-voyage implementor.
#
#     "Human" comments are those NOT prefixed with `[<rig>/<agent> — <lens>]`
#     (the con-voyage reviewer identity prefix). Bot/automation comments
#     typically carry a [bot] suffix or a well-known bot login.
#
#     Inline review-thread comments (reviewThreads) are also captured in
#     addition to top-level reviews and issue comments.
#
#     Deduplication uses GitHub GraphQL node-ID STRINGS (e.g. "PRR_kwDO...",
#     "IC_kwDO..."). IDs are stored newline-delimited in a per-PR state file.
#     The seen-set is capped each run to IDs from currently-open PRs to prevent
#     unbounded growth.
#
#     Routing uses `gc sling` to create a routed task bead assigned to the
#     implementor. This script NEVER merges or closes PRs — it only reads
#     GitHub and routes feedback.
#
#     This is BEST-EFFORT. Comment polling has no event-driven delivery
#     guarantee; a comment posted moments before this script runs might be
#     seen 10 minutes later. Use native GitHub webhooks (webhook_secret_env
#     in city.toml) for near-realtime comment delivery if available.
#
# Environment / configuration (all optional with sane defaults):
#
#   GC              Path to the gc binary (default: gc)
#   GH              Path to the gh binary (default: gh)
#   GC_CITY         City root passed to gc (default: current directory)
#   CV_STATE_DIR    Directory for idempotency state files (default: .gc/cv-pr-watch)
#   CV_IMPLEMENTOR  Implementor session/route target for routing human comments
#                   (default: gc.implementation-worker)
#   CV_PR_AUTHOR    REQUIRED (author-scoping). The single GitHub login whose PRs
#                   this monitor is allowed to act on. Defaults to the
#                   authenticated gh login. If it cannot be resolved, the script
#                   FAILS CLOSED (exit 1) before touching any repo.
#
# Exit codes:
#   0 — completed (some or all monitors may have had no actionable PRs)
#   Non-zero — fatal setup error (gh/gc not found, GITHUB_TOKEN missing, etc.)
#
# The order controller treats any non-zero exit as a transient failure and
# retries on the next cooldown interval.
#
# Requires: bash 4+, gh CLI (authenticated), gc CLI, python3.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GH="${GH:-gh}"
GC_CITY="${GC_CITY:-.}"
CV_STATE_DIR="${CV_STATE_DIR:-${GC_CITY}/.gc/cv-pr-watch}"
CV_IMPLEMENTOR="${CV_IMPLEMENTOR:-gc.implementation-worker}"

# AUTHOR SCOPING (see HARD INVARIANT in the header). The single GitHub login
# whose PRs this monitor may act on. Defaults to the authenticated gh login.
# Never leave this empty — the preflight fails closed if it is unresolved.
#
# NOTE: we do NOT resolve the gh-login default here. Under `set -e`, a failing
# command substitution on this assignment line would abort the script BEFORE
# the fail-closed guard could report a clear error. The gh-login fallback is
# resolved (guarded against set -e) in the preflight below, after gh is known
# to exist. Here we only accept an explicit CV_PR_AUTHOR from the environment.
CV_PR_AUTHOR="${CV_PR_AUTHOR:-}"

# Con-voyage reviewer identity prefix — comments starting with this pattern
# are agent review comments, not human comments. The prefix format is:
#   [<rig>/<agent> — <lens>]
# We match on the opening bracket + slash to avoid false positives.
CV_AGENT_PREFIX_PATTERN='^\[.*/cv-'

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if ! command -v "$GC" >/dev/null 2>&1; then
  echo "con-voyage-pr-watch: ERROR: gc binary not found at '${GC}'. Set GC= to override." >&2
  exit 1
fi

if ! command -v "$GH" >/dev/null 2>&1; then
  echo "con-voyage-pr-watch: ERROR: gh CLI not found at '${GH}'. Install github.com/cli/cli." >&2
  exit 1
fi

# Verify gh is authenticated (prints an error and exits non-zero if not)
if ! "$GH" auth status >/dev/null 2>&1; then
  echo "con-voyage-pr-watch: ERROR: gh is not authenticated. Run 'gh auth login' or set GITHUB_TOKEN." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "con-voyage-pr-watch: ERROR: python3 not found; required for PR comment filtering." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the CV_PR_AUTHOR gh-login default (guarded against set -e).
#
# If CV_PR_AUTHOR was not provided explicitly, fall back to the authenticated
# gh login. This runs AFTER the gh existence/auth preflight, and the command
# substitution is guarded with `|| true` so a gh failure leaves CV_PR_AUTHOR
# empty and lets the fail-closed guard below report a clear error and exit —
# rather than `set -e` aborting the script silently on this line.
# ---------------------------------------------------------------------------
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  CV_PR_AUTHOR="$("$GH" api user --jq .login 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# FAIL-CLOSED author-scoping guard (see HARD INVARIANT in the header).
#
# If CV_PR_AUTHOR is empty/unresolved we MUST NOT proceed: an unscoped run
# would act on every open PR in every configured repo, including PRs authored
# by other people. Exit non-zero BEFORE any PART A / PART B work — before we
# query a single repo.
# ---------------------------------------------------------------------------
if [ -z "${CV_PR_AUTHOR// /}" ]; then
  echo "con-voyage-pr-watch: FATAL: CV_PR_AUTHOR is empty/unresolved." >&2
  echo "con-voyage-pr-watch: author-scoping is mandatory — refusing to act on any PR." >&2
  echo "con-voyage-pr-watch: set CV_PR_AUTHOR explicitly (e.g. CV_PR_AUTHOR=kriscoleman)" >&2
  echo "con-voyage-pr-watch: or ensure 'gh api user --jq .login' resolves." >&2
  exit 1
fi
echo "con-voyage-pr-watch: author-scoped to PRs authored by '${CV_PR_AUTHOR}' (all other PRs are ignored)"

# Ensure state directory exists
mkdir -p "$CV_STATE_DIR"

# ---------------------------------------------------------------------------
# PART A: CI-failure repair (author-scoped)
# ---------------------------------------------------------------------------
#
# AUTHOR-SCOPED FLOW (see HARD INVARIANT in the header):
#
#   1. Run `gc github pr backfill --json` REPORT-ONLY (NO --create-repair-beads).
#      This evaluates all [[github.pr_monitor]] blocks and reports every
#      actionable PR (failed checks, DIRTY, BEHIND, BLOCKED) as JSON — but
#      creates NO beads.
#   2. For each actionable result, resolve the PR's author login (via
#      `gh pr view`) and DROP the PR unless its author == CV_PR_AUTHOR.
#   3. For each surviving PR, create ONE deduped repair bead by attaching the
#      `con-voyage-ci-repair` formula to the monitor's repair_route, matching
#      the native title/dedup shape:
#        title: "Repair GitHub PR <owner>/<repo>#<n> readiness: <title>"
#        dedup: repo + PR number + head-sha  (idempotent across cooldown ticks)
#
# We deliberately AVOID `--create-repair-beads` because that native path has no
# author filter and would create a bead for every actionable PR. The report +
# per-PR author check + our own bead creation is the ONLY way to guarantee the
# invariant: ZERO repair beads for PRs not authored by CV_PR_AUTHOR.
#
# ZERO-BEAD-FOR-OTHERS GUARANTEE: bead creation happens strictly inside the
# `author == CV_PR_AUTHOR` branch below. Any PR whose author cannot be resolved
# (empty login, gh error) is treated as "not ours" and skipped — fail closed.
# It is always better to create NO bead than to create one for someone else.

echo "con-voyage-pr-watch: [PART A] report-only backfill (gc github pr backfill --json), author-filtering to '${CV_PR_AUTHOR}'"

backfill_json=$("$GC" --city "$GC_CITY" github pr backfill --json 2>/dev/null) || {
  echo "con-voyage-pr-watch: [PART A] WARNING: report-only backfill returned non-zero; skipping repair-bead creation this cycle" >&2
  backfill_json=""
}

if [ -n "$backfill_json" ]; then
  # Emit only ACTIONABLE results as one JSON object per line for the shell loop.
  # (report-only JSON never contains a per-PR author field, so we resolve the
  # author separately below via gh — see ZERO-BEAD-FOR-OTHERS guarantee.)
  actionable_prs=$(printf '%s' "$backfill_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in data.get('results', []):
    if r.get('actionable'):
        print(json.dumps(r))
" 2>/dev/null || true)

  if [ -z "$actionable_prs" ]; then
    echo "con-voyage-pr-watch: [PART A] no actionable PRs reported; nothing to repair"
  else
    while IFS= read -r result_json; do
      [ -n "$result_json" ] || continue

      a_owner=$(printf '%s' "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin).get('owner',''))" 2>/dev/null || echo "")
      a_repo=$(printf '%s' "$result_json"  | python3 -c "import sys,json;print(json.load(sys.stdin).get('repo',''))"  2>/dev/null || echo "")
      a_num=$(printf '%s' "$result_json"   | python3 -c "import sys,json;print(json.load(sys.stdin).get('number',''))" 2>/dev/null || echo "")
      a_title=$(printf '%s' "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin).get('title',''))" 2>/dev/null || echo "")
      a_branch=$(printf '%s' "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin).get('head_ref_name',''))" 2>/dev/null || echo "")
      a_sha=$(printf '%s' "$result_json"   | python3 -c "import sys,json;print(json.load(sys.stdin).get('head_sha',''))" 2>/dev/null || echo "")
      a_route=$(printf '%s' "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin).get('repair_route',''))" 2>/dev/null || echo "")

      if [ -z "$a_owner" ] || [ -z "$a_repo" ] || [ -z "$a_num" ]; then
        echo "con-voyage-pr-watch: [PART A] skipping malformed backfill result: ${result_json}" >&2
        continue
      fi
      a_full="${a_owner}/${a_repo}"

      # Resolve the PR author. The report JSON has no author field, so ask gh.
      pr_author=$("$GH" pr view "$a_num" --repo "$a_full" --json author \
        --jq '.author.login' 2>/dev/null || echo "")

      # AUTHOR FILTER — the airtight gate. Anything that is not exactly
      # CV_PR_AUTHOR (including an unresolved/empty author) is dropped.
      if [ "$pr_author" != "$CV_PR_AUTHOR" ]; then
        echo "con-voyage-pr-watch: [PART A] DROP ${a_full}#${a_num} (author='${pr_author:-<unresolved>}' != '${CV_PR_AUTHOR}') — no repair bead created"
        continue
      fi

      # Survivor: author matches. Create ONE deduped repair bead.
      repair_title="Repair GitHub PR ${a_full}#${a_num} readiness: ${a_title}"
      dedup_key="cv-ci-repair-${a_owner}-${a_repo}-${a_num}-${a_sha}"

      if [ -z "$a_route" ]; then
        echo "con-voyage-pr-watch: [PART A] WARNING: ${a_full}#${a_num} has no repair_route in backfill result; cannot create bead safely; skipping" >&2
        continue
      fi

      echo "con-voyage-pr-watch: [PART A] KEEP ${a_full}#${a_num} (author='${pr_author}') — creating repair bead (dedup: ${dedup_key})"

      if "$GC" --city "$GC_CITY" sling "$a_route" \
        --on con-voyage-ci-repair \
        --title "$repair_title" \
        --var "title=${a_title}" \
        --var "pr=${a_num}" \
        --var "repo=${a_full}" \
        --var "branch=${a_branch}" \
        2>&1; then
        echo "con-voyage-pr-watch: [PART A] ${a_full}#${a_num}: repair bead created/attached and routed to ${a_route}"
      else
        echo "con-voyage-pr-watch: [PART A] WARNING: repair-bead sling failed for ${a_full}#${a_num}; will retry next cycle" >&2
        # Non-fatal: continue to next PR / Part B.
      fi
    done <<< "$actionable_prs"
  fi
fi

# ---------------------------------------------------------------------------
# PART B: Human PR-comment routing
# ---------------------------------------------------------------------------
#
# For each [[github.pr_monitor]] we enumerate open PRs targeting the monitored
# base branches, then look for new human review comments/feedback that has not
# been seen in the previous run. When new human feedback is found, we route it
# to the implementor.
#
# The gc config does not provide a CLI to enumerate monitors directly, so we
# read the city.toml to extract owner/repo pairs. If city.toml is not
# accessible or parseable, we skip Part B gracefully.

CITY_TOML="${GC_CITY}/city.toml"
if [ ! -f "$CITY_TOML" ]; then
  echo "con-voyage-pr-watch: [PART B] city.toml not found at ${CITY_TOML}; skipping comment routing"
  exit 0
fi

echo "con-voyage-pr-watch: [PART B] scanning for human PR comments to route"

# Extract unique owner/repo pairs from [[github.pr_monitor]] blocks using awk.
# Block-scoped extraction: awk activates at [[github.pr_monitor]], captures
# owner= and repo= lines until the next top-level [...] header, then emits
# the pair. Handles monitor blocks where owner/repo appear many lines below
# the header (no fixed-line-count limit). Handles multiple monitor blocks.
#
# PORTABILITY: use POSIX bracket classes ([[:space:]]) rather than the GNU
# extension `\s`. Under BSD awk (macOS) `\s` matches a LITERAL 's', so a
# `\s`-based parser silently matches ZERO owner/repo lines and PART B no-ops
# ("no [[github.pr_monitor]] blocks found"). [[:space:]] works under BOTH BSD
# awk and gawk, and matches both `owner = "x"` (spaced) and `owner="x"`.
#
# Output format: one "OWNER/REPO" per line.
mapfile -t MONITOR_REPOS < <(awk '
  /^\[\[github\.pr_monitor\]\]/ {
    in_block = 1
    owner = ""
    repo  = ""
    next
  }
  in_block && /^\[/ {
    # Next top-level header — emit pair if complete, then reset
    if (owner != "" && repo != "") {
      print owner "/" repo
    }
    in_block = 0
    owner = ""
    repo  = ""
    # Check if this new header is itself a pr_monitor block
    if (/^\[\[github\.pr_monitor\]\]/) {
      in_block = 1
    }
    next
  }
  in_block && /^[[:space:]]*owner[[:space:]]*=/ {
    val = $0
    sub(/.*=[[:space:]]*"/, "", val)
    sub(/".*/, "", val)
    owner = val
    next
  }
  in_block && /^[[:space:]]*repo[[:space:]]*=/ {
    val = $0
    sub(/.*=[[:space:]]*"/, "", val)
    sub(/".*/, "", val)
    repo = val
    next
  }
  END {
    # Emit last block if file ends without another header
    if (in_block && owner != "" && repo != "") {
      print owner "/" repo
    }
  }
' "$CITY_TOML")

if [ "${#MONITOR_REPOS[@]}" -eq 0 ]; then
  echo "con-voyage-pr-watch: [PART B] no [[github.pr_monitor]] blocks found in city.toml; nothing to poll"
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper: load seen node-IDs for a PR from its state file.
# State file: one node-ID string per line (e.g. PRR_kwDO... or IC_kwDO...).
# Returns a newline-delimited list to stdout.
# ---------------------------------------------------------------------------
load_seen_ids() {
  local state_file="$1"
  if [ -f "$state_file" ]; then
    cat "$state_file" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Helper: persist seen node-IDs back to the state file.
# Accepts newline-delimited ids on stdin; writes them (sorted, deduped).
# ---------------------------------------------------------------------------
save_seen_ids() {
  local state_file="$1"
  sort -u > "$state_file"
}

# Process each monitor's repo
for monitor_repo in "${MONITOR_REPOS[@]}"; do
  # Split "owner/repo" — use parameter expansion, not IFS tricks
  owner="${monitor_repo%%/*}"
  repo="${monitor_repo#*/}"
  if [ -z "$owner" ] || [ -z "$repo" ]; then
    echo "con-voyage-pr-watch: [PART B] skipping malformed entry '${monitor_repo}'" >&2
    continue
  fi
  full_repo="${owner}/${repo}"

  echo "con-voyage-pr-watch: [PART B] checking ${full_repo} for human comments"

  # List open PRs. We only care about non-draft PRs (con-voyage PRs are
  # always non-draft by the time they reach review).
  #
  # AUTHOR SCOPING (see HARD INVARIANT in the header): --author "$CV_PR_AUTHOR"
  # restricts the enumeration to the operator's own PRs, so we never poll or
  # route comments from anyone else's PR. This is the airtight gate for PART B.
  open_prs_json=$("$GH" pr list \
    --repo "$full_repo" \
    --author "$CV_PR_AUTHOR" \
    --state open \
    --json number,headRefName,url,isDraft \
    2>/dev/null) || {
    echo "con-voyage-pr-watch: [PART B] WARNING: gh pr list failed for ${full_repo}; skipping" >&2
    continue
  }

  # Iterate over open, non-draft PRs
  pr_count=$(printf '%s' "$open_prs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len([p for p in data if not p.get('isDraft', False)]))" 2>/dev/null || echo 0)

  if [ "$pr_count" -eq 0 ]; then
    echo "con-voyage-pr-watch: [PART B] ${full_repo}: no open non-draft PRs"
    continue
  fi

  # Collect open PR numbers for state-file GC (cap seen-set to open PRs only)
  open_pr_numbers=$(printf '%s' "$open_prs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data:
    if not p.get('isDraft', False):
        print(p['number'])" 2>/dev/null || true)

  # Process each PR
  while IFS= read -r pr_json; do
    pr_number=$(printf '%s' "$pr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['number'])" 2>/dev/null) || continue

    pr_url=$(printf '%s' "$pr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['url'])" 2>/dev/null || echo "")

    head_ref=$(printf '%s' "$pr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['headRefName'])" 2>/dev/null || echo "")

    # State file tracks seen node-ID strings per PR (keyed by repo+PR number)
    state_key=$(printf '%s' "${full_repo}/${pr_number}" | tr '/' '_')
    state_file="${CV_STATE_DIR}/${state_key}.seen-ids"

    # Load seen IDs into a temp file so we can pass to python3 via stdin
    seen_ids_content=$(load_seen_ids "$state_file")

    # Fetch PR reviews, issue comments, and inline review thread comments.
    # Pass JSON via STDIN to python3 (avoids ARG_MAX limits on large PRs).
    pr_comments_json=$("$GH" pr view "$pr_number" \
      --repo "$full_repo" \
      --json reviews,comments,reviewThreads \
      2>/dev/null) || {
      echo "con-voyage-pr-watch: [PART B] WARNING: gh pr view failed for ${full_repo}#${pr_number}; skipping" >&2
      continue
    }

    # Extract new human comments using python3.
    # Reads PR JSON from stdin (fd 0) and seen-IDs + config from argv.
    # A comment is "human" if:
    #   1. The author login is not a known bot (no [bot] suffix, not in BOT_LOGINS)
    #   2. The comment body does NOT start with the con-voyage agent prefix pattern
    #   3. The comment's node-ID STRING is NOT in the seen-IDs set
    #
    # Examines: reviews, comments (issue/timeline), reviewThreads (inline).
    # Outputs: JSON array of new items, or "NONE".
    # Also outputs "SEEN_IDS:<newline-delimited-ids>" of ALL seen IDs after
    # including new ones (for state-file update).
    # shellcheck disable=SC2016
    _PY_SCAN_COMMENTS='
import sys, json, re

pr_data    = json.load(sys.stdin)   # PR JSON from stdin
seen_ids   = set(line.strip() for line in sys.argv[1].splitlines() if line.strip())
agent_re   = re.compile(sys.argv[2])

BOT_SUFFIXES = ["[bot]"]
BOT_LOGINS   = {"github-actions", "dependabot", "renovate", "stale", "codecov"}

def is_bot(login):
    ll = (login or "").lower()
    for s in BOT_SUFFIXES:
        if ll.endswith(s):
            return True
    return ll in BOT_LOGINS

def is_agent_comment(body):
    return bool(agent_re.match(body or ""))

found      = []
new_ids    = set()

# --- PR review summaries ---
for review in pr_data.get("reviews", []):
    nid = str(review.get("id") or "").strip()
    if not nid or nid in seen_ids:
        continue
    author = review.get("author", {}).get("login", "")
    body   = review.get("body", "") or ""
    state  = review.get("state", "") or ""
    if is_bot(author):
        continue
    if is_agent_comment(body):
        continue
    if state == "PENDING":
        continue
    if not body.strip() and state not in ("APPROVED", "CHANGES_REQUESTED"):
        continue
    found.append({
        "id":     nid,
        "type":   "review",
        "author": author,
        "body":   body[:200],
        "state":  state,
    })
    new_ids.add(nid)

# --- Issue / timeline comments ---
for comment in pr_data.get("comments", []):
    nid = str(comment.get("id") or "").strip()
    if not nid or nid in seen_ids:
        continue
    author = comment.get("author", {}).get("login", "")
    body   = comment.get("body", "") or ""
    if is_bot(author):
        continue
    if is_agent_comment(body):
        continue
    if not body.strip():
        continue
    found.append({
        "id":     nid,
        "type":   "comment",
        "author": author,
        "body":   body[:200],
        "state":  "",
    })
    new_ids.add(nid)

# --- Inline review-thread comments ---
for thread in pr_data.get("reviewThreads", []):
    for comment in thread.get("comments", {}).get("nodes", []):
        nid = str(comment.get("id") or "").strip()
        if not nid or nid in seen_ids:
            continue
        author = comment.get("author", {}).get("login", "")
        body   = comment.get("body", "") or ""
        if is_bot(author):
            continue
        if is_agent_comment(body):
            continue
        if not body.strip():
            continue
        found.append({
            "id":     nid,
            "type":   "inline",
            "author": author,
            "body":   body[:200],
            "state":  "",
        })
        new_ids.add(nid)

# Emit results
if not found:
    print("NONE")
else:
    # Stable order: new items first (their relative order from the API)
    print(json.dumps(found))

# Always emit updated seen-IDs set (existing + newly routed) on a sentinel
# line so the shell can persist it without a second python invocation.
all_ids = seen_ids | new_ids
print("SEEN_IDS:" + "\n".join(sorted(all_ids)))
'
    new_comments=$(printf '%s' "$pr_comments_json" | python3 -c "$_PY_SCAN_COMMENTS" "$seen_ids_content" "$CV_AGENT_PREFIX_PATTERN") || {
      echo "con-voyage-pr-watch: [PART B] WARNING: comment parsing failed for ${full_repo}#${pr_number}" >&2
      continue
    }

    # Split python3 output into the result and the SEEN_IDS block
    result_line=$(printf '%s\n' "$new_comments" | grep -v '^SEEN_IDS:' | head -1)
    updated_seen_ids=$(printf '%s\n' "$new_comments" | awk '/^SEEN_IDS:/{found=1; sub(/^SEEN_IDS:/,""); print; next} found{print}')

    if [ "$result_line" = "NONE" ] || [ -z "$result_line" ]; then
      echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: no new human comments"
      # Persist seen-IDs even when nothing new (idempotent — same content)
      if [ -n "$updated_seen_ids" ]; then
        printf '%s\n' "$updated_seen_ids" | save_seen_ids "$state_file"
      fi
      continue
    fi

    echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: new human feedback found — routing to ${CV_IMPLEMENTOR}"

    # Build a routing message summarizing the new feedback.
    # Pass JSON via stdin to avoid ARG_MAX issues.
    # shellcheck disable=SC2016
    _PY_SUMMARIZE='
import sys, json
items = json.load(sys.stdin)
lines = []
for item in items[:5]:   # cap at 5 items per run to avoid info overload
    author = item.get("author", "?")
    kind   = item.get("type", "comment")
    state  = item.get("state", "")
    body   = item.get("body", "").strip()
    nid    = item.get("id", "")
    label  = (" (" + state + ")") if state else ""
    lines.append("  [" + kind + "] @" + author + label + ": " + body[:120] + "  [id:" + nid + "]")
if len(items) > 5:
    lines.append("  ... and " + str(len(items)-5) + " more comment(s)")
print("\n".join(lines))
'
    feedback_summary=$(printf '%s' "$result_line" | python3 -c "$_PY_SUMMARIZE" 2>/dev/null || echo "  (summary unavailable)")

    # Dedup key uses the set of new node-IDs (stable across retries with same comments)
    new_ids_for_key=$(printf '%s\n' "$result_line" | python3 -c "
import sys, json
items = json.load(sys.stdin)
print(','.join(sorted(x['id'] for x in items)))" 2>/dev/null || echo "unknown")

    route_title="Human PR feedback on ${full_repo}#${pr_number}: ${head_ref}"
    route_body="New human review feedback on PR ${pr_url} (branch: ${head_ref}).

Please read and respond to the following comments. Address any requested
changes on the branch '${head_ref}' using TDD. Push the fix — do NOT merge.

New feedback:
${feedback_summary}

Routing from con-voyage-pr-watch (idempotency: pr-comment-${full_repo//\//_}-${pr_number}-nodeids-${new_ids_for_key})"

    if "$GC" --city "$GC_CITY" sling "$CV_IMPLEMENTOR" \
      --title "$route_title" \
      --body "$route_body" \
      2>&1; then
      echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: routed to ${CV_IMPLEMENTOR}"
      # Persist updated seen-IDs only on successful route
      if [ -n "$updated_seen_ids" ]; then
        printf '%s\n' "$updated_seen_ids" | save_seen_ids "$state_file"
      fi
    else
      echo "con-voyage-pr-watch: [PART B] WARNING: gc sling failed for ${full_repo}#${pr_number}; will retry next cycle" >&2
      # Do NOT update state file — we'll retry on next cycle
    fi

  done < <(printf '%s' "$open_prs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pr in data:
    if not pr.get('isDraft', False):
        print(json.dumps(pr))" 2>/dev/null)

  # ---------------------------------------------------------------------------
  # State-file GC: remove state files for PRs that are no longer open.
  # This prevents unbounded accumulation of seen-ID files for merged/closed PRs.
  # ---------------------------------------------------------------------------
  if [ -n "$open_pr_numbers" ]; then
    # Build set of expected state-file basenames for open PRs
    for existing_state in "${CV_STATE_DIR}/${owner}_${repo}_"*.seen-ids; do
      [ -f "$existing_state" ] || continue
      basename_no_ext="${existing_state%.seen-ids}"
      # Extract PR number suffix: state key is owner_repo_<number>
      pr_num_from_file="${basename_no_ext##*_}"
      if ! printf '%s\n' "$open_pr_numbers" | grep -qx "$pr_num_from_file"; then
        echo "con-voyage-pr-watch: [PART B] GC: removing stale state for closed PR #${pr_num_from_file} (${full_repo})"
        rm -f "$existing_state"
      fi
    done
  fi

done

echo "con-voyage-pr-watch: done"
