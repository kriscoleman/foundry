Repair CI failures on the PR branch.

You have been assigned a CI repair task for a GitHub pull request. The PR
monitor detected failing CI checks, a merge conflict, or a branch-protection
block. Your job is to fix the root cause on the PR branch and push the fix.
The monitor re-evaluates the PR on the next backfill — you do not merge.

## Context variables

| Variable | Value              |
|----------|--------------------|
| pr        | {{pr}}             |
| repo      | {{repo}}           |
| branch    | {{branch}}         |
| convoy_id | {{convoy_id}}      |
| repair_bead | {{repair_bead}}  |
| title     | {{title}}          |
| cv_pr_author | {{cv_pr_author}} |
| cv_author_gate | {{cv_author_gate}} |
| cv_conflict_strategy | {{cv_conflict_strategy}} |

## Claim — mark the repair bead in_progress

`{{convoy_id}}` is a gc-internal work-item id for this step, not the
human-facing bead `con-voyage-pr-watch.sh` minted and that a human sees on the
dashboard (`{{repair_bead}}`). That bead must never sit at READY for the
duration of this repair, and must close on every terminal exit below — see
`cv_bead_mark_in_progress`/`cv_bead_close` in `con-voyage-lib.sh` (fk-7mw7
FIX-A: closing only `{{convoy_id}}` and never `{{repair_bead}}` was the #1
driver of a batch of orphaned repair beads found in a live sweep).

Run this block VERBATIM, before Step 0 — the claim must land even if Step 0
immediately drops the PR, because the worker IS actively evaluating the bead
from this point on:

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
CV_LIB="$(find "${GC_CITY}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
if [ -n "$CV_LIB" ] && [ -f "$CV_LIB" ]; then
  # shellcheck disable=SC1090
  source "$CV_LIB"
  cv_bead_mark_in_progress "{{repair_bead}}"
else
  echo "con-voyage-lib.sh not found — skipping repair-bead in_progress marker (non-fatal)" >&2
fi
```

## Step 0 — Author gate (fail-closed by default, toggle-able)

Before touching anything else — before even reading the bead — verify this PR
is actually owned by the operator. A `con-voyage-ci-repair` bead can be minted
for ANY PR by the native PR monitor (`--create-repair-beads` has no author
filter), by `con-voyage-pr-watch.sh`, or by a manual mis-sling. This gate is
what makes it safe for you to act on the bead at all; it re-checks the same
invariant the `con-voyage-ci-repair-guard` order already swept for, in case
that sweep lost a claim race with you.

**Feature toggle — `cv_author_gate` (default `enabled`).** This gate is behind a
toggle so the pack can also run in native `[[github.pr_monitor]]` "work all PRs"
mode. The default is `enabled` (the fail-closed scoping below) and MUST stay the
default in this city — a deliberate divergence from the native monitor, because
an earlier unfiltered version acted on PRs it did not own and got the operator
removed from an org. Set `cv_author_gate=disabled` to explicitly opt in to
working every PR regardless of author. The bash block below reads this toggle
first: when it is exactly `disabled` (case-insensitive) the gate is skipped and
you continue straight to Step 1. `disabled` is the ONLY thing that bypasses the
gate — an empty/unresolved `CV_PR_AUTHOR` under the enabled gate still DROPS,
never "works all".

The comparison rule (this is the *why* — the bash block below enforces it, do
not re-derive it by hand): compare `pr_author` to `CV_PR_AUTHOR` using an EXACT,
case-sensitive match, and treat an empty/unresolved value on EITHER side as a
mismatch — fail closed, never guess.

- `pr_author` is empty/unresolved → not verifiably the operator's PR. Drop.
- `CV_PR_AUTHOR` is empty/unresolved → identity cannot be verified. Drop.
- `pr_author != CV_PR_AUTHOR` (any case difference counts as a mismatch) → Drop.

**If it does not match, take ZERO further action** — no `gh run rerun`, no
`git checkout`/`commit`/`push`, no `gh pr comment`/`review`. The block below
closes the bead and `exit 0`s instead of continuing to Step 1.

Run this block VERBATIM. It resolves the identities, then makes the gate
decision as a deterministic conditional (not a judgement call you re-derive):

```bash
# FEATURE TOGGLE — author gate on/off. Default enabled (fail-closed scoping).
# Exact literal "disabled" (case-insensitive) is the ONLY value that turns the
# gate off; anything else (including a typo or empty string) stays enabled so an
# accidental value can never silently open the gate. When disabled, skip the
# whole gate and fall through to Step 1 — work this PR regardless of author.
CV_AUTHOR_GATE="{{cv_author_gate}}"
gate_lc="$(printf '%s' "$CV_AUTHOR_GATE" | tr '[:upper:]' '[:lower:]')"
if [ "$gate_lc" = "disabled" ]; then
  echo "ci-repair Step 0: author gate DISABLED (cv_author_gate=disabled) — working this PR regardless of author (native-parity opt-in)"
