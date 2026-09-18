# con-voyage-gascity mold

Cast this mold into a **Gas City** workspace to enable the full con-voyage delivery
loop: a chief-of-staff mayor orchestrates a persistent TDD implementor and a
configurable roster of persona review lenses through an iterate-until-clean cycle,
opens a PR, monitors CI and human feedback, and **never merges — a human lands it.**

This is the Gas City successor to `con-voyage-gastown` (which runs on Gas Town / `gt`).

---

## What it installs

Casting this mold drops two things into the target city:

### 1. The `con-voyage` pack (`packs/con-voyage/`)

A Gas City pack containing:

- **`con-voyage` formula** — an `expansion`/`graph.v2` formula that runs the full
  delivery pipeline: setup → parallel review lanes → synthesize → apply findings →
  loop until approved → push branch → open PR. `push=true` and `open_pr=true` by
  default; the work branch is pushed to origin and a PR is opened, but
  `merge_queue="observe"` in `city.toml` prevents any auto-merge path. A human
  must land the PR.

- **16 reviewer-lens agents** (scope `rig`, prefixed `cv-`) — gascity-native persona
  agents ported from the full con-voyage roster:

  | Agent | Role |
  |---|---|
  | `cv-go-principal-engineer` | Go principal engineer (floor lane for Go repos) |
  | `cv-frontend-principal-engineer` | Frontend principal engineer (floor for JS/TS repos) |
  | `cv-code-reviewer` | Generic code reviewer (floor fallback for other languages) |
  | `cv-security-reviewer` | Security reviewer (always-on floor lane) |
  | `cv-product-owner` | Product owner — appetite, usability, docs gate |
  | `cv-founder-cto` | Founder/CTO strategic perspective |
  | `cv-dev-ex-reviewer` | Developer experience |
  | `cv-standards-janitor` | Standards and conventions enforcement |
  | `cv-qa-test-engineer` | QA and test coverage |
  | `cv-sre-reliability` | SRE and reliability |
  | `cv-design-ux` | Design and UX |
  | `cv-documentation` | Documentation completeness |
  | `cv-marketing` | Marketing and messaging |
  | `cv-api-platform-contract` | API and platform contract |
  | `cv-compliance-privacy` | Compliance and privacy |
  | `cv-data-db-engineer` | Data and database |

- **`con-voyage-orchestration` template fragment** — chief-of-staff runbook appended
  to the mayor. Encodes the full facilitator role: intake → work bead, roster
  selection, formula sling, routing review/CI/human feedback back to the same
  implementor, posting reviewer verdicts to the PR with `[<rig>/<agent> — <lens>]`
  identity prefixes, and enforcing the never-merge posture.

### 2. A thin `/con-voyage` Claude Code skill (`.claude/skills/con-voyage/`)

An ergonomic `/con-voyage <issue|bead|"desc"> <rig>` launcher for human Claude Code
sessions and the mayor itself. It verifies the pack is imported, does intake, helps
select the roster, and slings the formula. All heavy orchestration lives in the pack.

### Never-merge posture

