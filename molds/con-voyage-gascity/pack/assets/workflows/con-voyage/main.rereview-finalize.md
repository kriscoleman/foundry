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

CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
if [ -z "$CV_LIB" ]; then
  echo "con-voyage rereview-finalize: con-voyage-lib.sh not found — cannot resolve formula vars from workflow root ${ROOT_ID}" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=missing_vars'
  bd close "$CLAIMED_BEAD_ID" --reason 'con-voyage-lib.sh not found — cannot resolve formula vars.'
  exit 0
fi

# review fk-z6rts BLOCKING-1: this description_file is too large for gc to
# inline-substitute {var} tokens into its body, so a literal
# {repo}/{pr}/{branch}/{finalize_key}/{review_round} token here is a
# permanent no-op (it broke the push block below exactly this way: a
# literal "{branch}" instead of the real branch name). Resolve every one
# dynamically from the workflow root's gc.var.* metadata instead, exactly
# like every other over-threshold step in this pack (e.g. main.publish.md
# resolves gc.build.source_anchor_id the same way, never a literal
# {convoy_id}).
REPO_FULL="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.repo)"
PR_NUMBER="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.pr)"
BRANCH="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.branch)"
FINALIZE_KEY="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.finalize_key)"
REVIEW_ROUND="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.review_round)"
if [ -z "${REPO_FULL}" ] || [ -z "${PR_NUMBER}" ] || [ -z "${BRANCH}" ] || [ -z "${FINALIZE_KEY}" ]; then
  echo "con-voyage rereview-finalize: missing required var(s) on workflow root ${ROOT_ID} — repo='${REPO_FULL}' pr='${PR_NUMBER}' branch='${BRANCH}' finalize_key='${FINALIZE_KEY}'" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=missing_vars'
  bd close "$CLAIMED_BEAD_ID" --reason 'Missing required repo/pr/branch/finalize_key var(s) — see stderr.'
  exit 0
fi

CV_STATE_DIR=""
if [ -n "$CV_LIB" ]; then
  CV_STATE_DIR="$(source "$CV_LIB" && cv_default_state_dir)"
fi
[ -n "${CV_STATE_DIR:-}" ] || CV_STATE_DIR="${GC_CITY:-.}/.gc/cv-pr-watch"
```

## Fold in any deferred ci-repair status (fk-shpd87, AC3)

Before building the manifest, read and clear any routine ci-repair status
deferred since this PR's last aggregated comment (a rebase/merge-conflict
resolution with no human decision needed — see
`{target}.ci-repair.md`'s "Defer this summary instead of commenting"). This
is the one place the design doc's "next comment-aggregate round" lands:
folding it in here is what lets ci-repair stay silent on the PR for routine
actions (AC3) without losing the audit trail — it still reaches a human,
just inside this round's one comment instead of as its own.

```bash
CV_DEFERRED_STATUS=""
if [ -n "$CV_LIB" ]; then
  CV_DEFERRED_STATUS="$(export CV_STATE_DIR; source "$CV_LIB" && cv_defer_status_read_and_clear "$FINALIZE_KEY")"
fi

# Same absolute-rig-root resolution main.publish.md uses for every lane
# body_file below (fk-jg0ieq: a relative path resolves against this step's
# own cwd, not the rig root, and every lane silently renders as "report file
# unavailable").
CV_RIG_ROOT="${GC_RIG_ROOT:-}"
[ -n "$CV_RIG_ROOT" ] || [ -z "$CV_LIB" ] || CV_RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"
[ -n "$CV_RIG_ROOT" ] || CV_RIG_ROOT="${GC_CITY:-.}"
CV_BUILD_DIR="${CV_RIG_ROOT}/.gc/build/${ROOT_ID}"

if [ -n "$CV_DEFERRED_STATUS" ]; then
  printf '%s\n' "$CV_DEFERRED_STATUS" > "${CV_BUILD_DIR}/ci-repair-status.md"