else
  CV_PR_AUTHOR="{{cv_pr_author}}"
  if [[ "$CV_PR_AUTHOR" =~ ^[[:space:]]*$ ]]; then
    CV_PR_AUTHOR="$(gh api user --jq .login 2>/dev/null || true)"
  fi

  # {{pr}} must be a GitHub PR number. Refuse to interpolate anything else into
  # the command substitution below — fail closed rather than run a shell with an
  # unexpected value.
  pr="{{pr}}"
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    gc bd update "{{convoy_id}}" \
      --notes "dropped: not authored by operator (invalid pr='${pr}', expected a numeric PR id)"
    gc bd close "{{convoy_id}}" --reason "dropped: not authored by operator"
    GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
    CV_LIB="$(find "${GC_CITY}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
    [ -n "$CV_LIB" ] && [ -f "$CV_LIB" ] && source "$CV_LIB" \
      && cv_bead_close "{{repair_bead}}" abandoned "dropped: not authored by operator (invalid pr)"
    exit 0
  fi

  pr_author="$(gh pr view "$pr" --repo "{{repo}}" --json author --jq '.author.login' 2>/dev/null || echo "")"

  # EXACT, case-sensitive gate. Empty/whitespace on EITHER side is a mismatch.
  if [[ "$pr_author" =~ ^[[:space:]]*$ ]] || [[ "$CV_PR_AUTHOR" =~ ^[[:space:]]*$ ]] || [ "$pr_author" != "$CV_PR_AUTHOR" ]; then
    gc bd update "{{convoy_id}}" \
      --notes "dropped: not authored by operator (pr_author='${pr_author:-<unresolved>}', CV_PR_AUTHOR='${CV_PR_AUTHOR:-<unresolved>}')"
    gc bd close "{{convoy_id}}" --reason "dropped: not authored by operator"
    GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
    CV_LIB="$(find "${GC_CITY}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
    [ -n "$CV_LIB" ] && [ -f "$CV_LIB" ] && source "$CV_LIB" \
      && cv_bead_close "{{repair_bead}}" abandoned "dropped: not authored by operator (author mismatch)"
    exit 0
  fi
