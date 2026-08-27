# compliance-privacy mold

Compliance and privacy lens. Use for data handling, PII, SOC 2/enterprise compliance, and auditability — as a con-voyage reviewer or a standalone advisor.

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
| `compliance-privacy` | Compliance and privacy lens. Use for data handling, PII, SOC 2/enterprise compliance, and auditability — as a con-voyage reviewer or a standalone advisor. |

## Install with ailloy

```bash
ailloy cast github.com/kriscoleman/foundry//molds/compliance-privacy
```

Or pull the whole review crew at once via the aggregate:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/con-voyage-personas
```

## Target selection

Renders for **Claude Code** and **OpenCode** by default. Control with
`agent.targets`:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/compliance-privacy \
  --set 'agent.targets=[claude]'
```

## Requirements

- [ailloy](https://github.com/nimble-giant/ailloy) v0.6.17+
