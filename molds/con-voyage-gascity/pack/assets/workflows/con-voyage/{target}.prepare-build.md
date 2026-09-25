Prepare the con-voyage build worktree (fk-9aunv: fold the do-work build into
con-voyage as its own first phase, so one sling on a fresh work bead builds,
reviews, and publishes — no separate `gc sling ... --on do-work` first).

The `{{convoy_id}}` token is the source anchor for this journey — the same
synthetic input convoy `cv_resolve_work_bead` and every other con-voyage step
already resolve against. Unlike do-work, con-voyage never runs against a
drain-unit convoy, so trust `{{convoy_id}}` directly; do not re-derive it from
the workflow root.

## Resolve, or create, the build worktree

```bash
CONVOY_ID="{{convoy_id}}"
DEFAULT_WORKTREE="$(pwd)/worktrees/${CONVOY_ID}"

CV_LIB="$(command -v con-voyage-lib.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name con-voyage-lib.sh 2>/dev/null | head -1)"
CV_WT_PREP="$(command -v cv-worktree-prep.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-worktree-prep.sh 2>/dev/null | head -1)"
if [ -z "$CV_LIB" ] || [ -z "$CV_WT_PREP" ] || [ ! -x "$CV_WT_PREP" ]; then
  echo "con-voyage-lib.sh or cv-worktree-prep.sh not found — the con-voyage pack may not be imported correctly on this rig" >&2
  exit 1
fi

GC="${GC:-gc}"; GC_CITY="${GC_CITY:-.}"

# A prior do-work (or con-voyage) run may have already built this exact
# source anchor — do-work/prepare-worktree.md persists the resolved worktree
# as a bare `work_dir` metadata key on the source anchor bead, which is this
# same convoy. Read it back before creating anything.
EXISTING_WORK_DIR="$(source "$CV_LIB" && cv_bead_work_dir "$CONVOY_ID")"

SHORT_CIRCUIT="false"
WORKTREE="$DEFAULT_WORKTREE"

if [ -n "$EXISTING_WORK_DIR" ] && [ -d "$EXISTING_WORK_DIR" ] && "$CV_WT_PREP" built "$EXISTING_WORK_DIR"; then
  # Pre-built branch (backward-compat path): HEAD is already ahead of base.
  # Reuse it as-is; the build step short-circuits its own TDD round.
  WORKTREE="$EXISTING_WORK_DIR"
  SHORT_CIRCUIT="true"
  echo "con-voyage prepare-build: source anchor ${CONVOY_ID} already has a pre-built branch at ${WORKTREE} — short-circuiting the initial build"
else
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
  gc bd update "$CONVOY_ID" --set-metadata "work_dir=${WORKTREE}" \
    || { echo "con-voyage prepare-build: failed to persist work_dir on ${CONVOY_ID}" >&2; exit 1; }
  echo "con-voyage prepare-build: fresh source anchor ${CONVOY_ID} — worktree ready at ${WORKTREE}; the build step will run its first TDD round"
fi
```

## Record the resolution on the workflow root

Every later step (build, setup-con-voyage-review, and everything downstream)
reads the resolved source anchor from the workflow root instead of
re-deriving it — the same handoff pattern do-work's implement step uses for
`gc.implementation.summary_path`.

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

bd update "$ROOT_ID" \
  --set-metadata "gc.build.source_anchor_id=${CONVOY_ID}" \
  --set-metadata "gc.build.source_anchor_work_dir=${WORKTREE}" \
  --set-metadata "gc.build.short_circuited=${SHORT_CIRCUIT}" \
  || { echo "con-voyage prepare-build: failed to record source anchor metadata on workflow root ${ROOT_ID}" >&2; exit 1; }
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
