Run the con-voyage simplicity review lane.

Review the implementation for maintainability, readable boundaries, unnecessary
abstractions, accidental broad changes, and obvious future maintenance risk.

Flag only concrete issues that a reader can understand and act on: overly large
functions, deep nesting, duplicated logic that belongs in a shared helper,
misleading names, or patterns that will be confusing to the next engineer.

Write findings under the build artifact root. Required findings must be tied to
specific changed files or artifacts and must explain the smallest useful fix.
Tag each finding BLOCKING or LOW with file:line and a concrete fix.

Close with gc.outcome=pass, code_review.simplicity_verdict=approve|iterate, and
code_review.output_path=<simplicity review report path>.

Use explicit close metadata:

  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=pass' \
    --set-metadata 'code_review.simplicity_verdict=approve' \
    --set-metadata 'code_review.output_path=<simplicity review report path>'
  bd close "$CLAIMED_BEAD_ID" --reason 'Con-voyage simplicity review approved.'

If you find required fixes, set code_review.simplicity_verdict=iterate instead of
approve and explain the smallest required fix in the report and close reason.

Do not set gc.verdict or code_review.report_path; synthesis owns the final verdict.

Do not invoke provider-native subagents. You are the con-voyage simplicity review lane.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.