fi
```

Only continue to Step 1 when the block above did NOT exit — i.e. `pr_author`
exactly matches `CV_PR_AUTHOR`.

## Step 0b — Review-required self-gate (defense in depth)

The monitor (`con-voyage-pr-watch.sh`) already refuses to mint a repair bead
for a PR that is only awaiting human review — its ACTIONABLE FILTER treats a
PR as non-actionable when all CI checks are green/neutral, the PR is
`MERGEABLE`, the branch is up to date with base, and the only outstanding
blocker is `reviewDecision=REVIEW_REQUIRED`. This step re-verifies that same
condition independently, in case this bead reached you through a path the
monitor does not control — the native `[[github.pr_monitor]]`
`--create-repair-beads` (which has no such filter), a manual sling, or a bead
minted before this gate existed.

con-voyage PRs never auto-merge, so a PR with every real defect already
resolved ends in `reviewDecision=REVIEW_REQUIRED` forever — that is a human
already in the loop, not something a machine can fix. The correct action is
to close quietly and take no GitHub action at all: no `gh run rerun`, no
commit/push, and — unlike every other escalation path in this workflow — **no
PR comment and no escalation mail**. Commenting or mailing here would just be
recurring noise on a PR that is working exactly as intended (the live
incident this gate exists to prevent: a repair bead escalated repeatedly on
kriscoleman/foundry#10494 — 48/48 checks green, MERGEABLE, blocked solely on
REVIEW_REQUIRED — for something no machine could ever satisfy).

Only relevant when `{{failure_kind}}` is `blocked` — `checks_failed`,
`merge_conflict`, and `behind_base` already mean a real defect exists, and
review state must never suppress a real defect.

Run this block VERBATIM. It resolves the live review/mergeability signals,
then makes the gate decision as a deterministic conditional (not a judgement
call you re-derive):

```bash
FAILURE_KIND="{{failure_kind}}"
if [ "$FAILURE_KIND" = "blocked" ]; then
  gate_json="$(gh pr view {{pr}} --repo {{repo}} \
    --json reviewDecision,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null || echo "")"
  skip_awaiting_human="$(printf '%s' "$gate_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
review_decision = d.get('reviewDecision', '') or ''
mergeable = d.get('mergeable', '') or ''
merge_state_status = d.get('mergeStateStatus', '') or ''
checks = d.get('statusCheckRollup') or []
def is_green(c):
    conclusion = c.get('conclusion')
    if conclusion is not None:
        return str(conclusion).upper() in ('SUCCESS', 'NEUTRAL', 'SKIPPED')
    state = c.get('state')
    if state is not None:
        return str(state).upper() == 'SUCCESS'
    return False
checks_green = all(is_green(c) for c in checks)
skip = (
    review_decision == 'REVIEW_REQUIRED'
    and mergeable == 'MERGEABLE'
    and merge_state_status != 'BEHIND'
    and checks_green
)
print('1' if skip else '0')
" 2>/dev/null || echo "0")"

  if [ "$skip_awaiting_human" = "1" ]; then
    gc bd update "{{convoy_id}}" \
      --notes "not actionable: awaiting human review only (CI green, MERGEABLE, branch up to date, reviewDecision=REVIEW_REQUIRED) — no machine action taken, no PR comment posted"
    gc bd close "{{convoy_id}}"
    GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
    CV_LIB="$(find "${GC_CITY}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
    [ -n "$CV_LIB" ] && [ -f "$CV_LIB" ] && source "$CV_LIB" \
      && cv_bead_close "{{repair_bead}}" no-op "awaiting human review only — no machine action taken"
    exit 0
  fi
fi
```

Only continue to Step 1 when the block above did NOT exit. Do NOT post a PR
comment or send an escalation mail for this specific case — there is nothing
wrong to report, and a human is already in the loop by definition. This is the
ONE case in this workflow where you close silently; every other
failure/escalation path elsewhere in this file still comments or mails as
documented there.

## Step 1 — Read the repair bead

```bash
gc bd show "{{convoy_id}}"
```

The bead title and description list the failing checks and failure kind
(checks_failed, merge_conflict, behind_base, or blocked). Read it carefully.

## Step 2 — Fetch the exact failing checks

```bash
# List all CI checks for this PR (shows each check's run and status):
gh pr checks {{pr}} --repo {{repo}}

# Resolve the failing run id(s) for the PR head commit:
gh pr view {{pr}} --repo {{repo}} --json headRefOid --jq .headRefOid
gh api "repos/{{repo}}/commits/<head-sha>/check-runs" \
  --jq '.check_runs[] | select(.conclusion=="failure") | {name, run_id: .id, url: .html_url}'
# Or list recent workflow runs for the branch:
gh run list --repo {{repo}} --branch {{branch}}

