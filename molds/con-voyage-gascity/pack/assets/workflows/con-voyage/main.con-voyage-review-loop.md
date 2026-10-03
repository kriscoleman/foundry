Run the con-voyage review loop.

The child beads are the active review lanes for this sling: acceptance,
test-evidence, simplicity (floor, always), security and code (floor, always),
plus any roster persona lanes enabled for this run. These fan out in parallel,
then fan in through synthesis and fix application.

The apply-review-findings lane owns code_review.verdict=done|iterate and
code_review.report_path=<review summary path>. The implementation-review-approved
check repeats this loop until the latest verdict is done.

Loop rules (authoritative at the finding level, not the verdict level):
- Any BLOCKING finding from any reviewer: consolidate ALL findings from every
  reviewer into one mail to the implementor, wait for FIXES PUSHED, then
  re-run ALL active review lanes against the new diff.
- Zero findings from every reviewer: proceed to the finalize step.
- No BLOCKING, LOWs only: stop and surface the findings to the human. They decide
  proceed or send back. Do not decide this yourself.

## Fail fast if the workflow root is already closed, or setup did not pass (fk-jg6rm)

A `needs` edge in graph.v2 is satisfied once setup-con-voyage-review is
CLOSED, regardless of its outcome (same reasoning as the build/setup guards
above it in this workflow) — a setup step that skipped because build never
passed does not, by itself, stop this controller from being routed and
claimed, and fanning out review lanes anyway. Separately, graph.v2 can mint
a fresh review-loop bead even after this workflow's root has already been
closed (confirmed live, root fk-viqoe 2026-10-03: the mayor's abandon at
00:46Z still let a fresh iteration get minted and claimed afterward). Check
both before doing anything else — no fan-out, no synthesis, no lane
dispatch:

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
  echo "con-voyage review loop: workflow root ${ROOT_ID} is already closed — abandoning this step and any pending descendants, minting nothing" >&2
  if [ -n "$CV_LIB" ]; then
    source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "workflow root already closed before the review loop ran; aborting, minting nothing"
  fi
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=skipped' \
    --set-metadata 'gc.skip_reason=workflow root already closed'
  bd close "$CLAIMED_BEAD_ID" --reason 'Skipped: workflow root already closed, nothing to review.'
  exit 0
fi

SETUP_OUTCOME=""
if [ -n "$CV_LIB" ]; then
  SETUP_OUTCOME="$(source "$CV_LIB" && cv_dependency_outcome "$GC_BEAD_ID" "Prepare con-voyage review context")"
fi
if [ -n "$SETUP_OUTCOME" ] && [ "$SETUP_OUTCOME" != "pass" ]; then
  echo "con-voyage review loop: setup-con-voyage-review outcome=${SETUP_OUTCOME} — nothing to review, abandoning the workflow instead of fanning out review lanes" >&2
  if [ -n "$CV_LIB" ]; then
    source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "setup-con-voyage-review outcome=${SETUP_OUTCOME}; no review lanes dispatched"
  fi
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=skipped' \
    --set-metadata "gc.skip_reason=setup outcome=${SETUP_OUTCOME}, nothing to review"
  bd close "$CLAIMED_BEAD_ID" --reason 'Skipped: setup did not pass, no review lanes dispatched.'
  exit 0
