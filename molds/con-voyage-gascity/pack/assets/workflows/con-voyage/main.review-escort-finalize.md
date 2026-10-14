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
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""

# review fk-eruo3s LOW-4: this push-safety check had no wall-clock bound — a
# hung remote read would stall finalize (and the one-time comment post below)
# indefinitely instead of failing safe.
if [ -n "$CV_LIB" ]; then
  LS_REMOTE_OUT="$(source "$CV_LIB" && cv_with_timeout 30 git ls-remote origin "refs/pull/${PR_NUMBER}/head" 2>/dev/null)"
else
  LS_REMOTE_OUT="$(git ls-remote origin "refs/pull/${PR_NUMBER}/head" 2>/dev/null)"
fi
REMOTE_HEAD_SHA="$(printf '%s' "$LS_REMOTE_OUT" | cut -f1)"
PR_MOVED="false"
if [ -n "$PR_HEAD_SHA_SEEDED" ] && [ -n "$REMOTE_HEAD_SHA" ] && [ "$PR_HEAD_SHA_SEEDED" != "$REMOTE_HEAD_SHA" ]; then
  PR_MOVED="true"
  echo "con-voyage review-escort-finalize: PR ${REPO_FULL}#${PR_NUMBER} head moved from ${PR_HEAD_SHA_SEEDED} (reviewed) to ${REMOTE_HEAD_SHA} (current) during this review — this is a new commit arriving mid-review, not anything this formula did; the posted comment and mayor mail will say which SHA was actually reviewed" >&2
fi
```

## Resolve the build dir and build the JSON manifest (review fk-hbsmk BLOCKING-3/4)

Same manifest shape as main.publish.md's own aggregated comment (round is
always `1` — this formula has no `.finalize` record to carry a round
counter across invocations, and each fresh dispatch is its own independent
workflow root, so the dedup marker
`<!-- con-voyage-review:<root_bead_id> round=1 -->` stays unique per run
regardless). `lanes[]`/`overall_line` are derived programmatically from each
lane `.md`'s own front matter (`verdict`/`blocking_count`/`low_count`) and
`review-synthesis.md`'s front matter — never a hand-written placeholder:

```bash
CV_RIG_ROOT="${GC_RIG_ROOT:-}"
[ -n "$CV_RIG_ROOT" ] || CV_RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"
[ -n "$CV_RIG_ROOT" ] || CV_RIG_ROOT="${GC_CITY:-.}"
CV_BUILD_DIR="${CV_RIG_ROOT}/.gc/build/${ROOT_ID}"
CV_RIG_NAME="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.rig_name)"

MANIFEST_PATH="$(
  CV_BUILD_DIR="$CV_BUILD_DIR" ROOT_ID="$ROOT_ID" CV_RIG_NAME="$CV_RIG_NAME" \
  PR_MOVED="$PR_MOVED" PR_HEAD_SHA_SEEDED="$PR_HEAD_SHA_SEEDED" REMOTE_HEAD_SHA="$REMOTE_HEAD_SHA" \
  python3 - <<'PYEOF'
import json, os, re, glob

build_dir = os.environ["CV_BUILD_DIR"]
root_id = os.environ["ROOT_ID"]
rig = os.environ.get("CV_RIG_NAME") or "unknown-rig"
pr_moved = os.environ.get("PR_MOVED", "false") == "true"
pr_head_seeded = os.environ.get("PR_HEAD_SHA_SEEDED", "")
remote_head = os.environ.get("REMOTE_HEAD_SHA", "")

def front_matter(path):
    with open(path) as f:
        text = f.read()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    meta = {}
    if m:
        for line in m.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
    return meta

synthesis_path = os.path.join(build_dir, "review-synthesis.md")
synth_meta = front_matter(synthesis_path)
blocking = int(synth_meta.get("blocking_count", "0") or "0")
low = int(synth_meta.get("low_count", "0") or "0")

