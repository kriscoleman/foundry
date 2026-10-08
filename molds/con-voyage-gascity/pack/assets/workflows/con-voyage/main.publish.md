Publish the con-voyage review result.

Read push {push} and open_pr {open_pr} from the workflow vars.

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

CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/cv-verify-review-approved.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_VERIFY="${CV_PACK_ROOT}/assets/scripts/cv-verify-review-approved.sh"
[ -f "$CV_VERIFY" ] || CV_VERIFY=""
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

## Resolve the journey's base branch (fk-qppb4 — GitHub stacked PRs)

Every base-branch reference below is the SAME resolved `$BASE_BRANCH` value —
never a hand-filled guess that silently defaults to `main`. Resolve it once, from the
same helper `{target}.setup-con-voyage-review.md` already used to seed the
review context, so a stacked slice's PR is opened against (and guarded
against) the branch it actually stacks on instead of always `main`:

```bash
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
BASE_BRANCH="main"
CONVOY_ID=""
if [ -n "$CV_LIB" ]; then
  # $ROOT_ID is already resolved above — never a literal {convoy_id} token:
  # this description_file is too large for gc to inline, so any {var} token
  # in this file's own content is a permanent no-op (fk-4q6ib). prepare-build
  # wrote this key on the workflow root before this workflow's first step
  # ever finished, so it is always PRESENT by the time publish runs — but a
  # transient `gc bd show` failure can still make it unreadable right now
  # (fk-zl42t iteration-3 BLOCKING-1), so guard the read, not just the write.
  CONVOY_ID="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.source_anchor_id)"
  if [ -z "$CONVOY_ID" ]; then
    echo "con-voyage publish: could not resolve source anchor id from workflow root ${ROOT_ID} metadata (gc.build.source_anchor_id empty or unreadable) — refusing to guess a base branch" >&2
    exit 1
  fi
  BASE_BRANCH="$(source "$CV_LIB" && cv_resolve_base_branch "$CONVOY_ID" "$(pwd)")"
fi

# fk-6os73y: use the branch name prepare-build computed once and stored on
# the workflow root — never recompute it from CONVOY_ID alone, it may carry a
# topic slug. Fall back to the pre-fk-6os73y bare name for a root that
# predates this key.
WORK_BRANCH_NAME=""
if [ -n "$CV_LIB" ]; then
  WORK_BRANCH_NAME="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.work_branch_name)"
fi
[ -n "$WORK_BRANCH_NAME" ] || WORK_BRANCH_NAME="con-voyage/${CONVOY_ID}"
echo "con-voyage publish: resolved base branch = ${BASE_BRANCH}"

# fk-6os73y: cv_ensure_work_branch_name stamps this flag on the root after
# exhausting its persist retries — prepare-build's computed name still works
# for THIS run (we just fell back to recomputing it above), but nobody was
# ever told the cache never stuck, so a human has no visibility into how
# often this degrades. Best-effort, non-fatal: mail the mayor once and keep
# publishing with the value already resolved above.
if [ -n "$CV_LIB" ]; then
  WORK_BRANCH_NAME_UNPERSISTED="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.work_branch_name_unpersisted)"
  if [ "$WORK_BRANCH_NAME_UNPERSISTED" = "true" ]; then
    echo "con-voyage publish: gc.build.work_branch_name_unpersisted=true on ${ROOT_ID} — the computed branch name never persisted to the workflow root; notifying the mayor" >&2
    gc mail send mayor \
      -s "con-voyage publish: work-branch name never persisted for ${ROOT_ID}" \
      -m "gc.build.work_branch_name_unpersisted=true on workflow root ${ROOT_ID} (resolved branch: ${WORK_BRANCH_NAME}). cv_ensure_work_branch_name exhausted its persist retries earlier in this journey; this run recomputed the same name and is proceeding, but the cache never stuck — worth a look if this recurs." \
      2>&1 || echo "note: escalation mail failed too (continuing)" >&2
  fi
fi
```