The formula runs with `push=true open_pr=true` by default: the work branch is pushed
to origin and a PR is opened. The `[[github.pr_monitor]]` block (see § "GitHub
monitoring" and "Per-rig `city.toml` snippet" below) is configured with
`merge_queue = "observe"` — observe only, never auto-merges. That monitor setting
is what enforces the never-merge invariant, not suppressing the push. A human must
land the PR.

---

## Cast + wire

### Step 1 — Cast the mold

```bash
ailloy cast github.com/kriscoleman/foundry//molds/con-voyage-gascity
```

This drops `packs/con-voyage/` and `.claude/skills/con-voyage/` into the city root.

### Step 2 — Register the pack

```bash
gc import add ./packs/con-voyage
```

`gc` supports local-path imports. This one command makes the formula, reviewer
agents, and template fragment available city-wide. Verify with:

```bash
gc formula                     # con-voyage formula visible
gc config show                 # packs/con-voyage listed under imports
```

> **Note:** ailloy cannot patch `city.toml` (TOML patching is not supported).
> The pack wiring that requires TOML edits — the GitHub PR monitor, reviewer model
> overrides, and mayor fragment — must be added manually. See the snippet below.

---

## Per-rig `city.toml` snippet

Add the following to your rig's `city.toml` after casting. Replace the angle-bracket
placeholders with real values for your rig.

```toml
# GitHub PR monitor — CI check-runs + merge-state; observe only, never auto-merges.
# repair_workflow points at the con-voyage CI repair formula shipped in the pack.
[[github.pr_monitor]]
name = "<rig>-prs"
owner = "<org>"
repo  = "<repo>"
base_branches = ["main"]
rig   = "<rig>"
notify         = ["mayor"]
repair_route   = "<rig>/gc.implementation-worker"
repair_workflow = "con-voyage-ci-repair"
merge_queue    = "observe"

# Wire the chief-of-staff orchestration fragment into the mayor
[mayor]
append_fragments = ["con-voyage-orchestration"]
```

The `merge_queue = "observe"` setting tells the `[[github.pr_monitor]]` to watch PRs
for CI results and merge-state problems but never to enqueue them for automatic
merging. `repair_workflow = "con-voyage-ci-repair"` attaches the formula shipped in
the pack to repair beads (instead of the default `mol-polecat-work`).

> **Author scoping (important — read this).** The native `[[github.pr_monitor]]`
> config **cannot express an author filter**, and `gc github pr backfill` has no
> `--author` flag. On its own the native monitor would evaluate *every* open PR in
> each configured repo — including PRs authored by other people. Author scoping is
> therefore enforced by the **`con-voyage-pr-watch` order/script**, which is the
> sole runtime driver of the monitor (the native `poll_interval` is inert without
> it). The script only ever acts on PRs authored by `CV_PR_AUTHOR`. See
> [Author scoping](#author-scoping) below.

> **Reviewer model:** The 16 `cv-*` reviewer agents now ship with `provider = "opus"`
> in their `agent.toml` files (inside the pack). No `[[patches.agent]]` blocks in
> `city.toml` are needed — the pack already sets opus as the default model for all
> reviewer lenses.

---

## GitHub monitoring

Con-voyage native GitHub monitoring combines two mechanisms:

### Native `[[github.pr_monitor]]` (CI checks + merge-state)

The per-rig `[[github.pr_monitor]]` block declared in `city.toml` watches:

- **Failed CI check-runs** — any required or reported check that fails
- **DIRTY** — merge conflict between the PR branch and its base
- **BEHIND** — PR branch is behind its base (needs rebasing)
- **BLOCKED** — GitHub branch-protection block without a more specific cause

When an actionable condition is detected, the monitor creates a deduped repair
bead keyed by `(monitor-name, PR-number, head-sha)`. The bead is assigned to
`repair_route` and the `con-voyage-ci-repair` formula is attached. The
implementor reads the bead, checks out the PR branch, diagnoses the exact
failing checks, fixes via TDD, and pushes — **never merges**.

The monitor is **on-demand only** — it runs when `gc github pr backfill
--create-repair-beads` is invoked. The `con-voyage-pr-watch` order (shipped in
the pack) drives this on a 10-minute cooldown. `poll_interval` in `city.toml`
is inert at runtime.

### `con-voyage-pr-watch` order (human PR-comment routing)

The native `[[github.pr_monitor]]` does **not** watch human PR review comments.
The `con-voyage-pr-watch` order bridges this gap via best-effort polling.

On each 10-minute tick the order script:

1. Runs `gc github pr backfill --json` report-only, drops every PR not authored
   by `CV_PR_AUTHOR`, and dispatches rework for each surviving actionable PR
   (Part A — CI repair, author-scoped). Every open con-voyage PR has exactly
   one implementor responsible for it: while that implementor is alive, the
   rework is mailed + notified directly to it (no new bead); a repair bead is
   created and routed to the pool `con-voyage-ci-repair` formula only as a
   fallback, when no implementor is known or the known one is gone — see
   "Repair routing and dedup" below.
2. For each configured monitor's repo, lists the configured author's open
   non-draft PRs (`gh pr list --author "$CV_PR_AUTHOR"`) and checks for
   new human review comments and review feedback since the last run (Part B —
   comment routing). Comments prefixed with `[<rig>/<agent> — <lens>]`
   (con-voyage reviewer identity) and known bot logins are excluded. New human
   feedback is routed to the implementor via `gc sling`. Idempotency is
   maintained via a state file keyed by `(repo, PR-number, max-comment-id)` so
   the same comment is never routed twice.

### `con-voyage-ci-repair-guard` order (defense-in-depth author gate)

A `con-voyage-ci-repair` bead is not only created by `con-voyage-pr-watch.sh`.
The native `[[github.pr_monitor]]` can also mint one directly via
`--create-repair-beads` (no author filter), and a bead can be mis-slung by
hand. `con-voyage-ci-repair-guard` is the backstop for those other two paths:

- Fires on `bead.created` (event-triggered, not a poll) so it races to close a
  bad bead *before* a worker can claim it. It does **not** act only on the
  bead named by the triggering event — every run re-sweeps **every open**
  `con-voyage-ci-repair` step bead in the city (unlimited, not just the first
  50), which is what makes it self-healing regardless of which bead.created
  event happened to fire it.
- For each one, resolves its PR's real author via `gh` and closes any bead
  whose author is not `CV_PR_AUTHOR` — taking no other action (no
  `gh run rerun`, no `git push`, no `gh pr comment`, no `gc sling`).
- Fails closed the same way as `con-voyage-pr-watch`: an unresolved
  `CV_PR_AUTHOR` or an unresolved PR author means the bead is dropped, never
  guessed into being kept.
- Is behind the `CV_AUTHOR_GATE` toggle (default `enabled`). Setting
  `CV_AUTHOR_GATE=disabled` makes this guard a no-op so every bead is worked
  regardless of author — see [Author-gate toggle](#author-gate-toggle-cv_author_gate).

### Coverage table

| Signal | Native monitor | pr-watch order |
|---|---|---|
| Failed CI check-runs | Yes | Driven (Part A) |
| Merge conflict (DIRTY) | Yes | Driven (Part A) |
| Branch behind base | Yes | Driven (Part A) |
| Branch-protection block | Yes | Driven (Part A) |
| Human review comments | No | Yes (best-effort, Part B) |
| Auto-merge | Never | Never |

### Per-state repair semantics (native-monitor parity)

Part A trusts `gc github pr backfill`'s own `failure_kind` field when present
— confirmed against a real, live backfill payload against this city's own
configured monitors, `gc` already computes and emits exactly this vocabulary
per result. Only when that field is absent does Part A fall back to deriving
one from `state`/`failed_checks` itself. Either way, Part A classifies every
actionable PR into one canonical `failure_kind` token
— `checks_failed` | `merge_conflict` | `behind_base` | `blocked` — and threads
it onto the repair bead (`--var failure_kind=...`), so the bead's title names
the state (`Repair GitHub PR <owner>/<repo>#<n> (<failure_kind>): <title>`) and
the `con-voyage-ci-repair` workflow's Step 4 is *told* the state instead of
re-deriving it. Classification is first-match order: a non-empty
`failed_checks[]` always wins (so a check-failure-blocked PR is
`checks_failed`, not `blocked`), then `state == dirty`, then `behind`, then
`blocked`.

Each state has a distinct, safety-reviewed repair path:

- **`checks_failed`** — unchanged: fix via TDD or `gh run rerun --failed` for a
  flake. See the existing non-destructive retrigger discipline above.
- **`merge_conflict` (DIRTY) — auto-resolves, with guardrails.** The
  implementor still runs `git rebase` and resolves conflicts (this was a
  deliberate, signed-off call to keep automating the common case rather than
  always punting to a human), but now MUST also: surface a human-readable
  summary of the resolution (which files conflicted, what the resolution did)
  as both a machine-bannered PR comment and the bead close note, and push with
  `--force-with-lease` (a rebase always creates new commit objects). Still
  never merges, never approves, never submits to the merge queue.
- **`behind_base` (BEHIND) — rebase + `git push --force-with-lease`.** Chosen
  over a `gh pr update-branch` merge to keep a clean linear history on the
  operator's own branch. This is a deliberate, explicit exception to the
  "never force-push" rule elsewhere in this doc: that rule targets
  force-pushing *to retrigger CI* on an unchanged commit (pure churn) — it
  does not forbid a legitimate rebase-driven branch update, which inherently
  requires a force-push. `--force-with-lease` (never a bare `--force`) is used
  either way.
- **`blocked` — a router, not a single action.** `blocked` is heterogeneous, so
  the workflow reads `statusCheckRollup` / `mergeStateStatus` / `reviewDecision`
  before acting: a genuinely failing required check is handled as
  `checks_failed`; pending-only checks are a no-op wait (never rerun a running
  check); a `BEHIND` merge state is handled as `behind_base`; and anything
  gated on human review (`CHANGES_REQUESTED`, CODEOWNERS, or other branch
  protection) gets a machine-bannered annotation plus an escalation mail — zero
  mutating action, and the implementor **never self-approves and never
  bypasses branch protection**. The one exception is a PR that is *purely*
  awaiting review — see **Awaiting-human filter** below; that case never
  reaches this router at all, and closes silently rather than annotating.

#### Awaiting-human filter (`REVIEW_REQUIRED`-only PRs are not a repair)

con-voyage PRs never auto-merge, so once every real defect is resolved (CI
green, mergeable, branch up to date) a PR ends in
`reviewDecision=REVIEW_REQUIRED` **forever** — that is a human already in the
loop, not something a machine can fix. Without a filter, every such PR would
be classified `blocked` and re-mint a repair bead (and, before this filter
existed, escalation mail) on every single 10-minute tick, forever.

Two layers apply the identical check — all `statusCheckRollup` entries
green/neutral, `mergeable == MERGEABLE`, `mergeStateStatus != BEHIND`, and
`reviewDecision == REVIEW_REQUIRED` — and both take zero action (no bead, no
comment, no mail) when it holds:

1. **Part A (creation-time), `con-voyage-pr-watch.sh`.** Only ever consulted
   when `failure_kind == blocked`; `checks_failed`/`merge_conflict`/
   `behind_base` already mean a real defect exists, so review state can never
   suppress those. A match is logged and skipped — no repair bead is created.
2. **`con-voyage-ci-repair` Step 0b (defense in depth).** Re-checks the same
   condition inside the workflow itself, in case a bead reached a worker via a
   path Part A does not control (native `--create-repair-beads`, a manual
   sling, or a bead minted before this filter existed). On a match, the bead is
   closed immediately with a `not actionable: awaiting human review only` note
   — no PR comment, no escalation mail, and Steps 1 onward never run.

Any PR with a genuinely failing check, a real merge conflict, a behind branch,
or a review state *other than* `REVIEW_REQUIRED` (`CHANGES_REQUESTED`,
CODEOWNERS, etc.) still mints and repairs exactly as before — this filter is
narrowly scoped to the one true "nothing left to do but wait" combination.

### Repair routing and dedup (PR-scoped, not head-sha-scoped)

**Every open con-voyage PR has exactly one live implementor responsible for
it, from escort until land.** `con-voyage-pr-watch.sh` tracks this per PR
(keyed on repo + PR number only, never head-sha) in a state record under
`CV_STATE_DIR`: `implementor_session`, `inflight_rework` (a tracked bead id,
when the last dispatch used the pool fallback), and `last_handled_state` (the
failure_kind — or `clean` — this monitor last reacted to).

**Dispatch.** While the recorded implementor is alive, rework is mailed +
notified directly to it (`gc mail send ... --notify` — durable and self-waking,
the same path con-voyage already uses for review/CI feedback) and **no new
pool workflow is created**. Only when no implementor is known, or the known
one is no longer a live session, does the monitor fall back to creating a
repair bead and routing it to the pool `con-voyage-ci-repair` formula — same
as before. Once a pool worker claims that fallback bead, it becomes the PR's
implementor for future cycles.

**Dedup.** A re-dispatch is blocked *only* while the SAME defect
(`last_handled_state` equals the just-classified failure_kind) is genuinely
in-flight — a tracked fallback bead, if any, is still open (**status alone**,
not assignee — a pool-slung bead sits unclaimed with an empty assignee for an
unbounded time before a worker picks it up, so requiring a live assignee here
was the historical over-mint bug: a repair that was still legitimately
pending got treated as abandoned and re-minted every cycle). A closed tracked
bead never blocks a fresh dispatch: it is superseded (closed, with a note)
and a new one is minted in its place.

**Re-detection.** Any state *change* — a different failure_kind, or the PR
going dirty again after a prior `clean` observation — always supersedes the
old record and dispatches exactly one fresh rework, so a stale record can
never permanently suppress a real, newly-observed defect. A PR that is
already clean is left alone; its record is refreshed to `last_handled_state=
clean` (and any still-open tracked bead is closed) purely so a *later*
re-conflict has a real prior state to compare against.

**Back-compat.** A pre-upgrade `<dedup_key>.minted` marker (bead-id only) is
read as `inflight_rework=<that id>`, no known implementor, `last_handled_state
=unknown` — "unknown" never matches a real observed state, so the first
post-upgrade cycle re-evaluates the PR fresh rather than trusting stale
pre-upgrade bookkeeping.

All states share the same bright lines as everything else in this pack:
author-gated at the source (an unauthorized PR never reaches any of this),
and never merge / never approve / never submit to the merge queue.

### Author scoping

**The monitor only ever touches PRs authored by a single configured user.**
This is enforced by three independent, defense-in-depth layers, so that no
single path — script, order, or workflow prompt — is the sole thing standing
between a stranger's PR and an automated GitHub action:

1. **`con-voyage-pr-watch` order (creation-time gate).** Both of its duties are
   scoped to the login in the `CV_PR_AUTHOR` environment variable:
   - **Part A (CI repair)** runs `gc github pr backfill --json` *report-only*
     (never `--create-repair-beads`), then resolves each actionable PR's
     author via `gh` and **drops every PR whose author is not
     `CV_PR_AUTHOR`** before creating any repair bead. An unresolvable author
     is treated as "not ours" and skipped (fail closed).
   - **Part B (comment routing)** passes `--author "$CV_PR_AUTHOR"` to
     `gh pr list`, so only the configured author's open PRs are ever polled
     or routed.
   - The hard invariant: **zero repair beads are ever created by this script
     for a PR not authored by `CV_PR_AUTHOR`.**
2. **`con-voyage-ci-repair-guard` order (backstop sweep).** Catches beads
   created by paths Part A doesn't control — the native monitor's own
   `--create-repair-beads`, or a manual mis-sling — and closes any whose
   author doesn't match, before a worker can claim them. See above.
3. **Step 0 in the `con-voyage-ci-repair` workflow itself (last resort).** The
   implementor's own first instruction re-verifies `pr_author == CV_PR_AUTHOR`
   and takes zero action on a mismatch, in case the guard sweep loses a claim
   race. See `pack/assets/workflows/con-voyage-ci-repair/{target}.ci-repair.md`.

All three layers resolve the same author the same way:

1. An explicit `CV_PR_AUTHOR` (in `[order.env]` for the two orders, or the
   `cv_pr_author` formula var — default `kriscoleman` in all three places).
2. If unset, fall back to the authenticated `gh` login (`gh api user --jq
   .login`).
3. If it still cannot be resolved, **fail closed** — refuse to act rather than
   guess. The two scripts exit non-zero before querying any repo; Step 0
   drops the bead it was handed.

> **Why this is enforced here, not in the native config.** The
> `[[github.pr_monitor]]` blocks in `city.toml` have no author field and
> `gc github pr backfill` has no `--author` flag, so author scoping cannot be
> expressed natively. Layering all three of the above covers every path by
> which a `con-voyage-ci-repair` bead can come into existence.

To change the allowed author, edit `[order.env] CV_PR_AUTHOR` in
`con-voyage-pr-watch.toml` **and** `con-voyage-ci-repair-guard.toml`, and
`[vars.cv_pr_author] default` in `con-voyage-ci-repair.formula.toml` (or
export `CV_PR_AUTHOR` in the controller environment, which covers both
orders).

### Author-gate toggle (`CV_AUTHOR_GATE`)

The `CV_PR_AUTHOR` allow-list above is itself gated by a feature toggle,
`CV_AUTHOR_GATE`, so a city can run the ci-repair path **either** author-scoped
(the default) **or** on **all PRs** (native `[[github.pr_monitor]]` parity):

| `CV_AUTHOR_GATE` | ci-repair guard + Step 0 behavior |
|---|---|
| `enabled` (**default**) | Fail-closed author scoping — only PRs authored by `CV_PR_AUTHOR` are worked. An empty/unresolved `CV_PR_AUTHOR` drops **everything**. |
| `disabled` | Explicit opt-in — every actionable PR is worked **regardless of author**. |
| anything else | Treated as `enabled` (fail closed on ambiguity). |

**Default is `enabled`, and it stays enabled in this city.** This is a
**deliberate divergence** from the native monitor, whose default is "all PRs":
an earlier *unfiltered* version of this path acted on 43 PRs it did not own
across other people's repos and got the operator **removed from the org**. So we
default gated, and "work all PRs" is an explicit, documented opt-in — never a
silent fall-through.

**The fail-closed invariant is preserved.** `CV_AUTHOR_GATE=enabled` with an
empty/unresolved `CV_PR_AUTHOR` **drops every bead** (the guard exits non-zero
before inspecting any bead; Step 0 drops the bead it was handed). "Work all PRs"
requires the explicit `disabled` toggle — an empty allow-list is *never*
interpreted as "work all". Only the literal `disabled` (case-insensitive)
bypasses the gate.

**Precedence.** `CV_AUTHOR_GATE` decides *whether* the gate runs; `CV_PR_AUTHOR`
decides *which* author it allows once it does. `disabled` short-circuits before
`CV_PR_AUTHOR` is even resolved, so the two are fully decoupled: the disable
opt-in works even with no allow-list set, and never fails closed.

To run the ci-repair path on all PRs, set `CV_AUTHOR_GATE = "disabled"` in
`[order.env]` of `con-voyage-ci-repair-guard.toml` **and** set
`[vars.cv_author_gate] default = "disabled"` in
`con-voyage-ci-repair.formula.toml` (or export `CV_AUTHOR_GATE=disabled` in the
controller environment). Leaving `CV_AUTHOR_GATE` unset keeps the safe, enabled
default.

**What `disabled` does — and does not — reach.** The toggle governs the
**ci-repair worker/guard** decision only:

- The **guard order** (`con-voyage-ci-repair-guard.sh`) reads `CV_AUTHOR_GATE`
  **directly** and short-circuits to a no-op when it is `disabled`, so it stops
  closing non-operator repair beads — that is the switch that lets the ci-repair
  path work all PRs.
- Each **ci-repair bead** carries a `cv_author_gate` var, so its own Step 0
  re-check honors the same toggle when a worker claims it.
- The **`con-voyage-pr-watch` order does NOT read the toggle for its own author
  filtering.** It only *forwards* the value onto each ci-repair bead it mints
  (`--var cv_author_gate=...`); it still applies its own `CV_PR_AUTHOR` scoping
  to decide *which* PRs get a bead in the first place. So `disabled` does **not**
  make pr-watch mint repair beads (Part A) or route review comments (Part B) for
  non-operator PRs — those paths stay `CV_PR_AUTHOR`-scoped, and pr-watch still
  fails closed (exit 1) on an empty/unresolved `CV_PR_AUTHOR` regardless of the
  toggle. Bringing pr-watch's own author gate to full toggle parity is tracked
  separately (bead `fk-08o`).

In short: `disabled` turns off the **guard/worker** author check for ci-repair
beads that already exist; it does **not** widen which PRs pr-watch acts on.

> **Future native-parity story (gc [#6280](https://github.com/gastownhall/gascity/pull/6280)).**
> gc PR #6280 adds an `authors` allow-list to the native `[[github.pr_monitor]]`
> itself (allow-list, with the native "all PRs" behavior when the list is
> empty). Once that lands, `CV_PR_AUTHOR` maps onto the native `authors`
> allow-list and `CV_AUTHOR_GATE` maps onto "list populated vs. empty" — letting
> pack users run the monitor both ways natively. We keep our incident-driven
> divergence regardless: **enabled + empty allow-list drops everything**, so an
> operator who forgets to populate the list is never silently switched into
> working every PR. This toggle is the pack-side bridge until #6280 ships.

### Nothing ever auto-merges

`merge_queue = "observe"` is set in `[[github.pr_monitor]]`. The native monitor
has no merge capability. The `con-voyage-pr-watch` order has no merge capability.
The `con-voyage-ci-repair` formula instructs the implementor to push fixes to the
PR branch and explicitly prohibits merging. **A human must land every PR.**

### Testing the author-scoping invariant

The author-scoping guarantee is security-critical (an earlier unfiltered version
acted on PRs it did not own and got the operator removed from an org), so it has
dedicated regression tests — one per defense-in-depth layer:

```
bash molds/con-voyage-gascity/tests/con-voyage-pr-watch.test.sh
bash molds/con-voyage-gascity/tests/con-voyage-ci-repair-guard.test.sh
```

Both are fully hermetic and offline — they build recording stub `gh` and `gc`
executables in a temp dir, point the script under test at them via `GH=`/`GC=`,
and assert on the recorded call-logs. Neither touches the network or the real
gc runtime. Each exits `0` when every case passes, non-zero otherwise.

`con-voyage-pr-watch.test.sh` covers layer 1 (creation-time gate):

- **Fail-closed** — no resolvable `CV_PR_AUTHOR` ⇒ exit 1 before any repo query.
- **PART A author drop** — only the operator's PR gets a repair bead; other
  humans and bots never do.
- **Exact, case-sensitive match** — `kriscoleman2` and `KRISCOLEMAN` are dropped.
- **Unresolved author** — a PR whose author can't be resolved is dropped.
- **PART B scoping** — `gh pr list` carries `--author <operator>`, and comments
  are routed only for the operator's PRs.
- **Default resolution** — an unset `CV_PR_AUTHOR` falls back to the
  authenticated `gh` login and then scopes to it.

It also covers native-monitor parity (per-state classification, fk-08o):

- **Operator PR in each state → correct `failure_kind`** — a `dirty` /
  `behind` / `blocked` / failed-checks PR each mints a bead carrying the right
  classified token, with `cv_pr_author` still forwarded on every one.
- **Non-operator PR in each state → dropped before mint** — the author gate is
  state-agnostic; exactly the operator's PRs mint, never the others.
- **Classifier precedence** — a PR with `state=blocked` AND a non-empty
  `failed_checks[]` classifies as `checks_failed`, never `blocked`.
- **Non-actionable (clean) PRs never churn.**
- **The minted title is state-aware**, naming the `failure_kind`.
- **PART B surfaces the real `gh` error text** on a `gh pr view` failure
  instead of a bare "skipping" message.

`con-voyage-ci-repair-guard.test.sh` covers layer 2 (the backstop sweep) and
content-checks layer 3 (the workflow's own Step 0 gate):

- **Fail-closed** — no resolvable `CV_PR_AUTHOR` ⇒ exit 1 before inspecting
  any bead.
- **Drop vs. keep** — a non-operator bead is closed with zero other GitHub
  action taken (`gh run rerun` / `gh pr comment` / `gh pr review` / `gc sling`
  all assert to zero); the operator's bead is left untouched for the worker.
- **Exact, case-sensitive match** — `kriscoleman2` and `KRISCOLEMAN` are dropped.
- **Unresolved PR author** — dropped, fail closed.
- **Formula scoping** — a bead whose root is not a `con-voyage-ci-repair`
  workflow is skipped entirely, never even looked up on GitHub.
- **Step 0 content check** — `{target}.ci-repair.md` carries a `## Step 0`
  section that precedes Step 1, the first `gh run rerun`, and the `git push`,
  and that closes a mismatch with a `dropped: not authored by operator` note.
- **Non-destructive retrigger content check** — the run-specific
  `gh run rerun <run-id> --failed --repo` path is present, and the
  close/reopen, empty-commit, and force-push prohibitions are still there.
- **Author-gate toggle (`CV_AUTHOR_GATE`)** — `enabled` (and the default with no
  toggle set) drops non-operator beads; `enabled` + empty allow-list drops
  everything (exit 1, never work-all); `disabled` keeps every bead regardless of
  author (work-all), even with an empty allow-list and without failing closed;
  an unrecognized toggle value falls back to `enabled` (fail closed). The
  disabled/default cases double as mutation guards: reverting the toggle logic
  (or flipping the default to `disabled`) fails the suite.
- **Per-state repair semantics content checks (fk-08o)** — pins the operator's
  locked, signed-off decisions into `{target}.ci-repair.md` and the formula:
  `merge_conflict` still auto-resolves (not surface-only) AND surfaces a
  resolution summary; `behind_base` pushes with `--force-with-lease` (never
  `gh pr update-branch`, never a bare `--force`) and carries the explicit
  reconciliation note distinguishing it from the CI-retrigger force-push ban;
  `blocked` stays a router with a never-self-approve bright line; Step 4
  references `{{failure_kind}}` instead of guessing; the formula declares
  `[vars.failure_kind]`. Reverting any of these to the design doc's original
  (safer-looking but operator-rejected) recommendation fails the suite.

The `tests/` directory lives outside `pack/`, so it is never compiled into the
shipped `packs/con-voyage` pack.

---

## Machine identity & artifact hygiene

Two more defense-in-depth mechanisms, independent of the GitHub monitoring
above: making the machine-identity banner structural (impossible to forget),
and keeping this toolchain's own local scratch state out of every clone's
history.

### `cv-pr-comment.sh` — structural identity banner (no more prose-only rule)

con-voyage runs under the operator's GitHub PAT, so every `gh pr comment` /
`gh pr review` / `gh pr create` it issues shows up as posted by the **human**
(@kriscoleman), not a bot. Text posted without a machine banner is an
impersonation risk. This used to be a prose rule inside
`{target}.ci-repair.md` ("every comment MUST lead with this banner") — and a
worker skipped it in production (a real @kriscoleman-attributed comment with
no machine banner).

`pack/assets/scripts/cv-pr-comment.sh` makes the banner **structural**: it is
the only supported way this pack posts to a PR or issue, and it unconditionally
prepends the banner — there is no passthrough mode.

```bash
cv-pr-comment.sh comment <pr> --repo <owner/repo> --body-file <path> [--formula <name>] [--agent <rig/agent>]
cv-pr-comment.sh review <pr> --repo <owner/repo> (--comment|--approve|--request-changes) --body-file <path> [--formula <name>] [--agent <rig/agent>]
cv-pr-comment.sh create --repo <owner/repo> --title <title> --body-file <path> [--base <branch>] [--head <branch>] [--draft] [--formula <name>] [--agent <rig/agent>]
cv-pr-comment.sh reply-thread <pr> --repo <owner/repo> --comment-id <db_id> --body-file <path> [--formula <name>] [--agent <rig/agent>]
```

`comment` posts at ROOT level (general/summary feedback); `reply-thread` posts a
**threaded reply inside an existing inline review thread** — use it when
addressing one specific inline review-thread comment so the reply lands in that
conversation rather than as a new root-level comment. Its `--comment-id` is the
review comment's numeric DATABASE id (not the GraphQL node-id); it posts via the
review-comment replies API (`POST .../pulls/<pr>/comments/<comment_id>/replies`),
reading the body from the file (`-F body=@<file>`) so — like every other mode —
the body never round-trips through argv. `con-voyage-pr-watch.sh` PART B surfaces
that reply target per inline item as `[reply-thread comment-id:<db_id> @
<path>:<line>]` in the feedback it routes.

Every posted body leads with:

```
🤖 **Automated con-voyage agent** (<formula> / <rig>/<agent>)
```

`{target}.ci-repair.md` and `{target}.publish.md` route every `gh pr comment`
/ `gh pr review` / `gh pr create` through this script and explicitly forbid the
raw `gh` equivalents in the worker path. Enforcement is deliberately structural
rather than a PR-comment scan: a scan of the operator's own comments can't
distinguish a skipped-banner bot post from a genuine human remark (same
PAT-backed author), so it would only ever flag noise — routing every post
through `cv-pr-comment.sh` makes the banner impossible to omit in the first
place.

### `cv-worktree-prep.sh` — external-rig / worktree artifact hygiene

con-voyage (and the ci-repair path) works inside a git worktree or clone —
sometimes of an external target rig, not this operator's own dev environment.
That working copy sits alongside local, operator-specific scratch directories
this toolchain writes as it works: `.beads/`, `.gc/`, `.claude/`, and Dolt's
on-disk data dir (`.dolt/`). None of these belong in the clone's history or
its upstream remote.

```bash
cv-worktree-prep.sh exclude <dir>   # write hygiene patterns into <dir>'s LOCAL
                                     # .git/info/exclude — resolved via `git
                                     # rev-parse --git-path info/exclude`, so
                                     # it works from inside a linked worktree
                                     # too. Never touches the tracked
                                     # .gitignore.
cv-worktree-prep.sh guard <dir>     # commit-step backstop: detect any hygiene
                                     # path staged or already tracked. A
                                     # staged-only offender is unstaged
                                     # (DROPPED); one already committed to
                                     # HEAD is BLOCKED — this script never
                                     # rewrites history.
```

`{target}.ci-repair.md` runs `exclude` right after checking out the PR branch
and `guard` right before committing. `{target}.publish.md` runs `guard` again
immediately before pushing, as a last line of defense.

### Testing machine identity & artifact hygiene

```
bash molds/con-voyage-gascity/tests/cv-pr-comment.test.sh
bash molds/con-voyage-gascity/tests/cv-worktree-prep.test.sh
```

`cv-pr-comment.test.sh` is hermetic/offline via a recording stub `gh`; it
asserts the banner is always the first line of whatever gets posted, that
required args are validated before `gh` is ever invoked, and that there is no
raw-passthrough subcommand. `cv-worktree-prep.test.sh` uses real, local,
throwaway git repos (git itself is fully offline) to prove `exclude` is
idempotent, never touches a tracked `.gitignore`, and resolves the correct
shared exclude file from inside a linked worktree; and that `guard` unstages a
staged-only offender but only ever BLOCKS (never rewrites history for) one
that is already committed. `con-voyage-ci-repair-guard.test.sh` (see above)
also asserts the guard never fetches PR comments at all — banner enforcement
is structural (`cv-pr-comment.sh`), not a scan.

---

## Usage

### Via the `/con-voyage` skill (Claude Code or mayor)

```
/con-voyage <issue|bead|"description"> <rig>
```

Examples:

```
/con-voyage 142 my-rig
/con-voyage bd-abc123 my-rig
/con-voyage "Add retry backoff to the HTTP client" my-rig
```

The skill handles intake (resolves the target to a work bead), detects the dominant
language to pick the native-language floor lens, prompts for roster selection, and
slings the formula.

### Via `gc sling` directly (facilitator/advanced)

The formula exposes one boolean enable var per optional roster lens. Pass
`--var enable_<lens>=true` for each lens you want active on this run. The floor
lanes (security + native-language code review + acceptance + test-evidence +
simplicity) are always active regardless.

Override the native-language code lens when the repo's dominant language is not Go:

| Language | `--var code_lens=` |
|---|---|
| Go | `con-voyage.cv-go-principal-engineer` (default; omit flag) |
| JS / TS | `con-voyage.cv-frontend-principal-engineer` |
| Other | `con-voyage.cv-code-reviewer` |

```bash
gc sling <target> <bead> --formula \
  --var push=true \
  --var open_pr=true \
  [--var code_lens=con-voyage.cv-frontend-principal-engineer] \
  --var enable_product_owner=true \
  --var enable_dev_ex=true \
  --var enable_qa_test=true \
  --var enable_sre=true \
  --var enable_compliance=true
```

**Full list of roster `enable_*` vars** (all default to `"false"`):

| Var | Lens |
|---|---|
| `enable_product_owner` | Product-owner review |
| `enable_founder_cto` | Founder/CTO strategic review |
| `enable_dev_ex` | Developer experience review |
| `enable_standards_janitor` | Standards and conventions review |
| `enable_qa_test` | QA and test-engineering review |
| `enable_sre` | SRE reliability review |
| `enable_design_ux` | Design and UX review |
| `enable_documentation` | Documentation review |
| `enable_marketing` | Marketing review |
| `enable_api_platform` | API and platform contract review |
| `enable_compliance` | Compliance and privacy review |
| `enable_data_db` | Data and database review |

### Review loop semantics

The formula loops until `implementation-review-approved.sh` exits 0 (up to 8
attempts). Each iteration:

1. All active lanes run in parallel and produce PASS/CHANGES REQUIRED verdicts.
2. Any BLOCKING finding triggers a consolidate-all → apply-findings step that runs
   the implementor in the same session (`continuation_group = "con-voyage-review-fixes"`).
3. All active lanes re-run against the new diff.
4. LOW-only findings: the mayor surfaces them to the human (accept vs send back).
5. Zero blocking findings: the loop exits; the PR is opened (or updated).

---

## Authoring note: the pack is a raw pass-through (`process: false`)

Everything under `pack/` is a **Gas City** artifact, not an ailloy blank. The
files are full of gc-runtime template tokens that **gc itself** resolves at
prime / cook / sling time:

- prompt/template-fragment tokens like `{{ "{{" }} define "con-voyage-orchestration" {{ "}}" }}`
  and `{{ "{{" }} .AgentName {{ "}}" }}` (resolved by the gc template engine at `gc prime`),
- graph.v2 formula conditions like `{{ "{{" }}enable_sre{{ "}}" }}` (resolved by the gc
  formula compiler at cook time),
- workflow / formula run-target vars like `{{ "{{" }}push{{ "}}" }}`, `{{ "{{" }}open_pr{{ "}}" }}`,
  `{{ "{{" }}implementation_target{{ "}}" }}`, `{{ "{{" }}pr{{ "}}" }}`, `{{ "{{" }}branch{{ "}}" }}`
  (resolved by gc at sling / backfill time).

ailloy also uses Go `text/template` with `{{ "{{" }}...{{ "}}" }}` delimiters. If ailloy
rendered the pack, its preprocessor would rewrite every `{{ "{{" }}token{{ "}}" }}` to
`{{ "{{" }}.token{{ "}}" }}` and, against ailloy's empty flux context, flatten it to the
literal string `<no value>` — corrupting the pack (unclaimable run-targets,
broken publish/CI-repair steps, mangled `define` blocks).

So the pack output is mapped with **`process: false`** in `flux.yaml`:

```yaml
output:
  pack:
    dest: packs/con-voyage
    process: false
```

That makes ailloy copy the pack verbatim — the gc tokens are stored plainly, in
their native double-brace form, exactly the way gc's own first-party packs ship
them. **Do NOT escape gc tokens in `pack/` files** (no `{{ "{{" }} "{{" {{ "}}" }}` dance);
write them as plain `{{ "{{" }}token{{ "}}" }}`. The single-brace graph.v2 expansion
placeholders (`{target}`, `{code_lens}`, `{implementation_target}`) are likewise
left untouched — Go templating only reacts to double braces.

### Script execute bit — one manual step

ailloy `cast` does not preserve or set file modes: it writes every file `0644`,
so `pack/assets/scripts/*.sh` lose their execute bit on cast even under
`process: false`. gc's order runner execs the script directly
(`exec = "$PACK_DIR/assets/scripts/con-voyage-pr-watch.sh"`), which needs the
bit. After casting, restore it:

```bash
chmod +x packs/con-voyage/assets/scripts/*.sh
```

The source keeps the bit (git mode `100755`); this only re-applies it to the
cast output. If ailloy gains file-mode preservation, this step goes away.

### About `README.md`

`README.md` is a mold **root** file, not part of the pack, so `process: false`
does **not** apply to it — ailloy still renders it as a Go template at cast time.
That is why the token examples in *this* file are still written escaped as
`{{ "{{" }} "{{" {{ "}}" }}...{{ "{{" }} "}}" {{ "}}" }}`: the escaping is what makes them render
as literal `{{ "{{" }}...{{ "}}" }}` in the installed README.
