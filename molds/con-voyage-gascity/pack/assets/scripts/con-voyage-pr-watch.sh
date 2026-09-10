#!/usr/bin/env bash
# con-voyage-pr-watch.sh — GitHub PR monitoring driver
#
# Drives two monitoring duties:
#
#   PART A: CI-failure repair
#     Runs `gc github pr backfill --create-repair-beads` against all configured
#     [[github.pr_monitor]] blocks. The native monitor evaluates PR check-run
#     state and merge-state, creates deduped repair beads for actionable PRs,
#     and attaches the configured repair_workflow formula. This script is what
#     actually invokes that backfill on a recurring basis — without it the
#     native monitor never fires (poll_interval is inert at runtime).
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
#     Routing uses `gc sling` to create a routed task bead assigned to the
#     implementor. Idempotency is maintained via a state file that records
#     the last-seen comment/review ID per PR so the same comment is never
#     routed twice.
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
#
# Exit codes:
#   0 — completed (some or all monitors may have had no actionable PRs)
#   Non-zero — fatal setup error (gh/gc not found, GITHUB_TOKEN missing, etc.)
#
# The order controller treats any non-zero exit as a transient failure and
# retries on the next cooldown interval.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GC="${GC:-gc}"
GH="${GH:-gh}"
GC_CITY="${GC_CITY:-.}"
CV_STATE_DIR="${CV_STATE_DIR:-${GC_CITY}/.gc/cv-pr-watch}"
CV_IMPLEMENTOR="${CV_IMPLEMENTOR:-gc.implementation-worker}"

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

# Ensure state directory exists
mkdir -p "$CV_STATE_DIR"

# ---------------------------------------------------------------------------
# PART A: CI-failure repair via native pr_monitor backfill
# ---------------------------------------------------------------------------
#
# gc github pr backfill reads all [[github.pr_monitor]] blocks from city.toml,
# evaluates open PRs against each monitor, and creates deduped repair beads
# for any actionable PR (failed checks, DIRTY, BEHIND, BLOCKED). Repair beads
# are keyed by (monitor-name, PR-number, head-sha) so this call is idempotent.
#
# The --create-repair-beads flag is what triggers bead creation. Without it
# the command only evaluates and prints results (useful for debugging).
#
# Output goes to stdout (JSON lines). Failures are printed to stderr and the
# exit code reflects the worst outcome; we tolerate per-monitor errors and
# continue to Part B.

echo "con-voyage-pr-watch: [PART A] running gc github pr backfill --create-repair-beads"
if ! "$GC" --city "$GC_CITY" github pr backfill --create-repair-beads 2>&1; then
  echo "con-voyage-pr-watch: WARNING: backfill returned non-zero; repair beads may be incomplete" >&2
  # Non-fatal: continue to Part B
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

# Extract unique owner/repo pairs from [[github.pr_monitor]] blocks.
# We parse them with simple grep/sed — toml parsers are not guaranteed to be
# available in the controller environment. This is intentionally simple and
# conservative: it may miss monitors in included files (include = [...]) but
# correctly handles monitors defined directly in city.toml.
#
# Format in city.toml:
#   [[github.pr_monitor]]
#   owner = "some-org"
#   repo  = "some-repo"
mapfile -t OWNERS < <(grep -A 5 '^\[\[github\.pr_monitor\]\]' "$CITY_TOML" | grep '^\s*owner\s*=' | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d ' ')
mapfile -t REPOS  < <(grep -A 5 '^\[\[github\.pr_monitor\]\]' "$CITY_TOML" | grep '^\s*repo\s*='  | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d ' ')

if [ "${#OWNERS[@]}" -eq 0 ]; then
  echo "con-voyage-pr-watch: [PART B] no [[github.pr_monitor]] blocks found in city.toml; nothing to poll"
  exit 0
fi

