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
to origin and a PR is opened. The `[[github]]` monitor (see § "Per-rig `city.toml`
snippet" below) is configured with `merge_queue = "observe"` — observe only, never
auto-merges. That monitor setting is what enforces the never-merge invariant, not
suppressing the push. A human must land the PR.

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
# GitHub PR monitor — CI + human feedback; observe only, never auto-merges
[[github]]
name = "<rig>-prs"
owner = "<org>"
repo  = "<repo>"
base_branches = ["main"]
rig   = "<rig>"
notify       = ["mayor"]
repair_route = "<rig>/gc.implementation-worker"
merge_queue  = "observe"

# Run every reviewer lens on opus for this rig (one entry per cv-* agent)
[[patches.agent]]
rig = "*"; name = "cv-security-reviewer"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-go-principal-engineer"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-frontend-principal-engineer"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-code-reviewer"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-product-owner"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-founder-cto"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-dev-ex-reviewer"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-standards-janitor"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-qa-test-engineer"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-sre-reliability"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-design-ux"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-documentation"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-marketing"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-api-platform-contract"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-compliance-privacy"; provider = "opus"

[[patches.agent]]
rig = "*"; name = "cv-data-db-engineer"; provider = "opus"

# Wire the chief-of-staff orchestration fragment into the mayor
[mayor]
append_fragments = ["con-voyage-orchestration"]
```

The `merge_queue = "observe"` setting tells the `[github]` monitor to watch PRs for
CI results and human feedback but never to enqueue them for automatic merging.

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

## Authoring note: double-templating

Files under `pack/` that end in `.template.md` go through **two** render passes:

1. **ailloy** renders them as Go templates at `ailloy cast` time (substituting
   mold vars like `{{ "{{" }}.Name{{ "}}" }}`).
2. **Gas City** renders them again as prompt templates at `gc prime` time (substituting
   city/rig vars).

Any gascity template expression that must survive the ailloy pass — such as
`{{ "{{" }}define "con-voyage-orchestration"{{ "}}" }}` or `{{ "{{" }}enable_sre{{ "}}" }}` — must be
escaped in the mold source as:

```
{{ "{{" }} "{{" {{ "}}" }} ... {{ "{{" }} "}}" {{ "}}" }}
```

Plain `.md` files (not `.template.md`) are copied verbatim by ailloy and only
rendered by gascity at prime time, so no escaping is needed in those files.

`README.md` itself is rendered by ailloy at cast time (it is not listed in
`.ailloyignore`). Any literal `{{ "{{" }}...{{ "}}" }}` in README code blocks must be escaped the
same way.
