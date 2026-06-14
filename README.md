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
ailloy cast github.com/kriscoleman/foundry//molds/con-voyage
```

## Molds

| Name | Description |
|------|-------------|
| [con-voyage](molds/con-voyage) | Gas Town orchestration: deliver an issue with a polecat team through implementation, code/security review, CI, and human-review loops — and never merge until a human does. Claude Code / Gas Town specific. |

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