fi
```

Empty values above (lib not found, or the dependency not resolvable by
title) are "unknown" — fall through to the normal loop rather than guessing.
If either block above closes this bead, STOP — do not continue to any later
section in this file, including the first fan-out.

## Gate lane reopen on apply-review-findings landing a fix (fk-itiq6)

CONFIRMED LIVE (fk-lhjn3 iteration 5, 2026-09-29): the next cycle's lane
re-reviews ran and wrote reports 13-17 minutes after synthesis flagged a
BLOCKING finding, while this cycle's own apply-review-findings bead did not
even get claimed until ~4 hours later — 7 review lanes burned a full pass
reviewing a commit nobody had touched yet. Nothing mechanically checked that
apply-review-findings had actually landed a fix before lanes were reopened;
it was entirely on agent discretion.

Before reopening any lane bead for the next cycle, poll for this cycle's
sibling `apply-review-findings` bead and require it to be closed with
`gc.outcome=pass` and either a `code_review.fix_commit` or
`code_review.verdict=done`. Never reopen lanes while that bead is still
open/unclaimed. If it closes any other way (abandoned, `gc.outcome=fail`,
force-closed) that is a terminal failure, not "still working" — stop and
escalate distinctly instead of polling forever. If it has not closed within
`{cv_lens_claim_seconds}` seconds, escalate to `{cv_lens_escalate_target}`
and keep waiting rather than reopening speculatively, re-escalating on the
same interval for as long as the wait continues:

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
ROOT_ID="${GC_ROOT_BEAD_ID:-$GC_BEAD_ID}"
THIS_JSON="$(gc bd show "$GC_BEAD_ID" --json 2>/dev/null)"
THIS_STEP_ID="$(printf '%s' "$THIS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
print((d.get('metadata') or {}).get('gc.step_id') or '')
" 2>/dev/null)"
THIS_ATTEMPT="$(printf '%s' "$THIS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
print((d.get('metadata') or {}).get('gc.attempt') or '0')
" 2>/dev/null)"
APPLY_STEP_ID="${THIS_STEP_ID%.con-voyage-review-loop}.apply-review-findings"

CV_LENS_GATE_TIMEOUT_SECONDS="{cv_lens_claim_seconds}"
case "$CV_LENS_GATE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_GATE_TIMEOUT_SECONDS="300" ;;
esac
CV_LENS_ESCALATE_TARGET="{cv_lens_escalate_target}"

gate_start=$(date +%s)
last_mailed_elapsed=-1
while :; do
  MATCH_JSON="$(bd list --all --metadata-field "gc.root_bead_id=${ROOT_ID}" --json --limit=0 2>/dev/null || printf '[]')"
  read -r apply_status apply_outcome apply_fix_commit apply_verdict <<< "$(printf '%s' "$MATCH_JSON" | python3 -c "
import json, sys
attempt = '$THIS_ATTEMPT'
step = '$APPLY_STEP_ID'
data = json.load(sys.stdin)
best = None
for b in data:
    meta = b.get('metadata') or {}
    # Every graph.v2 step spawns a paired gc.kind=scope-check 'Finalize
    # scope for ...' latch bead carrying the SAME gc.step_id/gc.attempt as
    # the real work bead — skip it, or bd list's created_at-DESC ordering
    # can make it win the 'last match wins' selection below (fk-itiq6
    # review, BLOCKING-1: reproduced live on fk-gfedd iteration 1 and
    # fk-lhjn3 iteration 6, where picking the scope-check bead deadlocks
    # the gate forever since it never carries code_review.verdict/fix_commit).
    if meta.get('gc.kind') == 'scope-check':
        continue
    if meta.get('gc.attempt') != attempt or meta.get('gc.step_id') != step:
        continue
    best = b
if best is None:
    print('-', '-', '-', '-')
else:
    meta = best.get('metadata') or {}
    print(best.get('status') or '-', meta.get('gc.outcome') or '-', meta.get('code_review.fix_commit') or '-', meta.get('code_review.verdict') or '-')
" 2>/dev/null)"

  if [ "$apply_status" = "closed" ] && [ "$apply_outcome" = "pass" ] && { [ "$apply_verdict" = "done" ] || [ "$apply_fix_commit" != "-" ]; }; then
    echo "review loop: ${APPLY_STEP_ID} landed (fix_commit=${apply_fix_commit}, verdict=${apply_verdict}) — safe to reopen lanes"
    break
  fi

  # Terminal-failure exit (BLOCKING-2): a closed apply-review-findings bead
  # that did NOT meet the landed-fix condition above (abandoned,
  # gc.outcome=fail, force-closed by a human) is a normal terminal state,
  # not "still working" — without this branch the loop polls forever,
  # indistinguishable from a bead that simply hasn't closed yet.
  if [ "$apply_status" = "closed" ]; then
    echo "review loop: ${APPLY_STEP_ID} closed with outcome=${apply_outcome} (verdict=${apply_verdict}, fix_commit=${apply_fix_commit}) — not a landed fix, cannot safely reopen lanes" >&2
    gc mail send "$CV_LENS_ESCALATE_TARGET" \
      -s "con-voyage review loop: ${APPLY_STEP_ID} closed without a landed fix" \
      -m "${APPLY_STEP_ID} (attempt ${THIS_ATTEMPT}) closed with status=${apply_status} outcome=${apply_outcome} verdict=${apply_verdict} fix_commit=${apply_fix_commit} — this does not satisfy the landed-fix condition (gc.outcome=pass plus verdict=done or a fix_commit), so lanes cannot be safely reopened. This needs a human decision." \
      2>&1 || echo "note: escalation mail failed for ${APPLY_STEP_ID} (continuing)"
    exit 1
  fi

  # Heartbeat (BLOCKING-3): bump this gate step's OWN bead every poll so a
  # stall watchdog scanning for inactive-but-in_progress beads can tell
  # "correctly waiting per the gate" from "actually stalled" — mirrors the
  # touched_at pattern the sibling FIX-F lane-redispatch loop below already
  # uses. Best-effort: a gc/bd hiccup here must never abort the gate.
  gc bd update "$GC_BEAD_ID" --set-metadata "gc.review_gate.touched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true

  # Periodic re-escalation (BLOCKING-3): a single one-shot mail (the old
  # one-shot suppression flag that blocked all further escalation after the
  # first) is indistinguishable from a lost/ignored mail once the wait runs
  # for hours (fk-lhjn3 iteration 5:
  # ~4h wait, well past cv_lens_claim_seconds' default 300s). Re-escalate
  # every CV_LENS_GATE_TIMEOUT_SECONDS instead of only once.
  elapsed=$(( $(date +%s) - gate_start ))
  if [ "$elapsed" -ge "$CV_LENS_GATE_TIMEOUT_SECONDS" ] && [ $(( elapsed - last_mailed_elapsed )) -ge "$CV_LENS_GATE_TIMEOUT_SECONDS" ]; then
    gc mail send "$CV_LENS_ESCALATE_TARGET" \
      -s "con-voyage review loop: ${APPLY_STEP_ID} has not landed a fix after ${elapsed}s" \
      -m "Waiting on ${APPLY_STEP_ID} (attempt ${THIS_ATTEMPT}) to close with gc.outcome=pass and a fix commit or verdict=done before reopening review lanes. Current status=${apply_status} outcome=${apply_outcome}." \
      2>&1 || echo "note: escalation mail failed for ${APPLY_STEP_ID} (continuing to wait)"
    last_mailed_elapsed="$elapsed"
  fi
  sleep 30
done
```

