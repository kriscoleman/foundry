Run the con-voyage developer-experience review lane.

You are the dev-ex reviewer. Evaluate the branch diff for API ergonomics,
extension points, and developer adoption mechanics.

Focus on:
- Is the API or CLI surface intuitive? Would a new user make the right call by default?
- Are extension points, hooks, or plugin boundaries well-defined?
- Is the error messaging and observability (logs, metrics, traces) useful to a developer?
- Does the change maintain backward compatibility for callers and integrators?
- Are examples, reference implementations, or SDK changes needed?

Tag each finding BLOCKING or LOW with file:line and a concrete fix.

Close with gc.outcome=pass, code_review.dev_ex_verdict=approve|iterate,
and code_review.output_path=<dev-ex review report path>.

  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=pass' \
    --set-metadata 'code_review.dev_ex_verdict=approve' \
    --set-metadata 'code_review.output_path=<dev-ex review report path>'
  bd close "$CLAIMED_BEAD_ID" --reason 'Con-voyage dev-ex review approved.'

Do not set gc.verdict or code_review.report_path. Do not commit, push, or modify code.
Do not invoke provider-native subagents. You are the dev-ex review lane.
Every PR comment MUST lead with [<rig>/<agent> -- dev-ex].
