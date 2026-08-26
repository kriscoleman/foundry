# standards-janitor mold

Standards and consistency lens. Use when checking a change for convention/naming consistency, lint/format cleanliness, dead code, DRY across the diff, and docs hygiene — as a con-voyage reviewer or standalone standards pass.

This mold ships a single reusable persona as an **agent**. It is designed to be
used two ways:

- **As a con-voyage reviewer** — slung `--review-only` by the `con-voyage`
  orchestrator to apply this lens to a branch diff and report BLOCKING/LOW
  findings.
- **As a standalone subagent** — invoked directly in Claude Code or OpenCode to
  apply the same lens on demand.

## Agent

| Agent | Purpose |
|---|---|
| `standards-janitor` | Standards and consistency lens. Use when checking a change for convention/naming consistency, lint/format cleanliness, dead code, DRY across the diff, and docs hygiene — as a con-voyage reviewer or standalone standards pass. |

## Install with ailloy

```bash
ailloy cast github.com/kriscoleman/foundry//molds/standards-janitor
```

Or pull the whole review crew at once via the aggregate:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/con-voyage-personas
```

## Target selection

Renders for **Claude Code** and **OpenCode** by default. Control with
`agent.targets`:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/standards-janitor \
  --set 'agent.targets=[claude]'
```

## Requirements

- [ailloy](https://github.com/nimble-giant/ailloy) v0.6.17+