If push is true:
- Before pushing, refuse to ship a worktree that still has uncommitted review
  fixes (fk-etw7): apply-review-findings commits its own edits, so anything
  left uncommitted here means a fix was applied but never landed in a commit —
  pushing anyway would silently drop it from the PR. Fail loud instead of
  pushing stale HEAD:

  ```bash
  CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
  CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
  [ -f "${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
  CV_GUARD="${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh"
  [ -f "$CV_GUARD" ] || CV_GUARD=""
  if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
    "$CV_GUARD" dirty "$(pwd)" || { echo "worktree has uncommitted changes — review fixes must be committed before publish; refusing to push stale HEAD" >&2; exit 1; }
  fi
  ```
- Then run the artifact-hygiene guard as a last line of defense — it fails
  loud if a local tooling path (`.beads/`, `.gc/`, `.claude/`, dolt data) is
  staged, or is committed AND was added by this work branch relative to its
  base. Pass the resolved `$BASE_BRANCH` from above as the 3rd argument: the
  guard flags only hygiene paths this branch *introduced* on top of that
  base, so a repo that legitimately tracks e.g. `.claude/` upstream is not a
  false positive:

  ```bash
  if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
    "$CV_GUARD" guard "$(pwd)" "origin/${BASE_BRANCH}" || { echo "hygiene violation detected — fix it before pushing" >&2; exit 1; }
  fi
  ```
