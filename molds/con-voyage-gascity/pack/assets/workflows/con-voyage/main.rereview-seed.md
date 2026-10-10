Seed the con-voyage re-review round (fk-pubvq). The PR branch already
exists and is already published — there is nothing to build. This step's
only job is to attach a worktree to that EXISTING branch and stamp the
workflow root with the metadata the REUSED review-loop machinery
(main.setup-con-voyage-review.md, main.con-voyage-review-loop.md) already
expects from con-voyage's own prepare-build/build phases, so that machinery
runs completely unmodified.

## Resolve this run's inputs

`repo`, `pr`, `branch`, `finalize_key`, and `review_round` are the formula
vars con-voyage-rereview-watch.sh passed at sling time. Resolve the
workflow root id the same way every other con-voyage step does, then read
every var back from the root's `gc.var.*` metadata (review fk-z6rts
BLOCKING-1): this `description_file` is too large for gc to inline-
substitute `{var}` tokens into its body, so a literal `{repo}`/`{pr}`/
`{branch}`/`{finalize_key}`/`{review_round}` token here is a permanent
no-op — resolve dynamically instead, exactly like every other over-
threshold step in this pack (e.g. `main.publish.md` resolves
`gc.build.source_anchor_id` the same way, never a literal `{convoy_id}`):

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
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

CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
if [ -z "$CV_LIB" ]; then
  echo "con-voyage rereview-seed: con-voyage-lib.sh not found — cannot resolve formula vars from workflow root ${ROOT_ID}" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=missing_vars'
  bd close "$CLAIMED_BEAD_ID" --reason 'con-voyage-lib.sh not found — cannot resolve formula vars.'
  exit 0
fi

REPO_FULL="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.repo)"
PR_NUMBER="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.pr)"
BRANCH="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.branch)"
FINALIZE_KEY="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.finalize_key)"
REVIEW_ROUND="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.review_round)"
if [ -z "${REPO_FULL}" ] || [ -z "${PR_NUMBER}" ] || [ -z "${BRANCH}" ] || [ -z "${FINALIZE_KEY}" ]; then
  echo "con-voyage rereview-seed: missing required var(s) on workflow root ${ROOT_ID} — repo='${REPO_FULL}' pr='${PR_NUMBER}' branch='${BRANCH}' finalize_key='${FINALIZE_KEY}'" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=missing_vars'
  bd close "$CLAIMED_BEAD_ID" --reason 'Missing required repo/pr/branch/finalize_key var(s) — see stderr.'
  exit 0
fi
```

## Attach a worktree to the existing PR branch

Create a fresh worktree keyed on this re-review round's OWN root (never
reuse or assume the original con-voyage run's worktree still exists — it may
already have been swept) and check out `$BRANCH` from `origin`, attaching it
as a real local branch (never detached — detached HEAD here makes every
later review step look like there is nothing to review).

`git worktree add -B <branch>` refuses outright when `$BRANCH` is already
checked out in ANOTHER worktree — the original con-voyage build worktree, or
an operator's own fixer worktree outside the rig (fk-zhyz68: this killed 3/3
round-2 rereviews on 2026-10-09). Free the branch first via
`cv-worktree-prep.sh free-branch`, which detaches that other worktree only
if it is clean, and fails loud if it is dirty rather than silently
discarding uncommitted work:

```bash
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
CV_GUARD="${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh"
[ -f "$CV_GUARD" ] || CV_GUARD=""
RIG_ROOT=""
if [ -n "$CV_LIB" ]; then
  RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"
fi
[ -n "${RIG_ROOT:-}" ] || RIG_ROOT="${GC_CITY:-.}"

WORKTREE="${RIG_ROOT}/worktrees/rereview-${ROOT_ID}"
rm -rf "$WORKTREE"
mkdir -p "$(dirname "$WORKTREE")"

