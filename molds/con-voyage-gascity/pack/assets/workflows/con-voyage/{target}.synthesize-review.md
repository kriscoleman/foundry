Synthesize the con-voyage review.

Read all active review lane reports. Deduplicate findings, preserve the source
review lane for each finding, and classify each item as required fix (BLOCKING),
low-priority concern (LOW), or approved.

Write one consolidated review synthesis under the build artifact root. The
synthesis must be concrete enough for the fix lane to act without another
planning pass. Structure it as:

1. Overall verdict: approve or iterate
2. BLOCKING findings (must fix before landing): list each with lane, file:line, fix
3. LOW findings (surface to human for decision): list each with lane, file:line, fix
4. Lanes approved with no findings

When any BLOCKING finding exists from any lane, the verdict is iterate.
When no BLOCKING findings exist but LOWs remain, stop and surface them to the
human facilitator. Never silently accept LOWs.

Close with gc.outcome=pass, code_review.synthesis_path=<synthesis path>, and
code_review.output_path=<synthesis path>.

This synthesis is the source content the facilitator later posts to the PR as
a reviewer-verdict comment. Do not post anything to GitHub from this step
yourself — but write the synthesis knowing any downstream consumer that posts
it to the PR MUST do so via `cv-pr-comment.sh`, never a raw `gh pr comment` /
`gh pr review`, so the machine-identity banner always leads the posted text.

Do not invoke provider-native subagents. Synthesis happens in this Gas City fan-in lane.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.