- A source-anchor worktree can still reach this step on a detached HEAD
  (fk-tazxl: build's own `ensure-branch` call may predate this fix on an
  older worktree, or a non-con-voyage path fed this one) — there is no ref to
  push otherwise. Attach a branch now, using `$WORK_BRANCH_NAME` — the SAME
  `con-voyage/<bead-id>-<topic-slug>` (or bare `con-voyage/<bead-id>`) name
  prepare-build computed once and `{target}.build.md` reuses, never a freshly
  recomputed name — or fail loud rather than silently push nothing:

  ```bash
  if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
    "$CV_GUARD" ensure-branch "$(pwd)" "$WORK_BRANCH_NAME" \
      || { echo "worktree is on a detached HEAD and no branch could be attached — refusing to push nothing" >&2; exit 1; }
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
  so the banner is guaranteed. Pass the SAME resolved `$BASE_BRANCH` as
  `--base` — never a hardcoded `main` — so a stacked slice's PR targets the
  slice it actually stacks on:

  ```bash
  CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
  CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
  [ -f "${CV_PACK_ROOT}/assets/scripts/cv-pr-comment.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
  CV_BIN="${CV_PACK_ROOT}/assets/scripts/cv-pr-comment.sh"
  [ -f "$CV_BIN" ] || CV_BIN=""
  if [ -z "$CV_BIN" ] || [ ! -x "$CV_BIN" ]; then
    echo "cv-pr-comment.sh not found — refusing to open the PR without the banner (do NOT fall back to raw gh pr create)" >&2
    exit 1
  fi
  "$CV_BIN" create --repo <owner/repo> --title "<conventional-commit title>" \
    --body-file <path to the assembled PR body> --base "$BASE_BRANCH" --head "$WORK_BRANCH_NAME" \
    --formula con-voyage --agent "<rig>/gc.publisher"
  ```
- Do not auto-merge. The PR is opened in ready state for human review only.

### Post the round's ONE aggregated review comment (fk-9boht)

Review lanes never comment on the PR themselves (they only write to
`.gc/build/${ROOT_ID}/*-review.md`); posting the round's result to the PR is
this step's job, and it is always exactly ONE new comment via
`cv-pr-comment.sh comment-aggregate` — never a separate comment per lane,
never an edit of an earlier round's comment. Do this right after the PR
above opens (skip entirely when open_pr is false — there is no PR to comment
on):

1. Resolve the rig root as an ABSOLUTE path first, and build every
   `body_file` below from it — NOT from a bare `.gc/build/${ROOT_ID}/...`
   relative path. By this point in the journey this step's own cwd is the
   SOURCE-ANCHOR WORKTREE (prepare-build/build `cd`s into it and nothing
   downstream `cd`s back), which has no `.gc/` directory of its own — only
   the rig root does. A relative `body_file` silently resolves against the
   wrong directory, `cv-pr-comment.sh` can't open any of them, and every
   lane renders as `(report file unavailable)` in the posted comment even
   though the real reports are sitting right there at the rig root
   (observed in production, fk-jg0ieq — a human had to ask why every report
   was "unavailable"). Reuse the same rig-root resolution
   `cv_default_state_dir` already relies on — do not hand-copy it:

   ```bash
   CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
   CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
   [ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
   CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
   [ -f "$CV_LIB" ] || CV_LIB=""
   CV_RIG_ROOT="${GC_RIG_ROOT:-}"
   [ -n "$CV_RIG_ROOT" ] || [ -z "$CV_LIB" ] || CV_RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"
   [ -n "$CV_RIG_ROOT" ] || CV_RIG_ROOT="${GC_CITY:-.}"
   CV_BUILD_DIR="${CV_RIG_ROOT}/.gc/build/${ROOT_ID}"
   ```
2. Build a JSON manifest from what this cycle already produced:
   - `rig` / `root_bead_id` — this journey's rig and `$ROOT_ID`.
   - `round` — `1` (publish posts the first aggregated comment for this PR;
     a later re-review cycle — con-voyage-rereview-watch.sh's triggered
     `con-voyage-rereview` formula, fk-pubvq — increments `review_round` on
     the finalize record below and uses that value for its own equivalent
     call).
   - `overall_line` — one line, e.g. `"Approved: 6 lanes, 0 blocking, 4
     low."`, derived from `review-synthesis.md`'s own verdict/counts.
   - `extra_line` — omit, or `"LOWs for the human reviewer below."` when any
     LOW findings were surfaced to the human.
   - `lanes[]` — one entry per lane in the active roster (`review-context.md`
     Section 6: floor lanes + any active roster lenses), each
     `{agent, lens, verdict, findings, body_file}`, where `body_file` is that
     lane's own `${CV_BUILD_DIR}/<lane>-review.md` — an ABSOLUTE path built
     from `$CV_BUILD_DIR` above, never the bare relative form.
   - `synthesis` — `{agent, lens: "synthesis", verdict, findings, body_file:
     "${CV_BUILD_DIR}/review-synthesis.md"}` (same absolute-path rule),
     `findings` being the total LOW count (BLOCKING is always 0 by the time
     publish runs).
3. Post it once:

   ```bash
   CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
   CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
   [ -f "${CV_PACK_ROOT}/assets/scripts/cv-pr-comment.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
   CV_BIN="${CV_PACK_ROOT}/assets/scripts/cv-pr-comment.sh"
   [ -f "$CV_BIN" ] || CV_BIN=""
   [ -n "$CV_BIN" ] && [ -x "$CV_BIN" ] || { echo "cv-pr-comment.sh not found — skipping the aggregated review comment (PR body already carries the verdict)" >&2; }
   if [ -n "$CV_BIN" ] && [ -x "$CV_BIN" ]; then
     if ! CV_AGGREGATE_OUT="$("$CV_BIN" comment-aggregate "$PR_NUMBER" --repo "$REPO_FULL" \
       --manifest <path to the assembled JSON manifest> \
       --city-root "${GC_CITY:-.}" \
       --formula con-voyage --agent "<rig>/gc.publisher" 2>&1)"; then
       echo "cv-pr-comment.sh comment-aggregate failed: ${CV_AGGREGATE_OUT}" >&2
       gc mail send mayor \
         -s "con-voyage publish: aggregated review comment failed for PR ${PR_NUMBER}" \
         -m "cv-pr-comment.sh comment-aggregate failed (a version-skewed pack copy missing the subcommand is one known cause, fk-fzebe): ${CV_AGGREGATE_OUT}" \
         2>&1 || echo "note: escalation mail failed too (continuing)" >&2
     fi
   fi
   ```

A failure here (script missing, or the hygiene scan blocking on a
token-shaped string) must never fail the publish step itself or block the
PR — the PR body already carries the verdict; the aggregated comment is a
posterity convenience on top of it. Log the failure to stderr AND escalate
it to the mayor (fk-fzebe: a failure here was previously a silent skip a PR
could ship past unnoticed) and continue — never fail the publish step over
this.

### After the PR opens — update the WORK BEAD and arm the finalize monitor

Once the PR exists, record it on the WORK BEAD, flip its phase to
`awaiting_merge`, and write the per-PR finalize record so the
`con-voyage-finalize` monitor can close the work bead + convoy and release the
implementor when a human lands (or abandons) the PR. The work bead is
`$WORK_BEAD` from the review context (resolved from `{convoy_id}` at setup);
re-resolve it the same way if the context does not carry it. Run this block
after a successful PR open, substituting the real values:

```bash
# Inputs (fill from this run):
WORK_BEAD="<work bead id from the review context>"   # NOT this step's bead
# $CONVOY_ID is already resolved (base-branch resolution block above)
PR_URL="<the https URL cv-pr-comment.sh create printed>"
PR_NUMBER="<the PR number>"
REPO_FULL="<owner/repo>"
PR_AUTHOR="$(gh api user --jq .login 2>/dev/null || echo kriscoleman)"  # operator login
# The long-lived implementor session the facilitator dispatched this con-voyage
# to (Phase 3: "the same implementor the formula put on the work bead"). This
# is the session the finalize monitor mails a release note to when the PR
# lands, and the session pr-watch routes new human PR feedback to instead of
# the generic pool default (fk-krsvc). Resolve it deterministically from
# $ROOT_ID's OWN metadata rather than leaving it to be hand-filled: the
# build/apply-review-findings steps (routed to implementation_target) stamp
# the workflow root's gc.build.implementor_session with their OWN claimed
# step bead's resolved session handle every time either one runs. $ROOT_ID is
# already resolved above; do not guess it or re-derive it here.
#
# gc.build.implementor_session is a DEDICATED write-once-per-run key, unlike
# gc.session_name on the same root bead: gc.session_name is re-stamped by
# EVERY session_affinity=require step that touches the root (every review
# lane, the synthesizer, the publisher itself too), so reading it here used
# to resolve to whichever role last ran against the root — never reliably the
# implementor (review fk-hbsmk BLOCKING-1: confirmed live, this convoy's own
# root flipped between a code-reviewer and a gap-analyst session seconds
# apart, never the implementor — and being wrong-but-non-empty, it silently
# passed the old empty-value fallback guard below).
#
# The value build/apply-review-findings stamp here is the session's
# rig-scoped `name`/`alias` handle, resolved live via `cv_session_route_handle`
# (falling back to the bare gc.session_name only when the session can't be
# resolved live) — that rig-scoped form is the only one confirmed to resolve
# for `implementor_alive`, `gc sling`, AND `gc mail send` all at once (review
# fk-pbadx BLOCKING-1: a bare gc.session_name resolves for
# `implementor_alive`/`gc mail send` but `gc sling` rejects it live — it only
# accepts a rig-scoped "<rig>/<agent>" handle). Do NOT hand-build a
# "<rig>/<session_name>" concatenation here or elsewhere — that string matches
# none of `implementor_alive`'s checked fields and always resolves DEAD; only
# `cv_session_route_handle`'s live-resolved name/alias is safe to use.
IMPLEMENTOR=""
{
  CV_TOPLEVEL="${GC_RIG_ROOT:-}"
  if [ -z "$CV_TOPLEVEL" ] || [ ! -f "${CV_TOPLEVEL}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh" ]; then
    CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
  fi
  CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
  [ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
  CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
  [ -f "$CV_LIB" ] || CV_LIB=""
  if [ -n "$CV_LIB" ]; then
    IMPLEMENTOR="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.implementor_session)"
  fi
}
if [ -z "$IMPLEMENTOR" ]; then
  echo "con-voyage publish: WARNING: could not resolve implementor_session from workflow root ${ROOT_ID}'s gc.build.implementor_session metadata — finalize record will have an empty implementor_session; the release mail and pr-watch's implementor-first feedback routing will fall back to the generic pool for this PR (fk-krsvc)" >&2
fi

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
#    root_bead_id=$ROOT_ID (fk-bkz94) lets con-voyage-finalize tear down the
#    graph.v2 workflow root this PR's con-voyage ran under on PR land, not
#    just this bookkeeping work bead/convoy — without it, the workflow root
#    (and its review loop) stays in_progress forever after a merge/close.
#
#    Resolve the state dir's default by calling con-voyage-lib.sh's
#    cv_default_state_dir() (fk-mr07) instead of hand-copying its
#    GC_RIG_ROOT / .beads-walkup / GC_CITY-fallback algorithm inline: GC_CITY
#    is the multi-rig CITY root, not any one rig's own root, so defaulting to
#    it here previously landed a finalize record at the city level while the
#    monitor scanned the rig level — confirmed live, PR #59's record sat
#    orphaned there until moved by hand. This is the same fenced ```bash block
#    as the IMPLEMENTOR resolution above (not a separate script invocation),
#    so $CV_LIB is already resolved and still in scope — reuse it rather than
#    re-deriving CV_TOPLEVEL/CV_PACK_ROOT/CV_LIB a second time in one script.
if [ -z "${CV_STATE_DIR:-}" ]; then
  if [ -n "${CV_LIB:-}" ]; then
    CV_STATE_DIR="$(source "$CV_LIB" && cv_default_state_dir)"
  fi
  [ -n "${CV_STATE_DIR:-}" ] || CV_STATE_DIR="${GC_CITY:-.}/.gc/cv-pr-watch"
fi
mkdir -p "$CV_STATE_DIR"
owner="${REPO_FULL%%/*}"; repo="${REPO_FULL##*/}"
finalize_key="cv-finalize-${owner}-${repo}-${PR_NUMBER}"

