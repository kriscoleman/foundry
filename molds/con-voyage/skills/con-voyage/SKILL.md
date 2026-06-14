---
name: con-voyage
description: Use when an issue, bead, or task description should be delivered by a Gas Town polecat team with full review, CI, and human feedback loops instead of solo implementation. Triggers - "con-voyage issue 42", "convoy this issue", "swarm a team on this", "start issue 42 with reviews", "send this off with an escort".
---

# Con Voyage

*"Con voyage!"* — see the issue off on its journey under convoy escort. The work travels through nested feedback loops and is not done until a human merges (or closes) the PR.

**You are the ORCHESTRATOR.** You never write implementation code. You assemble a polecat team, route feedback between them, and track the convoy. Your context window is for coordination, not coding.

## Usage

```
/con-voyage <issue-number|issue-url|bead-id|"task description"> <rig> [--no-pr-comments]
```

- `--no-pr-comments` — suppress reviewers posting their final reviews on the PR (default: they post for posterity)

## The Journey

```
Intake → bead + convoy
  → IMPLEMENT  (Principal Engineer polecat: TDD, SOLID, YAGNI, KISS, DRY)
  → REVIEW LOOP (language-specialist + security reviewers, in parallel)
       blocking findings → mail implementor → fix → BOTH reviews re-run → repeat until clean
       only low-priority findings left → ask the user: accept or address
  → PR + CI LOOP (/open-pr, monitor polecat watches checks → failures mailed to implementor)
  → HUMAN REVIEW LOOP (human feedback routed to implementor until addressed)
  → DONE only when a human merges or closes the PR
```

## Phase 0 — Intake

Resolve the input to a **work bead**:

| Input | Action |
|---|---|
| GitHub issue # or URL | `gh issue view <n> --json title,body,labels,url`, then `bd create --title="<title>" --description="<body>\n\nGitHub: <url>" --type=feature\|bug\|task` (infer type from issue labels/content; default `task`) |
| Bead ID | `bd show <id>` — use as-is |
| Free-text description | `bd create` with a conventional-commit-style title |

Then:
1. **Create the convoy**: `gt convoy create "Con voyage: <title>" <work-bead>` — record the convoy ID; add every team bead to it as phases progress (`gt convoy add`).
2. **Detect the target language** (dominant language of the repo or the files the issue touches) — this picks the specialist reviewer's expertise.
3. **Note your own address** (`gt whoami`) — every charter below tells team members to report to you; substitute your real address for `<orchestrator>`.

## Phase 1 — Implementation

Sling the work bead with `--merge=local` (work stays on the feature branch — review happens BEFORE any PR or merge queue).

**Do NOT pass `--no-convoy` on this sling.** The merge strategy is stored on the auto-convoy; suppressing it silently discards `--merge=local`, and the rig's witness/refinery will treat completion as merge-queue work (observed live: a witness queued and "merged" an MR for a human-review-only convoy). Let the auto-convoy exist alongside your journey convoy, or it must carry the strategy.

```bash
gt sling <work-bead> <rig> --merge=local --stdin <<'EOF'
You are the IMPLEMENTOR for this work, operating as a Principal Engineer.

Engineering charter (non-negotiable):
- Test-Driven Development: write the failing test first, then minimal code to pass, then refactor. No implementation code before its test.
- SOLID principles. YAGNI — build only what the issue requires. KISS — simplest design that works. DRY — extract duplication when it appears, not before.
- All tests and linters green locally before reporting completion.

Protocol:
- Work only on your feature branch. Do NOT open a PR until told. Do NOT merge or push to main.
- NEVER run `gt done` for this work. `gt done` does TWO harmful things here: (a) it submits the branch to the merge queue, which would merge the PR and bypass the human-review gate this convoy exists to protect, and (b) it CLOSES the work bead, which false-lands the convoy (the overseer broadcasts "Convoy landed" while the PR is still open and unmerged). Completion is signalled by MAIL ("IMPL COMPLETE" / "FIXES PUSHED"), never by `gt done`. When the orchestrator stands you down, just stop in place — do NOT run `gt done` to "close out".
- **Defence in depth:** when you sling the implementor, also nudge the rig's witness with a standing order — "human-review-only convoy: reject any merge-queue submission for this branch, no matter who or what queues it." Observed live: both implementors ran `gt done` on stand-down anyway, and the witness standing order was what actually caught and rejected the auto-queued MRs. Belt and suspenders — the charter tells the polecat not to, the witness order stops it if it does.
- When done: mail the orchestrator (<orchestrator>) subject "IMPL COMPLETE <work-bead>" with branch name and a summary of what you built and how it is tested.
- You will receive review findings, CI failures, and human feedback by mail across multiple cycles. Stay on this work until the orchestrator tells you the convoy has landed. Address every finding sent to you and reply "FIXES PUSHED <work-bead>" when each round is done.
EOF
```

