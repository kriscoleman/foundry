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
  delivery pipeline: build (if needed) → setup → parallel review lanes →
  synthesize → apply findings → loop until approved → push branch → open PR.
  `push=true` and `open_pr=true` by default; the work branch is pushed to
  origin and a PR is opened, but `merge_queue="observe"` in `city.toml`
  prevents any auto-merge path. A human must land the PR.

- **One-sling build phase (fk-9aunv)** — a single `gc sling <target> <bead>
  --formula` on a FRESH bead (no pre-built branch yet) now builds it first: the
  `{target}.prepare-build` / `{target}.build` steps run do-work's own first TDD
  round as con-voyage's own first phase, before setup and the review loop. This
  is fully automatic and backward compatible — a bead that already has a
  pre-built branch (e.g. from a prior `gc sling ... --on do-work`) is detected
  at runtime and the build phase short-circuits straight to setup, so the old
  two-step (`do-work` then `con-voyage --force`) still works, it is just no
  longer required.

- **Work-bead lifecycle** — the formula now drives the *work bead* it delivers
  through its full lifecycle so it moves on the dashboard and never sits open
  after its PR lands (see § "Work-bead lifecycle" below): setup claims it
  (`--claim` → in_progress), seeds its description, and labels it `cv:reviewing`;
  each review cycle appends a verdict/finding-count note; publish records the PR
  URL and flips it to `cv:awaiting_merge`; and the new `con-voyage-finalize`
  order closes it (with an accurate reason), closes the convoy, and releases the
  implementor when the PR merges or closes.

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

- **`gc-slack` shared skill** (`packs/con-voyage/skills/gc-slack/`) — a
  binding-qualified skill (`con-voyage.gc-slack` once the pack is imported)
  teaching any agent in the city — not just the mayor — how to send and read
  Slack messages through an imported Slack pack's `gc slack` CLI: replying,
  reacting, posting proactively, and delegating, plus the CLI's sharp edges
  (session id vs. alias, `--conversation-id` on multi-binding sessions,
  `--thread-current` vs. `--reply-to`, etc). See "Pack-shared skills vs. the
  Claude Code skill" below for how this differs from item 2.

### 2. A thin `/con-voyage` Claude Code skill (`.claude/skills/con-voyage/`)

An ergonomic `/con-voyage <issue|bead|"desc"> <rig>` launcher for human Claude Code
sessions and the mayor itself. It verifies the pack is imported, does intake, helps
select the roster, and slings the formula. All heavy orchestration lives in the pack.

### Pack-shared skills vs. the Claude Code skill

Two different directories in this mold are both named `skills/`, and they
reach completely different audiences:

- **`pack/skills/<name>/SKILL.md`** (inside the pack) casts to
  `packs/con-voyage/skills/<name>/`. Once the pack is imported
  (`gc import add ./packs/con-voyage`), `gc` materializes it to every agent's
  provider skill directory as a binding-qualified shared skill
  (`con-voyage.<name>`) — the same mechanism the bundled `core` pack uses for
  `core.gc-mail` / `core.gc-work`. Use this location for anything any agent
  in the city should be able to reach.
