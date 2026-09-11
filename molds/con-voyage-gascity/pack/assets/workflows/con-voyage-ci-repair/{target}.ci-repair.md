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
| title     | {{title}}          |

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

## MANDATORY — machine identity on every PR comment/review

You run under the operator's GitHub PAT. Any comment or review you post shows
up as **@kriscoleman** (the human) — so anything you write WITHOUT a machine
banner is an impersonation of Kris. This is a trust/security problem and it is
NOT allowed.

**Rule (mandatory, no exceptions):** every `gh pr comment`, `gh pr review`,
`gh pr review --comment/--approve/--request-changes` body — any text you post
to a PR or issue — MUST lead with this identity banner as the FIRST line of the
body:

```
🤖 **Automated con-voyage agent** (con-voyage-ci-repair / <rig>/<agent>) — posted via @kriscoleman's token, not by Kris personally.
```

Substitute your actual rig and agent handle for `<rig>/<agent>` (the same
identity the con-voyage reviewers use in their `[<rig>/<agent> — <lens>]`
prefix). If you cannot resolve them, still post the banner with a clear
`con-voyage-ci-repair` self-identification. Never post a bare comment as if a
human wrote it.

Note: this repair pass is normally SILENT on the PR — it pushes a code fix and
lets the monitor re-evaluate. You generally do NOT need to comment. But IF you
ever post a diagnosis comment, a review, or any other PR/issue text, the banner
above is required. When in doubt, do not comment; push the fix.

## Step 3 — Check out the PR branch

Work in the rig root. Fetch the branch and create a local tracking ref:

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

## Step 4 — Fix using TDD

For each failing check:

1. Write or update the test that exposes the failure (if applicable).
2. Run the test and confirm it fails for the right reason.
3. Fix the production code.
4. Run the test again and confirm it passes.
5. Run the full test suite and any lint checks relevant to the failure.

If the failure is a **merge conflict** (failure_kind=merge_conflict):

```bash
git fetch origin
git rebase origin/main   # or origin/<base_branch>
# Resolve conflicts, then:
git rebase --continue
```

If the failure is **behind_base** (branch needs updating):

```bash
git fetch origin
git rebase origin/main   # or origin/<base_branch>
```

If the failure is **blocked** (branch-protection rule violated), read the
GitHub error from `gh pr view {{pr}} --repo {{repo}} --json statusCheckRollup`
to understand which protection is triggered, then fix the underlying issue.

## Step 5 — Verify locally

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

Commit only the changes that fix the CI failure. Commit ONLY when there is a
real code fix — never an empty/no-op commit and never a commit whose sole
purpose is to retrigger CI (for that, use `gh run rerun` from Step 2):

```bash
git add -p   # stage only relevant changes
git commit -m "fix: <brief description of CI fix> (repair {{convoy_id}})"
```

Push to the PR branch:

```bash
git push origin {{branch}}
```

**NEVER push to main, NEVER merge, NEVER approve, NEVER submit to any merge
queue.** The PR stays open. A human lands it.

## Step 7 — Close the repair bead

```bash
gc bd update "{{convoy_id}}" \
  --notes "CI repair pushed to {{branch}}: <one-line summary of fix>"
gc bd close "{{convoy_id}}"
```

## Failure / escalation

If you cannot fix the failure (blocked on external service, ambiguous
requirements, or the fix requires a human decision):

```bash
gc mail send {{escalation_target}} \
  -s "CI repair blocked: {{repo}}#{{pr}}" \
  -m "Repair bead {{convoy_id}} is stuck. Reason: <brief explanation>. Branch: {{branch}}."
gc runtime drain-ack
exit 1
```

Do not spin indefinitely. If three attempts at a step do not make progress,
escalate and exit.

Do not invoke provider-native subagents. This is a single focused repair pass.
