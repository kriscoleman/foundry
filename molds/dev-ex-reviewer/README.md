# dev-ex-reviewer mold

Developer-experience adoption lens. Use when judging how easy a change is to adopt — error-message quality, sane defaults, discoverability, and copy-paste onboarding — as a con-voyage reviewer or standalone DevEx critique.

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
| `dev-ex-reviewer` | Developer-experience adoption lens. Use when judging how easy a change is to adopt — error-message quality, sane defaults, discoverability, and copy-paste onboarding — as a con-voyage reviewer or standalone DevEx critique. |

## Install with ailloy

```bash
ailloy cast github.com/kriscoleman/foundry//molds/dev-ex-reviewer
```

Or pull the whole review crew at once via the aggregate:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/con-voyage-personas
```

## Target selection

Renders for **Claude Code** and **OpenCode** by default. Control with
`agent.targets`:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/dev-ex-reviewer \
  --set 'agent.targets=[claude]'
```

## Requirements

- [ailloy](https://github.com/nimble-giant/ailloy) v0.6.17+
