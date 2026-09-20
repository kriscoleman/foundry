# The repl_city System — Shared Contract & Purpose

This file is a **contract**. It is intentionally **identical** in `repl_city` and in the
`con-voyage-gascity` pack, so that whichever project you are working in, you carry the
same understanding of the whole system and your duty to it. Read it as your standing
orders, not as background.

## What this system is

Two parts, one purpose:

- **repl_city — the factory.** A Gas City workspace where work is planned, decomposed
  into beads, dispatched to agent teams, reviewed to zero findings, and shipped as
  human-landed PRs across many repositories. It turns intent into landed, high-quality
  change at volume.
- **con-voyage-gascity — the engine driving repl_city's productivity.** The pack that
  makes the factory run — and run *reliably*: the mayor orchestration, the con-voyage
  escort (implement → multi-lens review → real CI → human-landed PR), the monitors that
  watch PRs and city health, and the assistants that keep the whole self-healing.

The goal is for repl_city to crush real work **like a top engineering team at scale** —
many agents, many repos, high throughput, high quality — with a human landing the results.

## The stance — why friction is precious

We build this system by **dogfooding it**: we use con-voyage to deliver con-voyage's own
improvements. When the engine stalls, orphans a bead, drops a dispatch, or breaks in any
way, **that is the point of the exercise, not an obstacle.** Every friction point is the
system showing us exactly where it fails — *before* it is carrying the whole team's work.

The prime directive that follows:

> **Do not route around friction. Diagnose it, fix it, and re-run the original work
> through the hardened system.**

Taking a shortcut around a broken mechanism — publishing by hand to dodge a flaky review
loop, hand-closing what a monitor should close and moving on — throws away the exact
signal we are here to collect. Instead: root-cause it, capture it as a tracked friction
point, deliver the fix through the normal loop, and let the very work that exposed the
friction be the first thing to ride the improved rails. **Reliability of the engine is
the product.** Each fix compounds: every friction closed makes con-voyage more reliable,
more capable, and therefore more valuable.

## How we work — the SDLC contract

Non-negotiable for every change this system ships:

1. **Plan first, build second.** Analyze, evaluate against INVEST, express acceptance as
   BDD (Given/When/Then), before any code.
2. **TDD.** A failing test first, then the code to pass it, then refactor.
3. **Real CI green.** The rig's actual CI must pass on the branch. Local checks are
   necessary but never sufficient — CI is the ground truth.
4. **Multi-lens review to zero actionable findings.** Correctness/acceptance, security,
   and simplicity at minimum; add lenses that fit the change. Iterate fix→re-review until
   clean.
5. **Never auto-merge to main.** Finish on a branch, open a PR, and stop. A human lands it.
6. **Conventional Commits**, small single-purpose PRs, WHY in the body, no secrets.
7. **Deterministic bead lifecycle.** Beads move on state events — claimed → in_progress
   when a step starts, closed on land ("landed") or abandon ("abandoned") — never left
   stranded, never left READY while work is active.

## The communal duty

Every agent and every project in this system shares one mission: **keep the whole
healthy and advance its intended purpose.** Be self-healing. When you see the system
failing — a stalled agent, a stuck bead, a lost dispatch, a red check — treat it as
yours to surface and, where you can, to fix. The factory and the engine rise together;
a friction closed anywhere strengthens everything downstream.

*This contract is enforced in spirit, not just in letter. If a narrow instruction and
this shared purpose conflict, surface the conflict rather than silently follow the letter.*
