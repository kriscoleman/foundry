Finalize the con-voyage review-only escort (fk-aygo23). The review pass
above has completed. Post the round's ONE aggregated comment, report the
verdict to the mayor, write the build artifact, and stop.

**This step never pushes, commits, rebases, merges, or opens a PR, and never
writes a `.finalize` record.** This PR is not con-voyage's to publish — a
human (or the PR's own author) owns landing it. Verifying this is this
step's own job, below.

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
  echo "con-voyage review-escort-finalize: con-voyage-lib.sh not found — cannot resolve formula vars from workflow root ${ROOT_ID}" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=missing_vars'
  bd close "$CLAIMED_BEAD_ID" --reason 'con-voyage-lib.sh not found — cannot resolve formula vars.'
  exit 0
fi

REPO_FULL="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.repo)"
PR_NUMBER="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.pr)"
PR_HEAD_SHA_SEEDED="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.review_escort.pr_head_sha)"
WORKTREE="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.source_anchor_work_dir)"
if [ -z "${REPO_FULL}" ] || [ -z "${PR_NUMBER}" ]; then
  echo "con-voyage review-escort-finalize: missing required var(s) on workflow root ${ROOT_ID} — repo='${REPO_FULL}' pr='${PR_NUMBER}'" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=missing_vars'
  bd close "$CLAIMED_BEAD_ID" --reason 'Missing required repo/pr var(s) — see stderr.'
  exit 0
fi
```

## Prove nothing was pushed (fk-aygo23 acceptance: "the remote head SHA is unchanged")

Compare the PR's CURRENT remote head to `gc.review_escort.pr_head_sha`
(stamped by the seed step before any review ran). This formula has no code
path that could move it, but checking is cheap and turns "we never push"
from a design claim into something this step actually verifies every run.
A mismatch does not block posting the comment or mailing the verdict — the
PR simply gained new commits mid-review, which the posted comment and mail
below both note — but it is always logged and escalated, never silently
absorbed:

```bash
REMOTE_HEAD_SHA="$(git ls-remote origin "refs/pull/${PR_NUMBER}/head" 2>/dev/null | cut -f1)"
PR_MOVED="false"
if [ -n "$PR_HEAD_SHA_SEEDED" ] && [ -n "$REMOTE_HEAD_SHA" ] && [ "$PR_HEAD_SHA_SEEDED" != "$REMOTE_HEAD_SHA" ]; then
  PR_MOVED="true"
  echo "con-voyage review-escort-finalize: PR ${REPO_FULL}#${PR_NUMBER} head moved from ${PR_HEAD_SHA_SEEDED} (reviewed) to ${REMOTE_HEAD_SHA} (current) during this review — this is a new commit arriving mid-review, not anything this formula did; the posted comment and mayor mail will say which SHA was actually reviewed" >&2
fi
```

## Post the round's ONE aggregated review comment

Same manifest shape as main.publish.md's own aggregated comment (round is
always `1` — this formula has no `.finalize` record to carry a round
counter across invocations, and each fresh dispatch is its own independent
workflow root, so the dedup marker
`<!-- con-voyage-review:<root_bead_id> round=1 -->` stays unique per run
regardless):

```bash
CV_RIG_ROOT="${GC_RIG_ROOT:-}"
[ -n "$CV_RIG_ROOT" ] || CV_RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"
[ -n "$CV_RIG_ROOT" ] || CV_RIG_ROOT="${GC_CITY:-.}"
CV_BUILD_DIR="${CV_RIG_ROOT}/.gc/build/${ROOT_ID}"

CV_PACK_ROOT_BIN="$CV_PACK_ROOT"
[ -f "${CV_PACK_ROOT_BIN}/assets/scripts/cv-pr-comment.sh" ] || CV_PACK_ROOT_BIN="${GC_CITY:-.}/packs/con-voyage"
CV_BIN="${CV_PACK_ROOT_BIN}/assets/scripts/cv-pr-comment.sh"
[ -f "$CV_BIN" ] && [ -x "$CV_BIN" ] || CV_BIN=""
if [ -n "${CV_BIN:-}" ]; then
  if ! CV_AGGREGATE_OUT="$("$CV_BIN" comment-aggregate "$PR_NUMBER" --repo "$REPO_FULL" \
    --manifest <path to the assembled JSON manifest, round=1, built from CV_BUILD_DIR exactly like main.publish.md: rig/root_bead_id/overall_line/lanes[]/synthesis, with an extra_line noting "Reviewed commit ${PR_HEAD_SHA_SEEDED}; PR has since advanced to ${REMOTE_HEAD_SHA}." when $PR_MOVED is true> \
    --city-root "${GC_CITY:-.}" \
    --formula con-voyage-review-escort --agent "<rig>/gc.run-operator" 2>&1)"; then
    echo "con-voyage review-escort-finalize: comment-aggregate failed: ${CV_AGGREGATE_OUT}" >&2
    gc mail send mayor \
      -s "con-voyage review-escort: aggregated comment failed for ${REPO_FULL}#${PR_NUMBER}" \
      -m "cv-pr-comment.sh comment-aggregate failed: ${CV_AGGREGATE_OUT}" \
      2>&1 || echo "note: escalation mail failed too (continuing)" >&2
  fi
else
  echo "cv-pr-comment.sh not found — skipping the aggregated review comment" >&2
fi
```

A failure here must never fail this step — log it, escalate to the mayor,
and continue to the verdict mail below.

## Report the verdict to the mayor

Derive `overall_line`/verdict from `review-synthesis.md` the same way
publish.md does. Mail the mayor REGARDLESS of verdict (LOW-only and
BLOCKING results are both surfaced here, never silently dropped — this
formula has no publish step to fall back on if this mail doesn't go out):

```bash
gc mail send mayor \
  -s "REVIEW-ESCORT COMPLETE: ${REPO_FULL}#${PR_NUMBER}" \
  -m "con-voyage review-only escort finished for ${REPO_FULL}#${PR_NUMBER} (commit ${PR_HEAD_SHA_SEEDED}${PR_MOVED:+, PR has since advanced to ${REMOTE_HEAD_SHA}}): <overall_line from review-synthesis.md>. No commit, rebase, or push was made — this formula is review-only." \
  || echo "note: mayor mail failed (continuing)" >&2
```

## Write the build artifact

Write a `gc.build.review.v1` artifact under `.gc/build/${ROOT_ID}/`
recording: the repo/PR, the exact commit reviewed
(`gc.review_escort.pr_head_sha`), whether the PR head moved during review,
the review roster that ran, the final verdict, disposition of any LOW/BLOCKING
findings, and the aggregated-comment round posted (always 1). Record
`gc.build.review_report_path` on `$ROOT_ID`.

## Close — never merge, never publish

```bash
bd update "$CLAIMED_BEAD_ID" \
  --set-metadata 'gc.outcome=pass' \
  --set-metadata "gc.build.review_report_path=<final report path>"
bd close "$CLAIMED_BEAD_ID" --reason "Review-escort complete for ${REPO_FULL}#${PR_NUMBER}."
```

Do not merge the branch. Do not open a PR. Do not write a `.finalize` record
or register this PR with con-voyage-pr-watch, con-voyage-ci-repair, or
con-voyage-rereview-watch — this formula owns nothing past this close. Do
not invoke provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