SEED_FAIL=""
git fetch origin "$BRANCH" || SEED_FAIL="failed to fetch ${BRANCH} from origin"
if [ -z "$SEED_FAIL" ] && [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
  "$CV_GUARD" free-branch "$CV_TOPLEVEL" "$BRANCH" \
    || SEED_FAIL="${BRANCH} is checked out in another worktree and could not be freed (dirty holder) — see stderr above"
fi
if [ -z "$SEED_FAIL" ]; then
  git worktree add -q -B "$BRANCH" "$WORKTREE" "origin/${BRANCH}" \
    || SEED_FAIL="failed to attach a worktree for ${BRANCH} at ${WORKTREE}"
fi
```

If `$SEED_FAIL` is non-empty, mail the mayor with the exact error, close
this step AND sweep the whole workflow root (so review lanes mint nothing
against a seed that never ran — fk-zhyz68: a failed seed previously left
~28 descendant beads OPEN for a human to tear down by hand), and STOP — do
not proceed to stamp the root or close this step as pass:

```bash
if [ -n "$SEED_FAIL" ]; then
  echo "con-voyage rereview-seed: ${SEED_FAIL}" >&2
  if [ -n "$CV_LIB" ]; then
    MAIL_ERR_FILE="$(mktemp)"
    source "$CV_LIB" && cv_with_timeout 30 gc mail send mayor -s "con-voyage rereview-seed failed: ${ROOT_ID}" -m "con-voyage rereview-seed (${CLAIMED_BEAD_ID}) could not attach a worktree for ${BRANCH}: ${SEED_FAIL}. The re-review workflow has been abandoned — no review lanes will be dispatched." --json >/dev/null 2>"$MAIL_ERR_FILE"
    MAIL_RC=$?
    MAIL_ERR_TEXT="$(cat "$MAIL_ERR_FILE" 2>/dev/null)"
    rm -f "$MAIL_ERR_FILE"
    [ "$MAIL_RC" -eq 0 ] || echo "con-voyage rereview-seed: mail to mayor on seed failure failed/timed out: ${MAIL_ERR_TEXT} — mayor NOT confirmed notified" >&2
    bd update "$CLAIMED_BEAD_ID" \
      --set-metadata 'gc.outcome=fail' \
      --set-metadata 'gc.failure_class=seed_worktree_attach'
    bd close "$CLAIMED_BEAD_ID" --reason "Re-review seed failed: ${SEED_FAIL}"
    source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "con-voyage rereview-seed failed (${CLAIMED_BEAD_ID}): ${SEED_FAIL}; no review lanes dispatched"
  fi
  exit 0
fi
```

## Stamp the workflow root for the reused review machinery

```bash
gc bd update "$ROOT_ID" \
  --set-metadata "gc.build.source_anchor_id=${GC_BEAD_ID}" \
  --set-metadata "gc.build.source_anchor_work_dir=${WORKTREE}" \
  --set-metadata 'gc.build.short_circuited=true' \
  --set-metadata "gc.build.implementor_session={implementation_target}"
```

`gc.build.source_anchor_id` is set to THIS step's own claimed bead
(`$GC_BEAD_ID`) rather than a synthetic convoy: `cv_resolve_work_bead`
(con-voyage-lib.sh) detects this as a graph.v2 step-bead anchor (via
`gc.step_ref`, stamped on every real workflow step bead) and resolves it
through the workflow root's finalize record when one exists, falling back
to returning its input id unchanged only when no finalize record is
resolvable — so the review loop's own work-bead resolution still terminates
correctly either way, usually landing on the real, already-shipped PR's
work bead rather than this step bead itself.

## Close

```bash
bd update "$CLAIMED_BEAD_ID" --set-metadata 'gc.outcome=pass'
bd close "$CLAIMED_BEAD_ID" --reason "Re-review seed: attached worktree for ${BRANCH} (round ${REVIEW_ROUND})."
```

Do not invoke provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
