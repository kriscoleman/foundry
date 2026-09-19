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

## Append a per-cycle summary to the WORK BEAD (work-bead lifecycle)

After each review cycle synthesizes, append a one-line summary to the work bead
so the dashboard shows progress and the description stays current. The work bead
is `$WORK_BEAD` recorded in the review context (resolved from `{{convoy_id}}` at
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