# For any failed run, fetch the logs:
gh run view <run-id> --repo {{repo}} --log-failed
```

Understand WHAT is failing and WHY before touching any code. Do not guess.

### When the failure is a flake / infra blip (NOT a code problem)

Sometimes CI fails for a reason that is NOT a code defect — a transient network
error, a runner outage, a timed-out dependency download, a known-flaky job. In
that case there is nothing to fix in the code; you just need to re-run CI.

**Re-run CI the smart, non-destructive way — use the gh CLI:**

```bash
# PREFERRED: re-run ONLY the failed jobs of a run (cheapest, least noisy):
gh run rerun <run-id> --failed --repo {{repo}}

# Full re-run of a workflow run (use only if a partial re-run isn't enough):
gh run rerun <run-id> --repo {{repo}}
```

Find `<run-id>` via `gh pr checks {{pr}}`, the `check-runs` API, or
`gh run list` as shown above. Always prefer `--failed` (re-run failed jobs
only) over a full re-run.

### FORBIDDEN retrigger tactics — never do these

An earlier version of this repair path retriggered CI destructively and got the
operator in trouble. The following are STRICTLY FORBIDDEN — do NOT do any of
them, ever, for any reason:

- **Do NOT close and reopen the PR** to retrigger CI.
- **Do NOT push an empty commit** (`git commit --allow-empty`) or any no-op /
  whitespace-only / "trigger ci" commit to retrigger CI.
- **Do NOT force-push** solely to retrigger CI.
- **Do NOT amend/reword or re-push existing commits** just to kick a new run.

Only push a commit when you have an ACTUAL code fix (see Step 6). If there is no
code change to make, use `gh run rerun` — never a commit and never PR
open/close churn. If `gh run rerun` is not available or you lack permission,
escalate (see Failure / escalation) rather than resorting to any forbidden
tactic.

## MANDATORY — machine identity on every PR comment/review (STRUCTURAL)

You run under the operator's GitHub PAT. Any comment or review you post shows
up as **@kriscoleman** (the human) — so anything you write WITHOUT a machine
banner is an impersonation of Kris. This is a trust/security problem and it is
NOT allowed.

**Rule (mandatory, no exceptions, structurally enforced):** this is no longer
prose you have to remember — it is enforced by a script. The ONLY supported
way to post any text to this PR or issue is `cv-pr-comment.sh`. It
unconditionally prepends the identity banner as the first line of whatever you
post, so the banner can no longer be forgotten:

```
🤖 **Automated con-voyage agent** (con-voyage-ci-repair / <rig>/<agent>)
```

### FORBIDDEN commenting tactics — never do these

- **Do NOT run raw `gh pr comment`** for any reason, in this workflow.
- **Do NOT run raw `gh pr review`** (`--comment`, `--approve`, or
  `--request-changes`) for any reason, in this workflow.
- **Do NOT run raw `gh api ... /replies`** (or any raw `gh` call) to reply to an
  inline review-thread comment. Threaded replies go through
  `cv-pr-comment.sh reply-thread` (below) so the banner is still guaranteed.
- **Do NOT hand-assemble the banner string yourself and pass it via
  `gh ... --body`.** Always go through `cv-pr-comment.sh` so the banner is
  guaranteed by the script, not typed from memory.

Locate and use the script:

```bash
CV_BIN="$(command -v cv-pr-comment.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-pr-comment.sh 2>/dev/null | head -1)"
if [ -z "$CV_BIN" ] || [ ! -x "$CV_BIN" ]; then
  echo "cv-pr-comment.sh not found — refusing to post without the banner (do NOT fall back to raw gh pr comment/review)" >&2
  exit 1
fi
printf '%s\n' "<your comment text>" > /tmp/cv-comment-body.md
"$CV_BIN" comment {{pr}} --repo {{repo}} --body-file /tmp/cv-comment-body.md \
  --formula con-voyage-ci-repair --agent "<rig>/<agent>"
# For a review instead of a plain comment, swap the subcommand:
"$CV_BIN" review {{pr}} --repo {{repo}} --comment --body-file /tmp/cv-comment-body.md \
  --formula con-voyage-ci-repair --agent "<rig>/<agent>"
