# Kris Coleman's Foundry

An [Ailloy](https://github.com/nimble-giant/ailloy) foundry of Gas Town and Claude Code workflow molds.

This repo is both a **foundry index** (a catalog for mold discovery) and a **monorepo** that holds the molds themselves under `molds/`.

## Register and use

Register this foundry with ailloy:

```bash
ailloy foundry add https://github.com/kriscoleman/foundry
```

Search across registered foundries:

```bash
ailloy foundry search con-voyage
```

Or cast a mold directly:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/con-voyage-gastown
```

## Molds

| Name | Description |
|------|-------------|
| [con-voyage-gastown](molds/con-voyage-gastown) | Gas Town (gt) orchestration: deliver an issue with a polecat team through implementation, code/security review, CI, and human-review loops — and never merge until a human does. Claude Code / Gas Town specific. |
| [con-voyage-gascity](molds/con-voyage-gascity) | Gas City-native con-voyage: casts a chief-of-staff + reviewer lenses + delivery loop into a gas city. |
| [engineering-planning](molds/engineering-planning) | Conversational Agile-Coach / Scrum-Master facilitator: interview stakeholders, brainstorm work items, refine them into create-issue-format GitHub issues with epic/sub-issue decomposition, gate on explicit consensus, then create the issues via `gh` and optionally track them as a GitHub Projects iteration. |

## Developing

Molds live in `molds/<name>/`. Local checks (auto-installs ailloy if missing):

```bash
make test        # temper (structure) + assay (instruction quality) + markdown link check
make cast-test   # test-cast every mold into a temp dir
```

CI runs the same validation on every PR via `.github/workflows/mold-validate.yml`.

## Adding a mold

1. Create `molds/<name>/` with `mold.yaml`, `flux.yaml`, `flux.schema.yaml`, and your content (`skills/`, `agents/`, `commands/`).
2. Add the mold to `foundry.yaml`.
3. Run `make test` and `make cast-test`.

See the [foundry documentation](https://github.com/nimble-giant/ailloy/blob/main/docs/foundry.md) for the full schema reference.
