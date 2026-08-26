---
name: con-voyage
description: Use when an issue, bead, or task description should be delivered by a Gas Town polecat team with full review, CI, and human feedback loops instead of solo implementation. Triggers - "con-voyage issue 42", "convoy this issue", "swarm a team on this", "start issue 42 with reviews", "send this off with an escort".
---

# Con Voyage

*"Con voyage!"* — see the issue off on its journey under convoy escort. The work travels through nested feedback loops and is not done until a human merges (or closes) the PR.

**You are the ORCHESTRATOR.** You never write implementation code. You assemble a polecat team, route feedback between them, and track the convoy. Your context window is for coordination, not coding.

## Non-negotiable: real polecats, never subagents

A con-voyage is a **Gas Town** operation. It runs on `gt sling` / `gt convoy` / beads / the rig witness — a real team of polecats in their own sandboxes, reporting by mail. **Never** assemble a "team" of Agent-tool subagents inside your own context to implement or review: subagents share your context window, cannot survive session death, cannot be nudged, and leave no auditable bead/convoy trail. If you catch yourself about to spawn a subagent to "implement" or "review," STOP — sling a polecat instead.

**If the target repo is not a rig yet, create one — do not bypass the idioms because "it's not a rig."**

```bash
# Register the repo as a rig. Use the SSH remote (git@github.com:<org>/<repo>.git)
# when the local gh token lacks the `workflow` scope, or polecats can't push.
gt rig add <name> git@github.com:<org>/<repo>.git --prefix <p>
gt rig boot <name>

# If beads reports "issue_prefix missing", initialise beads in SERVER mode against
# the shared Dolt server. Do NOT flip to embedded mode.
bd init --prefix <p> --server --server-host 127.0.0.1 --server-port 3307 --database <rig> --force
```

## Review lenses: the persona roster

The review panel is a **configurable roster of lenses**, not a fixed code+security pair. Each lens is a review persona whose charter comes from the **`con-voyage-personas` mold** (cast it alongside this one). Available lenses:

| Lens | Reviews for |
|---|---|
| Native-language principal engineer | correctness, language idioms, tests, API design, SOLID/KISS/DRY |
| Security | injection, authn/authz, secrets, input validation, dependency risk |
| Dev-ex | ergonomics for the developers who integrate or extend the change |
| Founder / CTO | strategic fit, appetite vs. cost, risk, technical debt |
| Product owner | appetite/worth-it, usability for the buyer AND their customers, UX, holistic docs |
| Standards / best-practices janitor | conventions, lint, consistency, dead code, hygiene |

**Pick the lenses that fit the change** — not every change needs every lens. A library refactor might be principal-engineer + janitor; a customer-facing feature pulls in product-owner + dev-ex + security. The **native-language principal engineer and security lenses are the default floor** for any code change. Record the chosen roster on the convoy so every review cycle re-runs the same set.

## Agent identity on every PR comment

Any comment an agent posts to the PR — a reviewer posting findings, the monitor posting status, or YOU posting reviews for posterity — MUST lead with a bold identity prefix:

**`[<rig>/<agent> — <lens>]`**  → e.g. `**[foundry/polecat-3 — security]**`

This lets a human tell which agent spoke and, crucially, distinguish agent comments from the human's own (unprefixed) comments. A human's comments are never prefixed; that asymmetry is the signal. Bake this line into every reviewer and monitor charter, and use it for the Phase-3 posterity comments.

## Usage

```
/con-voyage <issue-number|issue-url|bead-id|"task description"> <rig> [--lenses <lens,lens,...>] [--no-pr-comments]
```

- `--lenses <list>` — override the review roster (see the persona roster above); default is auto-selected from the change, with the native-language + security lenses as the floor
- `--no-pr-comments` — suppress reviewers posting their final reviews on the PR (default: they post for posterity)

## The Journey

