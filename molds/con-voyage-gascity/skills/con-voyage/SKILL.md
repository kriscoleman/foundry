---
name: con-voyage
description: Use when an issue, bead, or task description should be delivered by a Gas City polecat team with full review, CI, and human feedback loops instead of solo implementation. Triggers - "con-voyage issue 42", "convoy this issue", "swarm a team on this", "start issue 42 with reviews", "send this off with an escort".
---

# Con Voyage (Gas City)

Launch a full escort review for a branch. The work travels through multi-lens review cycles and is not done until a human merges (or closes) the PR.

**You are the FACILITATOR.** You never write implementation code. You orchestrate: intake, roster selection, formula sling, route feedback, post verdicts. Real orchestration is handled by the mayor, the `con-voyage` formula, and the `con-voyage-orchestration` template fragment — this skill is the launcher.

## Prerequisites

A Gas City city (`gc`) with the con-voyage pack imported:

```bash
gc import add ./packs/con-voyage
```

Run this once per city before invoking `/con-voyage`. If the pack is already imported, `gc import add` is idempotent.

## Usage

```
/con-voyage <issue-number|issue-url|bead-id|"task description"> <rig> [--lenses <lens,...>]
```

- `<target>` — GitHub issue number or URL, an existing bead ID, or a free-text description. A bead is created if one does not yet exist.
- `<rig>` — Gas City rig name for the target repository.
- `--lenses <list>` — optional comma-separated override of the roster (see lens names below). The floor lanes (security + native-language code review + acceptance/test-evidence/simplicity) are always on regardless of this flag.

## How it maps to `gc sling`

After intake and roster selection (Phase 0–1 of the orchestration fragment), sling the formula:

```bash
gc sling <target> <work-bead> --formula \
  --var push=true \
  --var open_pr=true \
  [--var code_lens=con-voyage.cv-frontend-principal-engineer] \
  --var enable_<lens>=true \
  [--var enable_<lens2>=true ...]
```

Each chosen roster lens is activated by its own `--var enable_<lens>=true`. Floor lanes (security, code, acceptance, test-evidence, simplicity) are always active — no var needed.

**Code lens selection** — override the default (`cv-go-principal-engineer`) when the repo's dominant language differs:

| Language | `--var code_lens=` |
|---|---|
| Go | `con-voyage.cv-go-principal-engineer` (default; omit flag) |
| JS / TS | `con-voyage.cv-frontend-principal-engineer` |
| Other | `con-voyage.cv-code-reviewer` |

**Never-merge posture**: `push=true` pushes the work branch to origin (required to open a PR). `open_pr=true` opens the PR. Auto-merge is prevented by `merge_queue="observe"` in `city.toml`. A human must land the PR.

### Available roster lens vars

| `--var` flag | Lens |
|---|---|
| `enable_product_owner=true` | Product owner: appetite, usability (buyer + end-customers), docs gate |
| `enable_founder_cto=true` | Founder/CTO: strategy, appetite vs. cost, architecture risk |
| `enable_dev_ex=true` | Developer experience: APIs, extension-point ergonomics, adoption mechanics |
| `enable_standards_janitor=true` | Standards janitor: conventions, lint, hygiene, dead code |
| `enable_qa_test=true` | QA/test engineer: test coverage gaps, edge cases, regression risk |
| `enable_sre=true` | SRE/reliability: observability, failure modes, operational risk |
| `enable_design_ux=true` | Design/UX: flows, defaults, error messages, drift from established design conventions |
| `enable_documentation=true` | Documentation: correctness, completeness, discoverability |
| `enable_marketing=true` | Marketing: messaging, positioning, launch readiness |
| `enable_api_platform=true` | API/platform contract: API design, backward compat, contract stability |
| `enable_compliance=true` | Compliance/privacy: regulatory risk, data handling, GDPR/SOC2 |
| `enable_data_db=true` | Data/database engineer: schema, migrations, query correctness |

## The Journey (summary)