**One implementor for the whole journey.** All feedback goes back to this same polecat via `gt mail send` (it must survive session death) followed by `gt nudge` to wake it. Never spawn a second implementor while the first is alive. If the implementor dies (witness reports POLECAT_DIED), diagnose why before re-slinging the same work bead — its branch and mail history are the new polecat's context.

## Phase 2 — Review Loop

When "IMPL COMPLETE" arrives, create two review beads, add them to the convoy, and sling both **in parallel** with `--review-only`:

```bash
bd create --title="Code review (<language>): <title>" --description="Review branch <branch> diff vs main for <work-bead>" --type=task
bd create --title="Security review: <title>" --description="Security review of branch <branch> diff vs main for <work-bead>" --type=task
gt convoy add <convoy-id> <code-review-bead> <security-review-bead>

gt sling <code-review-bead> <rig> --review-only --stdin <<'EOF'
You are the CODE REVIEWER, a <language> specialist. Review the diff of branch <branch> against main.
Evaluate: correctness, <language> idioms, error handling, test quality and coverage, API design, performance, maintainability (SOLID/KISS/DRY violations).
Report by mail to <orchestrator>, subject "REVIEW <code-review-bead>":
- Verdict: PASS or CHANGES REQUIRED
- Each finding tagged BLOCKING or LOW, with file:line and a concrete fix suggestion.
You must not commit, push, or modify any code.
EOF

gt sling <security-review-bead> <rig> --review-only --stdin <<'EOF'
You are the SECURITY REVIEWER. Review the diff of branch <branch> against main.
Evaluate: injection, authn/authz flaws, secrets in code or logs, unsafe deserialization, input validation, dependency risk, path traversal, SSRF, insecure defaults.
Report by mail to <orchestrator>, subject "REVIEW <security-review-bead>":
- Verdict: PASS or CHANGES REQUIRED
- Each finding tagged BLOCKING or LOW, with file:line and a concrete fix suggestion.
You must not commit, push, or modify any code.
EOF
```

**Loop rules — apply exactly. Finding tags are authoritative; verdicts are summaries (if they disagree, follow the tags):**
- **Any BLOCKING finding (from either reviewer)** → consolidate ALL findings from both reviewers (including LOWs from a passing review) into one mail to the implementor, `gt nudge` it, wait for "FIXES PUSHED" → **re-sling BOTH review beads against the new diff**. A fix can introduce a new defect in either dimension; a review of stale code proves nothing.
- **Zero findings from both** → proceed to Phase 3.
- **No BLOCKING, but LOW findings remain** → STOP and ask the user: list the remaining low-priority findings and let them decide *proceed* or *send back*. Do not decide this yourself. If the user says *send back*, treat the LOWs as blocking: mail them to the implementor and re-run BOTH reviews after "FIXES PUSHED".

**Re-sling mechanics:** reuse the SAME two review beads every cycle. Two cleanups are needed before re-slinging or the sling errors out:
1. Completed review beads auto-close → `bd reopen <review-bead>` (from the rig directory).
2. The prior cycle's formula molecule stays bonded to the bead → re-sling with `--force` (it burns the stale molecule: "bead X already has 1 attached molecule"). 

Then `gt sling <review-bead> <rig> --review-only --force ...` spawns a fresh reviewer against the current diff. Do not create new review beads or re-add them to the convoy per cycle. Track the cycle count — you report it at landing.

## Phase 3 — PR + CI Loop

1. **Nudge the implementor to open the PR** via `/open-pr`. **Voice polish:** include in the nudge: "if a ghostwriter-produced voice skill (e.g. `kris-writing-style`) is installed in `~/.claude/skills/`, apply it to the PR description body." Global skills are visible to polecats on the same machine. If none exists, neutral prose — never block on this.
2. **Post reviews for posterity** (default; skip if `--no-pr-comments`): the reviewer polecats are likely gone by now — YOU post each reviewer's final mailed report as a PR comment, attributed (e.g. "**Code review (Go)** — foundry reviewer polecat: ..."), voice-polished the same way. This is coordination prose, not code — it is orchestrator work.
3. **Sling the MONITOR polecat** — create a monitor bead, add it to the convoy, sling `--review-only`:

```bash
bd create --title="PR monitor: <title>" --description="Monitor PR #<n> on <repo> for <work-bead>: CI checks, human feedback, merge/close" --type=task
gt convoy add <convoy-id> <monitor-bead>
```

```bash
gt sling <monitor-bead> <rig> --review-only --stdin <<'EOF'
You are the PR MONITOR for PR #<n> on <repo>. Loop until the PR is merged or closed:
- Watch CI: `gh pr checks <n> --watch`. On any failure, mail the implementor (<implementor>) the failing check names and relevant log excerpts, cc <orchestrator>, then nudge the implementor. Re-watch after every new push.
- Watch human feedback: `gh pr view <n> --json reviews,comments,state`. Forward new human review comments or requested changes to the implementor by mail, cc <orchestrator>, then nudge.
- When ALL checks are green, mail <orchestrator> "CI GREEN <n>".
- When the PR is merged or closed by a human, mail <orchestrator> "PR LANDED <n>: <merged|closed>".
You must not commit, push, comment on the PR, or merge.
EOF
```

CI is a hard gate: the work is never "done" while any check is red. Failures cycle implementor-fix → push → re-watch until green. You are cc'd on every failure mail — count CI cycles as they happen; you report the count at landing.

## Phase 4 — Human Review and Landing

Human feedback forwarded by the monitor goes to the implementor like any other finding (the implementor may use `/pr-comments` to respond; replies are voice-polished too). After each push, the CI loop re-arms automatically via the monitor.

**Never merge the PR yourself. No auto-merge exists in this skill.** Done means a human merged or closed it.

**Standing down implementors (e.g. the user hands the PR to a team for final review):** when you release a polecat before the PR has merged, your stand-down nudge MUST explicitly say "do NOT run `gt done`" — polecats reflexively run `gt done` to "close out", which submits to the merge queue and can merge the PR behind the human-review gate. Tell them to stop in place; their work is already recorded by mail. After standing them down, verify nothing slipped through: PR still `OPEN` / `mergedAt` null, branch head not on main, and no open `gt:merge-request` wisp on the work bead.

On "PR LANDED":
1. `bd close` the work bead and any open team beads. Reasons must reflect reality: merged → "landed: PR #<n> merged"; closed without merge → "abandoned: PR #<n> closed without merge" — do not record rejected work as delivered.
2. The convoy auto-closes when all members close; verify with `gt convoy status <convoy-id>`.
3. Nudge the rig witness: `gt nudge <rig>/witness "Con voyage <convoy-id> landed: PR #<n> <merged|closed>"`.
4. Report the final state to the user: PR link, review cycles count, CI cycles count.

## Quick Reference

| Role | Sling | Charter focus | Reports to |
|---|---|---|---|
| Implementor | `--merge=local` | Principal Engineer: TDD, SOLID, YAGNI, KISS, DRY | Orchestrator |
| Code reviewer | `--review-only` | Language-specific correctness, idioms, tests | Orchestrator |
| Security reviewer | `--review-only` | Vulnerabilities, secrets, input validation | Orchestrator |
| PR monitor | `--review-only` | CI checks, human feedback, merge/close detection | Implementor + orchestrator |

## Red Flags — STOP if you catch yourself

| Rationalization | Reality |
|---|---|
| "This fix is small, I'll just code it myself" | You are the orchestrator. Mail the implementor. Your context is the convoy's scarcest resource. |
| "The fix was trivial, skip re-review" | Trivial fixes break things too. BOTH reviews re-run on every cycle, every time. |
| "Only the code review needs to re-run" | A correctness fix can open a security hole and vice versa. Both. |
| "CI is green enough / that check is flaky" | All checks green. A red check is a finding, not noise. |
| "Reviews passed, I'll merge it" | Never. A human merges or closes. That event — not your judgment — ends the journey. |
| "Low-priority findings, I'll accept them" | That call belongs to the user. Ask. |
| "Implementor died, sling a fresh one immediately" | Diagnose first. Point the replacement at the existing branch and mail history. |