```
Intake → bead + convoy
  → IMPLEMENT  (Principal Engineer polecat: TDD, SOLID, YAGNI, KISS, DRY)
  → REVIEW LOOP (roster of lenses — code + security floor, plus product-owner / dev-ex / etc., in parallel)
       blocking findings → mail implementor → fix → ALL reviews re-run → repeat until clean
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
0. **Ensure the target is a rig.** If `<rig>` is not registered yet, bootstrap it now (see *Non-negotiable: real polecats* above) — `gt rig add` / `gt rig boot`, and `bd init … --server` if beads reports a missing prefix. Never downgrade to subagents because a repo "isn't a rig yet."
1. **Create the convoy**: `gt convoy create "Con voyage: <title>" <work-bead>` — record the convoy ID; add every team bead to it as phases progress (`gt convoy add`).
2. **Detect the target language** (dominant language of the repo or the files the issue touches) — this picks the native-language principal-engineer lens's expertise.
3. **Choose the review roster** — select the lenses that fit this change from the persona roster (native-language principal engineer + security are the floor; add product-owner / dev-ex / founder-CTO / janitor when the change warrants). Honour `--lenses` if the user passed it. Record the chosen roster on the convoy so every review cycle re-runs the same set.
4. **Note your own address** (`gt whoami`) — every charter below tells team members to report to you; substitute your real address for `<orchestrator>`.

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

When "IMPL COMPLETE" arrives, create **one review bead per chosen lens**, add them all to the convoy, and sling them **in parallel** with `--review-only`. Each reviewer's charter is the persona charter for its lens (from the `con-voyage-personas` mold). The two below are the canonical floor — the native-language code lens and the security lens; add slings for the other chosen lenses (dev-ex, founder/CTO, product owner, janitor) the same way, using their persona charters.

Every reviewer charter carries the same reporting-and-identity contract:
- Report by mail to `<orchestrator>`, subject `REVIEW <review-bead>`: Verdict PASS or CHANGES REQUIRED; each finding tagged BLOCKING or LOW, with file:line and a concrete fix.
- You must not commit, push, or modify any code. **If you post anything to the PR, lead with `[<rig>/<you> — <lens>]`** so a human can tell which agent spoke.

```bash
bd create --title="Code review (<language>): <title>" --description="Review branch <branch> diff vs main for <work-bead>" --type=task
bd create --title="Security review: <title>" --description="Security review of branch <branch> diff vs main for <work-bead>" --type=task
gt convoy add <convoy-id> <code-review-bead> <security-review-bead>   # ...and one bead per additional chosen lens

gt sling <code-review-bead> <rig> --review-only --stdin <<'EOF'
You are the CODE REVIEWER, a <language> specialist (native-language principal-engineer lens). Review the diff of branch <branch> against main.
Evaluate: correctness, <language> idioms, error handling, test quality and coverage, API design, performance, maintainability (SOLID/KISS/DRY violations).
Report by mail to <orchestrator>, subject "REVIEW <code-review-bead>":
- Verdict: PASS or CHANGES REQUIRED
- Each finding tagged BLOCKING or LOW, with file:line and a concrete fix suggestion.
You must not commit, push, or modify any code. If you post anything to the PR, lead the comment with `[<rig>/<you> — code:<language>]`.
EOF

gt sling <security-review-bead> <rig> --review-only --stdin <<'EOF'
You are the SECURITY REVIEWER (security lens). Review the diff of branch <branch> against main.
Evaluate: injection, authn/authz flaws, secrets in code or logs, unsafe deserialization, input validation, dependency risk, path traversal, SSRF, insecure defaults.
Report by mail to <orchestrator>, subject "REVIEW <security-review-bead>":
- Verdict: PASS or CHANGES REQUIRED
- Each finding tagged BLOCKING or LOW, with file:line and a concrete fix suggestion.
You must not commit, push, or modify any code. If you post anything to the PR, lead the comment with `[<rig>/<you> — security]`.
EOF
```

**Product-owner lens (first-class).** When the change is customer-facing, the product-owner lens is not optional. Its charter must cover:
- **Appetite / worth-it:** is this change worth what it costs, and right-sized for the problem?
- **Usability for BOTH audiences:** the vendor/buyer who operates it AND their end customers who feel it.
- **UX / DevEx:** flows, defaults, error messages, and docs discoverability.
- **Holistic docs:** the feature is not shippable without docs. Require a **matching downstream docs PR** (e.g. product docs) opened in **draft**, tracked as a convoy bead, and merged in **lockstep** when the feature PR merges. "Docs PR missing" is a BLOCKING product-owner finding.

**Loop rules — apply exactly. Finding tags are authoritative; verdicts are summaries (if they disagree, follow the tags):**
- **Any BLOCKING finding (from any reviewer)** → consolidate ALL findings from every reviewer (including LOWs from a passing review) into one mail to the implementor, `gt nudge` it, wait for "FIXES PUSHED" → **re-sling ALL review beads against the new diff**. A fix can introduce a new defect in any dimension; a review of stale code proves nothing.
- **Zero findings from every reviewer** → proceed to Phase 3.
- **No BLOCKING, but LOW findings remain** → STOP and ask the user: list the remaining low-priority findings and let them decide *proceed* or *send back*. Do not decide this yourself. If the user says *send back*, treat the LOWs as blocking: mail them to the implementor and re-run ALL reviews after "FIXES PUSHED".

**Re-sling mechanics:** reuse the SAME review beads every cycle. Two cleanups are needed before re-slinging or the sling errors out:
1. Completed review beads auto-close → `bd reopen <review-bead>` (from the rig directory).
2. The prior cycle's formula molecule stays bonded to the bead → re-sling with `--force` (it burns the stale molecule: "bead X already has 1 attached molecule"). 

Then `gt sling <review-bead> <rig> --review-only --force ...` spawns a fresh reviewer against the current diff. Do not create new review beads or re-add them to the convoy per cycle. Track the cycle count — you report it at landing.

## Phase 3 — PR + CI Loop

1. **Nudge the implementor to open the PR** via `/open-pr`. **Voice polish:** include in the nudge: "if a ghostwriter-produced voice skill (e.g. `kris-writing-style`) is installed in `~/.claude/skills/`, apply it to the PR description body." Global skills are visible to polecats on the same machine. If none exists, neutral prose — never block on this. **If the product-owner lens required a docs PR**, ensure that downstream docs PR is open in **draft** and linked from the feature PR now, so the two can merge in lockstep.
2. **Post reviews for posterity** (default; skip if `--no-pr-comments`): the reviewer polecats are likely gone by now — YOU post each reviewer's final mailed report as a PR comment, each led with its identity prefix `[<rig>/<agent> — <lens>]` (e.g. `**[foundry/reviewer-2 — code:Go]**` …), voice-polished the same way. The prefix is what lets a human tell agent comments apart from their own. This is coordination prose, not code — it is orchestrator work.
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
You must not commit, push, or merge. Do not comment on the PR by default; if the orchestrator ever asks you to post status, lead the comment with `[<rig>/<you> — monitor]` so a human can tell it from their own comments.
EOF
```

