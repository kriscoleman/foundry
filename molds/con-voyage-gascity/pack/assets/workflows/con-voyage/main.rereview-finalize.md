Finalize the con-voyage re-review round (fk-pubvq). The review loop above
has completed and all active lanes approved (LOW findings only, or clean).
Post the round's ONE aggregated comment, report the verdict to the mayor,
clear this PR's in-flight re-review guard, and write the build artifact.

This step does not itself rewrite the PR body today — only the comment
thread above and the mayor mail below. If a future change has this step (or
any other) rewrite the PR body's verdict section on a later round, use
`cv_set_pr_verdict_section` (con-voyage-lib.sh, fk-db9yc3) on the existing
body rather than hand-building the section again — it replaces the marked
verdict block in place so a later round never leaves two.

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
# review fk-drbqfj BLOCKING-1 (simplicity, iteration 4): each fenced ```bash```
# block in a con-voyage step .md executes as its own independent shell — a
# variable assigned in an earlier fence (CV_LIB/FINALIZE_KEY/ROOT_ID from
# "Resolve this run's inputs" above) does NOT survive into this one. Re-derive
# every one of them here rather than reusing names from the earlier fence,
# the same remedy already applied elsewhere in this pack
# (main.apply-review-findings.md).
#
# review fk-7bmhlz LOW-6 (SRE reliability): CV_LIB/CV_PACK_ROOT are resolved
# BEFORE the ROOT_ID fallback below (reordered from the earlier fix) so the
# fallback's own `gc bd show` call can be wrapped in cv_with_timeout once
# CV_LIB is known to be available — an unwrapped call here is the one this
# fence can actually reach (GC_ROOT_BEAD_ID is unset) if a hung/slow store
# ever makes it the live path, unlike every other `gc`/`bd` call in this
# file, which only runs on failure branches that already exit immediately.
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"

CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""

# review fk-z6rts BLOCKING-2 (iteration 2, QA/test-engineering): resolve via
# the shared cv_step_root_bead_id helper (GC_ROOT_BEAD_ID env var, else a
# timeout-bounded live lookup) so this fence and the posting fence below
# cannot drift onto two different fallback behaviors again.
if [ -n "$CV_LIB" ]; then
  ROOT_ID="$(source "$CV_LIB" && cv_step_root_bead_id "$GC_BEAD_ID")"
else
  ROOT_ID="${GC_ROOT_BEAD_ID:-$GC_BEAD_ID}"
fi
[ -n "$ROOT_ID" ] || ROOT_ID="$GC_BEAD_ID"

FINALIZE_KEY=""
CV_STATE_DIR=""
if [ -n "$CV_LIB" ]; then
  FINALIZE_KEY="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.finalize_key)"
  CV_STATE_DIR="$(source "$CV_LIB" && cv_default_state_dir)"
fi
[ -n "${CV_STATE_DIR:-}" ] || CV_STATE_DIR="${GC_CITY:-.}/.gc/cv-pr-watch"

