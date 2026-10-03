Run con-voyage's initial implementation phase (fk-9aunv: fold the do-work
build into con-voyage as its own first phase).

## Fail fast if prepare-build did not pass

`needs` in graph.v2 is satisfied once the upstream bead is CLOSED, regardless
of its outcome — a failed prepare-build does not, by itself, stop this step
from being routed and claimed (fk-03g4s: a torn-down run burned a claim and a
full worktree investigation on every downstream build step before a human
had to intervene). Check prepare-build's own recorded outcome first, so a
known-failed prepare-build is a near-free close instead of a worktree
investigation:

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
PREPARE_OUTCOME=""
if [ -n "$CV_LIB" ]; then
  PREPARE_OUTCOME="$(source "$CV_LIB" && cv_dependency_outcome "$GC_BEAD_ID" "Prepare con-voyage build worktree")"
fi
if [ -n "$PREPARE_OUTCOME" ] && [ "$PREPARE_OUTCOME" != "pass" ]; then
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=skipped' \
    --set-metadata "gc.skip_reason=prepare-build outcome=${PREPARE_OUTCOME}, no worktree to build in"
  bd close "$CLAIMED_BEAD_ID" --reason 'Skipped: prepare-build did not pass, so there is no worktree to build in.'
  exit 0
fi
```

An empty `$PREPARE_OUTCOME` (lib not found, or prepare-build not resolvable as
a direct dependency by that exact title) is "unknown", not "confirmed pass" —
fall through to the existing worktree-based guard below rather than guessing.

If the block above closes this bead, STOP — do not continue to "Read what
prepare-build resolved" or any later section in this file.

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

## Fail fast if the workflow root is already closed (fk-jg6rm)

`needs`/retry semantics in graph.v2 can mint a FRESH build attempt bead even
after this workflow's root has already been closed (confirmed live, root
fk-viqoe 2026-10-03: the mayor abandoned the root at 00:46Z and a fresh
review iteration was still minted and claimed afterward — closing a root
does not, by itself, stop the engine from dispatching more steps under it).
A later attempt bead must not spend a fresh TDD round on a workflow nobody
is waiting on anymore. Check the root's own status before doing anything
else:

```bash
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
  echo "con-voyage build: workflow root ${ROOT_ID} is already closed — abandoning this attempt and sweeping any pending descendants, minting nothing" >&2
  if [ -n "$CV_LIB" ]; then
    source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "workflow root already closed before this build attempt ran; aborting, minting nothing"
  fi
  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=skipped' \
    --set-metadata 'gc.skip_reason=workflow root already closed'
  bd close "$CLAIMED_BEAD_ID" --reason 'Skipped: workflow root already closed, nothing to build.'
  exit 0
fi
```

An empty `$ROOT_BEAD_STATUS` (lib not found, or `bd show` failed) is
"unknown", not "confirmed open" — fall through to the rest of this file
rather than guessing. If the block above closes this bead, STOP.

## Record this step's own session as the implementor (review fk-hbsmk BLOCKING-1, fk-pbadx BLOCKING-1/3)

Stamp `$ROOT_ID` with a dedicated `gc.build.implementor_session` key, read
from THIS step's own claimed bead (`$GC_BEAD_ID`) — never from the workflow
root's `gc.session_name`, which every `session_affinity=require` step
(review lanes, the synthesizer, publish itself) re-stamps as it touches the
root, so it never reliably names the implementor by the time publish reads
it. Resolve it through `con-voyage-lib.sh`'s shared helpers (not an inline
one-off) so the stamped value is the rig-scoped handle
(`cv_session_route_handle`) that resolves for `implementor_alive`, `gc
sling`, AND `gc mail send` alike — the bare `gc.session_name` value
(`cv_bead_metadata`'s plain read) is only a fallback for when the session
cannot be resolved live:

```bash
CV_TOPLEVEL="${GC_RIG_ROOT:-}"
if [ -z "$CV_TOPLEVEL" ] || [ ! -f "${CV_TOPLEVEL}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh" ]; then
  CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
fi
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
IMPLEMENTOR_SESSION=""
if [ -n "$CV_LIB" ]; then
  IMPLEMENTOR_SESSION_BARE="$(source "$CV_LIB" && cv_bead_metadata "$GC_BEAD_ID" gc.session_name)"
  if [ -n "$IMPLEMENTOR_SESSION_BARE" ]; then
    IMPLEMENTOR_SESSION="$(source "$CV_LIB" && cv_session_route_handle "$IMPLEMENTOR_SESSION_BARE")"
    [ -n "$IMPLEMENTOR_SESSION" ] || IMPLEMENTOR_SESSION="$IMPLEMENTOR_SESSION_BARE"
  fi
