Plan the change before the first TDD round (con-voyage plan mode).

Every con-voyage journey kicks off here, between prepare-build and build. The
contract is "plan first, build second": analyze the work, evaluate it against
INVEST, express acceptance as BDD (Given/When/Then), and write it down as a
`gc.build.plan.v1` artifact that the build step implements against. Plan mode
is ON by default. A city turns it off with `[con_voyage] plan_mode = false` in
its `con-voyage.toml`; a single journey overrides the city with
`--var plan_mode=true|false`. When plan mode is off, or prepare-build adopted a
branch that is already built, this step records the skip and closes in
seconds.

The plan proceeds to build automatically. Nobody approves it by hand: it is
the implementor's own working plan, recorded so the build, the reviewers and
the human landing the PR can all check the implementation against it.

Do not edit, stage or commit anything in this step. Planning is read-only.

## Fail fast if prepare-build did not pass

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
if [ -z "$CV_LIB" ]; then
  echo "con-voyage-lib.sh not found — the con-voyage pack may not be imported correctly on this rig" >&2
  exit 1
fi
PREPARE_OUTCOME="$(source "$CV_LIB" && cv_dependency_outcome "$GC_BEAD_ID" "Prepare con-voyage build worktree")"
if [ -n "$PREPARE_OUTCOME" ] && [ "$PREPARE_OUTCOME" != "pass" ]; then
  PREPARE_ROOT_ID="${GC_ROOT_BEAD_ID:-}"
  [ -n "$PREPARE_ROOT_ID" ] || PREPARE_ROOT_ID="$(source "$CV_LIB" && cv_root_bead_id "$GC_BEAD_ID")"
  [ -n "$PREPARE_ROOT_ID" ] && gc bd update "$PREPARE_ROOT_ID" \
    --set-metadata 'gc.plan.skipped=true' \
    --set-metadata "gc.plan.skip_reason=prepare-build outcome=${PREPARE_OUTCOME}"
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=skipped' \
    --set-metadata "gc.skip_reason=prepare-build outcome=${PREPARE_OUTCOME}, nothing to plan against"
  bd close "$CLAIMED_BEAD_ID" --reason 'Skipped: prepare-build did not pass, so there is no worktree to plan against.'
  exit 0
fi
```

An empty `$PREPARE_OUTCOME` is "unknown", not "confirmed pass": fall through to
the worktree check below. If the block above closes this bead, STOP.

## Read what prepare-build resolved

```bash
ROOT_ID="${GC_ROOT_BEAD_ID:-}"
[ -n "$ROOT_ID" ] || ROOT_ID="$(source "$CV_LIB" && cv_root_bead_id "$GC_BEAD_ID")"
[ -n "$ROOT_ID" ] || ROOT_ID="$GC_BEAD_ID"

CONVOY_ID="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.source_anchor_id)"
WORKTREE="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.source_anchor_work_dir)"
SHORT_CIRCUIT="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.build.short_circuited)"
JOURNEY_PLAN_MODE="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.plan_mode)"
RIG_ROOT="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.work_dir)"
[ -n "$RIG_ROOT" ] || RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "con-voyage plan: no valid gc.build.source_anchor_work_dir on workflow root ${ROOT_ID} — prepare-build did not run or failed silently" >&2
  exit 1
fi
```

## Fail fast if the workflow root is already closed

```bash
if source "$CV_LIB" && cv_root_closed_guard "$ROOT_ID" "$CLAIMED_BEAD_ID" "plan" "plan"; then
  exit 0
fi
```

If the block above closes this bead, STOP.

## Decide whether to plan

```bash
SKIP_REASON=""
if [ "$SHORT_CIRCUIT" = "true" ]; then
  SKIP_REASON="pre-built branch adopted by prepare-build; nothing left to plan"
else
  CV_PLAN_MODE_SH="${CV_PACK_ROOT}/assets/scripts/cv-plan-mode.sh"
  PLAN_MODE_SOURCE_FILE="$(mktemp)"
  PLAN_MODE="$(GC_CITY="$GC_CITY" bash "$CV_PLAN_MODE_SH" resolve "$JOURNEY_PLAN_MODE" 2>"$PLAN_MODE_SOURCE_FILE")" || PLAN_MODE="on"
  PLAN_MODE_SOURCE="$(tail -n 1 "$PLAN_MODE_SOURCE_FILE")"
  cat "$PLAN_MODE_SOURCE_FILE" >&2
  rm -f "$PLAN_MODE_SOURCE_FILE"
  [ "$PLAN_MODE" = "off" ] && SKIP_REASON="${PLAN_MODE_SOURCE}"
fi

if [ -n "$SKIP_REASON" ]; then
  gc bd update "$ROOT_ID" \
    --set-metadata 'gc.plan.skipped=true' \
    --set-metadata "gc.plan.skip_reason=${SKIP_REASON}"
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=pass' \
    --set-metadata "gc.plan.skip_reason=${SKIP_REASON}"
  bd close "$CLAIMED_BEAD_ID" --reason "Plan skipped: ${SKIP_REASON}"
  exit 0
