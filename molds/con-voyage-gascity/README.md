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
   by `CV_PR_AUTHOR`, and creates a repair bead only for each surviving
   actionable PR (Part A — CI repair, author-scoped).
2. For each configured monitor's repo, lists the configured author's open
   non-draft PRs (`gh pr list --author "$CV_PR_AUTHOR"`) and checks for
   new human review comments and review feedback since the last run (Part B —
   comment routing). Comments prefixed with `[<rig>/<agent> — <lens>]`
   (con-voyage reviewer identity) and known bot logins are excluded. New human
   feedback is routed to the implementor via `gc sling`. Idempotency is
   maintained via a state file keyed by `(repo, PR-number, max-comment-id)` so
   the same comment is never routed twice.

### Coverage table

| Signal | Native monitor | pr-watch order |
|---|---|---|
| Failed CI check-runs | Yes | Driven (Part A) |
| Merge conflict (DIRTY) | Yes | Driven (Part A) |
| Branch behind base | Yes | Driven (Part A) |
| Branch-protection block | Yes | Driven (Part A) |
| Human review comments | No | Yes (best-effort, Part B) |
| Auto-merge | Never | Never |

### Author scoping

**The monitor only ever touches PRs authored by a single configured user.**

Both duties of the `con-voyage-pr-watch` order are scoped to the login in the
`CV_PR_AUTHOR` environment variable:

- **Part A (CI repair)** runs `gc github pr backfill --json` *report-only* (never
  `--create-repair-beads`), then resolves each actionable PR's author via `gh` and
  **drops every PR whose author is not `CV_PR_AUTHOR`** before creating any repair
  bead. A PR whose author cannot be resolved is treated as "not ours" and skipped
  (fail closed). The hard invariant: **zero repair beads are ever created for a PR
  not authored by `CV_PR_AUTHOR`.**
- **Part B (comment routing)** passes `--author "$CV_PR_AUTHOR"` to `gh pr list`,
  so only the configured author's open PRs are ever polled or routed.

`CV_PR_AUTHOR` resolution:

1. `[order.env]` in `con-voyage-pr-watch.toml` sets it explicitly (default
   `kriscoleman`; change it to your own login when casting for a different user).
2. If unset there, the script defaults to the authenticated `gh` login
   (`gh api user --jq .login`).
3. If it still cannot be resolved, the script **fails closed** — it prints an
   error and exits non-zero **before querying any repo**. It never runs unscoped.

> **Why this is enforced in the script, not the native config.** The
> `[[github.pr_monitor]]` blocks in `city.toml` have no author field and
> `gc github pr backfill` has no `--author` flag, so author scoping cannot be
> expressed natively. The `con-voyage-pr-watch` script is the sole runtime driver
> of the monitor (the native `poll_interval` is inert without it), so scoping it
> here covers every path by which the monitor can act on a PR.

To change the allowed author, edit `[order.env] CV_PR_AUTHOR` in
`con-voyage-pr-watch.toml` (or export `CV_PR_AUTHOR` in the controller
environment).

### Nothing ever auto-merges

`merge_queue = "observe"` is set in `[[github.pr_monitor]]`. The native monitor
has no merge capability. The `con-voyage-pr-watch` order has no merge capability.
The `con-voyage-ci-repair` formula instructs the implementor to push fixes to the
PR branch and explicitly prohibits merging. **A human must land every PR.**

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
