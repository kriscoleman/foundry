# con-voyage-personas mold

The **con-voyage review crew in one cast**. This is an *aggregate* mold: it holds
no persona content of its own — it just depends on the fifteen per-persona molds
so a consumer can grab the whole review-and-engineering crew with a single
install.

These are the reusable lenses used by the [`con-voyage`](../con-voyage) skill's
review loop. Each is also usable **standalone** as a subagent, independent of
con-voyage.

## Personas

Strategy & product:

| Mold / agent | Lens |
|---|---|
| [`founder-cto`](../founder-cto) | Executive ship/no-ship: vision fit, business risk, ROI, opportunity cost. |
| [`product-owner`](../product-owner) | Appetite/worth-it, usability for buyer and their customers, UX/DevEx, holistic docs. |
| [`marketing`](../marketing) | Positioning, messaging, naming, value-prop clarity, launch/GTM readiness. |

Design & communication:

| Mold / agent | Lens |
|---|---|
| [`design-ux`](../design-ux) | Interaction/visual design, UX flows, information architecture, design-system consistency. |
| [`documentation`](../documentation) | Prose quality, docs structure/standards, clarity, grammar, completeness (Strunk & White). |
| [`dev-ex-reviewer`](../dev-ex-reviewer) | Adoption ease, error messages, sane defaults, discoverability, copy-paste onboarding. |

Engineering:

| Mold / agent | Lens |
|---|---|
| [`go-principal-engineer`](../go-principal-engineer) | Go idioms, fail-loud wrapped errors, concurrency, tests, SOLID/DRY/KISS/YAGNI. |
| [`frontend-principal-engineer`](../frontend-principal-engineer) | Accessibility, component/state design, performance, design-system fit. |
| [`api-platform-contract`](../api-platform-contract) | API design, backward compatibility, versioning, contract stability. |
| [`data-db-engineer`](../data-db-engineer) | Schema/migration safety, SQL correctness, query performance at scale. |

Quality, operations & governance:

| Mold / agent | Lens |
|---|---|
| [`qa-test-engineer`](../qa-test-engineer) | Test strategy, coverage, edge cases, regression risk. |
| [`sre-reliability`](../sre-reliability) | Observability, failure modes, rollout/rollback safety, SLOs. |
| [`security-reviewer`](../security-reviewer) | Injection, authn/authz, secrets, supply-chain, least-privilege, input validation. |
| [`compliance-privacy`](../compliance-privacy) | Data handling, PII, SOC 2/enterprise compliance, auditability. |
| [`standards-janitor`](../standards-janitor) | Code conventions/naming, lint/format, dead code, DRY across the diff. |

### Overlapping lanes — when to use which

- **Code lens coverage:** the language-engineering lens ships as `go-principal-engineer`
  and `frontend-principal-engineer` today. For code in other languages, con-voyage
  falls back to its own inline code-reviewer charter — add a language-specific persona
  here when one is needed.
- **`product-owner` vs `dev-ex-reviewer`:** both look at experience, from different
  seats. `product-owner` = *is the change worth it and does it land for the buyer and
  their customers* (appetite, value, holistic docs). `dev-ex-reviewer` = *can a
  developer actually adopt it* (error messages, sane defaults, discoverability).
- **`design-ux` vs `frontend-principal-engineer`:** `design-ux` owns the end-user
  *experience* (flow, IA, interaction, visual system); `frontend-principal-engineer`
  owns the *implementation* (component/state design, a11y code, render performance).
- **`documentation` vs `standards-janitor`:** `documentation` owns *prose* and docs
  quality; `standards-janitor` owns *code* conventions, naming, lint, and dead code.
- **`security-reviewer` vs `compliance-privacy`:** `security-reviewer` owns
  *attacker-facing* risk (injection, authz, exploits, supply-chain);
  `compliance-privacy` owns *governance*-facing risk (PII, retention, auditability,
  regulatory fit).
- **`marketing` vs `product-owner`:** `marketing` owns the *outward story* (positioning,
  naming, announce-readiness); `product-owner` owns *whether it's worth building* and
  fits the buyer's workflow.

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

- [ailloy](https://github.com/nimble-giant/ailloy) v0.6.33+ — higher than the
  personas' own v0.6.17+ floor because **this aggregate requires ailloy's
  dependency-resolution support** to pull in the seven persona molds. Casting a
  persona directly only needs v0.6.17+; casting this aggregate needs v0.6.33+.
