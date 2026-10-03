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
- Correctness or safety that holds only because of an unenforced
  precondition, today's caller behavior, or a promise about a future change —
  when the fix is local to this change.
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
- Tag every finding BLOCKING or LOW, with file:line and a concrete fix.
- You must not commit, push, or modify any code.
- Any comment you post to the PR MUST lead with `[<rig>/<agent> — <lens>]`
  (a human's comments are never prefixed — that asymmetry is the signal).
{{ end }}