fi
if [ -n "$IMPLEMENTOR_SESSION" ]; then
  gc bd update "$ROOT_ID" --set-metadata "gc.build.implementor_session=${IMPLEMENTOR_SESSION}" \
    || echo "con-voyage build: WARNING: could not stamp gc.build.implementor_session on workflow root ${ROOT_ID}" >&2
else
  echo "con-voyage build: WARNING: could not resolve this step's own gc.session_name to stamp as implementor_session on ${ROOT_ID}" >&2
fi
```

## Sync the worktree to the current base (fk-hbsmk)

Before anything else — before even the short-circuit decision — make sure
`$WORKTREE` actually starts from the CURRENT `origin/main` (or whatever the
repo's real default base is), not whatever it happened to be built from.
Evidence (2026-09-26): 4 of 7 foundry-kc con-voyage builds started on a
stale local main, 18 commits behind origin, on a detached HEAD, because a
stale-copy `find` resolved an old cv-worktree-prep.sh. This is now
structural instead of a per-run habit, and applies to BOTH the short-circuit
and fresh-bead paths below — this is a ref-level sync, not a source-file
change, so it does not conflict with "do not touch source files":

```bash
CV_TOPLEVEL="${GC_RIG_ROOT:-}"
if [ -z "$CV_TOPLEVEL" ] || [ ! -f "${CV_TOPLEVEL}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh" ]; then
  CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
fi
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
if [ -z "$CV_LIB" ]; then
  echo "con-voyage build: con-voyage-lib.sh not found — cannot sync ${WORKTREE} to its current base" >&2
  exit 1
fi
SYNC_ERR_FILE="$(mktemp)"
SYNC_RESULT="$(export CV_PACK_ROOT; source "$CV_LIB" && cv_sync_worktree_to_base "$WORKTREE" "con-voyage/${CONVOY_ID}" 2>"$SYNC_ERR_FILE")"
SYNC_RC=$?
SYNC_ERR_TEXT="$(cat "$SYNC_ERR_FILE")"
rm -f "$SYNC_ERR_FILE"
echo "$SYNC_ERR_TEXT" >&2
if [ "$SYNC_RC" -eq 0 ]; then
  echo "con-voyage build: worktree sync: ${SYNC_RESULT}"
