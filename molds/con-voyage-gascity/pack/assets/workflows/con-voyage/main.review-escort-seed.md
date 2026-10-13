Seed the con-voyage review-only escort (fk-aygo23). This PR was not built by
con-voyage — there is nothing to build and nothing con-voyage is allowed to
change. This step's only job is to attach a READ-ONLY detached worktree to
the PR's current head commit and stamp the workflow root with the metadata
the REUSED review machinery (main.setup-con-voyage-review.md,
main.synthesize-review.md, every lane file) already expects from
con-voyage's own prepare-build/build phases, so that machinery runs
completely unmodified.

**This step never creates a branch, never commits, never rebases, and never
pushes.** It only reads refs.

## Resolve this run's inputs

`repo` and `pr` are the formula vars set at sling time. Resolve the workflow
root id the same way every other con-voyage step does, then read both vars
back from the root's `gc.var.*` metadata (same reasoning as
main.rereview-seed.md BLOCKING-1 fk-z6rts): this `description_file` is too
large for gc to inline-substitute `{var}` tokens into its body, so a literal
`{repo}`/`{pr}` token here is a permanent no-op — resolve dynamically
instead, exactly like every other over-threshold step in this pack:

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
  echo "con-voyage review-escort-seed: con-voyage-lib.sh not found — cannot resolve formula vars from workflow root ${ROOT_ID}" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=missing_vars'
  bd close "$CLAIMED_BEAD_ID" --reason 'con-voyage-lib.sh not found — cannot resolve formula vars.'
  exit 0
fi

REPO_FULL="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.repo)"
PR_NUMBER="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.pr)"
if [ -z "${REPO_FULL}" ] || [ -z "${PR_NUMBER}" ]; then
  echo "con-voyage review-escort-seed: missing required var(s) on workflow root ${ROOT_ID} — repo='${REPO_FULL}' pr='${PR_NUMBER}'" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=missing_vars'
  bd close "$CLAIMED_BEAD_ID" --reason 'Missing required repo/pr var(s) — see stderr.'
  exit 0