## Abort the cycle if the workflow root was abandoned mid-review (fk-jg6rm)

The gate above can run for hours (fk-lhjn3 iteration 5: ~4h wait). A root
closed out from under this loop partway through that wait — a human or the
mayor abandoning a stalled con-voyage — must stop the NEXT cycle from
minting a fresh round of lane reopens, not just the controller's own first
fan-out. Re-check the root's own status right before reopening any lane:

```bash
ROOT_BEAD_STATUS=""
if [ -n "$CV_LIB" ]; then
  IFS=$'\x1f' read -r ROOT_BEAD_STATUS _ <<< "$(source "$CV_LIB" && bead_status "$ROOT_ID" id)"
fi
if [ "$ROOT_BEAD_STATUS" = "closed" ]; then
  echo "con-voyage review loop: workflow root ${ROOT_ID} was abandoned mid-review — closing this step and any pending descendants instead of reopening lanes for another cycle" >&2
  if [ -n "$CV_LIB" ]; then
    source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "workflow root abandoned mid-review; no further review cycles dispatched"
  fi
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=skipped' \
    --set-metadata 'gc.skip_reason=workflow root abandoned mid-review'
  bd close "$CLAIMED_BEAD_ID" --reason 'Skipped: workflow root was abandoned mid-review, no further cycles dispatched.'
  exit 0
fi
```

