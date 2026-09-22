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

## Sweep per-lane review worktrees (fk-q659)

Floor lanes that execute against the implementation (acceptance, test-evidence,
simplicity) and any other lane that ran build/test/lint commands did so inside their
own private worktree acquired via `cv-review-lane-worktree.sh acquire`, never the
shared source-anchor work_dir — see the per-lane worktree isolation note in each
lane's own instructions. After writing the synthesis, sweep this cycle's per-lane
copies so they do not accumulate across review rounds:

```bash
CV_LANE_WT_BIN="$(command -v cv-review-lane-worktree.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-review-lane-worktree.sh 2>/dev/null | head -1)"
if [ -n "$CV_LANE_WT_BIN" ]; then
  bash "$CV_LANE_WT_BIN" sweep "<source anchor work_dir from the review context>" \
    || echo "note: per-lane worktree sweep failed (continuing)"
else
  echo "note: cv-review-lane-worktree.sh not found — skipping per-lane worktree sweep (continuing)"
fi
```

This is hygiene, not correctness — a sweep failure must never block synthesis from
closing. If the review loop re-runs lanes for another cycle, each lane re-acquires a
fresh copy at the new HEAD commit.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs your zsh profile, not bash — zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array (`arr=(...)`; `for x in "${arr[@]}"`), an explicit split (`IFS=... read -r -a arr <<<"$var"`), or pipe through `xargs`/`while read`.
