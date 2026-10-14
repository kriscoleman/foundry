Run the con-voyage review-only escort's review pass.

The child beads are the active review lanes for this sling: acceptance,
test-evidence, simplicity (floor, always), security and code (floor,
always), plus any roster persona lanes enabled for this run. These fan out
in parallel, then fan in through synthesis.

**This is a SINGLE pass, not a retry loop.** There is no apply-review-findings
step in this formula and nothing in this workflow ever iterates: whatever
synthesis reports — clean, LOW findings, or BLOCKING findings — is final.
This step's only job is to make sure every lane actually gets reviewed and
synthesis actually runs, then close so the finalize step can report
whatever verdict came out. Do not wait for, create, or reference an
apply-review-findings bead anywhere in this file — none will ever exist for
this formula, and waiting for one would hang forever.

## Fail fast if the workflow root is already closed, or setup did not pass (fk-jg6rm)

Same reasoning as the identical guard in main.con-voyage-review-loop.md: a
`needs` edge in graph.v2 is satisfied once setup-con-voyage-review is
CLOSED, regardless of its outcome, and graph.v2 can mint a fresh
review-escort-loop bead even after this workflow's root has already been
closed. Check both before doing anything else — no fan-out, no synthesis,
no lane dispatch:

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
ROOT_ID="${GC_ROOT_BEAD_ID:-$GC_BEAD_ID}"
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""

if [ -n "$CV_LIB" ]; then
  if source "$CV_LIB" && cv_root_closed_guard "$ROOT_ID" "$CLAIMED_BEAD_ID" "review-escort loop" "review"; then
    exit 0
  fi
fi

SETUP_OUTCOME=""
if [ -n "$CV_LIB" ]; then
  SETUP_OUTCOME="$(source "$CV_LIB" && cv_dependency_outcome "$GC_BEAD_ID" "Prepare con-voyage review context")"
fi
if [ -n "$SETUP_OUTCOME" ] && [ "$SETUP_OUTCOME" != "pass" ]; then
  echo "con-voyage review-escort loop: setup-con-voyage-review outcome=${SETUP_OUTCOME} — nothing to review, abandoning the workflow instead of fanning out review lanes" >&2
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
title) are "unknown" — fall through to the normal pass rather than guessing.
If either block above closes this bead, STOP.

## Verify review-lane claims and re-dispatch stalled lenses (fk-loo1 FIX-F)

Review lenses are pool-managed and only ever wake on a nudge. On a
slow-startup (large) repo, a pool churn cycle can drain a still-starting
lens roster before it claims its lane bead, leaving that lane open and
unassigned forever with nothing left to re-drive it. After the fan-out,
verify that every active lane actually gets claimed, and re-dispatch the
ones that do not. This is best-effort — a gc/bd hiccup must never abort the
review — and it never blocks indefinitely on one stuck lane. On a fast repo
where lenses claim on the first nudge, this loop exits on its first pass and
adds no extra churn. (Same mechanism as main.con-voyage-review-loop.md's
identical section, minus the reopen-for-a-next-cycle framing — this
formula runs its lanes exactly once, so there is no "next cycle" to gate.)

