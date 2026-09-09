Finalize the con-voyage review.

The review loop has completed and all active lanes approved. Write the final
con-voyage review report under the build artifact root. The report must record:

- Branch reviewed and base branch
- Review roster that ran (floor lanes + active roster lanes)
- Number of review cycles
- Final verdict: APPROVED
- Disposition of any LOW findings (surfaced to human)
- push and open_pr var values as executed

Record gc.build.review_report_path on the workflow root pointing to the final report.

Close with gc.outcome=pass and gc.build.review_report_path=<final report path>.

Do not merge the branch. push and open_pr are controlled by the formula vars.
The human landing the PR is the terminal event. Do not invoke provider-native subagents.