lanes = []
for path in sorted(glob.glob(os.path.join(build_dir, "*-review.md"))):
    if os.path.basename(path) == "review-synthesis.md":
        continue
    meta = front_matter(path)
    lanes.append({
        "agent": meta.get("reviewer", "unknown"),
        "lens": meta.get("lane", os.path.basename(path)[:-3]),
        "verdict": meta.get("verdict", "unknown"),
        "findings": int(meta.get("blocking_count", "0") or "0") + int(meta.get("low_count", "0") or "0"),
        "body_file": path,
    })

overall_line = "{}: {} lane(s), {} blocking, {} low.".format(
    "Approved" if blocking == 0 else "Changes requested", len(lanes), blocking, low,
)

manifest = {
    "rig": rig,
    "root_bead_id": root_id,
    "round": 1,
    "overall_line": overall_line,
    "lanes": lanes,
    "synthesis": {
        "agent": synth_meta.get("reviewer", "gc.review-synthesizer"),
        "lens": "synthesis",
        "verdict": synth_meta.get("verdict", "unknown"),
        "findings": low,
        "body_file": synthesis_path,
    },
}
if pr_moved:
    manifest["extra_line"] = "Reviewed commit {}; PR has since advanced to {}.".format(
        pr_head_seeded, remote_head,
    )

out_path = os.path.join(build_dir, "review-escort-manifest.json")
with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2)
print(out_path)
PYEOF
)"
OVERALL_LINE="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['overall_line'])" "$MANIFEST_PATH" 2>/dev/null)"
[ -n "$OVERALL_LINE" ] || OVERALL_LINE="unknown verdict (manifest build failed — see .gc/build/${ROOT_ID}/)"
```

## Post the round's ONE aggregated review comment (review fk-hbsmk BLOCKING-7)

`[template.check] max_attempts = 3` on this node means a `build-artifact-valid.sh`
failure re-dispatches this SAME claimed bead. Gate the post on a
`gc.review_escort.comment_posted` flag on `$CLAIMED_BEAD_ID` via
`cv_claim_once` so a retry never posts a second comment for one round:

```bash
COMMENT_CLAIM="$(source "$CV_LIB" && cv_claim_once "$CLAIMED_BEAD_ID" "gc.review_escort.comment_posted")"
if [ "$COMMENT_CLAIM" = "skip" ]; then
  echo "con-voyage review-escort-finalize: aggregated comment already posted on a prior attempt of ${CLAIMED_BEAD_ID} — skipping duplicate post" >&2
else
  if [ "$COMMENT_CLAIM" = "claim-unpersisted" ]; then
    # review fk-eruo3s BLOCKING-1: the claim flag failed to persist after
    # cv_claim_once's own retries — still post this round's comment (never
    # drop the only human-visible verdict), but escalate so the mayor knows a
    # max_attempts retry of this SAME bead could re-post a duplicate comment,
    # since the flag it would check next time never stuck.
    gc mail send mayor \
      -s "con-voyage review-escort: comment_posted flag failed to persist for ${REPO_FULL}#${PR_NUMBER}" \
      -m "cv_claim_once could not persist gc.review_escort.comment_posted=true on ${CLAIMED_BEAD_ID} after its own retries. The aggregated comment is being posted this pass, but a later max_attempts retry of this same bead may re-post a duplicate — please check ${REPO_FULL}#${PR_NUMBER} for a repeated comment if this bead is re-dispatched." \
      2>&1 || echo "note: escalation mail failed too (continuing)" >&2
  fi
  CV_PACK_ROOT_BIN="$CV_PACK_ROOT"
  [ -f "${CV_PACK_ROOT_BIN}/assets/scripts/cv-pr-comment.sh" ] || CV_PACK_ROOT_BIN="${GC_CITY:-.}/packs/con-voyage"
  CV_BIN="${CV_PACK_ROOT_BIN}/assets/scripts/cv-pr-comment.sh"
  [ -f "$CV_BIN" ] && [ -x "$CV_BIN" ] || CV_BIN=""
  if [ -n "${CV_BIN:-}" ]; then
    if ! CV_AGGREGATE_OUT="$("$CV_BIN" comment-aggregate "$PR_NUMBER" --repo "$REPO_FULL" \
      --manifest "$MANIFEST_PATH" \
      --city-root "${GC_CITY:-.}" \
      --formula con-voyage-review-escort --agent "${CV_RIG_NAME:-unknown-rig}/gc.run-operator" 2>&1)"; then
      echo "con-voyage review-escort-finalize: comment-aggregate failed: ${CV_AGGREGATE_OUT}" >&2
      gc mail send mayor \
        -s "con-voyage review-escort: aggregated comment failed for ${REPO_FULL}#${PR_NUMBER}" \
        -m "cv-pr-comment.sh comment-aggregate failed: ${CV_AGGREGATE_OUT}" \
        2>&1 || echo "note: escalation mail failed too (continuing)" >&2
    fi
  else
    echo "cv-pr-comment.sh not found — skipping the aggregated review comment" >&2
  fi
