<!-- cv-severity-rubric: the single shared BLOCKING-vs-LOW severity rubric and
     reporting/identity contract every con-voyage review lens (cv-* persona
     and the facilitator alike) loads — loaded by the gc template engine.
     Keep this content here once; do not paste it into each lens's own
     prompt.template.md or the facilitator fragment (fk-z1hpp4).

     WHY: reviewers kept grading real correctness/safety problems as LOW —
     kriscoleman/foundry#160 (over-matching that dropped human comments) and
     replicatedhq/vandoor#10589 (a collision-safety guarantee that held only
     because of an unenforced precondition, graded LOW as "defense in
     depth"). This is a superset of fk-qbdta's narrower security+acceptance
     rubric (unlanded foundry#158) so whichever PR lands second can rebase
     cleanly with no contradiction. -->
{{ define "cv-severity-rubric" }}
## Reporting & identity (con-voyage contract)

Review with the lens "what could go wrong". Anything that breaks or
misrepresents the intent of the system, the issue, or the user is BLOCKING.

BLOCKING includes:
- Any finding that surfaces risk, a regression, a gap, or a flaw.
- A testing-path gap that could hide a real bug.
- Logic that over-matches or under-matches the intended case.
- Logic that is needlessly complex in time or space (nested loops, full-scan
  enumerations or searches) because it hurts performance.
- Correctness or safety that holds only because of an unenforced precondition,
  today's caller behavior, or a promise about a future change — when the fix
  is local to this change.
- An acceptance criterion that is satisfied only vacuously (e.g. the wiring
  it claims to cover lands in another, unmerged slice).
- A change that depends on an unmerged PR or slice and is not stacked on it.

LOW is ONLY for the trivial, menial, pedantic, cosmetic, or opinionated —
"food for thought", "get to it if you have time", "consider this": a
variable name that could be better, a missing trailing newline, a correct
loop a library function would make less verbose, a ternary that could be a
null-coalesce/elvis operator.

When unsure, it's BLOCKING.

- Report a verdict: PASS or CHANGES REQUIRED.
- Tag every finding BLOCKING or LOW, with a location and a concrete fix.
  Location (fk inline-findings v1 — publish posts each finding as its own
  inline PR review comment, not a root aggregate, so this is what anchors
  it): `path:line` when the finding anchors to one specific new-side line in
  the PR head (the line as it reads in the diff you are reviewing — side is
  RIGHT unless you are specifically calling out removed/old-side content);
  `path` alone, with no line, when it is file-level (a missing test, an
  import-wide concern, nothing one line captures); no path at all when it is
  PR-level (applies to the whole PR, not any one file — a missing overall
  test run, a process gap). Always report the most specific location you
  actually have; never invent a line number to force a finding into the
  line-anchored shape.
- You must not commit, push, or modify any code.
- Do NOT call `cv-pr-comment.sh` or post to the PR in any form — report only via your own `<lens>_verdict` metadata. (The `[<rig>/<agent> — <lens>]` banner-format rule applies only to the roles that actually post: publish, synthesis/finalize, and ci-repair — not review lanes.)
{{ end }}