# 3. fk-pubvq: record the roster this run approved, the head SHA it actually
#    reviewed, and round 1 (this publish step's own aggregated comment, just
#    posted above) — so con-voyage-rereview-watch.sh can detect a LATER
#    code-changing push to this PR (a human-feedback or ci-repair bead) and
#    re-run the SAME roster against it after this workflow root has closed.
#    ROSTER_VARS is flattened from $ROOT_ID's own gc.graphv2_vars.v1
#    metadata (already stamped there at sling/cook time) rather than
#    re-threading every enable_*/code_lens var through this file
#    individually — it is the one place that metadata already lives intact.
ROSTER_VARS=""
if [ -n "${CV_LIB:-}" ]; then
  ROSTER_VARS="$(source "$CV_LIB" && cv_flatten_roster_vars "$ROOT_ID")"
fi
if [ -z "${ROSTER_VARS// /}" ]; then
  echo "con-voyage publish: WARNING: could not flatten roster vars from ${ROOT_ID}'s gc.graphv2_vars.v1 — a later re-review round (fk-pubvq) will fall back to re-deriving them from the same metadata directly" >&2
fi
PUBLISHED_HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"

# fk-bcyt7v: last_reviewed_head_sha must record the head the review loop
# actually approved, not whatever happens to be at HEAD when publish runs.
# apply-review-findings stamps gc.build.reviewed_head_sha on $ROOT_ID at the
# exact moment it sets code_review.verdict=done (a genuine no-op pass — see
# "Setting code_review.verdict" in main.apply-review-findings.md), so that
# value IS the reviewed SHA. A commit pushed onto the branch between that
# approval and this publish run (e.g. a mayor send-back fix, fk-cszzzt) would
# otherwise get recorded as "reviewed" here, so con-voyage-rereview-watch
# would never fire on it. An empty value is ambiguous: a legacy pre-fk-bcyt7v
# root never wrote either key, but a post-fix root whose stamp write failed
# also leaves gc.build.reviewed_head_sha empty — and silently falling back on
# the latter reproduces the exact bug fk-bcyt7v fixed. apply-review-findings
# now also stamps gc.build.reviewed_head_sha_attempted=true unconditionally on
# every genuine no-op pass, BEFORE attempting the real stamp, so that marker
# distinguishes "this root's pack version tried and failed" from "this root
# never ran that code at all" (#174 regrade follow-up, fk-j29mzp).
REVIEWED_HEAD_SHA=""
REVIEWED_HEAD_SHA_ATTEMPTED=""
if [ -n "${CV_LIB:-}" ]; then
  REVIEWED_HEAD_SHA="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.reviewed_head_sha)"
  REVIEWED_HEAD_SHA_ATTEMPTED="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.reviewed_head_sha_attempted)"