CI is a hard gate: the work is never "done" while any check is red. Failures cycle implementor-fix → push → re-watch until green. You are cc'd on every failure mail — count CI cycles as they happen; you report the count at landing.

## Phase 4 — Human Review and Landing

Human feedback forwarded by the monitor goes to the implementor like any other finding (the implementor may use `/pr-comments` to respond; replies are voice-polished too). After each push, the CI loop re-arms automatically via the monitor.

**Never merge the PR yourself. No auto-merge exists in this skill.** Done means a human merged or closed it.

**Standing down implementors (e.g. the user hands the PR to a team for final review):** when you release a polecat before the PR has merged, your stand-down nudge MUST explicitly say "do NOT run `gt done`" — polecats reflexively run `gt done` to "close out", which submits to the merge queue and can merge the PR behind the human-review gate. Tell them to stop in place; their work is already recorded by mail. After standing them down, verify nothing slipped through: PR still `OPEN` / `mergedAt` null, branch head not on main, and no open `gt:merge-request` wisp on the work bead.

On "PR LANDED":
1. `bd close` the work bead and any open team beads. Reasons must reflect reality: merged → "landed: PR #<n> merged"; closed without merge → "abandoned: PR #<n> closed without merge" — do not record rejected work as delivered. If a lockstep docs PR was required, confirm it merged with the feature PR (or was closed alongside it) — a merged feature with its docs PR still in draft is an incomplete landing.
2. The convoy auto-closes when all members close; verify with `gt convoy status <convoy-id>`.
3. Nudge the rig witness: `gt nudge <rig>/witness "Con voyage <convoy-id> landed: PR #<n> <merged|closed>"`.
4. Report the final state to the user: PR link, review cycles count, CI cycles count.

## Quick Reference

| Role | Sling | Charter focus | Reports to |
|---|---|---|---|
| Implementor | `--merge=local` | Principal Engineer: TDD, SOLID, YAGNI, KISS, DRY | Orchestrator |
| Review lens — code (floor) | `--review-only` | Native-language correctness, idioms, tests | Orchestrator |
| Review lens — security (floor) | `--review-only` | Vulnerabilities, secrets, input validation | Orchestrator |
| Review lens — roster (as chosen) | `--review-only` | Dev-ex / founder-CTO / product-owner / janitor, per the `con-voyage-personas` mold | Orchestrator |
| PR monitor | `--review-only` | CI checks, human feedback, merge/close detection | Implementor + orchestrator |

Every agent PR comment leads with `[<rig>/<agent> — <lens>]`; a human's comments stay unprefixed — that asymmetry is how a reader tells them apart.

## Red Flags — STOP if you catch yourself

| Rationalization | Reality |
|---|---|
| "This fix is small, I'll just code it myself" | You are the orchestrator. Mail the implementor. Your context is the convoy's scarcest resource. |
| "The fix was trivial, skip re-review" | Trivial fixes break things too. BOTH reviews re-run on every cycle, every time. |
| "Only the code review needs to re-run" | A correctness fix can open a security hole and vice versa. Both. |
| "CI is green enough / that check is flaky" | All checks green. A red check is a finding, not noise. |
| "Reviews passed, I'll merge it" | Never. A human merges or closes. That event — not your judgment — ends the journey. |
| "Low-priority findings, I'll accept them" | That call belongs to the user. Ask. |
| "I'll just spin up subagents as the team" | Never. A con-voyage is real polecats via `gt sling` — subagents leave no bead/convoy trail and die with your context. |
| "It's not a rig, so I can't use polecats" | Then make it one: `gt rig add` / `gt rig boot`. Don't downgrade to subagents. |
| "Code + security is enough" | The roster is per-change. Customer-facing work needs product-owner (and often dev-ex) too. |
| "The feature's done, docs can follow later" | Not for a product-owner-gated change. The docs PR opens in draft and merges in lockstep. |
| "I'll attribute the posterity comment however" | Every agent comment leads with `[<rig>/<agent> — <lens>]` so a human can tell who spoke — and tell agents from their own comments. |
| "Implementor died, sling a fresh one immediately" | Diagnose first. Point the replacement at the existing branch and mail history. |
