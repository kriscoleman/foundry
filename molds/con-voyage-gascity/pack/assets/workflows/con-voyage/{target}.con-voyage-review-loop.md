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

Re-run mechanics: before each cycle, reopen the completed review bead with
gc bd reopen <review-bead>, then re-run. Do not create new review beads per cycle.

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