# Process each monitor's repo
for i in "${!OWNERS[@]}"; do
  owner="${OWNERS[$i]:-}"
  repo="${REPOS[$i]:-}"
  if [ -z "$owner" ] || [ -z "$repo" ]; then
    echo "con-voyage-pr-watch: [PART B] skipping monitor $i: incomplete owner/repo" >&2
    continue
  fi
  full_repo="${owner}/${repo}"

  echo "con-voyage-pr-watch: [PART B] checking ${full_repo} for human comments"

  # List open PRs. We only care about non-draft PRs (con-voyage PRs are
  # always non-draft by the time they reach review).
  open_prs_json=$("$GH" pr list \
    --repo "$full_repo" \
    --state open \
    --json number,headRefName,url,isDraft \
    2>/dev/null) || {
    echo "con-voyage-pr-watch: [PART B] WARNING: gh pr list failed for ${full_repo}; skipping" >&2
    continue
  }

  # Iterate over open, non-draft PRs
  pr_count=$(printf '%s' "$open_prs_json" | python3 -c "import sys,json; data=json.load(sys.stdin); print(len([p for p in data if not p.get('isDraft',False)]))" 2>/dev/null || echo 0)
  if [ "$pr_count" -eq 0 ]; then
    echo "con-voyage-pr-watch: [PART B] ${full_repo}: no open non-draft PRs"
    continue
  fi

  # Process each PR
  while IFS= read -r pr_json; do
    pr_number=$(printf '%s' "$pr_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['number'])" 2>/dev/null) || continue
    pr_url=$(printf '%s' "$pr_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['url'])" 2>/dev/null || echo "")
    head_ref=$(printf '%s' "$pr_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['headRefName'])" 2>/dev/null || echo "")

    # State file tracks last-seen comment ID per PR (keyed by repo+PR number)
    state_key=$(printf '%s' "${full_repo}/${pr_number}" | tr '/' '_')
    state_file="${CV_STATE_DIR}/${state_key}.last-comment-id"
    last_seen_id=0
    if [ -f "$state_file" ]; then
      last_seen_id=$(cat "$state_file" 2>/dev/null || echo 0)
    fi

    # Fetch PR reviews and issue comments
    pr_comments_json=$("$GH" pr view "$pr_number" \
      --repo "$full_repo" \
      --json reviews,comments \
      2>/dev/null) || {
      echo "con-voyage-pr-watch: [PART B] WARNING: gh pr view failed for ${full_repo}#${pr_number}; skipping" >&2
      continue
    }

    # Extract new human comments using python3 (available in gc controller envs)
    # A comment is "human" if:
    #   1. The author login is not a known bot (no [bot] suffix, not in BOT_PATTERNS)
    #   2. The comment body does NOT start with the con-voyage agent prefix pattern
    #   3. The comment database ID is > last_seen_id
    #
    # We examine both PR review comments and issue (timeline) comments.
    new_comments=$(python3 - "$pr_comments_json" "$last_seen_id" "$CV_AGENT_PREFIX_PATTERN" <<'PYEOF'
import sys, json, re

data = json.loads(sys.argv[1])
last_seen = int(sys.argv[2])
agent_prefix_re = re.compile(sys.argv[3])

BOT_SUFFIXES = ["[bot]"]
BOT_LOGINS = {"github-actions", "dependabot", "renovate", "stale", "codecov"}

def is_bot(login):
    login_lower = (login or "").lower()
    for suffix in BOT_SUFFIXES:
        if login_lower.endswith(suffix):
            return True
    return login_lower in BOT_LOGINS

def is_agent_comment(body):
    # Con-voyage agents prefix their comments with [<rig>/<agent> — <lens>]
    return bool(agent_prefix_re.match(body or ""))

found = []

# PR review comments (inline code comments + review summaries)
for review in data.get("reviews", []):
    # Reviews have an id (integer or string), author, body, state
    rid = review.get("id")
    if rid is None:
        continue
    # GitHub review IDs are large integers; compare numerically when possible
    try:
        rid_int = int(str(rid).strip())
    except (ValueError, AttributeError):
        continue
    if rid_int <= last_seen:
        continue
    author = review.get("author", {}).get("login", "")
    body = review.get("body", "") or ""
    state = review.get("state", "") or ""
    if is_bot(author):
        continue
    if is_agent_comment(body):
        continue
    # Only surface reviews with substantive feedback (APPROVED, CHANGES_REQUESTED,
    # COMMENTED with a non-empty body). Skip PENDING (not yet submitted).
    if state in ("PENDING",):
        continue
    if not body.strip() and state not in ("APPROVED", "CHANGES_REQUESTED"):
        continue
    found.append({
        "id": rid_int,
        "type": "review",
        "author": author,
        "body": body[:200],
        "state": state,
    })

# Issue comments (timeline comments on the PR)
for comment in data.get("comments", []):
    cid = comment.get("id")
    if cid is None:
        continue
    try:
        cid_int = int(str(cid).strip())
    except (ValueError, AttributeError):
        continue
    if cid_int <= last_seen:
        continue
    author = comment.get("author", {}).get("login", "")
    body = comment.get("body", "") or ""
    if is_bot(author):
        continue
    if is_agent_comment(body):
        continue
    if not body.strip():
        continue
    found.append({
        "id": cid_int,
        "type": "comment",
        "author": author,
        "body": body[:200],
        "state": "",
    })

if not found:
    print("NONE")
else:
    # Sort by id so we process in chronological order
    found.sort(key=lambda x: x["id"])
    print(json.dumps(found))
PYEOF
    ) || {
      echo "con-voyage-pr-watch: [PART B] WARNING: comment parsing failed for ${full_repo}#${pr_number}" >&2
      continue
    }

    if [ "$new_comments" = "NONE" ] || [ -z "$new_comments" ]; then
      echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: no new human comments"
      continue
    fi

    echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: new human feedback found — routing to ${CV_IMPLEMENTOR}"

    # Build a routing message summarizing the new feedback
    feedback_summary=$(printf '%s' "$new_comments" | python3 -c "
import sys, json
items = json.load(sys.stdin)
lines = []
for item in items[:5]:  # cap at 5 items per run to avoid info overload
    author = item.get('author','?')
    kind = item.get('type','comment')
    state = item.get('state','')
    body = item.get('body','').strip()
    if state:
        lines.append(f'  [{kind}] @{author} ({state}): {body[:120]}')
    else:
        lines.append(f'  [{kind}] @{author}: {body[:120]}')
if len(items) > 5:
    lines.append(f'  ... and {len(items)-5} more comment(s)')
print('\n'.join(lines))
" 2>/dev/null || echo "  (summary unavailable)")

    # Route the feedback to the implementor by slinging a task bead.
    # gc sling creates a routed bead that the implementor will pick up.
    # We use --title and --body to describe the task. The bead dedup key
    # is the PR URL + max comment ID so duplicate routes within a run are
    # prevented.
    max_id=$(printf '%s' "$new_comments" | python3 -c "import sys,json; items=json.load(sys.stdin); print(max(x['id'] for x in items))" 2>/dev/null || echo 0)

    route_title="Human PR feedback on ${full_repo}#${pr_number}: ${head_ref}"
    route_body="New human review feedback on PR ${pr_url} (branch: ${head_ref}).

Please read and respond to the following comments. Address any requested
changes on the branch '${head_ref}' using TDD. Push the fix — do NOT merge.

New feedback:
${feedback_summary}

Routing from con-voyage-pr-watch (idempotency: pr-comment-${full_repo//\//_}-${pr_number}-${max_id})"

    if "$GC" --city "$GC_CITY" sling "$CV_IMPLEMENTOR" \
      --title "$route_title" \
      --body "$route_body" \
      2>&1; then
      echo "con-voyage-pr-watch: [PART B] ${full_repo}#${pr_number}: routed to ${CV_IMPLEMENTOR}"
      # Update last-seen ID to the highest ID we processed
      echo "$max_id" > "$state_file"
    else
      echo "con-voyage-pr-watch: [PART B] WARNING: gc sling failed for ${full_repo}#${pr_number}; will retry next cycle" >&2
      # Do NOT update state file — we'll retry on next cycle
    fi

  done < <(printf '%s' "$open_prs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pr in data:
    if not pr.get('isDraft', False):
        print(json.dumps(pr))
" 2>/dev/null)

done

echo "con-voyage-pr-watch: done"