```

Substitute your actual rig and agent handle for `<rig>/<agent>` (the same
identity the con-voyage reviewers use in their `[<rig>/<agent> — <lens>]`
prefix). If you cannot resolve them, omit `--agent` — the script still posts,
with a clear self-identification fallback. Never post a bare comment as if a
human wrote it, and never find a way around the script to do so.

#### Root comment vs. threaded reply — pick the right one

Where a reply LANDS matters as much as the banner:

- **General / summary feedback** (a top-level review, a whole-PR remark, an
  overall status update) → post at ROOT with `cv-pr-comment.sh comment`
  (or `review`), exactly as above.
- **Addressing one specific INLINE review-thread comment** → reply INSIDE that
  thread with `cv-pr-comment.sh reply-thread`, so your answer lands in the same
  conversation the reviewer opened — not as a disconnected new root comment.

When `con-voyage-pr-watch.sh` routes inline review-thread feedback to you, it
names the reply target per item as
`[reply-thread comment-id:<db_id> @ <path>:<line>]`. Use that `<db_id>` (the
review comment's numeric DATABASE id) as `--comment-id`:

```bash
printf '%s\n' "<your reply text>" > /tmp/cv-reply-body.md
"$CV_BIN" reply-thread {{pr}} --repo {{repo}} --comment-id <db_id> \
  --body-file /tmp/cv-reply-body.md \
  --formula con-voyage-ci-repair --agent "<rig>/<agent>"
