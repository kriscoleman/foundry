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
later review step look like there is nothing to review):

```bash
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
RIG_ROOT=""
if [ -n "$CV_LIB" ]; then
  RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"
fi
[ -n "${RIG_ROOT:-}" ] || RIG_ROOT="${GC_CITY:-.}"

WORKTREE="${RIG_ROOT}/worktrees/rereview-${ROOT_ID}"
rm -rf "$WORKTREE"
mkdir -p "$(dirname "$WORKTREE")"

git fetch origin "$BRANCH" || { echo "con-voyage rereview-seed: failed to fetch ${BRANCH} from origin" >&2; exit 1; }
git worktree add -q -B "$BRANCH" "$WORKTREE" "origin/${BRANCH}" \
  || { echo "con-voyage rereview-seed: failed to attach a worktree for ${BRANCH} at ${WORKTREE}" >&2; exit 1; }
```

If either command above fails, mail the mayor with the exact error, close
this step AND the workflow root (`gc.outcome=fail`), and STOP — do not
proceed to stamp the root or close this step as pass.

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
(con-voyage-lib.sh) falls back to returning its input id unchanged for any
non-synthetic, non-convoy bead, so the review loop's own work-bead
resolution still terminates correctly — it simply will not find a tracked
"real" work bead distinct from this one, which is expected for a re-review
round (there is no fresh convoy here, only a PR that already shipped once).

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