fi
```

A failure here must never fail this step — log it, escalate to the mayor,
and continue to the verdict mail below.

## Report the verdict to the mayor (review fk-hbsmk BLOCKING-4)

Mail the mayor REGARDLESS of verdict (LOW-only and BLOCKING results are both
surfaced here, never silently dropped — this formula has no publish step to
fall back on if this mail doesn't go out), using the `$OVERALL_LINE` derived
from the manifest above:

```bash
gc mail send mayor \
  -s "REVIEW-ESCORT COMPLETE: ${REPO_FULL}#${PR_NUMBER}" \
  -m "con-voyage review-only escort finished for ${REPO_FULL}#${PR_NUMBER} (commit ${PR_HEAD_SHA_SEEDED}${PR_MOVED:+, PR has since advanced to ${REMOTE_HEAD_SHA}}): ${OVERALL_LINE}. No commit, rebase, or push was made — this formula is review-only." \
  || echo "note: mayor mail failed (continuing)" >&2
```

## Write the build artifact and clean up the worktree (review fk-hbsmk BLOCKING-2/5)

Write a `gc.build.review.v1` artifact recording the repo/PR, the exact
commit reviewed, whether the PR head moved, the verdict, and the posted
comment round, then remove the read-only worktree the seed step attached —
it is never cleaned up otherwise, and this formula is dispatched repeatedly,
so every run would otherwise leave one more permanent worktree directory on
disk:

```bash
REVIEW_REPORT_PATH="${CV_BUILD_DIR}/review-escort-report.md"
cat > "$REVIEW_REPORT_PATH" <<REPORT
---
schema: gc.build.review.v1
root_bead_id: ${ROOT_ID}
repo: ${REPO_FULL}
pr: ${PR_NUMBER}
reviewed_commit: ${PR_HEAD_SHA_SEEDED}
remote_head_at_finalize: ${REMOTE_HEAD_SHA}
pr_moved: ${PR_MOVED}
comment_round: 1
---

# Con-voyage review-only escort — ${REPO_FULL}#${PR_NUMBER}

${OVERALL_LINE}

See \`${CV_BUILD_DIR}/review-synthesis.md\` and \`${MANIFEST_PATH}\` for the
full per-lane breakdown.
REPORT

gc bd update "$ROOT_ID" --set-metadata "gc.build.review_report_path=${REVIEW_REPORT_PATH}" \
  || echo "con-voyage review-escort-finalize: WARNING: could not stamp gc.build.review_report_path on ${ROOT_ID}" >&2

if [ -n "${WORKTREE:-}" ]; then
  if git worktree remove --force "$WORKTREE" 2>/dev/null; then
    echo "con-voyage review-escort-finalize: removed read-only worktree ${WORKTREE}"
  else
    echo "con-voyage review-escort-finalize: git worktree remove failed for ${WORKTREE} — falling back to rm -rf + prune" >&2
    rm -rf "$WORKTREE"
    git worktree prune 2>/dev/null || true
  fi
else
  echo "con-voyage review-escort-finalize: WARNING: no worktree path resolved on ${ROOT_ID} — nothing to clean up" >&2
fi
```

## Close — never merge, never publish

```bash
bd update "$CLAIMED_BEAD_ID" \
  --set-metadata 'gc.outcome=pass' \
  --set-metadata "gc.build.review_report_path=${REVIEW_REPORT_PATH}"
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