# review fk-7bmhlz LOW-5 (code-review/native-language fk-202t44): PEEK, don't
# clear, here. This fence runs before the aggregate comment is actually
# posted (below); clearing the per-PR record now and having the post later
# fail would silently drop this round's only chance to surface it — it
# would never be re-offered to a later round. The posting fence clears the
# record for real, and only once that post is CONFIRMED to have succeeded.
CV_DEFERRED_STATUS=""
if [ -n "$CV_LIB" ] && [ -n "$FINALIZE_KEY" ]; then
  CV_DEFERRED_STATUS="$(export CV_STATE_DIR; source "$CV_LIB" && cv_defer_status_peek "$FINALIZE_KEY")"
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
  else
    # review fk-7bmhlz LOW-5 (code-review/native-language fk-202t44): only
    # clear the deferred ci-repair pending-status once THIS round's
    # aggregate comment is CONFIRMED posted (the fold-in fence above only
    # peeked it, on purpose — see its own comment). Re-derive CV_LIB and the
    # finalize key fully self-contained here, independent of whatever this
    # fence's own $CV_LIB/$ROOT_ID happen to resolve to above, so this clear
    # is correct even if this fence runs on its own: a failed post leaves
    # the per-PR pending-status file untouched, so the NEXT round's fold-in
    # naturally re-peeks and re-offers it instead of this round silently
    # discarding it on a post failure.
    CLEAR_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
    CLEAR_CV_LIB="${CLEAR_TOPLEVEL:+${CLEAR_TOPLEVEL}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh}"
    [ -n "$CLEAR_CV_LIB" ] && [ -f "$CLEAR_CV_LIB" ] || CLEAR_CV_LIB="${GC_CITY:-.}/packs/con-voyage/assets/scripts/con-voyage-lib.sh"
    [ -f "$CLEAR_CV_LIB" ] || CLEAR_CV_LIB=""
    if [ -n "$CLEAR_CV_LIB" ]; then
      # review fk-z6rts BLOCKING-2 (iteration 2): same shared helper the
      # fold-in fence above uses. This fence's own `gc bd show` fallback was
      # missing outright, so CLEAR_ROOT_ID silently resolved to this
      # rereview-finalize STEP bead (which carries no gc.var.finalize_key)
      # instead of the workflow root whenever GC_ROOT_BEAD_ID did not
      # survive into this separately-invoked fence — silently skipping the
      # clear on every successful post in the realistic production case.
      CLEAR_ROOT_ID="$(source "$CLEAR_CV_LIB" && cv_step_root_bead_id "$GC_BEAD_ID")"
      CLEAR_FINALIZE_KEY="$(source "$CLEAR_CV_LIB" && cv_bead_metadata "$CLEAR_ROOT_ID" gc.var.finalize_key)"
      CLEAR_CV_STATE_DIR="$(source "$CLEAR_CV_LIB" && cv_default_state_dir)"
      [ -n "$CLEAR_CV_STATE_DIR" ] || CLEAR_CV_STATE_DIR="${GC_CITY:-.}/.gc/cv-pr-watch"
      if [ -n "$CLEAR_FINALIZE_KEY" ]; then
        # review fk-z6rts BLOCKING-1 (iteration 2): clear only the content
        # this round's fold-in fence actually peeked and just included in
        # the post confirmed above — never whatever is in the file at clear
        # time. A concurrent con-voyage-ci-repair append landing in the
        # (network-call-length) window between that peek and this confirmed
        # post must survive into the NEXT round's peek, not be silently
        # destroyed by a blind read_and_clear here. The fold-in fence above
        # wrote the exact peeked content to ci-repair-status.md (under the
        # same rig-root/root-bead-id-keyed build dir) whenever it peeked
        # something non-empty; re-read that file here as the expected
        # content to clear through.
        CLEAR_RIG_ROOT="${GC_RIG_ROOT:-}"
        [ -n "$CLEAR_RIG_ROOT" ] || CLEAR_RIG_ROOT="$(source "$CLEAR_CV_LIB" && cv_default_rig_root)"
        [ -n "$CLEAR_RIG_ROOT" ] || CLEAR_RIG_ROOT="${GC_CITY:-.}"
        CLEAR_EXPECTED_FILE="${CLEAR_RIG_ROOT}/.gc/build/${CLEAR_ROOT_ID}/ci-repair-status.md"
        CLEAR_EXPECTED_CONTENT=""
        [ -f "$CLEAR_EXPECTED_FILE" ] && CLEAR_EXPECTED_CONTENT="$(cat "$CLEAR_EXPECTED_FILE")"
        if [ -n "$CLEAR_EXPECTED_CONTENT" ]; then
          (export CV_STATE_DIR="$CLEAR_CV_STATE_DIR"; source "$CLEAR_CV_LIB" && cv_defer_status_clear_through "$CLEAR_FINALIZE_KEY" "$CLEAR_EXPECTED_CONTENT" >/dev/null) \
            || echo "con-voyage rereview-finalize: WARNING: deferred ci-repair status at ${CLEAR_FINALIZE_KEY} changed since this round's peek — leaving it untouched for the next round rather than risk dropping unposted content" >&2
        fi
      fi
    fi
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