- **Mold-root `skills/<name>/SKILL.md`** (sibling to `pack/`, mapped by
  `flux.yaml`'s `output.skills.dest: .claude/skills`) casts straight to
  `.claude/skills/<name>/` in the target city root. It is never part of the
  imported pack, so it only ever reaches human Claude Code sessions (including
  the mayor's own Claude Code session) — never a worker or reviewer-lens
  agent running under a different provider. The `/con-voyage` launcher above
  is the only skill of this kind today.

Run `gc skill list` from inside a target city to see both: city pack skills,
and imported pack shared skills under their binding-qualified name.

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

### GitHub stacked PRs (fk-qppb4) — base-branch threading and its boundary

A con-voyage journey can target a branch other than the repo default so slice
N+1 stacks on slice N's own PR branch. Set it once per journey, before
launching do-work/con-voyage against the journey's convoy — reusing the
existing convoy-target primitive rather than a parallel formula var, since a
convoy already carries exactly this field for child work beads to inherit:

```bash
gc convoy target <input-convoy-id> <base-branch>
```

`con-voyage-lib.sh`'s `cv_resolve_base_branch` reads this back (falling
through to today's `origin/HEAD -> origin/main -> main` default when unset —
byte-identical behavior for every non-stacked journey) and threads it through
the setup step's worktree-base correction (`cv_ensure_branch_based_on`), the
hygiene guard's base-ref, and the PR `--base` on create.

**Known boundary — Part A (CI repair) does not see a stacked PR until its
base is listed in `base_branches`.** Part A's actionable-PR discovery goes
through the native `gc github pr backfill`, which only evaluates PRs whose
base matches a configured `[[github.pr_monitor]].base_branches` entry — that
matching happens inside `gc` itself, outside this pack's repo. Add every
active stacked base branch to `base_branches` in `city.toml` (or add a second
monitor block) before that slice's PR opens, or its CI failures will not get
a repair bead. Part B (human comment routing) is unaffected — `gh pr list
--author "$CV_PR_AUTHOR"` above already lists every open PR for that author
regardless of base — and `con-voyage-finalize` is unaffected too, since it
polls one specific PR number directly rather than filtering by base. A native
`base_branches` glob/pattern match (so one config entry covers a whole family
of stacked branches, instead of a per-slice manual `city.toml` edit) is
tracked as follow-up core work outside this pack's repo, not forked in here.

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

### `con-voyage-repair-watchdog` order (self-heal dead/stalled rework)

`con-voyage-pr-watch` gets "every open PR has exactly one live implementor"
right **at dispatch time**, but nothing re-checks that between its own
10-minute cycles — a reused implementor can die mid-rework, or a rework
(mailed or a fallback pool bead) can simply stop making progress. Fixes 1's
own state record (`implementor_session`/`inflight_rework`/`last_handled_state`
— see "Repair routing and dedup" above) already carries everything needed to
notice this drift; `con-voyage-repair-watchdog` reads those SAME state
records on its own, faster, 5-minute cooldown and self-heals:

- **Implementor known but dead** → supersedes the tracked bead and dispatches
  a fresh fallback worker (the exact mechanism `con-voyage-pr-watch` itself
  uses when no implementor is known). No staleness threshold gates this — a
  confirmed-dead session is unambiguous on its own.
- **No implementor known yet, and the fallback bead has sat unclaimed past
  `CV_STALL_SECONDS`** (default 900s / 15m) → same fallback re-dispatch. A
  freshly-minted, still-unclaimed bead within that window is left alone.
- **Implementor known and alive, but the tracked bead's `updated_at` hasn't
  advanced past `CV_STALL_SECONDS`** → re-notifies the *same* implementor
  directly (`gc mail send ... --notify`, no new bead — mirrors
  `con-voyage-pr-watch`'s own reuse path) and keeps watching the *same*
  bead; its `updated_at` is the progress signal the next cycle checks.
- **Implementor alive and progressing, or no in-flight rework at all** → no
  action.
- **After `CV_MAX_ATTEMPTS` (default 3) consecutive re-dispatches with still
  no progress** → escalates to `CV_ESCALATE_TARGET` (default the reserved
  `human` alias, same convention as `escalation_target` in
  `con-voyage-ci-repair.formula.toml`) via `gc mail` and stops re-dispatching
  that PR. Escalation only lifts once `con-voyage-pr-watch` records a
  genuinely fresh dispatch for it (a real state change — see below), never by
  the watchdog trying again on its own.

**State schema extension.** The watchdog needs a few fields
`con-voyage-pr-watch`'s original 3-field record didn't carry, so that record
now also includes `pr_author`, `repair_route`, `repo_full`, `pr_number`,
`branch` (everything needed to defensively re-verify author scope and mint a
fallback bead without any `gh` call), plus `attempt_count` and `escalated`
(the watchdog's own bookkeeping). `con-voyage-pr-watch` populates the first
five and resets `attempt_count`/`escalated` to `0` on every fresh dispatch,
preserves all seven unchanged on an in-flight-refresh skip cycle, and resets
them again once the PR goes clean; the watchdog only ever increments
`attempt_count` and sets `escalated` on its own writes. A closed/unknown
tracked bead, or a record missing the redispatch-context fields (e.g. one
`con-voyage-pr-watch` hasn't rewritten since this extension shipped), is left
untouched rather than guessed at — the next `con-voyage-pr-watch` cycle owns
re-evaluating those from scratch.

**No GitHub calls.** Unlike the other two orders, this script makes no `gh`
calls in its core logic at all — it only ever iterates local
`CV_STATE_DIR/*.state` files and calls `gc`. `gh` is consulted only for the
optional `CV_PR_AUTHOR` auto-resolve fallback, same as the other two scripts,
and is skipped entirely when `CV_PR_AUTHOR` is set explicitly (as it always is
in the shipped `[order.env]`).

**Rebuild note.** An earlier, unshipped build (commit `13d403a`) added this
same self-heal idea as an *inline* staleness check inside
`con-voyage-pr-watch.sh`'s own PART A loop, predating the implementor-reuse
state schema. This order is a ground-up rebuild against the current schema, as
a standalone periodic order — the inline version was not reused.

### Review-lane liveness guard (fk-loo1 FIX-F: PRIMARY in-loop check + `con-voyage-review-watchdog` order)

Review lenses are pool-managed and their only task delivery is a core
nudge-on-route mechanism. On a slow-startup (large) repo a lens can take
minutes to wake; if the pool restarts its still-starting run-operator in that
window, the review-lane bead it would have claimed is left open+unassigned
forever — the review loop can never fan in and the implementor waits forever
(the dogfooding root cause behind this fix; foundry-kc itself dodges it only
by waking its own roster fast enough to claim on the first nudge). This is
fixed in two complementary layers, mirroring the CI-repair watchdog's own
primary-check-plus-periodic-backstop shape:

- **PRIMARY — in-loop claim verification**, added directly to
  `{target}.con-voyage-review-loop.md`. After each fan-out (the initial one
  and every re-run after applying findings), it polls the cycle's active
  lanes — discovered from the claimed review-loop step bead's own
  `tracks`-dependents, filtered to the `"Con-voyage: "` lane-title prefix so
  sibling scope members (`Apply con-voyage review findings`, `Synthesize
  con-voyage review`) are never mistaken for lanes. A lane still
  open+unassigned past `cv_lens_claim_seconds` (default 300s) gets touched
  (bumping `updated_at`, which re-fires nudge-on-route) and its live pool
  session nudged directly; if the routed pool has **no** live session at all,
  it is immediately re-routed via `gc sling <routed_to> <lane> --nudge`
  instead (no staleness gate — a confirmed-empty pool is unambiguous on its
  own). Bounded to `cv_lens_max_redispatch` (default 3) attempts per lane,
  then escalates via `gc mail send cv_lens_escalate_target` and stops
  re-dispatching that one lane, without blocking the rest of the cycle.

- **DEFENSE-IN-DEPTH — `con-voyage-review-watchdog` order** (independent,
  5-minute cooldown). Catches the case the inline check cannot: the
  review-loop's own run-operator session is the thing that died, so nobody is
  even running the inline poll anymore. It discovers every open/in_progress
  review-lane bead city-wide with a single `bd list --has-metadata-key
  gc.ralph_step_id` query (no external state file — unlike
  `con-voyage-repair-watchdog`, a review-lane bead has no gap in its bd-native
  lifecycle to paper over, so attempt/escalation bookkeeping lives directly on
  the lane bead's own `gc.review_watchdog.*` metadata) and applies the same
  remedy shape: an open+unassigned lane with a live routed pool gets nudged
  directly once stalled past `CV_LENS_STALL_SECONDS` (default 600s), a lane
  whose pool has no live session at all is re-routed immediately, and a
  claimed-but-stalled lane is re-notified via its own assignee session (never
  re-routed out from under it — the inline check owns re-dispatch decisions
  with fuller context). `CV_LENS_MAX_ATTEMPTS` (default 3) and
  `CV_LENS_ESCALATE_TARGET` (default `human`) mirror the inline vars under a
  deliberately distinct `CV_LENS_` prefix so the two watchdogs' tunables never
  collide with `con-voyage-repair-watchdog`'s own `CV_STALL_SECONDS`/
  `CV_MAX_ATTEMPTS`/`CV_ESCALATE_TARGET`. No GitHub calls are made anywhere in
  this script — review lanes are internal gc beads, not PRs, so there is no
  author-scoping concern.

On a fast repo where lenses claim on the first nudge (foundry-kc itself),
both layers see every lane claimed well within their grace windows and take
no action — no extra churn.

**Testing:** `bash molds/con-voyage-gascity/tests/con-voyage-review-watchdog.test.sh`
covers the watchdog order end to end (never-claimed vs. claimed-but-stalled
lanes, pool-drained re-route vs. live-pool nudge, bounded escalation across
multiple cycles, malformed-metadata fail-safes) and content-checks the
PRIMARY in-loop block's required shape in `{target}.con-voyage-review-loop.md`
and the `cv_lens_*` var defaults in `con-voyage.formula.toml`. The
`session_id_for_ident`/`first_alive_session_id_for_route` helpers it shares
with `con-voyage-lib.sh` are unit-tested directly in
`tests/con-voyage-lib.test.sh`.

### `con-voyage-finalize` order (work-bead lifecycle: claim → close on land)

Before this, con-voyage managed only *repair* beads — it issued **zero** `bd`
calls against the **work bead** it was delivering, and the gc runtime does not
auto-transition beads. So the work bead never moved on the dashboard, its
description was whatever intake left (often empty), and it stayed `open`
forever after its PR merged (e.g. `fk-eiw`/#29 and `fk-wgl`/#27 sat `open` for
~2 days after their PRs merged, closed by hand). This order — plus small `bd`
additions in the formula's workflow steps — closes that gap end to end.

**Where the work bead lives.** In this `graph.v2` formula the `{{convoy_id}}`
token resolves to a **synthetic input convoy** (`gc.synthetic=true`,
`issue_type=convoy`) that `tracks` the real work bead. The workflow steps
resolve the work bead from `{{convoy_id}}` (convoy → its `tracks` dependency;
a non-convoy id is already the work bead — see `cv_resolve_work_bead` in
`con-voyage-lib.sh` and the inline resolver snippet in
`{target}.setup-con-voyage-review.md`). The `con-voyage-ci-repair` formula's
own `{{convoy_id}}` is a *repair* bead — a different formula; the two are never
confused.

**The lifecycle, stage by stage:**

| Stage | Work-bead action | Where |
|---|---|---|
| setup | `bd update <wb> --claim` (→ in_progress) + seed description (branch, base, roster, PR target) + `bd set-state <wb> cv=reviewing` | `{target}.setup-con-voyage-review.md` |
| review loop | append a per-cycle `bd note` (verdict + BLOCKING/LOW counts); stays `cv:reviewing` | `{target}.con-voyage-review-loop.md` |
| publish (PR open) | `bd update <wb> --set-metadata pr_url=<url>` + PR note + `bd set-state <wb> cv=awaiting_merge`; write the per-PR `.finalize` record | `{target}.publish.md` |
| PR merge/close | close `<wb>` (accurate reason) + close convoy + release implementor + rm record; while still open, keep `cv=` phase in sync (`awaiting_merge` clean / `repairing` red) | `con-voyage-finalize.sh` |

`cv=<phase>` is set via `bd set-state` — a **custom dimension** that renders as
a `cv:<phase>` dashboard label — NOT the primary status. Primary status stays
`in_progress` (via `--claim`) until the finalize monitor closes the bead on
land; there is no native `awaiting_merge` status, so that phase is modelled as
the `cv` dimension while status stays `in_progress`.

**The finalize monitor** (`con-voyage-finalize.sh`, a 5-minute cooldown order)
is the teardown side. The publish step writes a per-PR `.finalize` record under
`CV_STATE_DIR` (default `.gc/cv-pr-watch`, same dir the PR-watch orders use)
carrying `work_bead`, `convoy_id`, `repo_full`, `pr_number`, `pr_author`, and
`implementor_session`. This record is the **only reliable work-bead↔PR map**
for a clean, review-approved PR — the repair `.state` records exist only for
PRs with a CI failure, so they cannot serve that role. The monitor globs
`*.finalize`, polls each PR via one `gh pr view`, and:

- **merged** → close the work bead `"landed: PR #N merged"`, close the convoy,
  mail the implementor a release note, remove the record;
- **closed without merge** → same, with `"abandoned: PR #N closed without
  merge"`;
- **still open** → reflect the live phase on the work bead as a `cv=` label
  (`awaiting_merge` when clean / only awaiting human review; `repairing` when a
  check is failing, the branch is `DIRTY`/conflicting, or it is `BEHIND` base),
  idempotent via the record's `last_phase`;
- **unresolved state (gh error)** → fail safe: touch nothing, retry next cycle.

Every action is idempotent (re-closing an already-closed bead is a guarded
no-op via `close_if_open`; a re-poll after the record is gone is a clean
no-op) and **author-scoped**: a record whose `pr_author` is not `CV_PR_AUTHOR`
is skipped before any poll — the same fail-closed HARD INVARIANT as the other
two monitors. It **never** merges, force-pushes, comments on a PR, or kills a
session (releasing the long-lived implementor is a best-effort *mail*, not a
kill — the monitor cannot prove exclusive session ownership from a record
alone). See `con-voyage-finalize.toml` for the tunables (`CV_PR_AUTHOR`,
`CV_RELEASE_IMPLEMENTOR`).

### Coverage table

| Signal | Native monitor | pr-watch order | repair-watchdog order | finalize order |
|---|---|---|---|---|
| Failed CI check-runs | Yes | Driven (Part A) | — | — |
| Merge conflict (DIRTY) | Yes | Driven (Part A) | — | — |
| Branch behind base | Yes | Driven (Part A) | — | — |
| Branch-protection block | Yes | Driven (Part A) | — | — |
| Human review comments | No | Yes (best-effort, Part B) | — | — |
| Dead implementor mid-rework | No | No | Yes (reassigns) | — |
| Stalled rework (no progress) | No | No | Yes (re-dispatches, then escalates) | — |
| Work-bead status/phase/description | No | No | No | Yes (claim/phase/note; setup+loop+publish steps too) |
| Work-bead close on PR merge/close | No | No | No | Yes (close bead+convoy, release implementor) |
| Auto-merge | Never | Never | Never | Never |

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

**Dedup.** A re-dispatch is blocked *only* while a tracked fallback bead, if
any, is still open — **status alone gates it**, not assignee and not
failure_kind (a pool-slung bead sits unclaimed with an empty assignee for an
unbounded time before a worker picks it up, so requiring a live assignee here
was the historical over-mint bug: a repair that was still legitimately
pending got treated as abandoned and re-minted every cycle). A closed (or
never-tracked) bead never blocks a fresh dispatch: a new one is minted in its
place.

**Reclassification while in-flight (update, never supersede).** When the
SAME open tracked bead's failure_kind changes mid-flight (e.g. `blocked`
flipping to `checks_failed` on a later cycle), the monitor no longer
supersedes it and mints a fresh one — that behavior was implicitly keyed on
(PR-number, failure_kind), so a PR whose classification kept flipping minted a
new orphaned bead on every single flip (confirmed live: kots#6067 oscillated
`blocked`<->`checks_failed` on its ~10-minute cooldown). Instead the SAME bead
is updated in place (`bd update <bead> --title ... --set-metadata
failure_kind=...`) so its title and metadata reflect the current
classification, and `last_handled_state` advances — without spawning a second
implementor for one PR. A failed update is retried next cycle rather than
silently dropped.

**Re-detection.** A truly new problem cycle — no bead is currently tracked and
open (the prior one closed, or the PR was previously `clean`) — always
dispatches exactly one fresh rework, so a stale record can never permanently
suppress a real, newly-observed defect. A PR that is already clean is left
alone; its record is refreshed to `last_handled_state=clean` (and any
still-open tracked bead is closed) purely so a *later* re-conflict has a real
prior state to compare against.

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
This is enforced by four independent, defense-in-depth layers, so that no
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
4. **`con-voyage-repair-watchdog` order (state-record re-check).** Before
   acting on any per-PR state record, re-verifies its recorded `pr_author`
   against its own `CV_PR_AUTHOR` and skips (no bead read, no mail, no
   dispatch) on a mismatch or an empty/unresolved value — see
   "`con-voyage-repair-watchdog` order" above.

All four layers resolve the same author the same way:

1. An explicit `CV_PR_AUTHOR` (in `[order.env]` for the three orders, or the
   `cv_pr_author` formula var — default `kriscoleman` in all four places).
2. If unset, fall back to the authenticated `gh` login (`gh api user --jq
   .login`).
3. If it still cannot be resolved, **fail closed** — refuse to act rather than
   guess. The three scripts exit non-zero before querying any repo (or, for
   the watchdog, before reading any state record); Step 0 drops the bead it
   was handed.

> **Why this is enforced here, not in the native config.** The
> `[[github.pr_monitor]]` blocks in `city.toml` have no author field and
> `gc github pr backfill` has no `--author` flag, so author scoping cannot be
> expressed natively. Layering all four of the above covers every path by
> which a `con-voyage-ci-repair` bead can come into existence or be acted on.

To change the allowed author, edit `[order.env] CV_PR_AUTHOR` in
`con-voyage-pr-watch.toml`, `con-voyage-ci-repair-guard.toml`, **and**
`con-voyage-repair-watchdog.toml`, and `[vars.cv_pr_author] default` in
`con-voyage-ci-repair.formula.toml` (or export `CV_PR_AUTHOR` in the
controller environment, which covers all three orders).

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
bash molds/con-voyage-gascity/tests/con-voyage-repair-watchdog.test.sh
```

All three are fully hermetic and offline — they build recording stub `gh`
and/or `gc` executables in a temp dir, point the script under test at them via
`GH=`/`GC=`, and assert on the recorded call-logs. None touches the network or
the real gc runtime. Each exits `0` when every case passes, non-zero
otherwise.

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

`con-voyage-repair-watchdog.test.sh` covers layer 4 (the state-record
re-check) plus the watchdog's own self-heal/escalation behavior:

- **Fail-closed** — no resolvable `CV_PR_AUTHOR` ⇒ exit 1 before reading any
  state record.
- **Author-scope skip** — a record whose `pr_author` doesn't match (or is
  empty/unresolved) is skipped defensively: no `bd show`, no mail, no sling.
- **No in-flight rework / already escalated** — both are left strictly alone,
  including no repeated escalation mail once `escalated=1` is already set.
- **Closed/unknown tracked bead** — deferred to `con-voyage-pr-watch`'s own
  next cycle rather than guessed at.
- **Dead implementor** — the stale bead is superseded and a fresh fallback
  bead is minted and slung with the recorded `pr`/`repo`/`branch`/
  `failure_kind`, `attempt_count` advances to 1.
- **Stalled but alive** — the SAME implementor is re-notified by mail, no new
  bead, the SAME tracked bead keeps being watched.
- **Never-claimed fallback bead** — treated as stalled once past the
  threshold (same fallback remedy as dead); left alone within the grace
  period.
- **Attempt cap → escalation** — an end-to-end, multi-cycle run drives
  `attempt_count` from 1 to 3 across three consecutive stalled cycles, then
  proves the 4th detection escalates (mail to `CV_ESCALATE_TARGET`, including
  a custom target) instead of re-dispatching a 4th time, sets `escalated=1`,
  and confirms a 5th cycle sends no mail of any kind (no escalation spam).
- **Failed escalation mail never sets `escalated=1`** — a transient mail
  outage is retried next cycle rather than silently and permanently
  suppressing re-dispatch.
- **Missing redispatch context** — a record without `repair_route`/
  `repo_full`/`pr_number` (e.g. pre-dating this extension) logs a WARNING and
  leaves `attempt_count` untouched rather than guessing.

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
   Each fan-out is claim-verified — see [Review-lane liveness
   guard](#review-lane-liveness-guard-fk-loo1-fix-f-primary-in-loop-check--con-voyage-review-watchdog-order)
   — so a lens that never wakes gets re-dispatched instead of stalling the
   loop forever.
2. Any BLOCKING finding triggers a consolidate-all → apply-findings step that runs
   the implementor in the same session (`continuation_group = "con-voyage-review-fixes"`).
3. All active lanes re-run against the new diff (claim-verified again).
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
bit. After casting, restore it — including the `checks/` subdirectory, which
the plain `assets/scripts/*.sh` glob does not reach:

```bash
chmod +x packs/con-voyage/assets/scripts/*.sh packs/con-voyage/assets/scripts/checks/*.sh
```

The source keeps the bit (git mode `100755`); this only re-applies it to the
cast output. If ailloy gains file-mode preservation, this step goes away.
(`cv-ensure-gate-scripts.sh` below re-applies the exec bit itself to whatever
it seeds into a rig's `.gc/scripts/checks/`, so a forgotten chmod here does
not block the gate scripts specifically — but the manual step is still needed
for every other `pack/assets/scripts/*.sh` entry point.)

### Gate check scripts — shipped and self-seeded (fk-6i53)

The `con-voyage-review-loop` and workflow-finalize gates are graph.v2
`mode = "exec"` checks that reference `.gc/scripts/checks/*.sh` by path,
resolved relative to the rig root — `.gc/` is local, non-committed, rig-specific
state, never touched by `ailloy cast`. The pack ships the two check scripts
(`pack/assets/scripts/checks/build-artifact-valid.sh` and
`implementation-review-approved.sh`) and the con-voyage-review formula's setup
step runs `cv-ensure-gate-scripts.sh` to seed any missing one into
`.gc/scripts/checks/` before the review loop is ever dispatched, without
overwriting a rig-local customization if one already exists. `publish.md` also
runs `cv-verify-review-approved.sh` as a defense-in-depth check immediately
before pushing or opening a PR: it re-derives the review loop's true
gc.outcome directly, instead of trusting graph dispatch, so a quarantined or
otherwise-broken gate can never silently read as "review approved" downstream.

`build-artifact-valid.sh` itself further depends on a `validate_build_artifact.py`
validator and a `schemas/build/*.yaml` schema set, both resolved relative to the
rig root (`.gc/scripts/validate_build_artifact.py` and `schemas/build/`). The
pack ships both (`pack/assets/scripts/validate_build_artifact.py` and
`pack/assets/schemas/build/*.yaml`) and the same setup step runs
`cv-ensure-build-artifact-validator.sh` to seed whichever of them is missing,
right after `cv-ensure-gate-scripts.sh`, without overwriting a rig-local
customization if one already exists (fk-ohoy).

### About `README.md`

`README.md` is a mold **root** file, not part of the pack, so `process: false`
does **not** apply to it — ailloy still renders it as a Go template at cast time.
That is why the token examples in *this* file are still written escaped as
`{{ "{{" }} "{{" {{ "}}" }}...{{ "{{" }} "}}" {{ "}}" }}`: the escaping is what makes them render
as literal `{{ "{{" }}...{{ "}}" }}` in the installed README.