```

`reply-thread` posts via the review-comment replies API and still prepends the
identity banner. Root-level comments are for general/summary; a reply to a
specific inline comment must be a thread reply.

Note: this repair pass is normally SILENT on the PR — it pushes a code fix and
lets the monitor re-evaluate. You generally do NOT need to comment. But IF you
ever post a diagnosis comment, a review, or any other PR/issue text, it MUST go
through `cv-pr-comment.sh` as shown above. When in doubt, do not comment; push
the fix.

## Step 3 — Check out the PR branch

Work in the rig root. Fetch the branch and create a local tracking ref:

<!-- FOLLOW-UP (noted, not fixed — out of scope for fk-4xq): every {{branch}}
     interpolation in this file (here and in Steps 4/6/7 below) is unquoted in
     its shell command example. GitHub branch names can't contain spaces, but
     can contain other shell-meaningful characters; quoting "{{branch}}"
     everywhere would be the safer default. Left as-is per fk-4xq's scope
     (BLOCKING-1/2 + LOW-1/2 only) — file separately if this needs hardening. -->

```bash
git fetch origin {{branch}}
git checkout {{branch}}
# Verify you are on the right branch:
git branch --show-current
```

If your worktree already has a local checkout of this branch, pull latest:

```bash
git pull --rebase origin {{branch}}
```

Do NOT create a new branch. Do NOT work on main or any other branch.

### Artifact hygiene — prep this working copy before editing anything

This working copy must never commit con-voyage's own local tooling state
upstream. Before touching any files, write the hygiene excludes:

```bash
CV_PREP="$(command -v cv-worktree-prep.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-worktree-prep.sh 2>/dev/null | head -1)"
[ -n "$CV_PREP" ] && [ -x "$CV_PREP" ] && "$CV_PREP" exclude "$(pwd)"
```

This writes `.beads/`, `.gc/`, `.claude/`, and dolt data paths into this
clone's LOCAL `.git/info/exclude` (never the tracked `.gitignore`) so a
routine `git add` can never scoop them up. Local only — nothing is ever
committed upstream because of this step.

## Step 4 — Fix based on `{{failure_kind}}`

The bead's `{{failure_kind}}` var already carries PART A's classification —
one of `checks_failed`, `merge_conflict`, `behind_base`, or `blocked`. Branch
on it directly; do not re-derive it from the failing-checks list yourself
(that was PART A's job, and re-guessing risks disagreeing with the bead you
were handed). The `merge_conflict` (4b) and `behind_base` (4c) paths ALSO
depend on `{{cv_conflict_strategy}}` (default `rebase`) — read that section's
own instructions for how to branch on it. Resolve the PR's real base branch
once, up front — every sub-path below that rebases uses it:

```bash
base_ref="$(gh pr view {{pr}} --repo {{repo}} --json baseRefName --jq .baseRefName)"
```

### 4a. `checks_failed` — fix or rerun (unchanged)

For each failing check:

1. Write or update the test that exposes the failure (if applicable).
2. Run the test and confirm it fails for the right reason.
3. Fix the production code.
4. Run the test again and confirm it passes.
5. Run the full test suite and any lint checks relevant to the failure.

Continue to **Step 5 (Verify locally)** and **Step 6 (Commit and push)**.

### 4b. `merge_conflict` — auto-resolve, WITH guardrails

**Scope note:** this only ever runs on an operator-authored, author-gated PR —
Step 0 already verified that. Automated conflict resolution is normally
dangerous (a silently-wrong merge can look clean, and even pass tests, while
dropping or mismerging changes), so the guardrails below exist to make this
auditable — they are not optional decoration.

**Conflict/branch-update strategy — `{{cv_conflict_strategy}}`.** This bead's
`cv_conflict_strategy` var selects one of the two sub-paths below. Read it
before doing anything else in this section — do not guess or default to
whichever sub-path seems more familiar.

#### 4b Strategy: `rebase` (DEFAULT — linear history, never a merge commit)

Use this sub-path when `{{cv_conflict_strategy}}` is `rebase` or is
unset/empty. This is the operator's TOP REQUIREMENT: linear history, always —
never a merge commit.

```bash
git fetch origin
git rebase "origin/${base_ref}"
# Resolve conflicts, then:
git rebase --continue
```

After the rebase completes and conflicts are resolved:

1. Run the full test suite and lint (the same commands as Step 5) before
   pushing. Do not push if anything fails.
2. Push the resolved branch. A rebase always creates new commit objects, so
   this requires a force-push — use `--force-with-lease` (never a bare
   `--force`), and only ever on this PR's own branch:
   ```bash
   git push --force-with-lease origin {{branch}}
   ```
3. **Surface a human-readable summary of the resolution** — which files
   conflicted and what the resolution did — as BOTH a machine-bannered PR
   comment (see the MANDATORY identity banner above) and the bead close note
   in Step 7. This is not optional: it is what lets a human audit an
   automated conflict resolution before trusting it.
4. **NEVER merge, NEVER approve, NEVER submit to the merge queue.** Push to
   the PR branch only — the same bright line as every other path here.

Under this (default) strategy, `git merge origin/<base>` and `gh pr
update-branch` are FORBIDDEN for this repair — either would create a merge
commit and break the linear-history requirement.

#### 4b Strategy: `merge` (EXPLICIT OPT-IN ONLY — never the default)

Use this sub-path ONLY when `{{cv_conflict_strategy}}` is EXACTLY `merge`.
This is for other targets that prefer merge commits over rebase; it is not the
default anywhere in this city.

```bash
git fetch origin
git merge "origin/${base_ref}"
# Resolve conflicts, then:
git add <resolved files>
git commit
```

After the merge completes and conflicts are resolved:

1. Run the full test suite and lint (the same commands as Step 5) before
   pushing. Do not push if anything fails.
2. Push the branch. The merge commit fast-forwards from the branch's own
   prior head, so a plain push suffices — no force-push is needed:
   ```bash
   git push origin {{branch}}
   ```
3. **Surface a human-readable summary of the resolution** — same requirement
   as the rebase sub-path above: a machine-bannered PR comment and the bead
   close note in Step 7.
4. **Never submit this PR to the merge queue, never approve it, and never
   close it as merged.** Creating a merge commit ON THE BRANCH to reconcile
   with base is not the same as merging the PR itself — the PR always stays
   open for a human to land.

Skip Step 6 (its plain-push form doesn't fit either sub-path above) and close
the bead (Step 7) directly, using the resolution summary as the close note.

### 4c. `behind_base` — branch update per `{{cv_conflict_strategy}}`

**Conflict/branch-update strategy — `{{cv_conflict_strategy}}`.** Same knob as
4b, same rule: read it before doing anything else in this section.

#### 4c Strategy: `rebase` (DEFAULT — linear history, never a merge commit)

Use this sub-path when `{{cv_conflict_strategy}}` is `rebase` or is
unset/empty.

```bash
git fetch origin
git rebase "origin/${base_ref}"
```

Run the full test suite and lint (Step 5's commands) before pushing, then push
with `--force-with-lease` — never a bare `--force`:

```bash
git push --force-with-lease origin {{branch}}
```

**Reconciling this with Step 2's forbidden tactics:** Step 2 forbids
force-pushing to *retrigger CI* — that rule targets kicking a new run on an
otherwise-unchanged commit, which is pure destructive churn. This is
different: a `behind_base` rebase is a legitimate content change (replaying
the branch onto a newer base) on the operator's own author-gated branch, and
rebasing inherently rewrites history, so updating the remote requires a
force-push. `--force-with-lease` (never bare `--force`) is permitted here — it
is not the forbidden CI-kick tactic Step 2 describes.

Under this (default) strategy, `gh pr update-branch` and a manual `git merge`
are FORBIDDEN for this repair — either would create a merge commit and break
the linear-history requirement.

#### 4c Strategy: `merge` (EXPLICIT OPT-IN ONLY — never the default)

Use this sub-path ONLY when `{{cv_conflict_strategy}}` is EXACTLY `merge`.

```bash
gh pr update-branch {{pr}} --repo {{repo}}
```

This is GitHub's native "Update branch" action: it merges the base branch
into the PR branch and pushes the result automatically — no manual `git
merge`, no force-push. If it is unavailable or fails, escalate (see Failure /
escalation) rather than reaching for a manual force-push.

Skip Step 6 and close the bead (Step 7) directly (either sub-path above).

### 4d. `blocked` — router, not a single action

`blocked` is heterogeneous — read the PR's actual signals before acting:

```bash
gh pr view {{pr}} --repo {{repo}} \
  --json statusCheckRollup,mergeStateStatus,reviewDecision