The always-resident `con-voyage-orchestration` template fragment (appended into every mayor's SessionStart context) carries only the facilitator contract, dispatch posture, and one-line phase pointers. The full runbook below is what it points to.

```
Intake → work bead + convoy
  → SLING formula  (gc sling <target> <work-bead> --formula --var push=true --var open_pr=true --var enable_<lens>=true)
  → BUILD (if needed)  (fresh bead: first TDD round runs automatically; a bead
                         that already has a pre-built branch short-circuits
                         straight to REVIEW LOOP — nothing to do on your end
                         either way)
  → REVIEW LOOP   (floor lanes + chosen roster in parallel; blocking findings → fix → re-run)
  → branch pushed + PR opened (push=true, open_pr=true); merge_queue="observe" prevents auto-merge
  → HUMAN LANDS   (you push + open PR; a human merges or closes it)
```

One sling is the whole journey — you never need to `gc sling ... --on do-work`
first. The formula detects whether the target bead already has a branch and
builds it itself when it does not.

`push=true open_pr=true` is the correct posture — the branch is pushed to origin and a PR is opened, but auto-merge is blocked by `merge_queue="observe"` in `city.toml`. A human lands it.

### Phase 0 — Intake → work bead

Resolve the input to a **work bead**:

| Input | Action |
|---|---|
| GitHub issue # or URL | `gh issue view <n> --json title,body,labels,url`, then `gc bd create` with a conventional-commit title (infer type from labels; default `task`) |
| Bead ID | `gc bd show <id>` — use as-is |
| Free-text description | `gc bd create` with a conventional-commit-style title |

Then:
1. Create the convoy: `gc convoy create "Con voyage: <title>" <work-bead>` — record the convoy ID.
2. Detect the target language (dominant language of the repo or the touched files) — this picks the native-language principal-engineer lens.
3. Choose the review roster (see below). Record it on the convoy so every review cycle re-runs the same set.
4. Note your own address (`gc whoami`) — every charter substitutes your real address for `<orchestrator>`.

### Phase 3 — Route review / CI / human feedback to the SAME implementor

All feedback — blocking review findings, CI failures, human PR comments — goes to the **same implementor** the formula put on the work bead. Use `gc mail send` (not nudge) for findings that must survive session death. After mailing, `gc nudge <rig>/<implementor-session>` to wake them.

**Loop rules (finding tags are authoritative; verdicts are summaries):**
- Any **BLOCKING** finding (from any reviewer) → consolidate ALL findings from every reviewer into one mail to the implementor → wait for "FIXES PUSHED" → re-run ALL active review lanes against the new diff. Every cycle, every time.
- **Zero findings** from every reviewer → proceed to the PR + CI phase.
- **No BLOCKING, LOWs only** → STOP and ask the human: list the findings and let them decide *proceed* or *send back*. Never decide this yourself.

Re-run mechanics: before each cycle (1) reopen the completed review bead — `gc bd reopen <review-bead>` — and (2) pass the force flag to the re-sling to burn the stale molecule bonded from the prior cycle. Do not create new review beads per cycle.

### Phase 4 — Post ONE aggregated review comment per round

Reviewers never comment on the PR themselves. Each review round produces
**exactly one NEW** agent comment, posted by you (or by the equivalent
downstream step on a later round) via `cv-pr-comment.sh comment-aggregate` —
never a separate comment per lane, and never an edit of an earlier round's
comment (there is no edit mode; a fresh comment every round is more intuitive
for implementors and reliably re-triggers notifications, the same posture
Doomer uses).

Build the manifest from that round's lane reports and the synthesis, then
call the script once:

```bash
cv-pr-comment.sh comment-aggregate <pr> --repo <owner/repo> \
  --manifest <path to the assembled JSON manifest> \
  --formula con-voyage --agent "<rig>/<your agent>"
```

The rendered comment is minimal at the surface — like Doomer's single-line
run summary — with every detail collapsed:

- **Surface:** the identity prefix plus ONE line, e.g. `**[<rig>/con-voyage —
  review]** Approved: 7 lanes, 0 blocking, 9 low.` (or `Changes requested: 2
  blocking, …`). At most one more short line: a link, or "LOWs for the human
  reviewer below."
- **Then** one `<details><summary>[<rig>/<agent> — <lens>] <verdict> · <n>
  findings</summary> … full report … </details>` per lane, plus one for the
  synthesis (rendered first — the actionable LOW list ahead of the per-lane
  detail). Keep the `[<rig>/<agent> — <lens>]` identity inside each
  `<summary>`: it's the agent-vs-human signal.
- A hidden marker (`<!-- con-voyage-review:<root> round=<n> -->`) identifies
  agent comments (e.g. so pr-watch can skip them) — it is never used to edit.
- Stays under GitHub's 65536-char comment limit: an oversized lane report
  truncates inside its own `<details>` block with a pointer to the full
  report, never across the surface.

This applies to every agent-authored PR comment, not just review verdicts:
ci-repair status, pr-watch notices, and publish notes are each their own
single NEW minimal comment per event — never edited in place.

### Phase 5 — Lockstep docs PR (product-owner gate)

When the `cv-product-owner` lens is active, "docs PR missing" is a **BLOCKING** finding. The docs PR is its own con-voyage in the docs repo's rig — not a side task bolted onto this one:
1. If the docs repo is not a rig yet, `gc rig add` / `gc rig boot` it.
2. Run a separate `/con-voyage` for it: its own work bead and convoy, its own implementor, reviewed with product-owner + native-language/prose lenses.
3. Open the docs PR in **draft** and cross-link it to the feature PR.
4. **Merge in lockstep:** neither PR lands alone. Confirm both merged (or both closed) before marking the convoy complete.

### Phase 6 — Never merge; human lands (teardown is automated)

You push the branch (`push=true`) and open the PR (`open_pr=true`). You do not merge it. The `merge_queue="observe"` setting in `city.toml` ensures no auto-merge path exists. Done means a human merged or closed it.

**The work-bead lifecycle is now driven by the pack itself, not by you:**
- The **setup** step claims the work bead (`--claim` → in_progress), seeds its description, and sets `cv=reviewing`.
- Each **review cycle** appends a one-line verdict/finding-count summary to the work bead.
- The **publish** step records `pr_url` on the work bead, sets `cv=awaiting_merge`, and writes a per-PR finalize record under `.gc/cv-pr-watch`.
- The **`con-voyage-finalize`** monitor order polls each tracked PR and, on merge/close, closes the work bead with the accurate reason, closes the convoy, releases the long-lived implementor, and removes the record — and while the PR is open it keeps the work bead's `cv=` phase in sync (`awaiting_merge` when clean, `repairing` when CI is red / a rebase is needed).

On "PR LANDED" the `con-voyage-finalize` monitor handles teardown within its cooldown. Do the following only as a **fallback** (monitor down, or you want it immediate):
1. `gc bd close` the work bead and all team beads. Reason must reflect reality: merged → "landed: PR #<n> merged"; closed without merge → "abandoned: PR #<n> closed without merge".
2. Verify the convoy closed: `gc convoy status <convoy-id>`.
3. Report to the user: PR link, review cycles, CI cycles.

## Model tiers & the opt-in all-opencode fallback mode (con-voyage-rate-limit-lookout)

Work is tiered by complexity, with a claude ↔ opencode equivalency:

| Tier | claude | opencode | Who runs on it |
|---|---|---|---|
| large (critical / intensive) | opus | kimi-k3 | you (the mayor), `cv-review-intensive` lenses |
| medium (standard) | sonnet | glm-5p3-flash | do-work / implementation workers, `cv-review-standard` lenses |
| small (rudimentary) | haiku | minimax-m3 | `cv-review-light` lenses |

By default reviewers ride the same claude tiers you and the workers do (the
pack's claude mode) — a city can opt into an opencode + fireworks mode for
reviewers instead (see README.md "Model tiers"), a separate, static choice
from the fallback mode below. You don't manage that choice — but if the city
has also opted into the **`con-voyage-rate-limit-lookout`** order (it ships off by
default; a city enables it by overriding its trigger), it watches every
claude-backed session for you, and its mail is actionable:

- **"claude limit circuit breaker OPEN — switch to all-opencode mode"** (`CV_LOOKOUT_AUTO_FLIP` off, the pack default) — one or more claude sessions is showing a usage/rate-limit signature. A session that will resume on its own (Claude Code's auto-continue banner showing) is left alone; every other active claude session has been handed off (context preserved). Your moves:
  1. **Verify the target pool can actually spawn before bulk re-slinging:** `gc sling <rig>/<pool> <one bead> --nudge` and confirm a session actually starts, not just that the sling command returned 0. On gc 1.4.2 there's an open bug ([gastownhall/gascity#5436](https://github.com/gastownhall/gascity/issues/5436)) where opencode/ACP sessions can be silently unroutable ('requires ACP transport but the session provider cannot route ACP sessions (skipping)') even though the dispatch looked fine — re-slinging a whole backlog onto a pool that can't spawn just idles it instead of running it.
  2. **Re-sling in-flight claude beads to the fallback pools:** `gc sling <rig>/<pool> <bead> --nudge`, where `<pool>` is the tier's opencode equivalent named in the mail (default `kimi-k3` large / `glm-5p3-flash` medium / `minimax-m3` small).
  3. **Prefer fallback pools for all new dispatches** until the all-clear: sling `<rig>/kimi-k3` where you would have used opus-class targets, `<rig>/glm-5p3-flash` for sonnet-class.
  4. **Durable switch (long limits):** point `city.toml` `[agent_defaults].provider` at the medium pool and your own `[[patches.agent]] mayor` provider at the large pool, then tell the human you did. Providerless role agents (implementation workers, run-operators, synthesizers) follow `agent_defaults`; pooled work follows where you sling it.
- **"city flipped to all-opencode (auto-flip)"** (`CV_LOOKOUT_AUTO_FLIP=true`) — the lookout already did step 4 above itself, but only after proving the fallback pool can actually spawn (a live probe, not just config resolution — see gascity#5436 above): a managed block in `city.toml` overrides `[agent_defaults].provider` and your own patch's `.provider` to the fallback pools, `gc reload` has run, and limited sessions (including ones that would otherwise have auto-resumed) have been handed off to respawn on opencode. This exists because you may be claude-limited too when this fires, unable to act on a mail-only escalation — so **do nothing to city.toml yourself**; re-editing `[agent_defaults]`/your patch on top would fight the lookout's managed block. Re-sling and prefer fallback pools for new dispatches same as above. The lookout undoes its own override once the limit clears (reset time passed + a live probe succeeds) — don't revert it by hand unless the mail's "undo by hand" instructions are what you're following.
- **"auto-flip BLOCKED (target can't spawn)"** (`CV_LOOKOUT_AUTO_FLIP=true`, but the pre-flip spawn probe failed) — the lookout did NOT flip: it proved the opencode fallback pool can't currently spawn a session (gascity#5436) and chose to keep the fleet on working claude providers instead of trading a real outage for a hypothetical one. Current claude sessions have been handed off on their CURRENT provider (context preserved), same as the non-auto-flip case above. Treat this exactly like "circuit breaker OPEN" above — manual re-sling is your only option, and step 1's spawn-capability check applies doubly here since the lookout's own probe just failed. The lookout keeps re-probing on a backoff and will flip automatically the moment the pool recovers; you don't need to intervene unless the human wants to force a manual fallback sooner.
- **"breaker closed — claude tiers clear"** (not flipped) — the reset window passed with no limit signature. Resume normal claude-tier dispatch for new work (revert your durable switch if you made one). In-flight opencode work finishes where it is; don't churn it back.
- **"city flipped back from all-opencode (auto-flip all-clear)"** (was flipped) — the lookout reverted its own override and reloaded. Resume normal claude-tier dispatch for new work; nothing for you to undo.
- **A lookout handoff mail addressed to you personally** (context-critical or fleet handoff): finish your current dispatch sentence, then `gc handoff` yourself so you resume fresh with this mail in hand. Don't postpone it past the task at hand — a compact mid-orchestration costs the roster, the convoy IDs, and the loop state you're holding.

## Red flags — STOP if you catch yourself

| Rationalization | Reality |
|---|---|
| "These share a file, I'll queue them to be safe" | Same-file overlap isn't a dependency — parallel PRs by default, rebase at land. Serial is the last resort. |
| "This fix is small, I'll code it myself" | You are the facilitator. Mail the implementor. |
| "Skip re-review, the fix was trivial" | Trivial fixes break things too. ALL active lanes re-run, every cycle. |
| "Only code review needs to re-run" | A correctness fix can open a security hole. Both, always. |
| "CI is green enough / that check is flaky" | All checks green. A red check is a finding, not noise. |
| "Reviews passed, I'll merge it" | Never. A human merges or closes. That event ends the journey. |
| "LOWs are fine, I'll accept them" | That call belongs to the human. Ask. |
| "The limit mail is probably transient, I'll keep dispatching claude" | The lookout watches the whole fleet; you see one bead. Open breaker = all-opencode mode until the all-clear. |
| "I'll restart a rate-limited worker to clear it" | The limit is account-side. Handoff preserves context; re-sling the work to a fallback pool instead. |
| "Product-owner passed, docs can follow" | Not on a product-owner-gated change. The docs PR opens in draft and merges in lockstep. |
| "I'll attribute the PR comment however" | Every agent comment leads with `[<rig>/<agent> — <lens>]` — always, inside its `<details><summary>` for a review round. |
| "I'll post each lane's report as its own comment" | One aggregated comment per round via `cv-pr-comment.sh comment-aggregate`. Lanes never comment individually — an enterprise PR is not the place for 8 separate bot comments. |
| "I'll just edit the earlier round's comment" | Never. Always a NEW comment per round; edits don't reliably notify and Doomer doesn't do it either. |
