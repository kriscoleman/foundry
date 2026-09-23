Publish the con-voyage review result.

Read push {{push}} and open_pr {{open_pr}} from the workflow vars.

Con-voyage posture: push=true causes the reviewed work branch to be pushed to
the remote origin. open_pr=true causes a GitHub PR to be opened against the
base branch. Neither action triggers an auto-merge — the merge_queue="observe"
city.toml monitor watches the PR for CI results and human feedback only. A
human must land the PR.

## Verify the review was actually approved before doing anything else (fk-6i53)

This step's graph.v2 dependency on `{target}.con-voyage-review-loop` is
satisfied by that bead's CLOSURE alone, regardless of its own gc.outcome. A
controller-level gate error (e.g. a missing check script) can close the
review loop with gc.outcome=fail while still leaving this dependency
satisfied — silently converting "review never actually ran" into "review
approved" for whatever runs next, which is you. Do not trust graph dispatch
alone; re-derive the true verdict directly before touching push or PR state:

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

CV_VERIFY="$(command -v cv-verify-review-approved.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-verify-review-approved.sh 2>/dev/null | head -1)"
if [ -z "$CV_VERIFY" ] || [ ! -x "$CV_VERIFY" ]; then
  echo "cv-verify-review-approved.sh not found — refusing to publish without being able to verify the review outcome" >&2
  exit 1
fi
"$CV_VERIFY" "$ROOT_ID" || { echo "review was NOT genuinely approved — refusing to push or open a PR" >&2; exit 1; }
```

If this block fails for ANY reason (script not found, or the review genuinely
was not approved), STOP here. Do not push, do not open a PR, do not write a
no-op publish record either. Mail the mayor with the exact output above, set
gc.build.publish_status=failed, gc.build.publish_action=failed, and
gc.build.publish_reason=<the printed reason> on the workflow root, and close
this publish bead with gc.outcome=fail and
gc.failure_class=review_not_approved instead of proceeding to the push/PR
logic below.

If push is true:
- Before pushing, refuse to ship a worktree that still has uncommitted review
  fixes (fk-etw7): apply-review-findings commits its own edits, so anything
  left uncommitted here means a fix was applied but never landed in a commit —
  pushing anyway would silently drop it from the PR. Fail loud instead of
  pushing stale HEAD:

  ```bash
  CV_GUARD="$(command -v cv-worktree-prep.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-worktree-prep.sh 2>/dev/null | head -1)"
  if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
    "$CV_GUARD" dirty "$(pwd)" || { echo "worktree has uncommitted changes — review fixes must be committed before publish; refusing to push stale HEAD" >&2; exit 1; }
  fi
  ```
- Then run the artifact-hygiene guard as a last line of defense — it fails
  loud if a local tooling path (`.beads/`, `.gc/`, `.claude/`, dolt data) is
  staged, or is committed AND was added by this work branch relative to its
  base. Pass the same `<base-branch>` you use in the PR-create call below as
  the 3rd argument: the guard flags only hygiene paths this branch
  *introduced* on top of that base, so a repo that legitimately tracks e.g.
  `.claude/` upstream is not a false positive:

  ```bash
  if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
    "$CV_GUARD" guard "$(pwd)" "origin/<base-branch>" || { echo "hygiene violation detected — fix it before pushing" >&2; exit 1; }
  fi
  ```
- Push the work branch to origin using create-if-absent or lease-checked
  semantics. Fail closed if the remote cannot enforce atomic or lease-safe
  push.

If open_pr is true (requires push to have succeeded):
- Open a PR only after push succeeds.
- Use the final review report for the PR title and body. The title must be a
  conventional-commit title derived from the work bead. The body must include
  the review verdict (APPROVED), the active reviewer roster, the number of
  review cycles completed, and any LOW findings surfaced to the human.
- The PR body is posted under the operator's GitHub PAT, exactly like every
  other piece of text con-voyage writes to GitHub — it MUST lead with the
  machine-identity banner. Do NOT run raw `gh pr create` with an unbannered
  body. Assemble the body, then open the PR through `cv-pr-comment.sh create`
  so the banner is guaranteed:

  ```bash
  CV_BIN="$(command -v cv-pr-comment.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-pr-comment.sh 2>/dev/null | head -1)"
  if [ -z "$CV_BIN" ] || [ ! -x "$CV_BIN" ]; then
    echo "cv-pr-comment.sh not found — refusing to open the PR without the banner (do NOT fall back to raw gh pr create)" >&2
    exit 1
  fi
  "$CV_BIN" create --repo <owner/repo> --title "<conventional-commit title>" \
    --body-file <path to the assembled PR body> --base <base-branch> --head <work-branch> \
    --formula con-voyage --agent "<rig>/gc.publisher"
  ```
- Do not auto-merge. The PR is opened in ready state for human review only.

### After the PR opens — update the WORK BEAD and arm the finalize monitor

Once the PR exists, record it on the WORK BEAD, flip its phase to
`awaiting_merge`, and write the per-PR finalize record so the
`con-voyage-finalize` monitor can close the work bead + convoy and release the
implementor when a human lands (or abandons) the PR. The work bead is
`$WORK_BEAD` from the review context (resolved from `{{convoy_id}}` at setup);
re-resolve it the same way if the context does not carry it. Run this block
after a successful PR open, substituting the real values:

```bash
# Inputs (fill from this run):
WORK_BEAD="<work bead id from the review context>"   # NOT this step's bead
CONVOY_ID="{{convoy_id}}"                             # the con-voyage convoy
PR_URL="<the https URL cv-pr-comment.sh create printed>"
PR_NUMBER="<the PR number>"
REPO_FULL="<owner/repo>"
PR_AUTHOR="$(gh api user --jq .login 2>/dev/null || echo kriscoleman)"  # operator login
# The long-lived implementor session the facilitator dispatched this con-voyage
# to (Phase 3: "the same implementor the formula put on the work bead"), in
# "<rig>/<session>" form. This is the session the finalize monitor mails a
# release note to when the PR lands. Leave it EMPTY if you cannot resolve it —
# the finalize monitor still closes the work bead + convoy; only the release
# note is skipped.
IMPLEMENTOR="<rig>/<the long-lived implementor session, or empty>"

