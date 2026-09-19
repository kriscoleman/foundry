Prepare the con-voyage review context.

Gather the requirements artifact, implementation plan, decomposition artifact,
implementation summary, changed-file summaries, task evidence, and verification
commands into one review context file under the build artifact root. Record that
path on the workflow root as gc.build.code_review_context_path.

Include:
- The base branch and branch under review
- The full diff summary (files changed, lines added/removed)
- The source anchor id, its work_dir, changed files, commit id, and proof commands
- The review roster that will run (floor lanes always; roster lanes active for this sling)

The floor review lanes (acceptance, test-evidence, simplicity, security, code) run
on every con-voyage. Optional roster lanes are listed in the review context so
synthesis can distinguish floor findings from persona findings.

## Claim the WORK BEAD and seed its description (work-bead lifecycle)

con-voyage now drives the WORK BEAD's own lifecycle so it moves on the dashboard
and never sits open after its PR lands. The work bead is the bead this con-voyage
delivers — NOT this setup step's own claimed bead. In this graph.v2 workflow the
`{{convoy_id}}` token resolves to a synthetic input convoy that `tracks` the real
work bead; resolve it, then claim it and seed its body. Run this block VERBATIM
(it fails safe: on any resolution error it falls back to the convoy id, and every
bd call is best-effort so a bd hiccup never blocks review):

```bash
# Resolve the real work bead from {{convoy_id}} (synthetic input convoy ->
# its `tracks` dependency = the work bead; a non-convoy id is already the work
# bead). Fail-safe: WORK_BEAD is never empty (falls back to the convoy id).
CONVOY_ID="{{convoy_id}}"
WORK_BEAD="$(gc bd show "$CONVOY_ID" --json 2>/dev/null | python3 -c "
import sys, json
cid = sys.argv[1]
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    print(cid); raise SystemExit(0)
if not isinstance(d, dict):
    print(cid); raise SystemExit(0)
meta = d.get('metadata') or {}
synthetic = str(meta.get('gc.synthetic','')).lower() in ('true','1','yes')
if synthetic or (d.get('issue_type') or '') == 'convoy':
    for dep in (d.get('dependencies') or []):
        if isinstance(dep, dict):
            dtype = dep.get('dependency_type') or dep.get('type') or ''
            did = dep.get('id') or ''
            if did and did != cid and dtype in ('tracks',''):
                print(did); raise SystemExit(0)
    print(cid); raise SystemExit(0)
print(cid)
" "$CONVOY_ID" 2>/dev/null || echo "$CONVOY_ID")"

# Claim -> in_progress (idempotent). Seed the description from the review
# context (base + branch under review, PR target, active roster) so the bead
# carries real content even when intake left it empty. Append rather than
# clobber if the human already wrote a description — use --append-notes/note for
# the review context so the original ask is preserved.
gc bd update "$WORK_BEAD" --claim || echo "note: could not claim work bead $WORK_BEAD (continuing)"
gc bd set-state "$WORK_BEAD" cv=reviewing --reason "con-voyage: review started" \
  || echo "note: could not set cv=reviewing on $WORK_BEAD (continuing)"
gc bd note "$WORK_BEAD" "con-voyage started — base <base-branch>, branch <branch-under-review>, PR target <owner/repo>. Review roster: floor (acceptance, test-evidence, simplicity, security, code) + <active roster lenses>. A human lands the PR; this bead closes automatically on merge/close via the con-voyage-finalize monitor." \
  || echo "note: could not append review context to $WORK_BEAD (continuing)"
```

Record `$WORK_BEAD` in the review context file (as `work_bead`) so the publish
step reuses it without re-resolving.

Do not invoke provider-native subagents. Gas City graph lanes are the delegation
mechanism.

Close this setup bead with gc.outcome=pass only after the review context path is
recorded.
