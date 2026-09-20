Apply con-voyage review findings.

Read the con-voyage review synthesis. If all active review lanes approve, write a
no-op review summary and set code_review.verdict=done.

If BLOCKING findings remain, make the smallest focused changes that address each
finding, run the relevant proof commands, and write a review-fix summary under the
build artifact root. Address findings from all lanes in one pass: a correctness fix
can open a security hole, and a security fix can break a test. Fix all BLOCKING
findings before setting verdict.

Apply fixes to the implementation source anchor/worktree named in the review
context, not to the launcher rig root.

Set code_review.verdict=done only when acceptance, test-evidence, simplicity,
security, and code review (plus any active roster lanes) all approve after this
pass. Set code_review.verdict=iterate when BLOCKING findings remain.

Always close with gc.outcome=pass, code_review.verdict=done|iterate,
code_review.report_path=<review summary path>, and
code_review.output_path=<review summary path>.

Use the exact claimed bead id when updating metadata:

  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=pass' \
    --set-metadata 'code_review.verdict=done' \
    --set-metadata 'code_review.report_path=<review summary path>' \
    --set-metadata 'code_review.output_path=<review summary path>'
  bd close "$CLAIMED_BEAD_ID" --reason 'Con-voyage review approved.'

Do not commit, push, or open a PR. The formula controls push and PR via the
push and open_pr vars. You are the fix-application lane.
Do not invoke provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.