fi
```

`$CV_DEFERRED_STATUS` is empty when nothing was deferred (the common case —
most rounds involve no ci-repair activity at all) — in that case add no
extra lane to the manifest below. When it is non-empty, the block above
already wrote it to `${CV_BUILD_DIR}/ci-repair-status.md` (ABSOLUTE path,
same rule as every other `body_file` below); add ONE extra entry to the
manifest's
`lanes[]`: `{"agent": "con-voyage-ci-repair", "lens": "ci-repair-status",
"verdict": "info", "findings": 0, "body_file":
"${CV_BUILD_DIR}/ci-repair-status.md"}` — rendered as its own `<details>`
block by `comment-aggregate`, exactly like any other lane, no schema change
needed.

## Post the round's ONE aggregated review comment

Same shape as con-voyage's own publish step (main.publish.md): build a JSON
manifest from `review-synthesis.md`, each active lane's own
`.gc/build/${ROOT_ID}/*-review.md`, and the optional deferred-ci-repair-status
lane above, with `round = $REVIEW_ROUND` (NOT `1` — this is a later round,
and the marker `<!-- con-voyage-review:<root_bead_id> round=<round> -->`
must stay unique per PR), then post it once:

```bash
if [ -n "$CV_LIB" ]; then
  CV_PACK_ROOT_BIN="$CV_PACK_ROOT"
  [ -f "${CV_PACK_ROOT_BIN}/assets/scripts/cv-pr-comment.sh" ] || CV_PACK_ROOT_BIN="${GC_CITY:-.}/packs/con-voyage"
  CV_BIN="${CV_PACK_ROOT_BIN}/assets/scripts/cv-pr-comment.sh"
  [ -f "$CV_BIN" ] && [ -x "$CV_BIN" ] || CV_BIN=""
fi
if [ -n "${CV_BIN:-}" ]; then
  if ! CV_AGGREGATE_OUT="$("$CV_BIN" comment-aggregate "$PR_NUMBER" --repo "$REPO_FULL" \
    --manifest <path to the assembled JSON manifest, round=$REVIEW_ROUND> \
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

## Push any converged fix commit(s) back to the PR branch (review fk-n74o9 BLOCKING-1)

`apply-review-findings` only commits locally — the only push/PR-open in the
whole con-voyage step set lives in `main.publish.md`. If a BLOCKING finding
this round caused `apply-review-findings` to commit a fix, that commit is
sitting in `$WORKTREE` only; the PR branch on GitHub still has the original
(pre-fix) commit. Reporting approval or advancing `last_reviewed_head_sha`
without pushing first would falsely mark an unreviewed commit land-ready and
silently discard the fix the next time `rereview-seed` does
`rm -rf "$WORKTREE"`. Resolve the worktree this round actually reviewed
(stamped by `rereview-seed`, the same key `build.md` uses for an ordinary
con-voyage run) and compare its HEAD to the PR branch's remote head before
doing anything else below:

```bash
WORKTREE=""
if [ -n "$CV_LIB" ]; then
  WORKTREE="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.source_anchor_work_dir)"
fi
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "con-voyage rereview-finalize: could not resolve the reviewed worktree from ${ROOT_ID}'s gc.build.source_anchor_work_dir — refusing to finalize without knowing what was actually reviewed" >&2
  gc mail send mayor \
    -s "con-voyage re-review: cannot finalize ${REPO_FULL}#${PR_NUMBER} — no reviewed worktree" \
    -m "rereview-finalize could not resolve gc.build.source_anchor_work_dir from workflow root ${ROOT_ID}; refusing to report approval or advance last_reviewed_head_sha without knowing what was reviewed." \
    2>&1 || echo "note: escalation mail failed too (continuing)" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=worktree_unresolved'
  bd close "$CLAIMED_BEAD_ID" --reason "Could not resolve the reviewed worktree — see stderr."
  exit 0
fi

LOCAL_HEAD_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "")"
REMOTE_HEAD_SHA="$(git -C "$WORKTREE" ls-remote origin "refs/heads/${BRANCH}" 2>/dev/null | cut -f1)"
LAST_REVIEWED_HEAD_SHA="${REMOTE_HEAD_SHA:-$LOCAL_HEAD_SHA}"

if [ -n "$LOCAL_HEAD_SHA" ] && [ "$LOCAL_HEAD_SHA" != "$REMOTE_HEAD_SHA" ]; then
  echo "con-voyage rereview-finalize: reviewed worktree HEAD (${LOCAL_HEAD_SHA}) differs from ${BRANCH}'s remote head (${REMOTE_HEAD_SHA:-<none>}) — pushing the converged fix commit(s) back before reporting approval"
  CV_GUARD="${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh"
  [ -f "$CV_GUARD" ] && [ -x "$CV_GUARD" ] || CV_GUARD=""
  PUSH_OK="true"
  if [ -n "$CV_GUARD" ]; then
    "$CV_GUARD" dirty "$WORKTREE" || PUSH_OK="false"
    "$CV_GUARD" guard "$WORKTREE" "origin/${BRANCH}" || PUSH_OK="false"
  fi
  if [ "$PUSH_OK" = "true" ] && ! git -C "$WORKTREE" push origin "HEAD:${BRANCH}"; then
    PUSH_OK="false"
  fi
  if [ "$PUSH_OK" != "true" ]; then
    echo "con-voyage rereview-finalize: failed to push the converged fix commit(s) back to ${BRANCH} — refusing to report approval or advance last_reviewed_head_sha against unpushed content" >&2
    gc mail send mayor \
      -s "con-voyage re-review: push failed for ${REPO_FULL}#${PR_NUMBER}" \
      -m "rereview-finalize's reviewed worktree (${WORKTREE}) has a converged fix at ${LOCAL_HEAD_SHA} that could not be pushed to ${BRANCH} (hygiene guard or push failure — see this step's stderr). The PR branch still has the original, unreviewed commit. This needs a human to land the fix manually." \
      2>&1 || echo "note: escalation mail failed too (continuing)" >&2
    bd update "$CLAIMED_BEAD_ID" \
      --set-metadata 'gc.outcome=fail' \
      --set-metadata 'gc.failure_class=push_failed'
    bd close "$CLAIMED_BEAD_ID" --reason "Converged fix commit could not be pushed back to the PR branch — see stderr/mayor mail."
    exit 0
  fi
  LAST_REVIEWED_HEAD_SHA="$LOCAL_HEAD_SHA"
fi
```

CI watching for this PR is already handled by the standing `con-voyage-pr-watch`
order once the push above lands a new commit on the branch — this step does
not itself wait on CI.

## Report the verdict to the mayor and clear the in-flight guard

Derive `overall_line`/verdict from `review-synthesis.md` the same way
publish.md does. Then, REGARDLESS of whether the round found only LOW
findings or was fully clean, mail the mayor the verdict (LOW-only results
are surfaced here, never silently auto-accepted) and advance the `.finalize`
record so con-voyage-rereview-watch.sh can detect the NEXT push:

```bash
gc mail send mayor \
  -s "RE-REVIEW COMPLETE: ${REPO_FULL}#${PR_NUMBER}" \
  -m "con-voyage re-review round ${REVIEW_ROUND} finished for ${REPO_FULL}#${PR_NUMBER}: <overall_line from review-synthesis.md>" \
  || echo "note: mayor mail failed (continuing)" >&2

if [ -n "$CV_LIB" ]; then
  # $LAST_REVIEWED_HEAD_SHA is resolved above (the PR branch's actual remote
  # head after any converged fix was pushed back) — never re-derive it from
  # the worktree alone here, or an unpushed local commit could advance this
  # record past what the PR branch actually has.
  (
    export CV_STATE_DIR
    source "$CV_LIB"
    finalize_read "$FINALIZE_KEY"
    finalize_write "$FINALIZE_KEY" "$FS_WORK_BEAD" "$FS_CONVOY_ID" "$FS_REPO_FULL" \
      "$FS_PR_NUMBER" "$FS_PR_AUTHOR" "$FS_IMPLEMENTOR" "awaiting_merge" "$FS_ROOT_BEAD_ID" \
      "$FS_ROSTER_VARS" "${LAST_REVIEWED_HEAD_SHA:-$FS_LAST_REVIEWED_HEAD_SHA}" "${REVIEW_ROUND}" ""
  )
  gc bd set-state "$FS_WORK_BEAD" cv=awaiting_merge \
    --reason "con-voyage re-review round ${REVIEW_ROUND} complete" >/dev/null 2>&1 \
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
bd close "$CLAIMED_BEAD_ID" --reason "Re-review round ${REVIEW_ROUND} complete."
```

Do not merge the branch. Do not open a second PR. Do not invoke
provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
