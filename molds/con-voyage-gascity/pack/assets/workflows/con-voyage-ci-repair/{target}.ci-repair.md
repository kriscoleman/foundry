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
# List all CI checks for this PR:
gh pr checks {{pr}} --repo {{repo}}

# For any failed run, fetch the logs:
gh run view <run-id> --repo {{repo}} --log-failed
```

Understand WHAT is failing and WHY before touching any code. Do not guess.

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

Commit only the changes that fix the CI failure:

```bash
git add -p   # stage only relevant changes
git commit -m "fix: <brief description of CI fix> (repair {{convoy_id}})"
```

Push to the PR branch:

```bash
git push origin {{branch}}
```

**NEVER push to main, NEVER merge, NEVER submit to any merge queue.**
The PR stays open. A human lands it.

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
