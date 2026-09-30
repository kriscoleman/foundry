Apply con-voyage review findings.

## Resolve the target worktree (review fk-hbsmk B1)

Every con-voyage step launches with cwd = the shared rig-root launcher
checkout, not the target worktree — never rely on ambient `$(pwd)` for
anything below. Resolve the real implementation source anchor/worktree the
same way `build.md` already does, from the workflow root's metadata:

```bash
ROOT_ID="${GC_ROOT_BEAD_ID:-}"
if [ -z "$ROOT_ID" ]; then
  ROOT_ID="$(gc bd show "$GC_BEAD_ID" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
print((d.get('metadata') or {}).get('gc.root_bead_id') or '')
" 2>/dev/null)"
fi
[ -n "$ROOT_ID" ] || ROOT_ID="$GC_BEAD_ID"

read -r CONVOY_ID WORKTREE <<< "$(gc bd show "$ROOT_ID" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
meta = d.get('metadata') or {}
print(meta.get('gc.build.source_anchor_id') or '', meta.get('gc.build.source_anchor_work_dir') or '')
" 2>/dev/null)"

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "apply-review-findings: no valid gc.build.source_anchor_work_dir on workflow root ${ROOT_ID} — cannot resolve the target worktree" >&2
  exit 1
fi
cd "$WORKTREE" || { echo "apply-review-findings: cd into ${WORKTREE} failed" >&2; exit 1; }
[ "$(pwd -P)" = "$(cd "$WORKTREE" && pwd -P)" ] || { echo "apply-review-findings: pwd verification failed" >&2; exit 1; }
```

Do not edit files anywhere but inside `$WORKTREE`. Never edit the launcher
checkout.

## Record this step's own session as the implementor (review fk-hbsmk BLOCKING-1)

Stamp `$ROOT_ID` with a dedicated `gc.build.implementor_session` key, read
from THIS step's own claimed bead (`$GC_BEAD_ID`) — never from the workflow
root's `gc.session_name`, which every `session_affinity=require` step
(review lanes, the synthesizer, publish itself) re-stamps as it touches the
root, so it never reliably names the implementor by the time publish reads
it. This step can re-run across multiple review-loop iterations, each
possibly claimed by a different session (fresh iteration beads per
graph.v2), so re-stamp every time this step runs, not just once:

```bash
IMPLEMENTOR_SESSION="$(gc bd show "$GC_BEAD_ID" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
print((d.get('metadata') or {}).get('gc.session_name') or '')
" 2>/dev/null)"
if [ -n "$IMPLEMENTOR_SESSION" ]; then
  gc bd update "$ROOT_ID" --set-metadata "gc.build.implementor_session=${IMPLEMENTOR_SESSION}" \
    || echo "apply-review-findings: WARNING: could not stamp gc.build.implementor_session on workflow root ${ROOT_ID}" >&2
else
  echo "apply-review-findings: WARNING: could not resolve this step's own gc.session_name to stamp as implementor_session on ${ROOT_ID}" >&2
fi
```

## Sync the worktree to the current base (fk-hbsmk)

Before reading the review synthesis or touching any file, sync `$WORKTREE`
to the current origin default base the same way the build phase does —
review findings must never be applied on top of an unconfirmed/stale base:

```bash
CV_TOPLEVEL="${GC_RIG_ROOT:-}"
if [ -z "$CV_TOPLEVEL" ] || [ ! -f "${CV_TOPLEVEL}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh" ]; then
  CV_TOPLEVEL="$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null)"
fi
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
if [ -z "$CV_LIB" ]; then
  echo "apply-review-findings: con-voyage-lib.sh not found — cannot sync to the current base" >&2
  exit 1
fi
SYNC_RESULT="$(export CV_PACK_ROOT; source "$CV_LIB" && cv_sync_worktree_to_base "$WORKTREE" "con-voyage/${CONVOY_ID}")" \
  || { echo "apply-review-findings: failed to sync to the current base — refusing to review/fix on a possibly-stale base" >&2; exit 1; }
echo "apply-review-findings: worktree sync: ${SYNC_RESULT}"
```

`CV_TOPLEVEL` for this bootstrap call is now resolved from `GC_RIG_ROOT`
first — every gc-spawned session already carries it, and recast+go-live
keeps the rig root's own mold cast current — falling back to `$WORKTREE`'s
own git toplevel only when `GC_RIG_ROOT` is unset or its mold copy is
missing `con-voyage-lib.sh` outright (fk-n7qn1: a worktree whose checked-out
branch predates `cv_sync_worktree_to_base`'s introduction has no copy of the
function in its own mold cast, so sourcing solely from the worktree's own
toplevel can never self-heal — the call meant to sync the worktree needs code
the worktree does not have). `CV_PACK_ROOT` still reflects whichever
toplevel was actually resolved, so `cv_sync_worktree_to_base` gets a
deterministic `cv-worktree-prep.sh` lookup instead of that helper's own
`command -v || find`-style fallback (review fk-hbsmk B2) — unaffected by
this change.

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
