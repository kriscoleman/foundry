Run con-voyage's initial implementation phase (fk-9aunv: fold the do-work
build into con-voyage as its own first phase).

## Read what prepare-build resolved

```bash
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

read -r CONVOY_ID WORKTREE SHORT_CIRCUIT <<< "$(gc bd show "$ROOT_ID" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
meta = d.get('metadata') or {}
print(meta.get('gc.build.source_anchor_id') or '', meta.get('gc.build.source_anchor_work_dir') or '', meta.get('gc.build.short_circuited') or 'false')
" 2>/dev/null)"

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "con-voyage build: no valid gc.build.source_anchor_work_dir on workflow root ${ROOT_ID} — prepare-build did not run or failed silently" >&2
  exit 1
fi
cd "$WORKTREE" || { echo "con-voyage build: cd into ${WORKTREE} failed" >&2; exit 1; }
[ "$(pwd -P)" = "$(cd "$WORKTREE" && pwd -P)" ] || { echo "con-voyage build: pwd verification failed" >&2; exit 1; }
```

Do not edit files anywhere but inside `$WORKTREE`. Never edit the launcher
checkout.

## Short-circuit: a pre-built branch already exists

If `$SHORT_CIRCUIT` is `true`, prepare-build already confirmed `$WORKTREE`
has commits ahead of base — do not run a new TDD round or touch source files.
Write a short `gc.build.implementation-summary.v1` artifact recording that the
existing branch was reused (see schema below for the required shape; the
`## Verification` section's proof command is simply re-confirming
`cv-worktree-prep.sh built "$WORKTREE"` still reports built), record its path
as `gc.implementation.summary_path` on `$ROOT_ID`, and close this step with
`gc.outcome=pass`. Skip the TDD implementation round in the "Fresh bead"
section below — but still write the artifact per "## Write the
implementation summary artifact".

## Fresh bead: run the first TDD implementation round

If `$SHORT_CIRCUIT` is `false`, resolve the real work bead — the source
anchor convoy itself typically carries no task content of its own — and treat
its description as the requirement:

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
CV_LIB="$(command -v con-voyage-lib.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
WORK_BEAD="$(source "$CV_LIB" && cv_resolve_work_bead "$CONVOY_ID")"
gc bd show "$WORK_BEAD" --json
```

Implement the requested behavior from inside `$WORKTREE` using TDD: a failing test first, then the code to pass it, then refactor (con-voyage-gascity pack CLAUDE.md contract). Run the relevant proof commands and confirm they pass. Commit your changes from inside `$WORKTREE`:

```bash
CV_GUARD="$(command -v cv-worktree-prep.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-worktree-prep.sh 2>/dev/null | head -1)"
git add -A
if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
  "$CV_GUARD" guard "$(pwd)" || { echo "fix the reported hygiene violation, re-stage, and re-run the guard before committing" >&2; exit 1; }
fi
git commit -m "<conventional-commit message for the requested change>"
```

## Write the implementation summary artifact

Write or update the task summary with these schema-required body sections,
using the exact `##` headings below in this order:

- `## Summary`
- `## Intended Behavior`
- `## Changed Files`
- `## Verification`
- `## Remaining Risks`

The `## Verification` section must include both the first verification
command and the final proof command, with the observed pass/fail result.

Write the summary as a `gc.build.implementation-summary.v1` artifact under
`.gc/build/${ROOT_ID}/` and record its absolute path on `$ROOT_ID` as
`gc.implementation.summary_path` before closing. Include a Markdown coverage
table. The validator only recognizes a table with an `ID` column and a
`Status` column. Use this shape:

| ID | Status |
| --- | --- |
| REQ-001 | covered |

Use mapping objects for front matter; do not use scalar shortcuts such as
`workflow: build-basic`. The top-level YAML shape must be:

- `schema: gc.build.implementation-summary.v1`
- `workflow: {id: <workflow-root-id>, formula: con-voyage}`
- `methodology: {pack: con-voyage-gascity, name: con-voyage}`
- `producer: {formula: con-voyage, stage: build, attempt: <positive integer>}`
- `status: approved` or another schema-allowed status
- `trace: {upstream: [...], coverage: [...]}`

Trace front matter must use the validator shape exactly:

- `trace.upstream[]` entries must include `path` and `hash`; do not use
  `id`/`title`/`type` entries as the upstream shape.
- For the work bead, use `path: beads/<work-bead-id>` and
  `hash: bead:<work-bead-id>`. For changed files, use repo-relative paths and
  scheme-qualified hashes such as `sha256:<digest>` or `git:<revision>`.
- If an upstream entry lists `ids`, every listed id must appear exactly once
  in `trace.coverage` and in the Markdown coverage table with the same
  status.
- Coverage statuses are not artifact statuses. Use `covered` for satisfied
  requirements; do not use `approved` in `trace.coverage[].status` or the
  Markdown coverage table.

Artifact validation: this step is gated by
`.gc/scripts/checks/build-artifact-valid.sh`, which validates the summary
recorded at `gc.implementation.summary_path` against schema
`gc.build.implementation-summary.v1`. Before closing this step, read the
launcher rig root from the workflow root bead's `gc.work_dir`, then run the
same validator locally from that rig root with
`GC_BEAD_ID=<claimed-step-id> .gc/scripts/checks/build-artifact-valid.sh`; fix
every reported validation error before setting `gc.outcome=pass`. On repair
attempts (`gc.attempt` greater than 1), read the validator errors from
`gc.attempt_log` on the validation loop control bead and repair the summary
in place instead of rewriting it. Two bounded repair attempts follow the
first failure; exhausting them closes this stage with `gc.outcome=fail` and
machine-readable validation errors that block downstream stages.

## Close

```bash
bd update "$CLAIMED_BEAD_ID" \
  --set-metadata 'gc.outcome=pass' \
  --set-metadata "gc.implementation.summary_path=<summary path>"
bd close "$CLAIMED_BEAD_ID" --reason 'Con-voyage build phase complete.'
```

Do not push or open a PR from this step — the publish step and its push/open_pr
vars own that. Do not invoke provider-native subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