fi
```

## Gate on the PR author's trust level (review fk-hbsmk BLOCKING-1)

Review lanes execute the PR's own checked-out code (build/test/lint, native
language review) inside the worktree this step attaches. This formula's
entire purpose is reviewing PRs of unknown provenance — including forks —
so running that code unsandboxed on the Gas City host is a direct
RCE → secret-exfiltration path against the host's `gh` token and mail
credentials. Refuse before fetching or attaching anything unless the PR
author is trusted:

```bash
AUTHOR_ASSOC="$(gh pr view "$PR_NUMBER" --repo "$REPO_FULL" --json authorAssociation --jq .authorAssociation 2>/dev/null)"
case "$AUTHOR_ASSOC" in
  OWNER|MEMBER|COLLABORATOR) ;;
  *)
    echo "con-voyage review-escort-seed: refusing ${REPO_FULL}#${PR_NUMBER} — author association '${AUTHOR_ASSOC:-unknown}' is not OWNER/MEMBER/COLLABORATOR. Review lanes execute checked-out code, so this formula is not a safe sandbox for an untrusted fork/contributor PR; no worktree was attached." >&2
    bd update "$CLAIMED_BEAD_ID" \
      --set-metadata 'gc.outcome=fail' \
      --set-metadata 'gc.failure_class=untrusted_pr_author'
    bd close "$CLAIMED_BEAD_ID" --reason "Refused: PR author association '${AUTHOR_ASSOC:-unknown}' is not trusted (OWNER/MEMBER/COLLABORATOR)."
    CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
    CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
    [ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
    CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
    [ -f "$CV_LIB" ] || CV_LIB=""
    if [ -n "$CV_LIB" ]; then
      source "$CV_LIB" && cv_with_timeout 30 gc mail send mayor -s "con-voyage review-escort refused: untrusted PR author (${ROOT_ID})" -m "con-voyage review-escort-seed (${CLAIMED_BEAD_ID}) refused ${REPO_FULL}#${PR_NUMBER}: author association '${AUTHOR_ASSOC:-unknown}' is not OWNER/MEMBER/COLLABORATOR. Review lanes execute checked-out code, so reviewing an untrusted fork/contributor PR here risks code execution against this host's gh token and mail credentials. If this PR must still be reviewed, do so manually or restrict escort lanes to a read-only diff review, then re-dispatch." --json >/dev/null 2>&1
      source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "con-voyage review-escort-seed refused (${CLAIMED_BEAD_ID}): untrusted PR author association '${AUTHOR_ASSOC:-unknown}'"
    else
      echo "con-voyage review-escort-seed: con-voyage-lib.sh unresolved — cannot mail the mayor or sweep the workflow root; a human must close ${ROOT_ID} by hand" >&2
    fi
    exit 0
    ;;
esac
```

An empty/unresolvable `$AUTHOR_ASSOC` (a `gh` failure, a private repo the
token can't see, etc.) falls into the refusal branch above, not into
"trusted" — fail safe, never fail open on an unknown trust level.

## Attach a READ-ONLY detached worktree to the PR's head commit

Fetch `refs/pull/<pr>/head` — a ref GitHub publishes for every PR, including
ones from a fork with no push access to this repo — and attach a fresh
worktree to it with `--detach`. Never `-B`/`-b` (that would create or move a
local branch); never fetch or push any other ref. If `$SEED_FAIL` ends up
non-empty below, mail the mayor with the exact error, close this step AND
sweep the whole workflow root (so review lanes mint nothing against a seed
that never ran, same pattern as main.rereview-seed.md fk-zhyz68), and STOP —
do not proceed to stamp the root or close this step as pass. This whole flow
runs as ONE shell (fk-9iqxnx: splitting across fences has previously made an
agent execute them as separate shells and silently read an earlier fence's
un-exported local as empty):

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

WORKTREE="${RIG_ROOT}/worktrees/review-escort-${ROOT_ID}"
rm -rf "$WORKTREE"
mkdir -p "$(dirname "$WORKTREE")"

SEED_FAIL=""
PR_HEAD_SHA=""
if ! git fetch origin "refs/pull/${PR_NUMBER}/head"; then
  SEED_FAIL="failed to fetch refs/pull/${PR_NUMBER}/head from origin"
fi
if [ -z "$SEED_FAIL" ]; then
  PR_HEAD_SHA="$(git rev-parse FETCH_HEAD 2>/dev/null || echo "")"
  [ -n "$PR_HEAD_SHA" ] || SEED_FAIL="could not resolve FETCH_HEAD after fetching refs/pull/${PR_NUMBER}/head"
fi
if [ -z "$SEED_FAIL" ]; then
  git worktree add -q --detach "$WORKTREE" "$PR_HEAD_SHA" \
    || SEED_FAIL="failed to attach a detached worktree for ${PR_HEAD_SHA} at ${WORKTREE}"
fi

if [ -n "$SEED_FAIL" ]; then
  echo "con-voyage review-escort-seed: ${SEED_FAIL}" >&2
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=seed_worktree_attach'
  bd close "$CLAIMED_BEAD_ID" --reason "Review-escort seed failed: ${SEED_FAIL}"
  if [ -n "$CV_LIB" ]; then
    MAIL_ERR_FILE="$(mktemp)"
    source "$CV_LIB" && cv_with_timeout 30 gc mail send mayor -s "con-voyage review-escort seed failed: ${ROOT_ID}" -m "con-voyage review-escort-seed (${CLAIMED_BEAD_ID}) could not attach a read-only worktree for ${REPO_FULL}#${PR_NUMBER}: ${SEED_FAIL}. The review-only workflow has been abandoned — no review lanes will be dispatched." --json >/dev/null 2>"$MAIL_ERR_FILE"
    MAIL_RC=$?
    MAIL_ERR_TEXT="$(cat "$MAIL_ERR_FILE" 2>/dev/null)"
    rm -f "$MAIL_ERR_FILE"
    [ "$MAIL_RC" -eq 0 ] || echo "con-voyage review-escort-seed: mail to mayor on seed failure failed/timed out: ${MAIL_ERR_TEXT} — mayor NOT confirmed notified" >&2
    source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "con-voyage review-escort-seed failed (${CLAIMED_BEAD_ID}): ${SEED_FAIL}; no review lanes dispatched"
  else
    echo "con-voyage review-escort-seed: con-voyage-lib.sh unresolved — cannot mail the mayor or sweep the workflow root; a human must close ${ROOT_ID} by hand" >&2
  fi
  exit 0
fi
```

## Stamp the workflow root for the reused review machinery

`gc.build.source_anchor_id` is set to THIS step's own claimed bead
(`$GC_BEAD_ID`), never a synthetic convoy — there is no convoy for a
review-only escort. `cv_resolve_work_bead` (con-voyage-lib.sh) detects this
as a graph.v2 step-bead anchor (via `gc.step_ref`) and, finding no
`gc.var.finalize_key` on this root (correctly unset — this PR has no
`.finalize` record and never will), fails safe to returning the step bead's
own id. This is intentional: it is exactly what keeps
main.setup-con-voyage-review.md's work-bead claim/reassign block a no-op
(fk-tvefk0 guard) for this formula, so no work bead anywhere is claimed,
reassigned, or touched — this PR is never registered with
con-voyage-finalize, con-voyage-pr-watch, con-voyage-ci-repair, or
con-voyage-rereview-watch:

```bash
gc bd update "$ROOT_ID" \
  --set-metadata "gc.build.source_anchor_id=${GC_BEAD_ID}" \
  --set-metadata "gc.build.source_anchor_work_dir=${WORKTREE}" \
  --set-metadata 'gc.build.short_circuited=true' \
  --set-metadata "gc.review_escort.pr_head_sha=${PR_HEAD_SHA}"
```

`gc.review_escort.pr_head_sha` records the exact commit reviewed, so the
finalize step can prove the remote PR head never moved (this formula never
pushes anything) and so the posted comment can be traced back to a specific
commit if the PR gains new commits before a human reads it.

## Close

```bash
bd update "$CLAIMED_BEAD_ID" --set-metadata 'gc.outcome=pass'
bd close "$CLAIMED_BEAD_ID" --reason "Review-escort seed: attached read-only worktree for ${REPO_FULL}#${PR_NUMBER} at ${PR_HEAD_SHA}."
```

Do not invoke provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