Only after BOTH this check and the gate above report it safe should you
reopen the lane beads for the next cycle: reopen the completed review bead
with `gc bd reopen <review-bead>`, then re-run. Do not create new review
beads per cycle.

## Verify review-lane claims and re-dispatch stalled lenses (fk-loo1 FIX-F)

Review lenses are pool-managed and only ever wake on a nudge. On a
slow-startup (large) repo, a pool churn cycle can drain a still-starting lens
roster before it claims its lane bead, leaving that lane open+unassigned
forever with nothing left to re-drive it — the review loop then never fans in
and the implementor waits forever. After EACH fan-out (the initial one and
every re-run after applying findings), verify that every active lane actually
gets claimed, and re-dispatch the ones that do not. This is best-effort — a
gc/bd hiccup must never abort the review — and it never blocks indefinitely on
one stuck lane. On a fast repo where lenses claim on the first nudge, this
loop exits on its first pass and adds no extra churn.

Run this block (or its logical equivalent) right after starting/re-running the
active lanes, before waiting on synthesis:

```bash
# Discover this cycle's active lane beads: dependents of THIS review-loop
# step bead ($GC_BEAD_ID) with dependency_type=tracks and the "Con-voyage: "
# floor/roster-lane title prefix (excludes sibling scope members that are not
# lanes, e.g. "Apply con-voyage review findings" / "Synthesize con-voyage
# review"), skipping any already closed from a prior cycle.
LANE_BEAD_IDS=($(gc bd show "$GC_BEAD_ID" --json --include-dependents 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
for dep in (d.get('dependents') or []):
    if not isinstance(dep, dict) or dep.get('dependency_type') != 'tracks':
        continue
    title = dep.get('title') or ''
    if not title.startswith('Con-voyage: ') or (dep.get('status') or '') == 'closed':
        continue
    print(dep.get('id') or '')
" 2>/dev/null))

CV_LENS_CLAIM_SECONDS="{cv_lens_claim_seconds}"
CV_LENS_MAX_REDISPATCH="{cv_lens_max_redispatch}"
# A malformed override must never silently break the claim-grace/re-dispatch-cap
# checks below (a non-numeric CV_LENS_MAX_REDISPATCH would make `-ge` exit 2 —
# treated as false — so the escalate-and-stop branch would never fire and a
# stuck lane would re-dispatch forever). Coerce both to their documented
# defaults when not a valid non-negative base-10 integer, same pattern as
# CV_STALL_SECONDS/CV_MAX_ATTEMPTS in con-voyage-repair-watchdog.sh.
case "$CV_LENS_CLAIM_SECONDS" in
  *[!0-9]*|'') CV_LENS_CLAIM_SECONDS="300" ;;
esac
case "$CV_LENS_MAX_REDISPATCH" in
  *[!0-9]*|'') CV_LENS_MAX_REDISPATCH="3" ;;
esac
CV_LENS_ESCALATE_TARGET="{cv_lens_escalate_target}"
declare -A CV_LENS_ATTEMPTS
pending=("${LANE_BEAD_IDS[@]}")
start_ts=$(date +%s)

while [ "${#pending[@]}" -gt 0 ]; do
  still_pending=()
  for lane_id in "${pending[@]}"; do
    show_json="$(gc bd show "$lane_id" --json 2>/dev/null)"
    read -r status assignee routed_to <<< "$(printf '%s' "$show_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
meta = d.get('metadata') or {}
print(d.get('status') or '-', d.get('assignee') or '-', meta.get('gc.routed_to') or '-')
" 2>/dev/null)"

    if [ "$status" != "open" ] || [ "$assignee" != "-" ]; then
      continue  # claimed (or closed/unknown) — stop tracking this lane
    fi

    elapsed=$(( $(date +%s) - start_ts ))
    if [ "$elapsed" -lt "$CV_LENS_CLAIM_SECONDS" ]; then
      still_pending+=("$lane_id")
      continue  # still inside the normal claim grace window
    fi

    attempts="${CV_LENS_ATTEMPTS[$lane_id]:-0}"
    if [ "$attempts" -ge "$CV_LENS_MAX_REDISPATCH" ]; then
      gc mail send "$CV_LENS_ESCALATE_TARGET" \
        -s "con-voyage review loop: giving up re-dispatching ${lane_id}" \
        -m "Review lane ${lane_id} (routed_to=${routed_to}) never claimed after ${attempts} re-dispatch attempt(s). Stopping automatic re-dispatch here; the periodic con-voyage-review-watchdog order keeps watching it." \
        2>&1 || echo "note: escalation mail failed for $lane_id (continuing)"
      continue  # stop tracking — never retry past CV_LENS_MAX_REDISPATCH
    fi

    if [ "$routed_to" = "-" ]; then
      gc mail send "$CV_LENS_ESCALATE_TARGET" \
        -s "con-voyage review loop: giving up re-dispatching ${lane_id}" \
        -m "Review lane ${lane_id} has no gc.routed_to metadata; cannot safely re-dispatch. Stopping automatic re-dispatch here; the periodic con-voyage-review-watchdog order keeps watching it." \
        2>&1 || echo "note: escalation mail failed for $lane_id (continuing)"
      continue  # stop tracking — cannot safely re-dispatch without gc.routed_to
    fi

    live_session="$(gc session list --json 2>/dev/null | python3 -c "
import json, sys
route = sys.argv[1]
d = json.load(sys.stdin)
sessions = d.get('sessions') if isinstance(d, dict) else d
for s in (sessions or []):
    if isinstance(s, dict) and s.get('template') == route and (s.get('state') or '') != 'closed':
        print(s.get('id') or ''); break
" "$routed_to" 2>/dev/null)"

    if [ -n "${live_session// /}" ]; then
      # Touch: bumps updated_at, re-firing core nudge-on-route, plus a direct
      # nudge to the live pool session (belt-and-suspenders delivery).
      gc bd update "$lane_id" --set-metadata "gc.review_watchdog.touched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true
      gc session nudge "$live_session" "Review lane $lane_id is ready and unclaimed — please pick it up." \
        || echo "note: nudge failed for $lane_id (continuing)"
    else
      # Pool fully drained — re-route the SAME bead to force a fresh dispatch.
      gc sling "$routed_to" "$lane_id" --nudge \
        || echo "note: re-route failed for $lane_id (continuing)"
    fi
    CV_LENS_ATTEMPTS[$lane_id]=$((attempts + 1))
    still_pending+=("$lane_id")
  done
  pending=("${still_pending[@]}")
  [ "${#pending[@]}" -eq 0 ] || sleep 30
done
```

An escalated lane is left open for a human or the periodic
con-voyage-review-watchdog order; do not retry it further from this loop and
do not let it block the rest of the cycle indefinitely.

## Append a per-cycle summary to the WORK BEAD (work-bead lifecycle)

After each review cycle synthesizes, append a one-line summary to the work bead
so the dashboard shows progress and the description stays current. The work bead
is `$WORK_BEAD` recorded in the review context (resolved from `{convoy_id}` at
setup); re-resolve it the same way if the context does not carry it. Keep the
work bead in the `reviewing` phase for the whole loop — do NOT close it here
(the publish step and the con-voyage-finalize monitor own the later phases and
the close). Each cycle, after synthesis produces the verdict and finding counts:

```bash
# WORK_BEAD is the value recorded at setup (review context `work_bead`). Count
# fields come from this cycle's synthesis. This is a best-effort note — a bd
# hiccup must never break the review loop.
gc bd note "$WORK_BEAD" "review cycle <N>: verdict=<approve|iterate>, BLOCKING=<count>, LOW=<count>" \
  || echo "note: could not append cycle summary to $WORK_BEAD (continuing)"
```

Do not invoke provider-native subagents. Continue only through this Gas City
graph loop.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