fi
```

A failure to run `cv-plan-mode.sh` counts as plan mode ON. Skipping planning is
an explicit opt-out, never a side effect of a broken install. If the block
above closes this bead, STOP.

## Plan the change

Resolve the real work bead and read it in full. Its description is the
requirement:

```bash
WORK_BEAD="$(source "$CV_LIB" && cv_resolve_work_bead "$CONVOY_ID")"
gc bd show "$WORK_BEAD" --json
```

Then read the code you are about to change, from inside `$WORKTREE` only:
the files the change touches, their tests, the conventions around them, and
any contract docs the repo keeps (`CLAUDE.md`, `AGENTS.md`, `features.md`,
`CONTRIBUTING.md`). Read; do not edit.

Work out:

1. **Requirements.** Restate what the bead asks for in your own words, as
   numbered acceptance criteria (`AC-001`, `AC-002`, ...).
2. **INVEST.** Check the change is Independent, Negotiable, Valuable,
   Estimable, Small and Testable. When it is not Small, say how you would
   slice it and plan only the first slice. When it depends on unmerged work,
   say so: the journey should have been slung with `base_branch`.
3. **BDD acceptance.** Write each criterion as Given/When/Then. These become
   the failing tests the build step writes first.
4. **Approach.** The files you will change, the test you will write first for
   each criterion, and how you will verify the result (the exact commands).
5. **Assumptions and risks.** Where the bead is ambiguous, pick the most
   sensible reading, state it under `## Assumptions`, and keep going. Planning
   never blocks on a question that a reasonable default answers.

## Write the plan artifact

Write the plan to `${RIG_ROOT}/.gc/build/${ROOT_ID}/plan.md`. The body must
carry these schema-required `##` sections, in this order:

- `## Summary`
- `## Current System`
- `## Proposed Implementation` (approach, files, test-first order, and an
  `### INVEST` subsection)
- `## Non-Goals`
- `## Verification` (the Given/When/Then criteria, the proof commands, and the
  coverage table)

Add `## Assumptions` and `## Risks` after `## Verification` when you have any.

Front matter must use mapping objects, with this top-level shape:

- `schema: gc.build.plan.v1`
- `workflow: {id: <workflow-root-id>, formula: con-voyage}`
- `methodology: {pack: con-voyage-gascity, name: con-voyage}`
- `producer: {formula: con-voyage, stage: plan, attempt: <positive integer>}`
- `status: approved`
- `trace: {upstream: [...], coverage: [...]}`

`trace.upstream` holds the work bead as `{path: beads/<work-bead-id>, hash:
bead:<work-bead-id>, ids: [AC-001, ...]}`. Every listed id must appear exactly
once in `trace.coverage` (status `covered`, or `deferred`/`out_of_scope` for a
criterion this slice deliberately leaves out) and in a Markdown table with an
`ID` column and a `Status` column carrying the same statuses:

| ID | Status |
| --- | --- |
| AC-001 | covered |

Record the path on the workflow root, then run the gate locally from the rig
root and fix every error it reports before closing:

```bash
PLAN_PATH="${RIG_ROOT}/.gc/build/${ROOT_ID}/plan.md"
gc bd update "$ROOT_ID" --set-metadata "gc.build.plan_path=${PLAN_PATH}"
(cd "$RIG_ROOT" && GC_BEAD_ID="$CLAIMED_BEAD_ID" .gc/scripts/checks/plan-ready.sh)
```

On repair attempts (`gc.attempt` greater than 1), read the validator errors
from `gc.attempt_log` on the validation loop control bead and repair the plan
in place instead of rewriting it.

## Abandon the workflow when the work cannot be planned

Close with `gc.outcome=fail` only when no sensible plan exists: the work bead
is empty or contradicts itself, the source anchor is the wrong repository, or
the validator repair attempts are exhausted. Then the build must never run.
Mail the mayor once, with what you found, and abandon the workflow:

```bash
if [ "$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.plan.failure_mail_sent)" != "true" ]; then
  if source "$CV_LIB" && cv_with_timeout 30 gc mail send mayor -s "con-voyage plan failed: ${ROOT_ID}" -m "con-voyage plan (${CLAIMED_BEAD_ID}) closed gc.outcome=fail on root ${ROOT_ID}: <why the work could not be planned>. The workflow has been abandoned; nothing was built."; then
    gc bd update "$ROOT_ID" --set-metadata 'gc.plan.failure_mail_sent=true' >/dev/null 2>&1
  else
    echo "con-voyage plan: mail to mayor on plan failure failed or timed out — mayor NOT confirmed notified" >&2
  fi
fi
source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "con-voyage plan failed (${CLAIMED_BEAD_ID}); nothing built"
```

## Close

```bash
bd update "$CLAIMED_BEAD_ID" \
  --set-metadata 'gc.outcome=pass' \
  --set-metadata "gc.build.plan_path=${PLAN_PATH}"
bd close "$CLAIMED_BEAD_ID" --reason 'Con-voyage plan complete.'
```

Do not invoke provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