fi
```

`CV_TOPLEVEL` for this bootstrap call is resolved from `GC_RIG_ROOT` first —
every gc-spawned session already carries it, and recast+go-live keeps the
rig root's own mold cast current — falling back to `$WORKTREE`'s own git
toplevel only when `GC_RIG_ROOT` is unset or its mold copy is missing
`con-voyage-lib.sh` outright (fk-n7qn1: a worktree whose checked-out branch
predates `cv_sync_worktree_to_base`'s introduction has no copy of the
function in its own mold cast, so sourcing solely from the worktree's own
toplevel can never self-heal — the call meant to sync the worktree needs
code the worktree does not have). `CV_PACK_ROOT` still reflects whichever
toplevel was actually resolved, so `cv_sync_worktree_to_base` gets a
deterministic `cv-worktree-prep.sh` lookup instead of that helper's own
`command -v || find`-style fallback.

(NOTE for reviewers: fk-q2pon is concurrently replacing this same
`command -v || find`-style resolution pattern across this file with a
`cv_pack_script`/`cv_pack_root` helper in con-voyage-lib.sh. It had not
landed on origin/main as of this change, so the snippet above uses the same
absolute pack-path fallback fk-q2pon introduces rather than adding a new
first-match `find`. Whichever of the two PRs lands second should rebase and
may be able to simplify this block to a `cv_pack_script` call.)

### A deterministic sync conflict is terminal, not retryable (fk-hcxre)

`cv_sync_worktree_to_base` returns a DISTINCT exit code for a deterministic
content conflict (`2`) versus a transient/environmental failure (`1`, e.g. a
fetch failure). Do not treat them the same way. Evidence (2026-09-30, con-
voyage root fk-vzgjt, mail rc-wisp-smmo329): main.build failed 3/3 attempts
on the IDENTICAL rebase conflict, because every attempt just re-ran the same
doomed rebase and consumed one of this step's `max_attempts = 3` graph.v2
retries — after which the root was left stranded `in_progress` with no open
steps. A content conflict cannot be fixed by retrying; retrying only burns
attempts and strands the root.

If `$SYNC_RC` is `2`, close this step AND the con-voyage root as a single
terminal outcome, right here — do not `exit 1` (that would consume another
`max_attempts` retry on the identical conflict) and do not continue to any
later section in this file:

```bash
if [ "$SYNC_RC" -eq 2 ]; then
  SYNC_CONFLICT_PATHS="$(printf '%s\n' "$SYNC_ERR_TEXT" | sed -n 's/^cv-lib: SYNC_CONFLICT_PATHS=//p' | tail -1)"

  CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
  CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
  [ -f "${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
  CV_PREP="${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh"
  [ -f "$CV_PREP" ] || CV_PREP=""
  BASE_REF="unknown"
  BEHIND_COUNT="unknown"
  if [ -n "$CV_PREP" ]; then
    BASE_REF="$(bash "$CV_PREP" resolve-base "$WORKTREE" 2>/dev/null || echo unknown)"
    BEHIND_COUNT="$(git -C "$WORKTREE" rev-list --count "HEAD..${BASE_REF}" 2>/dev/null || echo unknown)"
  fi
  STALE_BRANCH="$(git -C "$WORKTREE" symbolic-ref -q --short HEAD 2>/dev/null || echo "con-voyage/${CONVOY_ID}")"

  CV_LENS_STORE_TIMEOUT_SECONDS="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
  case "$CV_LENS_STORE_TIMEOUT_SECONDS" in
    *[!0-9]*|'') CV_LENS_STORE_TIMEOUT_SECONDS="30" ;;
  esac

  # Mail the mayor exactly once for this root (idempotent across a re-run of
  # this same terminal path): check the dedup flag on $ROOT_ID before
  # sending, same pattern cv-synthesis-low-mail.sh uses for
  # code_review.low_mail_sent. The send itself is bounded and its failure is
  # never swallowed (review fk-hcxre BLOCKING-1): an unbounded or silently
  # dropped call here can burn the step's lease or leave the mayor never told
  # about the stranded root.
  ALREADY_MAILED="$(gc bd show "$ROOT_ID" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
print((d.get('metadata') or {}).get('gc.build.sync_conflict_mail_sent') or '')
" 2>/dev/null)"
  if [ "$ALREADY_MAILED" != "true" ]; then
    MAIL_BODY="con-voyage build: deterministic sync conflict on ${STALE_BRANCH} (root ${ROOT_ID}).

Branch: ${STALE_BRANCH}
Behind base (${BASE_REF}): ${BEHIND_COUNT} commit(s)
Conflicted path(s): ${SYNC_CONFLICT_PATHS:-unknown}

This branch cannot be rebased onto the current base without manual conflict
resolution. Recommend reimplementing the change from the current base rather
than retrying — this step has stopped retrying and the con-voyage root has
been closed as abandoned."
    MAIL_ERR_FILE="$(mktemp)"
    MAIL_OUT="$(source "$CV_LIB" && cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" gc mail send mayor -s "con-voyage sync conflict: ${STALE_BRANCH} (root ${ROOT_ID})" -m "$MAIL_BODY" --json 2>"$MAIL_ERR_FILE")"
    MAIL_RC=$?
    MAIL_ERR_TEXT="$(cat "$MAIL_ERR_FILE" 2>/dev/null)"
    rm -f "$MAIL_ERR_FILE"
    if [ "$MAIL_RC" -eq 124 ]; then
      echo "con-voyage build: gc mail send to mayor timed out after ${CV_LENS_STORE_TIMEOUT_SECONDS}s on sync conflict for ${STALE_BRANCH} (root ${ROOT_ID}) — mayor NOT notified" >&2
      exit 1
    elif [ "$MAIL_RC" -ne 0 ]; then
      echo "con-voyage build: gc mail send to mayor failed on sync conflict for ${STALE_BRANCH} (root ${ROOT_ID}): ${MAIL_OUT}${MAIL_ERR_TEXT:+ ${MAIL_ERR_TEXT}} — mayor NOT notified" >&2
      exit 1
    fi
    MAIL_ID="$(printf '%s' "$MAIL_OUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print((d.get('message') or {}).get('id') or '')
