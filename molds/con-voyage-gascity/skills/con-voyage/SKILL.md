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
gc sling <work-bead> \
  --var push=false \
  --var open_pr=true \
  --var enable_<lens>=true \
  [--var enable_<lens2>=true ...]
```

Each chosen roster lens is activated by its own `--var enable_<lens>=true`. Floor lanes (security, code, acceptance, test-evidence, simplicity) are always active — no var needed.

### Available roster lens vars

| `--var` flag | Lens |
|---|---|
| `enable_product_owner=true` | Product owner: appetite, usability (buyer + end-customers), docs gate |
| `enable_founder_cto=true` | Founder/CTO: strategy, appetite vs. cost, architecture risk |
| `enable_dev_ex=true` | Developer experience: APIs, extension-point ergonomics, adoption mechanics |
| `enable_standards_janitor=true` | Standards janitor: conventions, lint, hygiene, dead code |
| `enable_qa_test=true` | QA/test engineer: test coverage gaps, edge cases, regression risk |
| `enable_sre=true` | SRE/reliability: observability, failure modes, operational risk |
| `enable_design_ux=true` | Design/UX: flows, defaults, error messages |
| `enable_documentation=true` | Documentation: correctness, completeness, discoverability |
| `enable_marketing=true` | Marketing: messaging, positioning, launch readiness |
| `enable_api_platform=true` | API/platform contract: API design, backward compat, contract stability |
| `enable_compliance=true` | Compliance/privacy: regulatory risk, data handling, GDPR/SOC2 |
| `enable_data_db=true` | Data/database engineer: schema, migrations, query correctness |

## The Journey (summary)

Full orchestration detail lives in the `con-voyage-orchestration` template fragment. In brief:

```
Intake → work bead + convoy
  → SLING formula  (gc sling ... --var push=false --var open_pr=true --var enable_<lens>=true)
  → REVIEW LOOP   (floor lanes + chosen roster in parallel; blocking findings → fix → re-run)
  → PR opened (push=false, open_pr=true); never auto-merged
  → HUMAN LANDS   (you open the PR; a human merges or closes it)
```

`push=false open_pr=true` is mandatory — the PR is opened but the branch is never auto-merged. A human lands it.

Consult the `con-voyage-orchestration` fragment for the full phase-by-phase runbook: intake, convoy creation, roster rules, Phase 2 sling, feedback routing, PR posterity comments, lockstep docs PR, and landing protocol.