```

- **A required check is actually failing** → this is really failing-CI.
  Handle it as 4a (fix, or `gh run rerun --failed`). PART A's classifier
  already prefers `checks_failed` when any check has failed, so you should
  rarely land here for this reason — treat it as a defense-in-depth
  re-check, not the expected case.
- **Only pending checks, none failed** → **wait, no-op this cycle.** Do not
  rerun a still-running check and do not mint any churn. Close the bead
  (Step 7) noting it is waiting on pending checks — the next backfill cycle
  re-evaluates the PR.
- **`mergeStateStatus` is `BEHIND`** → handle as 4c (rebase +
  `--force-with-lease`).
- **`reviewDecision` is `REVIEW_REQUIRED` or `CHANGES_REQUESTED`, or any other
  branch-protection rule (CODEOWNERS, required signatures, admin enforcement,
  unresolved conversations)** → **take ZERO mutating action.** Post one
  machine-bannered PR comment describing the block, and escalate:
  ```bash
  gc mail send {{escalation_target}} \
    -s "CI repair blocked (branch protection): {{repo}}#{{pr}}" \
    -m "Repair bead {{convoy_id}} is blocked by branch protection ({{repo}}#{{pr}}, branch {{branch}}) and needs a human decision. A machine cannot satisfy review or protection requirements."
  ```
  **Never self-approve. Never bypass branch protection. Never guess** at what
  would satisfy the block.

Whichever sub-path applies, close the bead (Step 7) as that sub-path directs.
Only the reclassified-as-4a sub-path continues through Steps 5-6 normally.

## Step 5 — Verify locally

Applies to the `checks_failed` (4a) path. (`merge_conflict` and `behind_base`
already ran their own verify-before-push above.)

Run the full test suite and linter:

```bash
# Adjust these commands to match the project's toolchain:
go test ./...         # for Go projects
npm test              # for Node projects
make test             # if a Makefile target exists
```

Also run lint:

```bash
golangci-lint run     # for Go projects
npm run lint          # for Node projects
make lint             # if a Makefile target exists
```

Do not push if any test or lint check fails.

## Step 6 — Commit and push

Applies to the `checks_failed` (4a) path only. `merge_conflict` and
`behind_base` push directly from Step 4 — a rebase has no new work-in-progress
change to stage as a fresh commit — and go straight to Step 7.

Commit only the changes that fix the CI failure. Commit ONLY when there is a
real code fix — never an empty/no-op commit and never a commit whose sole
purpose is to retrigger CI (for that, use `gh run rerun` from Step 2):

```bash
git add -p   # stage only relevant changes
```

Run the artifact-hygiene guard before committing. It fails loud (non-zero
exit) and unstages anything it safely can if a hygiene path (`.beads/`,
`.gc/`, `.claude/`, dolt data) ends up staged, or is committed AND was added
by this branch relative to its base — do not commit until it reports clean.
Pass this PR's base branch as the 3rd arg so a hygiene path the repo
legitimately tracks upstream (e.g. `.claude/`) is not a false positive; if the
base lookup comes up empty the guard auto-derives it (origin/HEAD → origin/main
→ main) and, failing that, fails safe:

```bash
CV_GUARD="$(command -v cv-worktree-prep.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-worktree-prep.sh 2>/dev/null | head -1)"
if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
  guard_base="$(gh pr view {{pr}} --repo {{repo}} --json baseRefName --jq .baseRefName 2>/dev/null || true)"
  "$CV_GUARD" guard "$(pwd)" "${guard_base:+origin/${guard_base}}" || { echo "fix the reported hygiene violation, re-stage, and re-run the guard before committing" >&2; exit 1; }
