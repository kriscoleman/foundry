# Changelog

## 0.2.1

- **Rename:** mold renamed from `con-voyage` to `con-voyage-gastown` to
  distinguish the Gas Town / `gt`-specific mold from the upcoming
  `con-voyage-gascity` variant. No functional changes — all `gt`-driving
  orchestration logic is preserved intact.

## 0.2.0

Hardened orchestration practices validated in live convoys folded into the
`con-voyage` skill:

- **Always real polecats, never subagents.** A con-voyage runs on `gt sling` /
  `gt convoy` / beads / the rig witness. Added a rule and red-flag rows, plus a
  bootstrap recipe (`gt rig add` with the SSH remote when the gh token lacks the
  `workflow` scope, `gt rig boot`, and `bd init … --server` when beads reports a
  missing prefix) for targets that are not rigs yet.
- **Agent PR-comment identity prefix.** Every agent PR comment now leads with a
  bold `[<rig>/<agent> — <lens>]` prefix so humans can tell which agent spoke and
  distinguish agent comments from their own (unprefixed) comments. Baked into the
  reviewer and monitor charters and the Phase-3 posterity step.
- **Persona-based review roster.** Generalised the fixed code+security pair into
  a configurable roster of review lenses sourced from the `con-voyage-personas`
  mold (native-language principal engineer, security, dev-ex, founder/CTO,
  product owner, standards/best-practices janitor), now declared as a **mold
  dependency** in `mold.yaml` so casting con-voyage pulls the personas. The
  code+security floor charters stay inline for graceful degradation. Added a
  reusable sling template for hand-added lenses, `--lenses` (floor always
  applied), and a `Prerequisites` note. Loop rules preserved exactly,
  generalised from BOTH reviewers to ALL reviewers.
- **Product-owner lens as first-class**, covering appetite/worth-it, usability
  for the vendor/buyer AND their customers, UX/DevEx, and holistic docs —
  requiring a matching downstream docs PR opened in draft to merge in lockstep,
  with the lockstep-docs recipe codified (the docs PR is its own con-voyage in
  the docs repo's rig, cross-linked and merged alongside the feature PR).
- Preserved all prior guidance: `--merge=local` (do not pass `--no-convoy`), the
  never-`gt done` warnings, re-sling mechanics (`bd reopen` + `--force`), and the
  defense-in-depth witness standing order.

## 0.1.0

- Initial release: `con-voyage` skill — a Gas Town orchestrator that delivers an
  issue, bead, or task description with a polecat team through nested
  implementation, code/security review, CI, and human-review feedback loops, and
  never merges until a human does.
