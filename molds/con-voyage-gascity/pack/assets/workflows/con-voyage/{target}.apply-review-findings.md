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

### Commit fixes before closing

A fix applied here lives only in the worktree until it is committed — publish
later pushes whatever is at HEAD, so an uncommitted fix is silently dropped
from the PR. When you changed any files this pass, commit them before closing
this step, from inside the worktree. Run the artifact-hygiene guard first; it
fails loud and unstages anything it safely can if a hygiene path (`.beads/`,
`.gc/`, `.claude/`, dolt data) ended up staged from your edits — do not commit
until it reports clean:

```bash
CV_GUARD="$(command -v cv-worktree-prep.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-worktree-prep.sh 2>/dev/null | head -1)"
git add -A
if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
  "$CV_GUARD" guard "$(pwd)" || { echo "fix the reported hygiene violation, re-stage, and re-run the guard before committing" >&2; exit 1; }
fi
git commit -m "fix: <brief description of the review fix> (review {convoy_id})"
```

Commit ONLY when you actually changed files this pass — never an empty/no-op
commit when all lanes already approved and nothing needed fixing.

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

Commit fixes locally as described above, but do not push or open a PR. The
formula controls push and PR via the push and open_pr vars. You are the
fix-application lane.
Do not invoke provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
