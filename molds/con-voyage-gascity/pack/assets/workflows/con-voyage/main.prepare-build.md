Prepare the con-voyage build worktree (fk-9aunv: fold the do-work build into
con-voyage as its own first phase, so one sling on a fresh work bead builds,
reviews, and publishes — no separate `gc sling ... --on do-work` first).

The convoy id is the source anchor for this journey — the same synthetic
input convoy `cv_resolve_work_bead` and every other con-voyage step already
resolve against. Unlike do-work, con-voyage never runs against a drain-unit
convoy, so trust it directly once resolved.

Resolve it from the workflow root's metadata below — never from a literal
`{convoy_id}` token in this file's own prose or bash. This description_file
is too large for gc to inline into the bead body (confirmed: a real
dispatched bead for this exact step rendered only the generic "External
Prompt Required" wrapper, never this file's content), so any `{var}` token
written here is a permanent no-op — it renders exactly as written, forever,
to whatever worker reads this file off disk (fk-4q6ib).

## Resolve the workflow root and the convoy id

```bash
CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_LIB="${CV_PACK_ROOT}/assets/scripts/con-voyage-lib.sh"
[ -f "$CV_LIB" ] || CV_LIB=""
if [ -z "$CV_LIB" ]; then
  echo "con-voyage-lib.sh not found — the con-voyage pack may not be imported correctly on this rig" >&2
  exit 1
fi

GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"

ROOT_ID="${GC_ROOT_BEAD_ID:-}"
[ -n "$ROOT_ID" ] || ROOT_ID="$(source "$CV_LIB" && cv_root_bead_id "$GC_BEAD_ID")"

# gc.var.convoy_id is the flat, gc-managed mirror of every formula var
# (including the built-in convoy id) that gc writes onto the workflow root at
# cook time — available before this, the first step, ever runs. Confirmed
# live: gc.input_convoy_id carries the identical value as a second, more
# narrowly-named key; prefer the var-namespaced one for consistency with how
# every other formula var is read, falling back to the alias only if a future
# gc version ever drops one of the two.
CONVOY_ID="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.convoy_id)"
[ -n "$CONVOY_ID" ] || CONVOY_ID="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.input_convoy_id)"
if [ -z "$CONVOY_ID" ]; then
  echo "con-voyage prepare-build: could not resolve convoy id from workflow root ${ROOT_ID} metadata (gc.var.convoy_id / gc.input_convoy_id both empty)" >&2
  exit 1
fi
```

## Seed the build gate's check scripts before build is ever dispatched (fk-oq5nt)

The BUILD node itself carries a graph.v2 `mode = "exec"` gate
(`build-artifact-valid.sh`), resolved relative to this rig's root — not
shipped there automatically by casting the pack. Until now only
`main.setup-con-voyage-review.md` seeded `.gc/scripts/checks/`, but that step
runs AFTER build. A rig that has never run a con-voyage before hits a
controller-level path-resolution error on the BUILD gate itself
(`gc.controller_error = resolving gate condition path: lstat .../.gc/scripts/
checks: no such file or directory`) and the build node goes
`gc.control_quarantined` — even when the implementation step that ran would
have passed. 22 rigs were confirmed unseeded on 2026-10-05 alone. Seed both
the gate check scripts AND the build-artifact validator dependency
(`validate_build_artifact.py` + `schemas/build/*.yaml`, which
`build-artifact-valid.sh` shells out to, and which the build step's own
"Write the implementation summary artifact" section runs locally before
closing `gc.outcome=pass`) BEFORE any worktree work begins, mirroring the
same two seed calls `main.setup-con-voyage-review.md` makes for the
review-loop/finalize gates:

```bash
RIG_ROOT="$(source "$CV_LIB" && cv_default_rig_root)"
[ -n "${RIG_ROOT:-}" ] || RIG_ROOT="${GC_CITY:-.}"

CV_ENSURE_GATE_SCRIPTS="${CV_PACK_ROOT}/assets/scripts/cv-ensure-gate-scripts.sh"
[ -f "$CV_ENSURE_GATE_SCRIPTS" ] || CV_ENSURE_GATE_SCRIPTS=""
if [ -z "$CV_ENSURE_GATE_SCRIPTS" ] || [ ! -x "$CV_ENSURE_GATE_SCRIPTS" ]; then
  echo "cv-ensure-gate-scripts.sh not found under ${GC_CITY:-.} — the con-voyage pack may not be imported correctly on this rig" >&2
  exit 1
fi
"$CV_ENSURE_GATE_SCRIPTS" "$RIG_ROOT" || { echo "gate check script seeding failed — refusing to start a build that would quarantine" >&2; exit 1; }

CV_ENSURE_VALIDATOR="${CV_PACK_ROOT}/assets/scripts/cv-ensure-build-artifact-validator.sh"
[ -f "$CV_ENSURE_VALIDATOR" ] || CV_ENSURE_VALIDATOR=""
if [ -z "$CV_ENSURE_VALIDATOR" ] || [ ! -x "$CV_ENSURE_VALIDATOR" ]; then
  echo "cv-ensure-build-artifact-validator.sh not found under ${GC_CITY:-.} — the con-voyage pack may not be imported correctly on this rig" >&2
  exit 1
fi
"$CV_ENSURE_VALIDATOR" "$RIG_ROOT" || { echo "build-artifact validator seeding failed — refusing to start a build whose own local check would fail confusingly" >&2; exit 1; }
```

Both scripts are "ensure" seeders: present-and-current is a true no-op (no
`.prev` backups), so re-running this on an already-seeded rig on every build
is safe. `main.setup-con-voyage-review.md` still calls both scripts too —
that call stays, since it also re-confirms currency right before the review
loop and finalize gate, which run much later and may span a pack upgrade.

If this block fails for any reason, do NOT proceed — mail the mayor with the
exact output above, then close this prepare-build step with
`gc.outcome=fail` and `gc.failure_class=gate_scripts_missing` (see the GC
Role Worker failure contract) rather than `gc.outcome=pass`.

## Declare a stacked base branch, if one was set at sling time (fk-wmhr96)

`gc sling ... --on con-voyage` always mints its own fresh input convoy, so a
pre-made convoy's own `gc convoy target` is ignored, and setting the target
AFTER the sling races this very step — prepare-build can already be
resolving the default base by the time a post-sling `gc convoy target` call
lands. `base_branch` is a formula var instead: it is available on `$ROOT_ID`
before this, the first step, ever runs, so applying it here — right after
`$CONVOY_ID` is known and before any worktree is touched — is deterministic,
not a race. `cv_convoy_target`/`cv_resolve_base_branch` (used by this step's
own sync below, and by setup-con-voyage-review/publish downstream) already
treat the convoy's target as the source of truth, so setting it here is the
only change needed for the rest of the journey to agree on the declared base:

```bash
BASE_BRANCH_VAR="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.base_branch)"
if [ -n "$BASE_BRANCH_VAR" ]; then
  gc convoy target "$CONVOY_ID" "$BASE_BRANCH_VAR" \
    || { echo "con-voyage prepare-build: failed to set convoy target ${BASE_BRANCH_VAR} on ${CONVOY_ID} from base_branch" >&2; exit 1; }
  echo "con-voyage prepare-build: declared base_branch=${BASE_BRANCH_VAR} — set as convoy target on ${CONVOY_ID}"
fi
```

## Resolve the stable work-branch name (fk-6os73y)

Compute the journey's branch name ONCE here — `con-voyage/<CONVOY_ID>-<topic-
slug-of-the-work-bead-title>`, falling back to the bare `con-voyage/<CONVOY_ID>`
when the title yields no usable slug — and persist it on `$ROOT_ID` via
`cv_ensure_work_branch_name`. Every later step (this one included, further
down, and build/apply-review-findings/publish/synthesize-review downstream)
reads that same stored value instead of recomputing it, so the name never
drifts even if the work bead's title changes mid-journey:

```bash
WORK_BEAD_ID="$(source "$CV_LIB" && cv_resolve_work_bead "$CONVOY_ID")"
WORK_BEAD_TITLE="$(source "$CV_LIB" && cv_bead_title "$WORK_BEAD_ID")"
WORK_BRANCH_NAME="$(source "$CV_LIB" && cv_ensure_work_branch_name "$ROOT_ID" "$CONVOY_ID" "$WORK_BEAD_TITLE")"
if [ -z "$WORK_BRANCH_NAME" ]; then
  echo "con-voyage prepare-build: could not resolve a work-branch name for ${ROOT_ID} (convoy ${CONVOY_ID})" >&2
  exit 1
fi
```

## Resolve, or create, the build worktree

```bash
DEFAULT_WORKTREE="$(pwd)/worktrees/${CONVOY_ID}"

CV_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
CV_PACK_ROOT="${CV_TOPLEVEL:+${CV_TOPLEVEL}/molds/con-voyage-gascity/pack}"
[ -f "${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh" ] || CV_PACK_ROOT="${GC_CITY:-.}/packs/con-voyage"
CV_WT_PREP="${CV_PACK_ROOT}/assets/scripts/cv-worktree-prep.sh"
[ -f "$CV_WT_PREP" ] || CV_WT_PREP=""
if [ -z "$CV_WT_PREP" ] || [ ! -x "$CV_WT_PREP" ]; then
  echo "cv-worktree-prep.sh not found — the con-voyage pack may not be imported correctly on this rig" >&2
  exit 1
fi

# A prior do-work (or con-voyage) run may have already built this exact
# source anchor — do-work/prepare-worktree.md persists the resolved worktree
# as a bare `work_dir` metadata key on the source anchor bead, which is this
# same convoy. Read it back before creating anything.
EXISTING_WORK_DIR="$(source "$CV_LIB" && cv_bead_work_dir "$CONVOY_ID")"

SHORT_CIRCUIT="false"
WORKTREE="$DEFAULT_WORKTREE"
STALE_ANCHOR=""

# fk-2klp2: an explicit `fresh_build=true` sling var always ignores any
# existing/prior anchor and forces a fresh build from the current base,
# regardless of staleness — the operator's manual override when re-slinging
# alone can't force it (re-slinging otherwise keeps adopting the same anchor).
FRESH_BUILD="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.fresh_build)"
STALE_MAX_BEHIND="$(source "$CV_LIB" && cv_bead_metadata "$ROOT_ID" gc.var.cv_stale_anchor_max_behind)"
if [ -n "$STALE_MAX_BEHIND" ]; then
  export CV_STALE_ANCHOR_MAX_BEHIND="$STALE_MAX_BEHIND"
fi

if [ "$FRESH_BUILD" = "true" ]; then
  echo "con-voyage prepare-build: fresh_build=true — ignoring any existing/prior source anchor and building fresh from the current base"
elif [ -n "$EXISTING_WORK_DIR" ] && [ -d "$EXISTING_WORK_DIR" ] && "$CV_WT_PREP" built "$EXISTING_WORK_DIR"; then
  # fk-2klp2: a pre-built branch this old is not automatically safe to reuse
  # — measure how stale it is against the current base before short-circuiting
  # onto it (evidence: fk-0f1 adopted a ~146-commits-behind branch with no
  # guard, and could only end in a big rebase conflict).
  STALE_INFO="$(source "$CV_LIB" && cv_anchor_too_stale "$EXISTING_WORK_DIR")"
  STALE_RC=$?
  if [ "$STALE_RC" -eq 0 ]; then
    STALE_BRANCH="$(git -C "$EXISTING_WORK_DIR" branch --show-current 2>/dev/null)"
    STALE_SHA="$(git -C "$EXISTING_WORK_DIR" rev-parse --short HEAD 2>/dev/null)"
    STALE_ANCHOR="${STALE_BRANCH:-detached}@${STALE_SHA:-unknown}"
    echo "con-voyage prepare-build: source anchor ${CONVOY_ID}'s existing branch at ${EXISTING_WORK_DIR} (${STALE_ANCHOR}, ${STALE_INFO}) is too stale to short-circuit onto — building fresh from the current base instead"

    # BLOCKING-1 (review con-voyage/fk-29ts8 iteration 2): EXISTING_WORK_DIR
    # is DEFAULT_WORKTREE for this convoy's own anchor, so leaving it on disk
    # here means the create/reuse block below finds a dir already present and
    # reuses it in place instead of building fresh — the exact stale
    # branch/HEAD this guard exists to reject survives, and the later
    # cv_sync_worktree_to_base rebase then conflicts on it. Remove it so the
    # worktree-creation block genuinely recreates it `--detach HEAD` from the
    # current base, the same fresh outcome the prior-anchor path already gets
    # for free because its PRIOR_ANCHOR_DIR never equals DEFAULT_WORKTREE.
    #
    # BLOCKING-1/BLOCKING-3 (review con-voyage/fk-29ts8 iteration 3): removing
    # only the worktree directory leaves its branch ref ($WORK_BRANCH_NAME)
    # surviving at the stale commit, which makes the downstream
    # ensure-branch call refuse to move it and abort the entire build; and a
    # bare `remove --force` silently discards any dirty/mid-rebase state with
    # no log. cv_discard_stale_anchor_worktree handles both: drops the stale
    # branch ref after removing the worktree, and logs (not just silently
    # discards) uncommitted changes or an in-progress rebase/merge first.
    source "$CV_LIB" && cv_discard_stale_anchor_worktree "$EXISTING_WORK_DIR" "$WORK_BRANCH_NAME" \
      || { echo "con-voyage prepare-build: failed to remove too-stale worktree ${EXISTING_WORK_DIR} — refusing to reuse it in place" >&2; exit 1; }
  else
    # Pre-built branch (backward-compat path): HEAD is already ahead of base
    # and not too stale to adopt. Reuse it as-is; the build step
    # short-circuits its own TDD round.
    WORKTREE="$EXISTING_WORK_DIR"
    SHORT_CIRCUIT="true"
    echo "con-voyage prepare-build: source anchor ${CONVOY_ID} already has a pre-built branch at ${WORKTREE} — short-circuiting the initial build"
  fi
fi

if [ "$SHORT_CIRCUIT" = "false" ] && [ "$FRESH_BUILD" != "true" ]; then
  # fk-ki8je: a fresh sling's own input convoy NEVER has a work_dir of its
  # own — do-work closes ITS OWN source anchor when it finishes, so that
  # state never carries onto a new convoy, and the branch above alone can
  # never fire for the normal do-work -> con-voyage handoff. Before building
  # fresh, check whether the underlying WORK BEAD has an earlier source
  # anchor (closed or still open) that already finished a build.
  PRIOR_ANCHOR_ID=""
  PRIOR_ANCHOR_DIR=""
  WORK_BEAD_ID="$(source "$CV_LIB" && cv_resolve_work_bead "$CONVOY_ID")"
  if [ -n "$WORK_BEAD_ID" ] && [ "$WORK_BEAD_ID" != "$CONVOY_ID" ]; then
    read -r PRIOR_ANCHOR_ID PRIOR_ANCHOR_DIR <<< "$(source "$CV_LIB" && cv_find_prior_built_anchor "$WORK_BEAD_ID" "$CONVOY_ID")"
  fi

  # fk-2klp2: the same staleness guard applies to a prior work-bead anchor —
  # an old anchor found here is just as capable of being months behind base.
  if [ -n "$PRIOR_ANCHOR_DIR" ]; then
    PRIOR_STALE_INFO="$(source "$CV_LIB" && cv_anchor_too_stale "$PRIOR_ANCHOR_DIR")"
    PRIOR_STALE_RC=$?
    if [ "$PRIOR_STALE_RC" -eq 0 ]; then
      PRIOR_STALE_BRANCH="$(git -C "$PRIOR_ANCHOR_DIR" branch --show-current 2>/dev/null)"
      PRIOR_STALE_SHA="$(git -C "$PRIOR_ANCHOR_DIR" rev-parse --short HEAD 2>/dev/null)"
      STALE_ANCHOR="${PRIOR_STALE_BRANCH:-detached}@${PRIOR_STALE_SHA:-unknown}"
      echo "con-voyage prepare-build: work bead ${WORK_BEAD_ID}'s earlier built source anchor ${PRIOR_ANCHOR_ID} at ${PRIOR_ANCHOR_DIR} (${STALE_ANCHOR}, ${PRIOR_STALE_INFO}) is too stale to short-circuit onto — building fresh from the current base instead"
      PRIOR_ANCHOR_DIR=""
    fi
  fi

  if [ -n "$PRIOR_ANCHOR_DIR" ]; then
    WORKTREE="$PRIOR_ANCHOR_DIR"
    SHORT_CIRCUIT="true"
    echo "con-voyage prepare-build: work bead ${WORK_BEAD_ID} has an earlier built source anchor ${PRIOR_ANCHOR_ID} at ${WORKTREE} — reusing it and short-circuiting the initial build"

    # fk-tazxl overlap: a reused anchor from an older do-work run can be left
    # on a detached HEAD (do-work's own implement step does not always name
    # a branch). publish pushes "whatever branch is checked out", so a
    # detached HEAD here would silently push nothing. Give it a stable name
    # now, while we already know exactly which worktree is being adopted.
    if [ -z "$(git -C "$WORKTREE" branch --show-current 2>/dev/null)" ]; then
      STABLE_BRANCH="$WORK_BRANCH_NAME"
      git -C "$WORKTREE" checkout -q -b "$STABLE_BRANCH" \
        || { echo "con-voyage prepare-build: failed to create ${STABLE_BRANCH} on detached-HEAD anchor ${WORKTREE}" >&2; exit 1; }
      echo "con-voyage prepare-build: ${WORKTREE} was on a detached HEAD — created ${STABLE_BRANCH} at the existing commit so publish has something to push"
    fi

    gc bd update "$CONVOY_ID" --set-metadata "work_dir=${WORKTREE}" \
      || { echo "con-voyage prepare-build: failed to persist work_dir on ${CONVOY_ID}" >&2; exit 1; }
  fi
fi

# fk-hlj5m: the deterministic worktree create/reuse must run regardless of
# fresh_build — it is not part of the prior-anchor lookup/adoption gated
# above by FRESH_BUILD, it is the only block that actually creates the
# worktree a fresh_build=true run still needs. Keeping it fenced behind
# `$FRESH_BUILD != "true"` left WORKTREE pointing at a directory that was
# never created, so the very next step (build.md) aborted with "prepare-build
# did not run or failed silently" on every fresh_build=true sling.
if [ "$SHORT_CIRCUIT" = "false" ]; then
  # Fresh bead: create or reuse the deterministic worktree, same convention
  # do-work/prepare-worktree.md uses ($(pwd)/worktrees/<source-anchor-id>).
  if [ -d "$WORKTREE" ]; then
    git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || { echo "con-voyage prepare-build: ${WORKTREE} exists but is not a git worktree for this repository — failing closed" >&2; exit 1; }
  else
    git worktree add "$WORKTREE" --detach HEAD \
      || { echo "con-voyage prepare-build: git worktree add failed for ${WORKTREE}" >&2; exit 1; }
  fi
  "$CV_WT_PREP" exclude "$WORKTREE" || echo "note: cv-worktree-prep.sh exclude failed for ${WORKTREE} (continuing)"

  # fk-grepg: `git worktree add ... --detach HEAD` bases the new worktree on
  # whatever the SHARED rig-root checkout's HEAD happens to be at this
  # instant, not on origin's current default branch. If a concurrent
  # workflow has left the rig root on its own feature branch, a fresh
  # worktree silently inherits that branch's commits (confirmed live:
  # worktrees/fk-qzq0p and worktrees/fk-5r71y both inherited fk-atuxk's
  # already-merged commit 8052f36 this way). Force a sync to the CURRENT
  # origin default right after creation — the same structural fix
  # build.md/apply-review-findings.md/ci-repair.md already apply at their
  # own start (fk-hbsmk) — so a contaminated worktree is never handed off
  # as "resolved" even briefly, rather than relying solely on a downstream
  # step to catch it later. Pass BASE_BRANCH_VAR through as the explicit base
  # (fk-wmhr96) so a declared stacked base lands the worktree on it from
  # creation — empty when unset, which is byte-identical to the default
  # origin/HEAD -> origin/main -> main resolution.
  SYNC_RESULT="$(source "$CV_LIB" && cv_sync_worktree_to_base "$WORKTREE" "$WORK_BRANCH_NAME" "$BASE_BRANCH_VAR")" \
    || { echo "con-voyage prepare-build: failed to sync fresh worktree ${WORKTREE} to its current base — refusing to hand off a possibly-contaminated worktree" >&2; exit 1; }
  echo "con-voyage prepare-build: worktree sync: ${SYNC_RESULT}"

  gc bd update "$CONVOY_ID" --set-metadata "work_dir=${WORKTREE}" \
    || { echo "con-voyage prepare-build: failed to persist work_dir on ${CONVOY_ID}" >&2; exit 1; }
  echo "con-voyage prepare-build: fresh source anchor ${CONVOY_ID} — worktree ready at ${WORKTREE}; the build step will run its first TDD round"
fi
```

## Record the resolution on the workflow root

Every later step (build, setup-con-voyage-review, and everything downstream)
reads the resolved source anchor from the workflow root instead of
re-deriving it — the same handoff pattern do-work's implement step uses for
`gc.implementation.summary_path`. `$ROOT_ID` is already resolved above.

```bash
bd update "$ROOT_ID" \
  --set-metadata "gc.build.source_anchor_id=${CONVOY_ID}" \
  --set-metadata "gc.build.source_anchor_work_dir=${WORKTREE}" \
  --set-metadata "gc.build.short_circuited=${SHORT_CIRCUIT}" \
  || { echo "con-voyage prepare-build: failed to record source anchor metadata on workflow root ${ROOT_ID}" >&2; exit 1; }

# fk-2klp2: when a staleness guard rejected an anchor above, hand the
# implementor reference context instead of silently discarding what was
# found — a stale branch/commit it rejected can still be useful history.
if [ -n "$STALE_ANCHOR" ]; then
  bd update "$ROOT_ID" --set-metadata "gc.build.stale_anchor=${STALE_ANCHOR}" \
    || echo "con-voyage prepare-build: note: failed to record gc.build.stale_anchor on ${ROOT_ID} (continuing)" >&2
fi
```

Do not edit source files in the launcher checkout — this step is infrastructure
setup only, the same posture as do-work's own prepare-worktree step. Close this
step with `gc.outcome=pass` only after the workflow root carries all three
`gc.build.source_anchor_*` keys above. Do not invoke provider-native
subagents.

## Communal duty (con-voyage-gascity pack)

You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.

## Shell safety (con-voyage-gascity pack)

This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.

## No interactive prompts (con-voyage-gascity pack)

This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.
