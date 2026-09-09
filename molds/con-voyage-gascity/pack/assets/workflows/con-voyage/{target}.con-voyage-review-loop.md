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

Do not invoke provider-native subagents. Continue only through this Gas City
graph loop.
