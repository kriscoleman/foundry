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
| cv_pr_author | {{cv_pr_author}} |
| cv_author_gate | {{cv_author_gate}} |

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
    exit 0
  fi

  pr_author="$(gh pr view "$pr" --repo "{{repo}}" --json author --jq '.author.login' 2>/dev/null || echo "")"

  # EXACT, case-sensitive gate. Empty/whitespace on EITHER side is a mismatch.
  if [[ "$pr_author" =~ ^[[:space:]]*$ ]] || [[ "$CV_PR_AUTHOR" =~ ^[[:space:]]*$ ]] || [ "$pr_author" != "$CV_PR_AUTHOR" ]; then
    gc bd update "{{convoy_id}}" \
      --notes "dropped: not authored by operator (pr_author='${pr_author:-<unresolved>}', CV_PR_AUTHOR='${CV_PR_AUTHOR:-<unresolved>}')"
    gc bd close "{{convoy_id}}" --reason "dropped: not authored by operator"
    exit 0
  fi
fi
```

Only continue to Step 1 when the block above did NOT exit — i.e. `pr_author`
exactly matches `CV_PR_AUTHOR`.

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
