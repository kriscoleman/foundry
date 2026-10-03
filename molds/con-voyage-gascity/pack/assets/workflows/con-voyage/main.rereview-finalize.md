Finalize the con-voyage re-review round (fk-pubvq). The review loop above
has completed and all active lanes approved (LOW findings only, or clean).
Post the round's ONE aggregated comment, report the verdict to the mayor,
clear this PR's in-flight re-review guard, and write the build artifact.

## Resolve this run's inputs

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

REPO_FULL="{repo}"
PR_NUMBER="{pr}"
FINALIZE_KEY="{finalize_key}"
REVIEW_ROUND="{review_round}"

CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
CV_STATE_DIR=""
if [ -n "$CV_LIB" ]; then
  CV_STATE_DIR="$(source "$CV_LIB" && cv_default_state_dir)"
fi
[ -n "${CV_STATE_DIR:-}" ] || CV_STATE_DIR="${GC_CITY:-.}/.gc/cv-pr-watch"
```

## Post the round's ONE aggregated review comment

Same shape as con-voyage's own publish step (main.publish.md): build a JSON
manifest from `review-synthesis.md` and each active lane's own
`.gc/build/${ROOT_ID}/*-review.md`, with `round = {review_round}` (NOT `1` —
this is a later round, and the marker
`<!-- con-voyage-review:<root_bead_id> round=<round> -->` must stay unique
per PR), then post it once:

```bash
if [ -n "$CV_LIB" ]; then
  CV_PACK_ROOT_BIN="$CV_PACK_ROOT"
  [ -f "${CV_PACK_ROOT_BIN}/assets/scripts/cv-pr-comment.sh" ] || CV_PACK_ROOT_BIN="${GC_CITY:-.}/packs/con-voyage"
  CV_BIN="${CV_PACK_ROOT_BIN}/assets/scripts/cv-pr-comment.sh"
  [ -f "$CV_BIN" ] && [ -x "$CV_BIN" ] || CV_BIN=""
fi
if [ -n "${CV_BIN:-}" ]; then
  if ! CV_AGGREGATE_OUT="$("$CV_BIN" comment-aggregate "$PR_NUMBER" --repo "$REPO_FULL" \
    --manifest <path to the assembled JSON manifest, round={review_round}> \
    --city-root "${GC_CITY:-.}" \
    --formula con-voyage-rereview --agent "<rig>/gc.run-operator" 2>&1)"; then
    echo "con-voyage rereview-finalize: comment-aggregate failed: ${CV_AGGREGATE_OUT}" >&2
    gc mail send mayor \
      -s "con-voyage re-review: aggregated comment failed for ${REPO_FULL}#${PR_NUMBER}" \
      -m "cv-pr-comment.sh comment-aggregate failed for re-review round ${REVIEW_ROUND}: ${CV_AGGREGATE_OUT}" \
      2>&1 || echo "note: escalation mail failed too (continuing)" >&2
  fi
else
  echo "cv-pr-comment.sh not found — skipping the aggregated review comment" >&2
fi
```

A failure here must never fail this step or block the round's own
finalization below — log it, escalate to the mayor, and continue.

## Report the verdict to the mayor and clear the in-flight guard

Derive `overall_line`/verdict from `review-synthesis.md` the same way
publish.md does. Then, REGARDLESS of whether the round found only LOW
findings or was fully clean, mail the mayor the verdict (LOW-only results
are surfaced here, never silently auto-accepted) and advance the `.finalize`
record so con-voyage-rereview-watch.sh can detect the NEXT push:

```bash
gc mail send mayor \
  -s "RE-REVIEW COMPLETE: ${REPO_FULL}#${PR_NUMBER}" \
  -m "con-voyage re-review round {review_round} finished for ${REPO_FULL}#${PR_NUMBER}: <overall_line from review-synthesis.md>" \
  || echo "note: mayor mail failed (continuing)" >&2

if [ -n "$CV_LIB" ]; then
  NEW_HEAD_SHA="$(git -C "<the worktree this round reviewed>" rev-parse HEAD 2>/dev/null || echo "")"
  (
    export CV_STATE_DIR
    source "$CV_LIB"
    finalize_read "$FINALIZE_KEY"
    finalize_write "$FINALIZE_KEY" "$FS_WORK_BEAD" "$FS_CONVOY_ID" "$FS_REPO_FULL" \
      "$FS_PR_NUMBER" "$FS_PR_AUTHOR" "$FS_IMPLEMENTOR" "awaiting_merge" "$FS_ROOT_BEAD_ID" \
      "$FS_ROSTER_VARS" "${NEW_HEAD_SHA:-$FS_LAST_REVIEWED_HEAD_SHA}" "{review_round}" ""
  )
  gc bd set-state "$FS_WORK_BEAD" cv=awaiting_merge \
    --reason "con-voyage re-review round {review_round} complete" >/dev/null 2>&1 \
    || echo "note: could not reset cv=awaiting_merge (continuing)" >&2
fi
```

Clearing `rereview_root_bead_id` back to empty (the final, 13th
`finalize_write` arg above) is what lets con-voyage-rereview-watch.sh detect
and dispatch the NEXT code-changing push — leaving it set would wedge this
PR in "re-review in flight" forever.

## Write the build artifact

Write a `gc.build.review.v1` artifact under `.gc/build/${ROOT_ID}/` recording:
branch reviewed, review roster that ran, this round's number, final verdict,
disposition of any LOW findings (surfaced above), and the aggregated-comment
round posted. Record `gc.build.review_report_path` on `$ROOT_ID`.

## Close

```bash
bd update "$CLAIMED_BEAD_ID" \
  --set-metadata 'gc.outcome=pass' \
  --set-metadata "gc.build.review_report_path=<final report path>"
bd close "$CLAIMED_BEAD_ID" --reason "Re-review round {review_round} complete."
```

Do not merge the branch. Do not open a second PR. Do not invoke
provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