fi
```

```bash
git commit -m "fix: <brief description of CI fix> (repair {{convoy_id}})"
```

Push to the PR branch:

```bash
git push origin {{branch}}
```

**NEVER push to main, NEVER merge, NEVER approve, NEVER submit to any merge
queue.** The PR stays open. A human lands it.

## Step 7 — Close the repair bead

This is the shared close point for every non-drop, non-blocked path above: 4a
(fix pushed), 4b/4c (conflict/behind-base resolved), and 4d's pending-checks
wait and branch-protection escalation. Pick the outcome that matches what
actually happened this cycle — do not default to `landed` for a no-op or
escalated cycle:

- `landed` — a fix was pushed (4a), or a conflict/behind-base rebase resolved
  and pushed (4b/4c).
- `no-op` — 4d's pending-checks wait: nothing changed this cycle.
- `abandoned` — 4d's branch-protection escalation: the machine could not
  satisfy the block and mailed a human instead.

```bash
gc bd update "{{convoy_id}}" \
  --notes "CI repair pushed to {{branch}}: <one-line summary of fix>"
gc bd close "{{convoy_id}}"
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
CV_LIB="$(find "${GC_CITY}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
[ -n "$CV_LIB" ] && [ -f "$CV_LIB" ] && source "$CV_LIB" \
  && cv_bead_close "{{repair_bead}}" <landed|no-op|abandoned> "<one-line summary of fix, or the 4d reason>"
```

## Failure / escalation

If you cannot fix the failure (blocked on external service, ambiguous
requirements, or the fix requires a human decision):

```bash
gc mail send {{escalation_target}} \
  -s "CI repair blocked: {{repo}}#{{pr}}" \
  -m "Repair bead {{convoy_id}} is stuck. Reason: <brief explanation>. Branch: {{branch}}."
gc bd close "{{convoy_id}}" --reason "abandoned: escalated to {{escalation_target}} — <brief explanation>"
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
CV_LIB="$(find "${GC_CITY}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
[ -n "$CV_LIB" ] && [ -f "$CV_LIB" ] && source "$CV_LIB" \
  && cv_bead_close "{{repair_bead}}" abandoned "escalated to {{escalation_target}} — <brief explanation>"
gc runtime drain-ack
exit 1
```

Do not spin indefinitely. If three attempts at a step do not make progress,
escalate and exit.

Do not invoke provider-native subagents. This is a single focused repair pass.