" 2>/dev/null)"
    if [ -z "$MAIL_ID" ]; then
      echo "con-voyage build: gc mail send to mayor returned no message id on sync conflict for ${STALE_BRANCH} (root ${ROOT_ID}) — mayor NOT confirmed notified" >&2
      exit 1
    fi
    gc bd update "$ROOT_ID" --set-metadata 'gc.build.sync_conflict_mail_sent=true' --set-metadata "gc.build.sync_conflict_mail_id=${MAIL_ID}" >/dev/null 2>&1
  fi

  bd update "$CLAIMED_BEAD_ID" \
    --set-metadata 'gc.outcome=fail' \
    --set-metadata 'gc.failure_class=sync_conflict' \
    --set-metadata "gc.sync_conflict.paths=${SYNC_CONFLICT_PATHS:-unknown}" \
    --set-metadata "gc.sync_conflict.behind_base=${BEHIND_COUNT}"
  bd close "$CLAIMED_BEAD_ID" --reason "sync_conflict: ${STALE_BRANCH} cannot be rebased onto ${BASE_REF} (conflicted: ${SYNC_CONFLICT_PATHS:-unknown}); not retrying"

  # Close the root, then re-verify it actually closed (review fk-hcxre
  # BLOCKING-2): cv_bead_close is documented fail-safe — a `bd close`
  # failure is warned and swallowed, returning 0 either way — so an
  # unconditional `exit 0` right after it can silently leave the root
  # in_progress with no open steps, the exact stranded-root symptom this
  # terminal path exists to fix. Retry once, then escalate to the mayor with
  # a distinct mail on a second failure rather than exiting clean.
  ROOT_CLOSE_REASON="sync conflict on ${STALE_BRANCH}, ${BEHIND_COUNT} commit(s) behind ${BASE_REF} (conflicted: ${SYNC_CONFLICT_PATHS:-unknown}) — reimplement from base"
  source "$CV_LIB" && cv_bead_close "$ROOT_ID" abandoned "$ROOT_CLOSE_REASON"
  ROOT_STATE="$(source "$CV_LIB" && IFS=$'\x1f' read -r s _ <<< "$(bead_status "$ROOT_ID")" && printf '%s' "$s")"
  if [ "$ROOT_STATE" != "closed" ]; then
    source "$CV_LIB" && cv_bead_close "$ROOT_ID" abandoned "$ROOT_CLOSE_REASON"
    ROOT_STATE="$(source "$CV_LIB" && IFS=$'\x1f' read -r s _ <<< "$(bead_status "$ROOT_ID")" && printf '%s' "$s")"
  fi
  if [ "$ROOT_STATE" != "closed" ]; then
    ESCALATE_ERR_FILE="$(mktemp)"
    source "$CV_LIB" && cv_with_timeout "$CV_LENS_STORE_TIMEOUT_SECONDS" gc mail send mayor -s "con-voyage root failed to close: ${ROOT_ID}" -m "con-voyage build: root ${ROOT_ID} did not close after two attempts following a sync conflict on ${STALE_BRANCH}. Last known status: ${ROOT_STATE:-unknown}. Manual close required." --json >/dev/null 2>"$ESCALATE_ERR_FILE"
    rm -f "$ESCALATE_ERR_FILE"
    echo "con-voyage build: root ${ROOT_ID} failed to close after two attempts (status: ${ROOT_STATE:-unknown}) — escalated to mayor" >&2
  fi

  exit 0
fi
```

If `$SYNC_RC` is any other non-zero value (transient/environmental), the
existing retryable behavior is unchanged:

```bash
if [ "$SYNC_RC" -ne 0 ]; then
  echo "con-voyage build: failed to sync ${WORKTREE} to its current base — refusing to start on a possibly-stale/unconfirmed base" >&2
  exit 1
fi
```

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

Despite the heading, "a pre-built branch" is not guaranteed — the reused
worktree can itself still be on a detached HEAD (fk-tazxl). Confirming/
attaching a branch is a ref operation, not a source-file change, so it does
not conflict with "do not touch source files" above:

```bash
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_GUARD="${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh"
[ -f "$CV_GUARD" ] || CV_GUARD=""
if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
  "$CV_GUARD" ensure-branch "$WORKTREE" "con-voyage/${CONVOY_ID}" \
    || { echo "failed to attach a named branch to the pre-built commit — publish would find a detached HEAD and silently push nothing (fk-tazxl)" >&2; exit 1; }