fi
REVIEWED_HEAD_STAMP_FAILED="false"
if [ -z "$REVIEWED_HEAD_SHA" ]; then
  if [ "$REVIEWED_HEAD_SHA_ATTEMPTED" = "true" ]; then
    # fk-j29mzp BLOCKING-2 (synthesis review): by this point in the script the
    # PR is already open and the work bead already flipped to
    # cv=awaiting_merge — an `exit 1` here, before the finalize record below is
    # written, would leave both live with no .finalize record anywhere, so
    # con-voyage-finalize has no way to ever discover and tear down this
    # workflow root. Give this abort the same explicit failure contract as the
    # sibling hard-fail in "Verify the review was actually approved" above
    # (mail the mayor, stamp gc.build.publish_status=failed) instead of a bare
    # exit, and still fall through to write the finalize record below so the
    # already-live PR/work bead stay discoverable and recoverable by a human
    # or the finalize monitor.
    echo "con-voyage publish: FATAL: gc.build.reviewed_head_sha_attempted=true on workflow root ${ROOT_ID} but gc.build.reviewed_head_sha is missing — the stamp write failed on a post-fix root; refusing to silently record publish-time HEAD (${PUBLISHED_HEAD_SHA}) as reviewed (fk-bcyt7v follow-up, fk-j29mzp)" >&2
    gc mail send mayor \
      -s "con-voyage publish: reviewed-head stamp missing for PR ${PR_URL}" \
      -m "workflow root ${ROOT_ID}: gc.build.reviewed_head_sha_attempted=true but gc.build.reviewed_head_sha is missing. PR ${PR_URL} is already open and work bead ${WORK_BEAD} is already cv=awaiting_merge — this publish step did NOT verify ${PUBLISHED_HEAD_SHA} was actually reviewed before recording it. A human should confirm the pushed commit was reviewed before landing." \
      2>&1 || echo "note: escalation mail failed too (continuing)" >&2
    gc bd update "$ROOT_ID" \
      --set-metadata 'gc.build.publish_status=failed' \
      --set-metadata 'gc.build.publish_reason=reviewed_head_stamp_missing' \
      || echo "con-voyage publish: WARNING: could not stamp gc.build.publish_status=failed on workflow root ${ROOT_ID}" >&2
    REVIEWED_HEAD_STAMP_FAILED="true"
  else
    echo "con-voyage publish: WARNING: no gc.build.reviewed_head_sha on workflow root ${ROOT_ID} (legacy pre-fix root, never attempted a stamp) — falling back to current HEAD (${PUBLISHED_HEAD_SHA}) for last_reviewed_head_sha, which may be a later unreviewed commit (fk-bcyt7v)" >&2
  fi
  REVIEWED_HEAD_SHA="$PUBLISHED_HEAD_SHA"
