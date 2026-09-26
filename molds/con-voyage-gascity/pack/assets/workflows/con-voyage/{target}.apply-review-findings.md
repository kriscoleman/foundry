Apply con-voyage review findings.

## Sync the worktree to the current base (fk-hbsmk)

Before reading the review synthesis or touching any file, sync this worktree
to the current origin default base the same way the build phase does — review
findings must never be applied on top of an unconfirmed/stale base:

```bash
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
if [ -z "$CV_LIB" ]; then
  echo "apply-review-findings: con-voyage-lib.sh not found — cannot sync to the current base" >&2
  exit 1
fi
SYNC_RESULT="$(source "$CV_LIB" && cv_sync_worktree_to_base "$(pwd)")" \
  || { echo "apply-review-findings: failed to sync to the current base — refusing to review/fix on a possibly-stale base" >&2; exit 1; }
echo "apply-review-findings: worktree sync: ${SYNC_RESULT}"
```

(NOTE for reviewers: fk-q2pon is concurrently replacing this same
`command -v || find`-style resolution pattern across this file with a
`cv_pack_script`/`cv_pack_root` helper in con-voyage-lib.sh. It had not
landed on origin/main as of this change, so the snippet above uses the same
absolute pack-path fallback fk-q2pon introduces rather than adding a new
first-match `find`. Whichever of the two PRs lands second should rebase.)

If `$SYNC_RESULT` is `recreated` or `rebased`, the sync alone moved HEAD to a
new commit before you evaluated a single finding — carry this forward into
"Setting code_review.verdict" below: it forces verdict=iterate even on an
otherwise no-op pass, exactly like a fix commit would (0.9.1 semantics: any
change to the tree this pass, whatever its source, means nobody has reviewed
the resulting commit yet).

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
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_GUARD="${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh"
[ -f "$CV_GUARD" ] || CV_GUARD=""
git add -A
if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
  "$CV_GUARD" guard "$(pwd)" || { echo "fix the reported hygiene violation, re-stage, and re-run the guard before committing" >&2; exit 1; }
fi
git commit -m "fix: <brief description of the review fix> (review {convoy_id})"
FIX_COMMIT_SHA="$(git rev-parse HEAD)"
```

Commit ONLY when you actually changed files this pass — never an empty/no-op
commit when all lanes already approved and nothing needed fixing. If
`$SYNC_RESULT` was `recreated` or `rebased` but there were no BLOCKING
findings to fix, do not create an empty commit either — the sync itself
already moved HEAD, so capture that as your fix commit instead:

```bash
[ -n "${FIX_COMMIT_SHA:-}" ] || FIX_COMMIT_SHA="$(git rev-parse HEAD)"
```

### Setting code_review.verdict

Set code_review.verdict=done ONLY on a genuine no-op pass: every active lane
had already approved before this pass ran, you changed nothing, AND
`$SYNC_RESULT` was `noop`. In every other case — you fixed one or more
BLOCKING findings and committed a change this pass, OR the worktree sync
above reported `recreated`/`rebased` — set code_review.verdict=iterate
instead, even if you believe every finding raised this cycle is now
addressed. The lanes that reported those BLOCKING findings (or approved
outright) reviewed the OLD commit, not this one; nobody has reviewed the new
commit yet, so the loop must run one more full iteration (every active lane
again) against it before the fix can be trusted as done. Never set done in
the same pass that committed a fix or synced to a new base commit.

When you commit a fix this pass, or the sync alone moved HEAD, also record
code_review.fix_commit=<sha> (the `$FIX_COMMIT_SHA` captured above) so the
loop's exit check can independently confirm no lane has reviewed it yet.
Leave code_review.fix_commit unset only on a genuine no-op pass (verdict=done).

Always close with gc.outcome=pass, code_review.verdict=done|iterate,
code_review.report_path=<review summary path>, and
code_review.output_path=<review summary path>.

Use the exact claimed bead id when updating metadata:

  # No-op pass — every lane already approved, nothing changed:
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=pass' \
    --set-metadata 'code_review.verdict=done' \
    --set-metadata 'code_review.report_path=<review summary path>' \
    --set-metadata 'code_review.output_path=<review summary path>'
  bd close "$CLAIMED_BEAD_ID" --reason 'Con-voyage review approved.'

  # Fix pass — you changed files and committed a fix this pass:
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=pass' \
    --set-metadata 'code_review.verdict=iterate' \
    --set-metadata "code_review.fix_commit=$FIX_COMMIT_SHA" \
    --set-metadata 'code_review.report_path=<review summary path>' \
    --set-metadata 'code_review.output_path=<review summary path>'
  bd close "$CLAIMED_BEAD_ID" --reason 'Con-voyage review fix applied; another iteration required.'

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
