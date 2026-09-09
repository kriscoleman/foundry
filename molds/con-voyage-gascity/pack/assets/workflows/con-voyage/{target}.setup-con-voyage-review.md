Prepare the con-voyage review context.

Gather the requirements artifact, implementation plan, decomposition artifact,
implementation summary, changed-file summaries, task evidence, and verification
commands into one review context file under the build artifact root. Record that
path on the workflow root as gc.build.code_review_context_path.

Include:
- The base branch and branch under review
- The full diff summary (files changed, lines added/removed)
- The source anchor id, its work_dir, changed files, commit id, and proof commands
- The review roster that will run (floor lanes always; roster lanes active for this sling)

The floor review lanes (acceptance, test-evidence, simplicity, security, code) run
on every con-voyage. Optional roster lanes are listed in the review context so
synthesis can distinguish floor findings from persona findings.

Do not invoke provider-native subagents. Gas City graph lanes are the delegation
mechanism.

Close this setup bead with gc.outcome=pass only after the review context path is
recorded.