fi

{
  printf 'work_bead=%s\n' "$WORK_BEAD"
  printf 'convoy_id=%s\n' "$CONVOY_ID"
  printf 'repo_full=%s\n' "$REPO_FULL"
  printf 'pr_number=%s\n' "$PR_NUMBER"
  printf 'pr_author=%s\n' "$PR_AUTHOR"
  printf 'implementor_session=%s\n' "$IMPLEMENTOR"
  printf 'last_phase=%s\n' "awaiting_merge"
  printf 'root_bead_id=%s\n' "$ROOT_ID"
  printf 'roster_vars=%s\n' "$ROSTER_VARS"
  printf 'last_reviewed_head_sha=%s\n' "$REVIEWED_HEAD_SHA"
  printf 'review_round=%s\n' "1"
  printf 'rereview_root_bead_id=%s\n' ""
} > "${CV_STATE_DIR}/${finalize_key}.finalize"
echo "con-voyage publish: armed finalize monitor for ${REPO_FULL}#${PR_NUMBER} -> work bead ${WORK_BEAD}"

if [ "$REVIEWED_HEAD_STAMP_FAILED" = "true" ]; then
  echo "con-voyage publish: finalize record written despite the reviewed-head stamp failure above — close this step with gc.outcome=fail and gc.failure_class=reviewed_head_stamp_missing instead of the normal success path" >&2
  exit 1
fi
```

If `$REVIEWED_HEAD_STAMP_FAILED` was `true` above (printed to stderr, mailed to
the mayor, and `gc.build.publish_status=failed` already stamped on the
workflow root): close THIS publish bead with `gc.outcome=fail` and
`gc.failure_class=reviewed_head_stamp_missing` — do NOT close with the normal
success metadata below. The PR and work bead are already live and the
finalize record is already armed, so this is a flagged-for-human-review
failure, not an orphaned workflow root.

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

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
