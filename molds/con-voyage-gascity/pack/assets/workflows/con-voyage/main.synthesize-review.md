Synthesize the con-voyage review.

## Fail fast if the workflow root is already closed (fk-jg6rm)

graph.v2 can mint a fresh synthesize-review bead even after this workflow's
root has already been closed (confirmed live, root fk-viqoe 2026-10-03 —
closing a root does not, by itself, stop the engine from dispatching more
steps under it). Synthesizing a review of a workflow nobody is waiting on
anymore just manufactures more work for apply-review-findings to iterate on.
Check the root's own status before reading any lane reports:

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
ROOT_ID="${GC_ROOT_BEAD_ID:-$GC_BEAD_ID}"
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
ROOT_BEAD_STATUS=""
if [ -n "$CV_LIB" ]; then
  IFS=$'\x1f' read -r ROOT_BEAD_STATUS _ <<< "$(source "$CV_LIB" && bead_status "$ROOT_ID" id)"
fi
if [ "$ROOT_BEAD_STATUS" = "closed" ]; then
  echo "synthesize-review: workflow root ${ROOT_ID} is already closed — abandoning this step and any pending descendants, minting nothing" >&2
  if [ -n "$CV_LIB" ]; then
    source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "workflow root already closed before synthesize-review ran; aborting, minting nothing"
  fi
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=skipped' \
    --set-metadata 'gc.skip_reason=workflow root already closed'
  bd close "$CLAIMED_BEAD_ID" --reason 'Skipped: workflow root already closed, nothing to synthesize.'
  exit 0
fi
```

An empty `$ROOT_BEAD_STATUS` is "unknown", not "confirmed open" — fall
through rather than guessing. If this block closes this bead, STOP.

Read all active review lane reports. Deduplicate findings, preserve the source
review lane for each finding, and classify each item as required fix (BLOCKING),
low-priority concern (LOW), or approved.

Never downgrade a lane's own BLOCKING classification to LOW — not on
"intentional per plan" grounds, not because the finding looks small, not
because you'd have called it LOW yourself. A lane's BLOCKING is authoritative;
synthesis consolidates and deduplicates, it does not re-grade.

Write one consolidated review synthesis under the build artifact root. The
synthesis must be concrete enough for the fix lane to act without another
planning pass. Structure it as:

1. Overall verdict: approve or iterate
2. BLOCKING findings (must fix before landing): one `### ` sub-heading per
   finding (any consistent per-finding title works, e.g. `BLOCKING-<n>`), each
   listing lane, file:line, fix. Write literal `None.` when there are zero.
3. LOW findings (surface to human for decision): one `### ` sub-heading per
   finding, each listing lane, file:line, fix. Write literal `None.` when
   there are zero.
4. Lanes approved with no findings

`cv-synthesis-low-mail.sh` (below) counts each section's findings by its
number of `### ` sub-headings — every finding must get its own `### `
heading (never a bare bullet list folded into one paragraph) so template and
script agree on the count by construction (fk-8g9ue BLOCKING-1: an earlier
version of the script matched only the literal `### BLOCKING-<n>` shape and
silently counted 0 on real documents that used a different per-finding
heading style).

When any BLOCKING finding exists from any lane, the verdict is iterate.
When no BLOCKING findings exist but LOWs remain, stop and surface them to the
human facilitator. Never silently accept LOWs — see "Mail the human on a
LOW-only verdict" below: surfacing means actually sending that mail, not just
writing that you would.

You must not downgrade a lane's BLOCKING finding to LOW on "intentional per plan" grounds (fk-qbdta) — a lane that already applied the severity rubric (an unenforced precondition with a local fix, a vacuous acceptance criterion, or an unstacked dependency on an unmerged slice) made that call deliberately; "the plan says this lands later" is exactly the rationale the rubric already rejects, not a reason to re-grade it here. Carry every lane's BLOCKING verdict through unchanged; only a lane itself, re-reviewing with new information, may change its own finding's severity.

## Mail the human on a LOW-only verdict (fk-8g9ue)

apply-review-findings only ever branches on BLOCKING, so nothing else in the
loop notifies anyone before publish. If this step does not actually send mail
on a LOW-only verdict, nobody is ever told — no matter what this synthesis's
own text claims. Run this right after writing the synthesis file, before
closing this step:

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
ROOT_ID="${GC_ROOT_BEAD_ID:-$GC_BEAD_ID}"
CONVOY_ID="$(gc bd show "$ROOT_ID" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
print((d.get('metadata') or {}).get('gc.build.source_anchor_id') or '')
" 2>/dev/null)"
[ -n "$CONVOY_ID" ] || { echo "con-voyage synthesis: no gc.build.source_anchor_id on root ${ROOT_ID} — cannot resolve the work bead for the LOW-only mail" >&2; exit 1; }

CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
esac
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
WORK_BEAD="$(source "$CV_LIB" && cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" cv_resolve_work_bead "$CONVOY_ID")"

CV_MAIL_BIN="${CV_PACK_ROOT}/assets/scripts/cv-synthesis-low-mail.sh"
CV_LENS_ESCALATE_TARGET="{cv_lens_escalate_target}" "$CV_MAIL_BIN" \
  "<synthesis path just written above>" "$ROOT_ID" "$WORK_BEAD" "con-voyage/${CONVOY_ID}"
```

This is a no-op (exits 0, sends nothing) when any BLOCKING finding is present
or when both counts are zero — those cases need no human mail. On a genuine
LOW-only verdict it sends the mail (to the mayor, who owns the human
conversation, and to the configured escalation target when that resolves to
a distinct real mailbox) and records `code_review.low_mail_sent=true` plus
`code_review.low_mail_id` on the root bead, so the gate and publish can
verify a mail actually went out. A failed send is a hard failure of this
script (non-zero exit) — never treat it as best-effort and close anyway.

Close with gc.outcome=pass, code_review.synthesis_path=<synthesis path>, and
code_review.output_path=<synthesis path>.

This synthesis is the source content the facilitator later posts to the PR as
a reviewer-verdict comment. Do not post anything to GitHub from this step
yourself — but write the synthesis knowing any downstream consumer that posts
it to the PR MUST do so via `cv-pr-comment.sh`, never a raw `gh pr comment` /
`gh pr review`, so the machine-identity banner always leads the posted text.

Do not invoke provider-native subagents. Synthesis happens in this Gas City fan-in lane.

## Sweep per-lane review worktrees (fk-q659)

Floor lanes that execute against the implementation (acceptance, test-evidence,
simplicity) and any other lane that ran build/test/lint commands did so inside their
own private worktree acquired via `cv-review-lane-worktree.sh acquire`, never the
shared source-anchor work_dir — see the per-lane worktree isolation note in each
lane's own instructions. After writing the synthesis, sweep this cycle's per-lane
copies so they do not accumulate across review rounds:

```bash
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/cv-review-lane-worktree.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LANE_WT_BIN="${CV_PACK_ROOT}/assets/scripts/cv-review-lane-worktree.sh"
[ -f "$CV_LANE_WT_BIN" ] || CV_LANE_WT_BIN=""
if [ -n "$CV_LANE_WT_BIN" ]; then
  bash "$CV_LANE_WT_BIN" sweep "<source anchor work_dir from the review context>" \
    || echo "note: per-lane worktree sweep failed (continuing)"
else
  echo "note: cv-review-lane-worktree.sh not found — skipping per-lane worktree sweep (continuing)"
fi
```

This is hygiene, not correctness — a sweep failure must never block synthesis from
closing. If the review loop re-runs lanes for another cycle, each lane re-acquires a
fresh copy at the new HEAD commit.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