fi
```

## Fresh bead: run the first TDD implementation round

If `$SHORT_CIRCUIT` is `false`, resolve the real work bead — the source
anchor convoy itself typically carries no task content of its own — and treat
its description as the requirement:

```bash
GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
WORK_BEAD="$(source "$CV_LIB" && cv_resolve_work_bead "$CONVOY_ID")"
gc bd show "$WORK_BEAD" --json
```

Implement the requested behavior from inside `$WORKTREE` using TDD: a failing test first, then the code to pass it, then refactor (con-voyage-gascity pack CLAUDE.md contract). Run the relevant proof commands and confirm they pass. Commit your changes from inside `$WORKTREE`:

```bash
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_GUARD="${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh"
[ -f "$CV_GUARD" ] || CV_GUARD=""
git add -A
if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
  "$CV_GUARD" guard "$(pwd)" || { echo "fix the reported hygiene violation, re-stage, and re-run the guard before committing" >&2; exit 1; }
fi
git commit -m "<conventional-commit message for the requested change>"
```

`$WORKTREE` was created by `git worktree add --detach HEAD` (prepare-build), so the commit above lands on a detached HEAD unless a branch is attached now. Attach one immediately — do not leave this to publish (fk-tazxl: a detached source-anchor worktree makes publish silently push nothing):

```bash
if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
  "$CV_GUARD" ensure-branch "$WORKTREE" "con-voyage/${CONVOY_ID}" \
    || { echo "failed to attach a named branch to the build commit — publish would find a detached HEAD and silently push nothing (fk-tazxl)" >&2; exit 1; }
fi
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

## Abandon the workflow on a terminal build failure (fk-jg6rm)

If this attempt is unrecoverable — an unresolvable requirement, a wrong-repo
source anchor, exhausted repair attempts, or any other reason you are about
to close this step with `gc.outcome=fail` rather than `pass` — the review
phase must never run against a build that never happened. Before closing,
abandon the whole workflow so setup-con-voyage-review, the review loop, and
every lane under it mint nothing (confirmed live, root fk-viqoe
2026-10-03: 4 failed build attempts still let code-review and
security-review lanes go in_progress with no review context on disk).
Mail the mayor exactly once per workflow — dedup via a build-specific
metadata flag (the sync-conflict path above already owns
`gc.build.sync_conflict_mail_sent`; this is a distinct failure class, so it
gets its own flag):

```bash
ALREADY_MAILED="$(gc bd show "$ROOT_ID" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    d = {}
print((d.get('metadata') or {}).get('gc.build.failure_mail_sent') or '')
" 2>/dev/null)"
if [ "$ALREADY_MAILED" != "true" ]; then
  MAIL_ERR_FILE="$(mktemp)"
  MAIL_OUT="$(source "$CV_LIB" && cv_with_timeout 30 gc mail send mayor -s "con-voyage build failed: ${ROOT_ID}" -m "con-voyage build (${CLAIMED_BEAD_ID}) closed gc.outcome=fail on root ${ROOT_ID}. The workflow has been abandoned — no review lanes will be dispatched." --json 2>"$MAIL_ERR_FILE")"
  MAIL_RC=$?
  MAIL_ERR_TEXT="$(cat "$MAIL_ERR_FILE" 2>/dev/null)"
  rm -f "$MAIL_ERR_FILE"
  if [ "$MAIL_RC" -eq 0 ]; then
    MAIL_ID="$(printf '%s' "$MAIL_OUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print((d.get('message') or {}).get('id') or '')
" 2>/dev/null)"
    if [ -n "$MAIL_ID" ]; then
      gc bd update "$ROOT_ID" --set-metadata 'gc.build.failure_mail_sent=true' --set-metadata "gc.build.failure_mail_id=${MAIL_ID}" >/dev/null 2>&1
    else
      echo "con-voyage build: mail to mayor on build failure returned no message id — not marking as sent" >&2
    fi
  else
    echo "con-voyage build: mail to mayor on build failure failed/timed out: ${MAIL_OUT}${MAIL_ERR_TEXT:+ ${MAIL_ERR_TEXT}} — mayor NOT confirmed notified" >&2
  fi
fi

source "$CV_LIB" && cv_close_workflow_root "$ROOT_ID" "con-voyage build failed (${CLAIMED_BEAD_ID}); no review lanes dispatched"
```

This runs in addition to, not instead of, the normal close below. Set
`gc.outcome=fail` on this step as usual — `cv_close_workflow_root` above
already swept the root and any other still-open descendants, so this bead's
own close just records its own terminal state.

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