# 1. Record the PR on the work bead + append a PR line (best-effort).
gc bd update "$WORK_BEAD" --set-metadata "pr_url=${PR_URL}" \
  || echo "note: could not set pr_url on $WORK_BEAD (continuing)"
gc bd note "$WORK_BEAD" "PR opened: ${PR_URL} — awaiting human land (never auto-merged). This bead closes automatically on merge/close via con-voyage-finalize." \
  || echo "note: could not append PR line to $WORK_BEAD (continuing)"
gc bd set-state "$WORK_BEAD" cv=awaiting_merge --reason "con-voyage: PR opened, awaiting human land" \
  || echo "note: could not set cv=awaiting_merge on $WORK_BEAD (continuing)"

# 2. Write the finalize record the con-voyage-finalize monitor consumes. It
#    lives under the SAME state dir the PR-watch orders use (default
#    .gc/cv-pr-watch), keyed cv-finalize-<owner>-<repo>-<pr_number>. This is
#    the ONLY reliable work-bead<->PR map for a clean, review-approved PR (the
#    repair .state records only exist for PRs with a CI failure).
#
#    Resolve the state dir's default by calling con-voyage-lib.sh's
#    cv_default_state_dir() (fk-mr07) instead of hand-copying its
#    GC_RIG_ROOT / .beads-walkup / GC_CITY-fallback algorithm inline: GC_CITY
#    is the multi-rig CITY root, not any one rig's own root, so defaulting to
#    it here previously landed a finalize record at the city level while the
#    monitor scanned the rig level — confirmed live, PR #59's record sat
#    orphaned there until moved by hand. This block is a single contiguous
#    fenced ```bash block, so it CAN source a shell lib like the pack's other
#    scripts do — no need to duplicate the resolver's algorithm here too.
if [ -z "${CV_STATE_DIR:-}" ]; then
  CV_LIB="$(command -v con-voyage-lib.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
  if [ -n "$CV_LIB" ]; then
    CV_STATE_DIR="$(source "$CV_LIB" && cv_default_state_dir)"
  fi
  [ -n "${CV_STATE_DIR:-}" ] || CV_STATE_DIR="${GC_CITY:-.}/.gc/cv-pr-watch"
fi
mkdir -p "$CV_STATE_DIR"
owner="${REPO_FULL%%/*}"; repo="${REPO_FULL##*/}"
finalize_key="cv-finalize-${owner}-${repo}-${PR_NUMBER}"
{
  printf 'work_bead=%s\n' "$WORK_BEAD"
  printf 'convoy_id=%s\n' "$CONVOY_ID"
  printf 'repo_full=%s\n' "$REPO_FULL"
  printf 'pr_number=%s\n' "$PR_NUMBER"
  printf 'pr_author=%s\n' "$PR_AUTHOR"
  printf 'implementor_session=%s\n' "$IMPLEMENTOR"
  printf 'last_phase=%s\n' "awaiting_merge"
} > "${CV_STATE_DIR}/${finalize_key}.finalize"
echo "con-voyage publish: armed finalize monitor for ${REPO_FULL}#${PR_NUMBER} -> work bead ${WORK_BEAD}"
```

If push is false or open_pr is false, record a no-op publish outcome and
preserve the approved con-voyage review result without mutating remotes. In the
no-op case do NOT write a finalize record and do NOT flip the work bead to
`awaiting_merge` (there is no PR to finalize); leave it in `cv=reviewing`.

Required workflow root metadata (update before closing):
- gc.build.publish_status=published|noop|failed
- gc.build.publish_action=push|pr|push_pr|noop|failed
- gc.build.publish_recorded_at=<UTC timestamp>
- gc.build.publish_artifact_path=<publish result artifact path>
- gc.build.publish_reason=<short machine-readable reason>

For disabled publishing use gc.build.publish_status=noop,
gc.build.publish_action=noop, and reason push=false_open_pr=false.

Close only after the push, PR creation, or explicit no-op is recorded on both
the workflow root and this publish step.

Do not merge the branch. Do not invoke provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.