```bash
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

GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
ROOT_ID="${GC_ROOT_BEAD_ID:-$GC_BEAD_ID}"
CV_LENS_CLAIM_SECONDS="{cv_lens_claim_seconds}"
CV_LENS_MAX_REDISPATCH="{cv_lens_max_redispatch}"
case "$CV_LENS_CLAIM_SECONDS" in
  *[!0-9]*|'') CV_LENS_CLAIM_SECONDS="300" ;;
esac
case "$CV_LENS_MAX_REDISPATCH" in
  *[!0-9]*|'') CV_LENS_MAX_REDISPATCH="3" ;;
esac
# review fk-eruo3s LOW-1: `{cv_lens_escalate_target}` is a literal token in a
# file above gc's inline-substitution threshold and never substitutes — read
# the real value back from the workflow root's metadata instead, same
# pattern as every other over-threshold `{var}` in this pack (cv_bead_metadata).
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
CV_LENS_ESCALATE_TARGET=""
if [ -n "$CV_LIB" ]; then
  CV_LENS_ESCALATE_TARGET="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.cv_lens_escalate_target)"
fi
[ -n "$CV_LENS_ESCALATE_TARGET" ] || CV_LENS_ESCALATE_TARGET="human"
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
        -s "con-voyage review-escort: giving up re-dispatching ${lane_id}" \
        -m "Review lane ${lane_id} (routed_to=${routed_to}) never claimed after ${attempts} re-dispatch attempt(s). Stopping automatic re-dispatch here." \
        2>&1 || echo "note: escalation mail failed for $lane_id (continuing)"
      continue  # stop tracking — never retry past CV_LENS_MAX_REDISPATCH
    fi

    if [ "$routed_to" = "-" ]; then
      gc mail send "$CV_LENS_ESCALATE_TARGET" \
        -s "con-voyage review-escort: giving up re-dispatching ${lane_id}" \
        -m "Review lane ${lane_id} has no gc.routed_to metadata; cannot safely re-dispatch. Stopping automatic re-dispatch here." \
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
      gc bd update "$lane_id" --set-metadata "gc.review_watchdog.touched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true
      gc session nudge "$live_session" "Review lane $lane_id is ready and unclaimed — please pick it up." \
        || echo "note: nudge failed for $lane_id (continuing)"
    else
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

An escalated lane is left open for a human; do not retry it further from
this loop and do not let it block synthesis indefinitely.

## Wait for synthesis, then close

Synthesis (`{target}.synthesize-review`, needs every lane above) always
closes with `gc.outcome=pass` regardless of its verdict (approve/iterate) —
that is synthesize-review.md's own contract, unchanged here. Poll for that
sibling bead to close before closing this step, so the finalize step below
never reads a `review-synthesis.md` that a still-running synthesis is
mid-write on. Re-check the root's own status on every iteration too — a
human or the mayor can abandon the workflow mid-wait:

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
SYNTH_STEP_ID="${THIS_STEP_ID%.review-escort-loop}.synthesize-review"

CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""

CV_LENS_GATE_TIMEOUT_SECONDS="{cv_lens_claim_seconds}"
case "$CV_LENS_GATE_TIMEOUT_SECONDS" in
  *[!0-9]*|'') CV_LENS_GATE_TIMEOUT_SECONDS="300" ;;
esac
# review fk-eruo3s LOW-1: `{cv_lens_escalate_target}` never substitutes (file
# is above gc's inline-substitution threshold) — resolve dynamically instead.
CV_LENS_ESCALATE_TARGET=""
if [ -n "$CV_LIB" ]; then
  CV_LENS_ESCALATE_TARGET="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.cv_lens_escalate_target)"
fi
[ -n "$CV_LENS_ESCALATE_TARGET" ] || CV_LENS_ESCALATE_TARGET="human"

gate_start=$(date +%s)
last_mailed_elapsed=-1
while :; do
  ROOT_BEAD_STATUS=""
  if [ -n "$CV_LIB" ]; then
    IFS=$'\x1f' read -r ROOT_BEAD_STATUS _ <<< "$(source "$CV_LIB" && bead_status "$ROOT_ID" id)"
  fi
  if [ "$ROOT_BEAD_STATUS" = "closed" ]; then
    echo "con-voyage review-escort loop: workflow root ${ROOT_ID} was abandoned mid-review — closing this step instead of waiting on synthesis" >&2
    bd update "$CLAIMED_BEAD_ID" \
      --set-metadata 'gc.outcome=skipped' \
      --set-metadata 'gc.skip_reason=workflow root abandoned mid-review'
    bd close "$CLAIMED_BEAD_ID" --reason 'Skipped: workflow root was abandoned mid-review.'
    exit 0
  fi

  MATCH_JSON="$(bd list --all --metadata-field "gc.root_bead_id=${ROOT_ID}" --json --limit=0 2>/dev/null || printf '[]')"
  read -r synth_status synth_outcome <<< "$(printf '%s' "$MATCH_JSON" | python3 -c "
import json, sys
attempt = '$THIS_ATTEMPT'
step = '$SYNTH_STEP_ID'
data = json.load(sys.stdin)
best = None
for b in data:
    meta = b.get('metadata') or {}
    if meta.get('gc.kind') == 'scope-check':
        continue
    if meta.get('gc.attempt') != attempt or meta.get('gc.step_id') != step:
        continue
    best = b
if best is None:
    print('-', '-')
else:
    meta = best.get('metadata') or {}
    print(best.get('status') or '-', meta.get('gc.outcome') or '-')
" 2>/dev/null)"

  if [ "$synth_status" = "closed" ] && [ "$synth_outcome" = "pass" ]; then
    echo "review-escort loop: ${SYNTH_STEP_ID} closed gc.outcome=pass — review-synthesis.md is final"
    break
  fi
  if [ "$synth_status" = "closed" ]; then
    echo "review-escort loop: ${SYNTH_STEP_ID} closed with outcome=${synth_outcome} — not a clean synthesis close, escalating" >&2
    gc mail send "$CV_LENS_ESCALATE_TARGET" \
      -s "con-voyage review-escort: ${SYNTH_STEP_ID} closed without gc.outcome=pass" \
      -m "${SYNTH_STEP_ID} (attempt ${THIS_ATTEMPT}) closed with status=${synth_status} outcome=${synth_outcome}. This needs a human decision." \
      2>&1 || echo "note: escalation mail failed for ${SYNTH_STEP_ID} (continuing)"
    bd update "$CLAIMED_BEAD_ID" \
      --set-metadata 'gc.outcome=fail' \
      --set-metadata 'gc.failure_class=synthesis_not_clean'
    bd close "$CLAIMED_BEAD_ID" --reason "${SYNTH_STEP_ID} closed without gc.outcome=pass — see mayor mail."
    exit 0
  fi

  gc bd update "$GC_BEAD_ID" --set-metadata "gc.review_gate.touched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true

  elapsed=$(( $(date +%s) - gate_start ))
  if [ "$elapsed" -ge "$CV_LENS_GATE_TIMEOUT_SECONDS" ] && [ $(( elapsed - last_mailed_elapsed )) -ge "$CV_LENS_GATE_TIMEOUT_SECONDS" ]; then
    gc mail send "$CV_LENS_ESCALATE_TARGET" \
      -s "con-voyage review-escort: ${SYNTH_STEP_ID} has not closed after ${elapsed}s" \
      -m "Waiting on ${SYNTH_STEP_ID} (attempt ${THIS_ATTEMPT}) to close with gc.outcome=pass. Current status=${synth_status} outcome=${synth_outcome}." \
      2>&1 || echo "note: escalation mail failed for ${SYNTH_STEP_ID} (continuing to wait)"
    last_mailed_elapsed="$elapsed"
  fi
  sleep 30
done

bd update "$CLAIMED_BEAD_ID" --set-metadata 'gc.outcome=pass'
bd close "$CLAIMED_BEAD_ID" --reason "Review-escort single pass complete; ${SYNTH_STEP_ID} closed clean."
```

Do not invoke provider-native subagents. Continue only through this Gas City
graph loop.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
