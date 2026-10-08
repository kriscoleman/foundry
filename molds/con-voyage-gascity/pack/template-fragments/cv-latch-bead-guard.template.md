{{ define "cv-latch-bead-guard" }}
## Latch-Bead Guard (fk-79odi)

`gc hook --claim --json` can hand this session a workflow-control latch bead
even though role workers should never receive one. Confirmed live on
foundry-kc, recurring 4x: `gc.implementation-worker` sessions were handed
con-voyage ROOT beads (`gc.kind=workflow`) as normal routed work — fk-2v5tdv
(claimed by TWO sessions at once), fk-qj2s9r, fk-2pw0n1. The Startup Claim
Protocol's own "## Notes" section above already states the rule
(`gc.kind=workflow` and `gc.kind=scope` are latch beads; `gc.kind=check`,
`fanout`, `scope-check`, and `workflow-finalize` belong to the implicit
`workflow-control` lane) but never enforces it — the claim loop verifies
id/status/assignee/route and stops there. This guard makes refusing one
explicit instead of leaving it to improvisation.

After the claim block above claims a bead (`$CLAIMED_BEAD_ID`), before
executing its description as task content, check the `gc.kind` metadata
already printed by that block's `bd show "$GC_BEAD_ID"` call (re-run
`bd show "$CLAIMED_BEAD_ID" --json` if metadata is not visible in that
output). If `gc.kind` is one of `workflow`, `scope`, `check`, `fanout`,
`scope-check`, or `workflow-finalize`, this is a latch bead, not routed work
for this role:

1. Do NOT execute its description, write code, or act on any task content it
   names.
2. Do NOT close it, set `gc.outcome`, or otherwise mutate it — the
   `workflow-control` lane owns its lifecycle, not this session.
3. Mail the mayor once per occurrence
   (`gc mail send mayor -s "latch bead claimed: <bead-id>" -m "..."`
   naming this session, the bead id, and its `gc.kind`) so a recurring
   routing gap is surfaced instead of silently worked around every time
   (communal duty).
4. Re-run the Startup Claim Protocol's claim block to pick up the next
   bead. Do not loop on the same latch bead: if the very next claim hands you
   this same bead id again immediately, drain (`gc runtime drain-ack`)
   rather than spin.
{{ end }}
