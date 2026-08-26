# product-owner mold

Product-owner appetite-and-worth-it lens. Use to judge whether a change is worth building and usable for both the buyer and their end customers — scope/appetite, UX and DevEx, and holistic docs coverage (requires a matching docs update).

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
| `product-owner` | Product-owner appetite-and-worth-it lens. Use to judge whether a change is worth building and usable for both the buyer and their end customers — scope/appetite, UX and DevEx, and holistic docs coverage (requires a matching docs update). |

## Install with ailloy

```bash
ailloy cast github.com/kriscoleman/foundry//molds/product-owner
```

Or pull the whole review crew at once via the aggregate:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/con-voyage-personas
```

## Target selection

Renders for **Claude Code** and **OpenCode** by default. Control with
`agent.targets`:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/product-owner \
  --set 'agent.targets=[claude]'
```

## Requirements

- [ailloy](https://github.com/nimble-giant/ailloy) v0.6.17+
