# con-voyage-personas mold

The **con-voyage review crew in one cast**. This is an *aggregate* mold: it holds
no persona content of its own — it just depends on the seven per-persona molds so
a consumer can grab the whole review-and-engineering crew with a single install.

These are the reusable lenses used by the [`con-voyage`](../con-voyage) skill's
review loop. Each is also usable **standalone** as a subagent, independent of
con-voyage.

## Personas

| Mold / agent | Lens |
|---|---|
| [`founder-cto`](../founder-cto) | Executive ship/no-ship: vision fit, business risk, ROI, opportunity cost. |
| [`product-owner`](../product-owner) | Appetite/worth-it, usability for buyer and their customers, UX/DevEx, holistic docs. |
| [`go-principal-engineer`](../go-principal-engineer) | Go idioms, fail-loud wrapped errors, concurrency, tests, SOLID/DRY/KISS/YAGNI. |
| [`frontend-principal-engineer`](../frontend-principal-engineer) | Accessibility, component/state design, performance, design-system fit. |
| [`security-reviewer`](../security-reviewer) | Injection, authn/authz, secrets, supply-chain, least-privilege, input validation. |
| [`standards-janitor`](../standards-janitor) | Conventions/naming, lint/format, dead code, DRY across the diff, docs hygiene. |
| [`dev-ex-reviewer`](../dev-ex-reviewer) | Adoption ease, error messages, sane defaults, discoverability, copy-paste onboarding. |

## Install with ailloy

```bash
ailloy cast github.com/kriscoleman/foundry//molds/con-voyage-personas
```

This resolves and casts all seven persona molds. To install a single persona
instead, cast its mold directly, e.g.:

```bash
ailloy cast github.com/kriscoleman/foundry//molds/security-reviewer
```

## Target selection

Each persona renders for **Claude Code** and **OpenCode** by default. Control per
cast with `agent.targets`, e.g. `--set 'agent.targets=[claude]'`.

## How the personas are used

- **Con-voyage reviewers** — the con-voyage orchestrator slings a persona
  `--review-only` against a branch diff; it reports `PASS`/`CHANGES REQUIRED` with
  findings tagged `BLOCKING`/`LOW` (`file:line` + fix) by mail.
- **Standalone subagents** — invoke a persona directly to apply its lens on
  demand, outside any convoy.

## Requirements

- [ailloy](https://github.com/nimble-giant/ailloy) v0.6.33+ (dependency
  resolution).
