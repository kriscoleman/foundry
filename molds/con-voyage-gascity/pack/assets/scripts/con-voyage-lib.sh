# shellcheck shell=bash
# con-voyage-lib.sh — shared per-PR state/dispatch helpers for
# con-voyage-pr-watch.sh (Fix 1), con-voyage-repair-watchdog.sh (Fix 2), and
# con-voyage-review-watchdog.sh (fk-loo1 FIX-F, review-lane liveness).
#
# The first two scripts read and write the SAME per-PR state record format under
# CV_STATE_DIR (see the field-by-field doc comment on state_read below) and
# share the same author-scoping/session-liveness primitives. This file is
# sourced, not executed — it defines functions only and has no shebang-level
# side effects (no `set -...`, so it never overrides either caller's own
# shell-option choice: con-voyage-pr-watch.sh runs `set -euo pipefail`,
# con-voyage-repair-watchdog.sh runs `set -uo pipefail` without `-e`).
#
# Callers must already have GC set (each caller resolves it in its own
# Configuration block before sourcing this file) — every function below reads
# it as a global at CALL time, not at source time.
#
# Bead/mail calls below intentionally omit --city/--rig (fk-7v3r): passing
# --city alone routed an already-rig-prefixed bead id to the CITY store
# instead of its owning rig's store, so bd show/close/update silently
# no-op'd against the wrong store ("Issue not found") — invisible because
# every helper here already fails safe (warns, never aborts). Every caller's
# cwd is already inside the correct rig checkout when these scripts run, so
# omitting both flags lets gc's own cwd-based store auto-detection resolve
# the right store instead.
#
# Requires: bash 4+, gc CLI, python3, git.

# cv_pack_root_has_required_functions TOPLEVEL_LIB CITY_LIB — internal
# staleness probe for cv_pack_root (fk-fzebe). Returns 0 when every function
# CITY_LIB defines is also defined by TOPLEVEL_LIB (the worktree copy is at
# least as complete as the city cast), 1 when TOPLEVEL_LIB is missing one or
# more of them — the signal that it is an OLDER copy than the city cast, not
# just a different one. Sources each file in its own `bash -c` subshell
# (never the caller's shell, whether bash or zsh — see cv_pack_script's doc
# comment above on why a caller's shell must never be assumed) purely to list
# its function names via `declare -F`; neither subshell executes anything the
# sourced file doesn't already run at source time (this file defines
# functions only, per the header comment).
cv_pack_root_has_required_functions() {
  local toplevel_lib="$1" city_lib="$2" missing
  missing="$(comm -23 \
    <(bash -c "source '${city_lib}' >/dev/null 2>&1; declare -F" 2>/dev/null | awk '{print $3}' | sort) \
    <(bash -c "source '${toplevel_lib}' >/dev/null 2>&1; declare -F" 2>/dev/null | awk '{print $3}' | sort))"
  [ -z "$missing" ]
}

# cv_pack_root — print this pack's asset root, resolved deterministically
# (fk-q2pon), never by searching $GC_CITY for whichever copy sorts first:
#   1. `git rev-parse --show-toplevel` — shell-agnostic (unlike
#      ${BASH_SOURCE[0]}, which the doc comment on
#      cv_worktree_prep_resolve_base below explains is empty under zsh) — if
#      that toplevel carries its own molds/con-voyage-gascity/pack copy, a
#      dogfooding run with cwd inside a rig checkout or one of its worktrees
#      uses THAT copy, so a step under test loads the same code it is
#      testing instead of a stale sibling elsewhere under $GC_CITY
#      (fk-8dfxt) — UNLESS that copy is stale (fk-fzebe): if the city cast at
#      $GC_CITY/packs/con-voyage defines a function the toplevel copy is
#      missing, the toplevel copy is an older version-skewed checkout (e.g. a
#      rig root parked behind origin/main), not a dogfooding target, and
#      loading it silently produces "command not found" for whatever the
#      missing function backed (the 2026-09-30 incident this guards against).
#      Fall back to the city cast instead, with a one-line stderr warning
#      naming both paths — fail soft rather than closed, since the city cast
#      is always a usable, current copy.
#   2. Otherwise (no toplevel copy, or the staleness check above tripped),
#      $GC_CITY/packs/con-voyage — the live pack cast a normal, non-dogfooding
#      cast rig actually runs from.
# Always returns one of these two paths; never a list of candidates.
cv_pack_root() {
  local toplevel toplevel_lib city_root city_lib
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$toplevel" ] && [ -f "${toplevel}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh" ]; then
    toplevel_lib="${toplevel}/molds/con-voyage-gascity/pack/assets/scripts/con-voyage-lib.sh"
    city_root="${GC_CITY:-.}/packs/con-voyage"
    city_lib="${city_root}/assets/scripts/con-voyage-lib.sh"
    if [ -f "$city_lib" ] && ! cv_pack_root_has_required_functions "$toplevel_lib" "$city_lib"; then
      echo "cv_pack_root: WARNING: ${toplevel_lib} is missing function(s) the city cast at ${city_lib} defines — treating it as a stale/version-skewed copy and falling back to the city cast (fk-fzebe)" >&2
      printf '%s' "$city_root"
      return 0
    fi
    printf '%s' "${toplevel}/molds/con-voyage-gascity/pack"
    return 0
  fi
  printf '%s' "${GC_CITY:-.}/packs/con-voyage"
}

# cv_pack_script NAME — print the absolute path to pack asset script NAME
# under cv_pack_root, or print nothing (matching the fail-soft contract the
# old command-v/find idiom had on a total miss, so existing `[ -n "$VAR" ]`
# call sites keep working unchanged) if it does not exist there either. Always
# returns 0, even on a miss (LOW-A, con-voyage review PR #103) — the fail-soft
# contract covers exit status, not just output, so a future direct
# `x="$(cv_pack_script foo)"` under `set -e` degrades gracefully instead of
# aborting.
#
# fk-q2pon (found dogfooding this very fix under zsh): the local var below is
# named `script_path`, never bare `path` — `path` is a special TIED parameter
# in zsh (an array kept in sync with $PATH, not an ordinary scalar), so
# `local path` silently replaces $PATH with an empty value for the rest of
# this function's scope. No error is raised (unlike fk-k14n's `local status`
# read-only-variable abort elsewhere in this file), so this survived a
# bash-only test run undetected: cv_pack_root's `git rev-parse` call above
# then silently "command not found"s under zsh, and this function falls back
# to the GC_CITY cast even when the correct worktree copy exists right there.
cv_pack_script() {
  local name="$1" script_path
  script_path="$(cv_pack_root)/assets/scripts/${name}"
  [ -f "$script_path" ] && printf '%s' "$script_path"
  return 0
}

# cv_default_state_dir — print the default CV_STATE_DIR base (each caller
# appends "/.gc/cv-pr-watch" via this function's own output) for when the
# caller does not set CV_STATE_DIR explicitly.
#
# fk-mr07: GC_CITY is the multi-rig CITY root, not any one rig's own root.
# Defaulting CV_STATE_DIR's base to it silently pointed reads/writes at the
# CITY-level .gc/cv-pr-watch instead of the owning rig's, in whichever
# session/process context did not happen to have CV_STATE_DIR pre-scoped —
# con-voyage's own publish step among them: PR #59's finalize record landed
# at the city root this way and sat orphaned until moved by hand, while the
# finalize monitor kept scanning the rig-level directory every cycle and
# never saw it. Resolution order, most to least authoritative:
#   1. GC_RIG_ROOT, when set — the rig root every gc-spawned session (role
#      worker, order exec) already carries; unambiguous by construction.
#   2. Walk up from cwd looking for a directory containing ".beads" (every
#      rig checkout's own root marker) — covers a context that runs with cwd
#      inside the rig checkout but does not export GC_RIG_ROOT.
#   3. GC_CITY (or cwd) — the original default. Kept as a last-resort so an
#      environment matching neither signal above degrades to prior behavior
#      instead of failing closed.
cv_default_state_dir() {
  printf '%s/.gc/cv-pr-watch' "$(cv_default_rig_root)"
}

# cv_default_rig_root — print the resolved rig root using the exact same
# resolution order cv_default_state_dir applies before appending its own
# "/.gc/cv-pr-watch" suffix. Callers that need the bare rig root itself as an
# argument (fk-4jdeh: cv-ensure-gate-scripts.sh and
# cv-ensure-build-artifact-validator.sh both take a positional <rig-root> and
# write to <rig-root>/.gc/... themselves) call this directly instead of
# stripping cv_default_state_dir's suffix back off or hand-copying the
# GC_RIG_ROOT/.beads-walkup/GC_CITY algorithm a third time. See
# cv_default_state_dir's own history (fk-mr07) for why GC_CITY -- the
# multi-rig CITY root -- is a last resort, not the default: it previously let
# a rig-scoped write silently land at the city level instead.
cv_default_rig_root() {
  if [ -n "${GC_RIG_ROOT:-}" ]; then
    printf '%s' "$GC_RIG_ROOT"
    return 0
  fi
  local dir="$PWD"
  while :; do
    if [ -d "${dir}/.beads" ]; then
      printf '%s' "$dir"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
  printf '%s' "${GC_CITY:-.}"
}

# cv_extra_rig_state_dirs PRIMARY_DIR — print one additional
# "<rig-path>/.gc/cv-pr-watch" directory per rig registered in
# "${GC_CITY:-.}/.gc/site.toml" ([[rig]] path = "..." or path = '...'),
# skipping any entry that equals PRIMARY_DIR (already scanned via
# cv_default_state_dir). One path per line; prints nothing if site.toml is
# missing (fail soft — a caller that can't enumerate rigs still scans its own
# primary directory). If site.toml EXISTS but no [[rig]] path entry parses at
# all, that is a silent-degradation signal (a future format change, or hand
# corruption) rather than the ordinary "not configured yet" case, so it is
# logged to stderr (review fk-2c937 SRE LOW-1) instead of staying silent —
# the fail-soft return value is unchanged either way.
#
# fk-2c937: a monitor that runs as a CITY-scoped order (no GC_RIG_ROOT) has
# its OWN cv_default_state_dir call walk up only from ITS OWN cwd, which
# stops at the CITY's own ".beads" and never reaches any rig's
# "<rig>/.gc/cv-pr-watch" — exactly where a DIFFERENT process (con-voyage's
# publish step, running with cwd inside that rig's worktree) lands via the
# very same function. Ancestor walk-up can only ever find an ancestor of the
# caller's own cwd, never a sibling rig directory, so a city-root process
# needs every registered rig named explicitly instead.
cv_extra_rig_state_dirs() {
  local primary="$1"
  local site_toml="${GC_CITY:-.}/.gc/site.toml"
  [ -f "$site_toml" ] || return 0
  local sq="'"
  awk -v skip="$primary" -v sq="$sq" -v site="$site_toml" '
    /^\[\[rig\]\]/ { in_block = 1; next }
    in_block && /^\[/ { in_block = 0 }
    in_block && /^[[:space:]]*path[[:space:]]*=/ {
      line = $0
      sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "", line)
      q = substr(line, 1, 1)
      if (q != "\"" && q != sq) next
      line = substr(line, 2)
      idx = index(line, q)
      if (idx == 0) next
      val = substr(line, 1, idx - 1)
      if (val ~ /^[[:space:]]*$/) next
      raw_matches++
      dir = val "/.gc/cv-pr-watch"
      if (dir != skip) print dir
    }
    END {
      if (raw_matches == 0) {
        print "con-voyage-lib: WARNING: " site " present but no [[rig]] path entries were parsed (missing [[rig]] blocks, or path values not in a recognized quoted form) -- falling back to the primary state dir only" > "/dev/stderr"
      }
    }
  ' "$site_toml"
}

# ---------------------------------------------------------------------------
# GitHub-stacked-PR base branch (fk-qppb4). A con-voyage journey normally
# targets the repo's default branch; a stacked slice instead needs the work
# branch cut from — and its PR opened against — an earlier slice's own work
# branch. Reuses the EXISTING `gc convoy target` primitive (a convoy already
# carries a target branch for child work beads to inherit) instead of a
# parallel formula var, so there is exactly one place a facilitator sets this
# per journey: `gc convoy target <input-convoy-id> <base-branch>` before
# launching do-work/con-voyage against that convoy.
# ---------------------------------------------------------------------------

# cv_convoy_target CONVOY_ID — print the base branch stored on a convoy via
# `gc convoy target`/`gc convoy create --target`. Empty output (never a
# non-zero exit) if the convoy has no target set, the id is empty, or
# gc/python3 fail — every caller has a safe default to fall through to.
# Also defaults $GC to "gc" itself (fk-zl42t iteration-2 BLOCKING-1), the same
# fix cv_bead_metadata got above — main.publish.md and
# main.setup-con-voyage-review.md both reach this via cv_resolve_base_branch
# with no `GC=` set in scope.
cv_convoy_target() {
  local convoy_id="$1"
  [ -n "${convoy_id// /}" ] || { printf ''; return 0; }
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" convoy status "$convoy_id" --json 2>/dev/null) || json=""
  [ -n "$json" ] || { printf ''; return 0; }
  printf '%s' "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print('')
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    print('')
    raise SystemExit(0)
convoy = data.get('convoy')
fields = convoy.get('fields') if isinstance(convoy, dict) else None
target = fields.get('target') if isinstance(fields, dict) else None
print(target or '')
" 2>/dev/null || printf ''
}

# cv_worktree_prep_resolve_base DIR [EXPLICIT_BASE] — locate cv-worktree-prep.sh
# and echo whatever its own `resolve-base` subcommand returns for DIR: a
# remote-tracking ref, a bare branch name, or the empty-tree fail-safe hash
# (see that script's own resolve_base doc comment for the exact order). Empty
# output if the script cannot be found or is not executable.
#
# fk-qppb4 B2 (con-voyage review): this used to locate the sibling script via
# `script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`. The `.md`
# workflow steps that use this lib `source` it directly in the agent's own
# interactive shell, which per this pack's own shell-safety contract may be
# bash OR zsh — and zsh leaves `${BASH_SOURCE[0]}` empty, so `script_dir`
# silently resolved to the caller's cwd instead of this file's directory, the
# executable check failed, and the delegation below was skipped entirely
# (reproduced first-hand under zsh 5.9: the caller fell back to the literal
# "main" instead of the real delegated "origin/main", for the same
# unconfigured input that bash resolved correctly). cv_pack_script (fk-q2pon)
# fixes this the same shell-agnostic way without reintroducing that bug: see
# its own and cv_pack_root's doc comments above for why.
cv_worktree_prep_resolve_base() {
  local dir="$1" explicit="${2:-}"
  local prep_script
  prep_script="$(cv_pack_script cv-worktree-prep.sh)"
  [ -n "$prep_script" ] && [ -x "$prep_script" ] || { printf ''; return 0; }
  bash "$prep_script" resolve-base "$dir" "$explicit" 2>/dev/null
}

# cv_resolve_base_branch CONVOY_ID WORKTREE_DIR — the single source of truth
# every con-voyage step uses to answer "what branch is this journey stacked
# on?". Resolution order:
#   1. cv_convoy_target CONVOY_ID — an explicit `gc convoy target` set by the
#      facilitator for a stacked slice. Short-circuits without ever touching
#      WORKTREE_DIR.
#   2. cv_worktree_prep_resolve_base's own `resolve-base` (origin/HEAD ->
#      origin/main -> main) — DELEGATED, not reimplemented, so the two
#      scripts can never disagree about what "the default base" means. A
#      leading "origin/" is stripped from that result: this function's return
#      value is threaded into `gh pr create --base` (via cv-pr-comment.sh) and
#      into this pack's hygiene guard call, both of which need a bare branch
#      name — `gh` rejects an `origin/`-prefixed --base outright (fk-qppb4 B1
#      review finding), and pre-fk-qppb4 this value was always the hand-filled
#      bare "main", so stripping the prefix is what keeps the unconfigured
#      default byte-identical to that behavior, not a new one.
#   3. The literal "main", when even step 2 degrades to the empty-tree
#      fail-safe hash (not a usable branch name for a PR --base/guard call).
# Default (no `gc convoy target` set) is byte-identical to pre-fk-qppb4
# behavior: this always falls through to step 2, the exact resolution
# cv-worktree-prep.sh's `guard` already used unconditionally.
cv_resolve_base_branch() {
  local convoy_id="$1" worktree_dir="$2"
  local target
  target="$(cv_convoy_target "$convoy_id")"
  if [ -n "${target// /}" ]; then
    printf '%s' "$target"
    return 0
  fi

  local default_base
  default_base="$(cv_worktree_prep_resolve_base "$worktree_dir")"
  default_base="${default_base#origin/}"
  case "$default_base" in
    ""|"4b825dc642cb6eb9a060e54bf8d69288fbee4904") printf 'main' ;;
    *) printf '%s' "$default_base" ;;
  esac
}

# cv_ensure_current_copy SRC DEST [--exec] — seed/replace DEST from SRC so
# that "ensure" means present AND current (fk-6z17l), not "present once,
# frozen forever". Shared by cv-ensure-gate-scripts.sh and
# cv-ensure-build-artifact-validator.sh, which used to each carry their own
# near-identical copy of this cmp/backup/replace sequence at 3 call sites
# across the two files (fk-elkyf review, fk-u7ycf simplicity finding #4).
#
# - DEST missing: copied straight from SRC.
# - DEST present and byte-identical to SRC: untouched, true no-op.
# - DEST present and different: the old content is backed up to
#   "<DEST>.prev" first, then SRC is staged into a same-directory temp file
#   and atomically renamed onto DEST (same-filesystem `mv`, so DEST is never
#   observable half-written).
# - Pass --exec to set the executable bit on the written file (skip it for
#   non-executable assets like YAML schemas).
#
# Echoes exactly one of: seeded | updated | current — callers use this to
# drive their own per-file log line and counters (the wording/prefix differs
# per caller, so that stays in the caller, not here). Whether DEST existed
# on entry is tracked explicitly rather than inferred from ".prev" existing
# afterward, so a destination that was deleted by hand after an earlier
# stale-replace (leaving an orphaned .prev behind) still correctly reports
# "seeded", not "updated", on the next run.
#
# Hardening folded in from the fk-elkyf review (fk-eqhgl, fk-hgulh — all LOW,
# none were live defects, applied here so every call site gets them for
# free rather than needing the same fix repeated at each one):
#   - refuses outright if DEST is a symlink (`-L`), before touching it at
#     all. Un-refused, both the `cmp` read and the `.prev` backup `cp` would
#     read through the symlink, duplicating whatever it points at into a new
#     regular file — the atomic `mv` at the end already replaces (de-symlinks)
#     the live path correctly, but that doesn't help the two reads before it.
#   - stages the temp file via `mktemp` (unpredictable name, created with
#     O_EXCL) instead of a `.tmp.$$` PID suffix, which is guessable and lets
#     a pre-planted symlink at that exact path get written through by `cp`.
#   - treats a `cmp` exit status > 1 ("trouble", e.g. unreadable SRC) as a
#     hard failure distinct from exit 1 ("differs"), rather than routing both
#     into the replace branch.
#
# Every failure returns non-zero with nothing on stdout; the caller decides
# its own die()-message wording, so this function only writes a short note
# to stderr and never exits the caller's shell itself.
cv_ensure_current_copy() {
  local src="$1" dest="$2" mode="${3:-}"

  if [ -L "$dest" ]; then
    echo "cv_ensure_current_copy: refusing to replace symlinked ${dest}" >&2
    return 1
  fi

  local existed=0
  if [ -e "$dest" ]; then
    existed=1
    local cmp_rc=0
    cmp -s "$src" "$dest" || cmp_rc=$?
    if [ "$cmp_rc" -eq 0 ]; then
      echo "current"
      return 0
    elif [ "$cmp_rc" -gt 1 ]; then
      echo "cv_ensure_current_copy: could not compare ${src} and ${dest}" >&2
      return 1
    fi
    cp "$dest" "${dest}.prev" || return 1
  fi

  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  if [ "$mode" = "--exec" ]; then
    chmod +x "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }

  if [ "$existed" -eq 1 ]; then echo "updated"; else echo "seeded"; fi
}

# cv_ensure_branch_based_on DIR BASE_BRANCH — make DIR's current HEAD sit on
# top of BASE_BRANCH (fk-qppb4 requirement 2: GitHub stacked PRs).
#
# WHY HERE, NOT AT WORKTREE CREATION: the worktree is cut by the shared
# do-work/build-basic formula (a different, core pack, out of this repo),
# which unconditionally runs `git worktree add --detach HEAD` against the
# LAUNCHER checkout's current ref — it has no notion of a con-voyage
# journey's base branch, and forking that formula into this pack would
# duplicate core rather than fix it (the documented boundary in fk-qppb4
# requirement 2). This is the con-voyage-level override instead: called from
# {target}.setup-con-voyage-review.md once the implementation commit(s)
# already exist, it moves them onto the real base with one
# `git rebase --onto`, which is observably identical — for the diff a PR
# opens with and the commits CI runs against — to "the work branch was cut
# from the base branch" in the first place.
#
# BASE_BRANCH empty means "no override configured": returns immediately
# without fetching or touching the worktree at all. This is the default path
# and MUST stay byte-identical to pre-fk-qppb4 behavior.
#
# Fails (non-zero) if BASE_BRANCH cannot be resolved to a commit, or if the
# rebase hits a conflict — a merge decision no automation should make
# silently. A conflict always leaves DIR back on its pre-rebase HEAD (`git
# rebase --abort`), never a half-finished rebase.
cv_ensure_branch_based_on() {
  local dir="$1" base_branch="${2:-}"

  if [ -z "${base_branch// /}" ]; then
    echo "cv-lib: no base-branch override configured — leaving ${dir} as prepare-worktree left it"
    return 0
  fi

  if [ -z "$dir" ] || [ ! -d "$dir" ] \
    || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "cv-lib: ERROR cv_ensure_branch_based_on: '${dir}' is not inside a git working tree" >&2
    return 1
  fi

  # SECURITY (fk-qppb4 L4, defense-in-depth): reject a base branch beginning
  # with '-' before it reaches git, where it would parse as an option (e.g.
  # --upload-pack=<cmd>) instead of a refspec/revision.
  case "$base_branch" in
    -*)
      echo "cv-lib: ERROR cv_ensure_branch_based_on: base branch '${base_branch}' begins with '-' — refusing to pass it to git" >&2
      return 1
      ;;
  esac

  # fk-qppb4 L2: an explicit refspec actually populates refs/remotes/origin/<b>
  # (a bare branch-name refspec only writes FETCH_HEAD), so the rev-parse
  # below can rely on this fetch instead of a pre-existing remote-tracking ref.
  #
  # fk-0f459: this is the one real network/remote-I/O call in this function
  # (rebase and rev-parse below are both local-only) and previously had no
  # wall-clock bound — reproduced first-hand as a genuine stuck-process pile
  # under concurrent-lane load (bash blocked in its own command-substitution
  # read() waiting on a slow/stalled git child, the same failure shape
  # cv_with_timeout's own doc comment already describes as "one stuck NFS
  # mount or long writer lock"). Bounded the same way every other
  # possibly-stalling external call in this pack already is.
  CV_BASE_BRANCH_FETCH_TIMEOUT_SECONDS="${CV_BASE_BRANCH_FETCH_TIMEOUT_SECONDS:-30}"
  case "$CV_BASE_BRANCH_FETCH_TIMEOUT_SECONDS" in
    *[!0-9]*|'') CV_BASE_BRANCH_FETCH_TIMEOUT_SECONDS="30" ;;
  esac
  cv_with_timeout "$CV_BASE_BRANCH_FETCH_TIMEOUT_SECONDS" \
    git -C "$dir" fetch -q origin "${base_branch}:refs/remotes/origin/${base_branch}" 2>/dev/null || true
  local new_base="origin/${base_branch}"
  git -C "$dir" rev-parse --verify --quiet "${new_base}^{commit}" >/dev/null 2>&1 || new_base="$base_branch"
  if ! git -C "$dir" rev-parse --verify --quiet "${new_base}^{commit}" >/dev/null 2>&1; then
    echo "cv-lib: ERROR base branch '${base_branch}' does not resolve to a commit in ${dir} (checked origin/${base_branch} and ${base_branch})" >&2
    return 1
  fi

  if git -C "$dir" merge-base --is-ancestor "$new_base" HEAD 2>/dev/null; then
    echo "cv-lib: ${dir} is already based on ${base_branch} — no rebase needed"
    return 0
  fi

  local old_base
  old_base="$(cv_worktree_prep_resolve_base "$dir")"
  [ -n "$old_base" ] || old_base="main"

  echo "cv-lib: rebasing ${dir} from ${old_base} onto ${new_base} (fk-qppb4 stacked-PR base threading)"
  if ! git -C "$dir" rebase --onto "$new_base" "$old_base" >&2; then
    git -C "$dir" rebase --abort >/dev/null 2>&1 || true
    echo "cv-lib: ERROR rebase of ${dir} onto ${new_base} failed (conflict) — resolve manually before continuing" >&2
    return 1
  fi
  echo "cv-lib: ${dir} is now based on ${base_branch}"
}

# cv_sync_worktree_to_base DIR [BRANCH_NAME] — fk-hbsmk: make sure DIR starts
# from the CURRENT origin default base before any code-writing step begins,
# instead of trusting a long-lived worktree/local main that can silently be
# many commits stale (evidence: 4 of 7 foundry-kc con-voyage builds on
# 2026-09-26 started detached on a local main 18 commits behind origin/main,
# because a stale-copy `find` resolution loaded an old cv-worktree-prep.sh).
#
# Never `git merge`. Fails closed (non-zero, no partial rebase left behind)
# rather than silently proceed on an unconfirmed base:
#   - the fetch itself fails or times out (CV_SYNC_FETCH_TIMEOUT_SECONDS,
#     default 60s, bounded via cv_with_timeout — macOS has no timeout(1))
#     -> returns 1 (transient/environmental; a caller may retry)
#   - the rebase hits a conflict (aborted immediately, HEAD restored)
#     -> returns 2 (deterministic content conflict; fk-hcxre: retrying
#        reproduces the identical conflict every time, so this is a DISTINCT,
#        terminal exit code a caller must not treat like the transient case
#        above — the conflicted paths are also reported on stderr via a
#        `SYNC_CONFLICT_PATHS=path1,path2,...` marker line)
#
# Base resolution and branch-naming are both DELEGATED to
# cv-worktree-prep.sh — never reimplemented here, so this can never disagree
# with guard/built/cv_resolve_base_branch about what "the base" means:
#   1. git fetch origin, bounded.
#   2. ensure-branch (fk-tazxl) — a detached worktree gets a name before
#      anything else happens.
#   3. resolve-base — the current default base ref (origin/HEAD ->
#      origin/main -> main).
#   4. HEAD already contains that base -> no-op.
#   5. Otherwise, diff HEAD against its merge-base with the resolved base:
#      zero commits of DIR's own beyond it -> recreate the branch straight
#      from the new base (`checkout -B`); one or more -> replay them onto the
#      new base (`rebase --onto`, preserving DIR's own commits). Using the
#      merge-base (rather than a base SHA captured before the fetch) makes
#      this immune to whether `git push` happened to also update this
#      worktree's own remote-tracking ref.
#
# Prints exactly one bare word to stdout on success: noop | recreated |
# rebased (nothing else — callers capture it via command substitution, the
# same contract cv_resolve_base_branch/resolve-base already use). All
# diagnostics go to stderr. Prints nothing to stdout and returns non-zero on
# any failure: 1 for a transient/environmental failure, 2 for a deterministic
# content conflict (see above).
#
cv_sync_worktree_to_base() {
  local dir="$1" branch_name="${2:-}"

  if [ -z "$dir" ] || [ ! -d "$dir" ] \
    || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "cv-lib: ERROR cv_sync_worktree_to_base: '${dir}' is not inside a git working tree" >&2
    return 1
  fi

  local fetch_timeout="${CV_SYNC_FETCH_TIMEOUT_SECONDS:-60}"
  if ! cv_with_timeout "$fetch_timeout" git -C "$dir" fetch -q origin >&2; then
    echo "cv-lib: ERROR cv_sync_worktree_to_base: git fetch origin failed or timed out (${fetch_timeout}s) in ${dir} — refusing to proceed on an unconfirmed base" >&2
    return 1
  fi

  # Resolving cv-worktree-prep.sh via `command -v || find $GC_CITY -maxdepth 6`
  # was the exact stale-copy-resolution mechanism this whole function exists
  # to eliminate for base resolution (see header) — using it again here for
  # the script lookup itself would just relocate the same risk (review
  # fk-hbsmk B2, con-voyage synthesis root fk-gg5d6: on a rig where the
  # script is not on PATH, the `find` fallback cannot reach this pack's own
  # mold-source copy within 6 levels and silently resolves the live
  # pack-cast copy instead — byte-identical today, but that is incidental
  # timing, not a guarantee). cv_pack_script (fk-q2pon) resolves this the
  # same shell-agnostic, deterministic way as the pack's other two internal
  # copies of this fallback (cv_worktree_prep_resolve_base,
  # cv_find_prior_built_anchor) — see cv_pack_root's doc comment above.
  local prep_script
  prep_script="$(cv_pack_script cv-worktree-prep.sh)"
  if [ -z "$prep_script" ] || [ ! -x "$prep_script" ]; then
    echo "cv-lib: ERROR cv_sync_worktree_to_base: cv-worktree-prep.sh not found — cannot sync ${dir}" >&2
    return 1
  fi

  bash "$prep_script" ensure-branch "$dir" "$branch_name" >&2 \
    || { echo "cv-lib: ERROR cv_sync_worktree_to_base: ensure-branch failed for ${dir}" >&2; return 1; }

  local current_branch
  current_branch="$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  [ -n "$current_branch" ] \
    || { echo "cv-lib: ERROR cv_sync_worktree_to_base: ${dir} is still detached after ensure-branch" >&2; return 1; }

  local base_ref base_sha
  base_ref="$(bash "$prep_script" resolve-base "$dir" 2>/dev/null)"
  base_sha="$(git -C "$dir" rev-parse --verify --quiet "${base_ref}^{commit}" 2>/dev/null || true)"

  if [ -z "$base_sha" ]; then
    echo "cv-lib: cv_sync_worktree_to_base: no base ref resolved for ${dir} — nothing to sync against" >&2
    printf 'noop\n'
    return 0
  fi

  if git -C "$dir" merge-base --is-ancestor "$base_sha" HEAD 2>/dev/null; then
    echo "cv-lib: ${dir} already contains ${base_ref} (${base_sha}) — no sync needed" >&2
    printf 'noop\n'
    return 0
  fi

  local mb ahead
  mb="$(git -C "$dir" merge-base "$base_sha" HEAD 2>/dev/null || true)"
  [ -n "$mb" ] || mb="$base_sha"
  ahead="$(git -C "$dir" rev-list --count "${mb}..HEAD" 2>/dev/null || echo 0)"
  case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac

  if [ "$ahead" -eq 0 ]; then
    if ! git -C "$dir" checkout -q -B "$current_branch" "$base_sha" >&2; then
      echo "cv-lib: ERROR cv_sync_worktree_to_base: checkout -B ${current_branch} ${base_ref} failed in ${dir}" >&2
      return 1
    fi
    echo "cv-lib: ${dir} had no commits of its own beyond ${base_ref}'s history — recreated ${current_branch} from ${base_ref}" >&2
    printf 'recreated\n'
    return 0
  fi

  echo "cv-lib: rebasing ${dir} onto ${base_ref} (${ahead} commit(s) of its own)" >&2
  if ! git -C "$dir" rebase --onto "$base_sha" "$mb" >&2; then
    # fk-hcxre: a rebase conflict is a DETERMINISTIC content conflict, not a
    # transient failure — retrying it (fetch/ensure-branch/environment style
    # failures below still return 1) just reproduces the identical conflict.
    # Capture the conflicted paths and return a distinct exit code (2) so a
    # caller can treat this as terminal instead of burning further retry
    # attempts on the same base+head (evidence: con-voyage root fk-vzgjt
    # failed main.build 3/3 identical attempts on this exact cause before the
    # root was left stranded in_progress). Read the conflict markers BEFORE
    # `rebase --abort` — abort discards the in-progress rebase state that is
    # the only place git records which paths were unmerged.
    local conflict_paths
    conflict_paths="$(git -C "$dir" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    git -C "$dir" rebase --abort >/dev/null 2>&1 || true
    echo "cv-lib: ERROR cv_sync_worktree_to_base: rebase of ${dir} onto ${base_ref} failed (conflict) — aborted, tree left clean; resolve manually before continuing" >&2
    echo "cv-lib: SYNC_CONFLICT_PATHS=${conflict_paths}" >&2
    return 2
  fi
  echo "cv-lib: ${dir} is now based on ${base_ref}" >&2
  printf 'rebased\n'
}

# cv_sync_patch_unchanged DIR OLD_BASE_SHA OLD_HEAD — fk-u8n34: tells the
# caller whether a "recreated"/"rebased" result from cv_sync_worktree_to_base
# actually changed any PATCH content, versus merely replaying the same change
# onto a newer base commit. OLD_BASE_SHA/OLD_HEAD are the base SHA and HEAD
# the caller observed immediately BEFORE calling cv_sync_worktree_to_base (the
# function itself does not retain that state, so the caller must capture it).
#
# Compares sorted `git patch-id --stable` sets for "DIR's own commits" before
# and after the sync (merge-base..HEAD against the base in effect at each
# point), not a raw tree/file diff — a clean `rebase --onto` can replay a
# commit onto a different base and still produce the exact same patch-id, and
# that identical-patch-id case is exactly the one apply-review-findings.md
# must NOT treat as "a new, unreviewed change" (fk-u8n34: a LOW-only review
# round was forced to iterate, re-running every lane, purely because
# cv_sync_worktree_to_base rebased onto a moved origin/main with no actual fix
# commit and no patch content change).
#
# Returns 0 ("unchanged" — caller may treat the sync as a no-op for review
# purposes), 1 ("changed" — a real new commit needing review, e.g. a rebase
# whose conflict resolution altered the diff), or 2 on any resolution error
# (caller should treat this conservatively as "changed"). Prints nothing;
# diagnostics go to stderr.
cv_sync_patch_unchanged() {
  local dir="$1" old_base_sha="${2:-}" old_head="${3:-}"

  if [ -z "$dir" ] || [ ! -d "$dir" ] \
    || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "cv-lib: ERROR cv_sync_patch_unchanged: '${dir}' is not inside a git working tree" >&2
    return 2
  fi
  if [ -z "$old_base_sha" ] || [ -z "$old_head" ]; then
    echo "cv-lib: ERROR cv_sync_patch_unchanged: old_base_sha and old_head are both required" >&2
    return 2
  fi
  if ! git -C "$dir" rev-parse --quiet --verify "${old_head}^{commit}" >/dev/null 2>&1; then
    echo "cv-lib: ERROR cv_sync_patch_unchanged: old_head '${old_head}' is not a commit in ${dir}" >&2
    return 2
  fi
  if ! git -C "$dir" rev-parse --quiet --verify "${old_base_sha}^{commit}" >/dev/null 2>&1; then
    echo "cv-lib: ERROR cv_sync_patch_unchanged: old_base_sha '${old_base_sha}' is not a commit in ${dir}" >&2
    return 2
  fi

  local new_head
  new_head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  if [ -z "$new_head" ]; then
    echo "cv-lib: ERROR cv_sync_patch_unchanged: could not resolve current HEAD in ${dir}" >&2
    return 2
  fi
  if [ "$old_head" = "$new_head" ]; then
    echo "cv-lib: cv_sync_patch_unchanged: HEAD did not move (${old_head}) — trivially unchanged" >&2
    return 0
  fi

  local new_base_ref new_base_sha
  new_base_ref="$(cv_worktree_prep_resolve_base "$dir")"
  if [ -z "$new_base_ref" ]; then
    echo "cv-lib: ERROR cv_sync_patch_unchanged: could not resolve the current base ref in ${dir}" >&2
    return 2
  fi
  new_base_sha="$(git -C "$dir" rev-parse --verify --quiet "${new_base_ref}^{commit}" 2>/dev/null)"
  if [ -z "$new_base_sha" ]; then
    echo "cv-lib: ERROR cv_sync_patch_unchanged: could not resolve '${new_base_ref}' to a commit in ${dir}" >&2
    return 2
  fi

  local old_mb new_mb
  old_mb="$(git -C "$dir" merge-base "$old_base_sha" "$old_head" 2>/dev/null)"
  [ -n "$old_mb" ] || old_mb="$old_base_sha"
  new_mb="$(git -C "$dir" merge-base "$new_base_sha" "$new_head" 2>/dev/null)"
  [ -n "$new_mb" ] || new_mb="$new_base_sha"

  local old_ids new_ids
  old_ids="$(git -C "$dir" log --no-color -p "${old_mb}..${old_head}" 2>/dev/null | git -C "$dir" patch-id --stable 2>/dev/null | awk '{print $1}' | sort)"
  new_ids="$(git -C "$dir" log --no-color -p "${new_mb}..${new_head}" 2>/dev/null | git -C "$dir" patch-id --stable 2>/dev/null | awk '{print $1}' | sort)"

  if [ "$old_ids" = "$new_ids" ]; then
    echo "cv-lib: cv_sync_patch_unchanged: patch-id sets identical across sync (${old_head} -> ${new_head}) — unchanged" >&2
    return 0
  fi
  echo "cv-lib: cv_sync_patch_unchanged: patch-id sets differ across sync (${old_head} -> ${new_head}) — changed" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Per-PR repair state record (fk-4o74 Fix 1; extended by Fix 2's watchdog,
# fk-lfan's B1 round). File: "<CV_STATE_DIR>/<dedup_key>.state", plain
# key=value lines:
#   implementor_session=<value, or empty if unknown>
#   inflight_rework=<tracked bead id, or empty>
#   last_handled_state=<failure_kind | clean | unknown>
#   pr_author=<the resolved PR author login at dispatch time, or empty>
#   repair_route=<the "<rig>/<agent>" pool route for this PR, or empty>
#   repo_full=<owner/repo, or empty>
#   pr_number=<PR number, or empty>
#   branch=<PR head ref, or empty>
#   attempt_count=<watchdog re-dispatch attempts against the CURRENT
#     inflight_rework (or bead-less reuse) cycle, default 0 — owned by
#     con-voyage-repair-watchdog.sh, this script only ever resets it (fresh
#     dispatch / clean) or preserves it (in-flight refresh). Coerced to a
#     validated base-10 integer on read — see state_read below. NOTE: one
#     counter serves two different actions by design — a STALLED+alive
#     re-notify (same implementor, same or no tracked bead — a "nudge") and a
#     DEAD/never-claimed fallback re-dispatch (a fresh implementor, a
#     superseded-and-reminted bead — a "re-mint") both increment it. This is
#     intentional, not a bug: CV_MAX_ATTEMPTS bounds total watchdog
#     intervention for one problem cycle regardless of which remedy was tried,
#     so a PR that alternates nudge/re-mint across cycles still escalates
#     after CV_MAX_ATTEMPTS total attempts rather than resetting the count
#     each time the remedy changes.>
#   escalated=<1 once the watchdog has escalated this PR's stalled rework to
#     the operator and stopped re-dispatching it, default 0 — owned by the
#     watchdog, this script only ever clears it (fresh dispatch / clean) or
#     preserves it (in-flight refresh). Coerced to a validated base-10
#     integer on read — see state_read below.>
#   last_dispatch_at=<ISO-8601 UTC timestamp of the last dispatch/re-notify
#     action for this record, or empty. Written by con-voyage-pr-watch.sh at
#     dispatch time and by con-voyage-repair-watchdog.sh at each re-notify.
#     This is the ONLY staleness signal available for a mail-only reuse
#     dispatch (inflight_rework empty, implementor_session set — Fix 1's
#     PRIMARY dispatch path): there is no tracked bead whose updated_at can
#     serve that role, so the watchdog keys off this field instead. Not
#     consulted while inflight_rework is non-empty (the tracked bead's own
#     updated_at is authoritative there).>
#
# pr_author/repair_route/repo_full/pr_number/branch exist so the watchdog can
# (a) defensively re-verify author scope from local state alone, with no gh
# call, before acting on a record, and (b) re-dispatch fallback work (mint a
# fresh pool bead) without re-deriving PR context. They are populated ONLY on
# a fresh dispatch (the only place con-voyage-pr-watch.sh has them all
# resolved) and are irrelevant whenever inflight_rework is empty AND
# implementor_session is empty (clean / never-dispatched), so that
# combination's write always writes them empty.
#
# Back-compat: a pre-existing "<dedup_key>.minted" file (the OLD, pre-Fix-1
# format, with no ".state" file yet) is read as inflight_rework=<that id>,
# implementor_session=<empty>, last_handled_state=unknown — "unknown" never
# matches a real observed state, so the first post-upgrade cycle re-evaluates
# the PR fresh instead of trusting stale pre-upgrade bookkeeping. A pre-Fix-2
# 3-field ".state" file (no pr_author/repair_route/etc.) reads those newer
# fields as empty and attempt_count/escalated/last_dispatch_at as their
# defaults.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # ST_* globals are consumed by the sourcing
# scripts (con-voyage-pr-watch.sh, con-voyage-repair-watchdog.sh), invisible
# to shellcheck when this file is checked standalone.

# ---------------------------------------------------------------------------
# Communal-duty reminder (PR #45 human review, fk-doh9): the mold's AGENTS.md
# states that every worker the pack dispatches — one-off, formula, order, or
# convoy — shares the duty to surface system-level trouble by mailing the
# mayor, not just the TDD implementor. AGENTS.md itself never reaches a
# dispatched worker (it lives at the mold root, outside pack/, so `ailloy
# cast` never ships it into a target rig) — the bead a worker claims is what
# actually reaches it. Every formula-dispatched task's text is a literal copy
# of this reminder appended to its description_file template (they are
# static assets, not shell, so they cannot source this constant directly —
# tests/agents-contract.test.sh diffs them against it instead, driven by the
# formulas' own description_file lists). cv_build_pr_feedback_body below is
# the one surface that composes a bead body in shell, so it is the one
# surface that references this constant instead of duplicating it.
CV_COMMUNAL_DUTY_REMINDER='You are dispatched by the con-voyage-gascity pack — this duty binds every worker it sends out, not just the implementor. If you hit something broken outside the scope of this bead (a stalled agent, a stuck bead, a lost dispatch, a red check), surface it: fix it if you can, otherwise mail the mayor (`gc mail`) with what you saw.'

# ---------------------------------------------------------------------------
# Review-lane worktree isolation reminder (fk-q659 LIVE finding): every
# con-voyage review lane for a work item used to read the review context's
# recorded source-anchor work_dir and run its own verification directly
# inside that ONE shared directory. A lane doing mutate-run-revert
# verification (temporarily edit a file, run a command, revert) races another
# lane's concurrent build/test in the same directory, producing a false
# BLOCKING or false-negative finding. cv-review-lane-worktree.sh gives each
# lane its own throwaway linked git worktree instead. Like
# CV_COMMUNAL_DUTY_REMINDER above, every review-lane description_file carries
# a literal copy of this text (static assets, not shell, so they cannot
# source the constant directly) — tests/review-lane-worktree-isolation.test.sh
# diffs them against it, driven by the con-voyage-review-loop's own
# `[[template.children]]` list in the formula, not a hand-maintained lane list.
CV_REVIEW_LANE_WORKTREE_REMINDER='This review lane never runs a command that touches the implementation on disk directly inside the shared source-anchor work_dir recorded in the review context. Every active lane can read and execute against that same directory at the same time, so a local edit (including a temporary mutate-run-revert check) or a build/test invocation there can race a concurrent build or test run from another lane and produce a false BLOCKING or false-negative finding (fk-q659). Acquire your own private worktree copy first with `cv-review-lane-worktree.sh acquire`, and run every such command inside it instead — never inside the shared work_dir.'

# ---------------------------------------------------------------------------
# Shell-safety reminder (fk-k14n; reworded fk-0o4d after PR #58 human review —
# the operator's shell is not always zsh): the Bash tool runs whichever shell
# the operator has configured — bash or zsh, never assume which. zsh does NOT
# word-split unquoted parameter expansions by default, so a pattern that
# behaves correctly under bash/POSIX sh (`for x in $var`, `set -- $pair`)
# silently collapses to one iteration (or a no-op on empty input) under zsh
# instead of splitting on whitespace — it reads like a tool malfunction
# rather than a shell semantics difference, and has already cost real turns
# (a rig-hygiene loop, a research-sling loop). The fix for that footgun must
# itself work in either shell: `read -a` (bash) and `read -A` (zsh) are NOT
# interchangeable and zsh hard-errors on `-a`, so hard-coding one over the
# other just trades a silent bash-side bug for a loud zsh-side one (or vice
# versa) depending on the operator's profile.
# Distributed the same way as CV_COMMUNAL_DUTY_REMINDER, for the same reason
# documented in the comment above it: static template assets cannot source
# this constant directly, so tests/agents-contract.test.sh diffs them against
# it instead, driven by the formulas' own description_file lists.
# shellcheck disable=SC2016  # backticks/$VAR below are literal reminder text for the reader, not expansion
CV_SHELL_SAFETY_REMINDER='This Bash tool runs whichever shell the operator has configured — bash or zsh, never assume which. zsh does not word-split unquoted `$VAR` the way bash/POSIX sh does, so under zsh `for x in $VAR` or `set -- $VAR` silently runs once on the whole string (or no-ops) instead of splitting on whitespace. Never rely on unquoted-variable splitting: use an array of literal elements (`arr=(...)`; `for x in "${arr[@]}"`), or pipe through `xargs`/`while read` — both behave identically in bash and zsh. If you must split a variable into an array directly, `read -a` (bash) and `read -A` (zsh) are not interchangeable (zsh hard-errors on `-a`) — branch on `$ZSH_VERSION` rather than hard-coding one.'

# ---------------------------------------------------------------------------
# No-interactive-prompts reminder (fk-6kvnt): city worker sessions run
# headless — nobody is watching the terminal — but they can still call an
# interactive terminal prompt tool (for example Claude Code's
# AskUserQuestion). Doing so blocks the session forever with nobody able to
# answer it: SEEN 2026-09-25 on a raw --no-formula bead that sat blocked on an
# AskUserQuestion prompt for roughly 20 minutes until the mayor happened to
# peek the pane and answered it by hand. Distributed the same way as
# CV_COMMUNAL_DUTY_REMINDER/CV_SHELL_SAFETY_REMINDER above, for the same
# reason: static template assets cannot source this constant directly, so
# tests/agents-contract.test.sh diffs them against it instead, driven by the
# formulas' own description_file lists. Deliberately NOT distributed to the
# mayor's own prompt (outside pack/formulas/*.toml entirely) — the mayor runs
# with a human at the terminal and is the designated point of contact this
# same reminder tells every other worker to mail instead.
CV_NO_INTERACTIVE_PROMPT_REMINDER='This session runs headless — nobody is watching a terminal, so an interactive prompt tool (for example AskUserQuestion) blocks the session forever with no one able to answer it. Never call an interactive prompt tool. When a real decision is needed, mail the mayor (`gc mail`) with the question, then either wait for a reply or close the bead as blocked with the open question recorded in the close reason.'

# ---------------------------------------------------------------------------
# PR-reply-integrity reminder (fk-ntq0): con-voyage posts to GitHub under the
# operator's own PAT, so every agent-authored PR comment shows up as the
# operator unless it carries cv-pr-comment.sh's machine-identity banner. A
# worker replying to routed human PR feedback found this out the hard way —
# it called a raw `gh` command instead of cv-pr-comment.sh, posted an
# unbannered comment that impersonated the operator, and self-reported
# gc.outcome=pass with no way to verify the post happened at all (PR #45
# round fk-8ymb; recurred in production on replicatedhq/vandoor#10589).
# cv_build_pr_feedback_body is the ONLY place this pack free-texts a bead
# body outside the formula graph (see tests/agents-contract.test.sh), so this
# reminder is distributed there, not via a formula description_file.
CV_PR_REPLY_INTEGRITY_REMINDER='Post ONLY through `cv-pr-comment.sh` — `reply-thread` for an inline review-thread reply (use the `[reply-thread comment-id:<id> @ path:line]` target from the feedback above), `comment` for a root-level reply. A raw `gh pr comment`, `gh pr review`, or `gh api ... comments` call posts under the operator'"'"'s own GitHub identity with no machine-identity banner, impersonating a human. Before closing this bead with `gc.outcome=pass`, record the URL `cv-pr-comment.sh` printed as `gc.pr_comment_url` metadata on this bead (`bd update <bead-id> --set-metadata "gc.pr_comment_url=<url>"`) — a pass-close without it is invalid and must not be reported as done.'

# cv_text_has_interactive_prompt_stall TEXT — exit 0 if TEXT contains the
# footer Claude Code's AskUserQuestion (and similar single/multi-select
# terminal prompts) prints while blocked waiting on a selection, exit 1
# otherwise. This is a detection PRIMITIVE only — it classifies a text blob
# handed to it and does not itself read any session's pane content. It exists
# so a future periodic watchdog (mirroring con-voyage-review-watchdog.sh /
# con-voyage-repair-watchdog.sh) can peek a live worker session's captured
# pane text and call this to recognize the stall (fk-6kvnt item 2); wiring
# that live watchdog is tracked as follow-up, see this change's implementation
# summary for why it is out of scope here. Matches on the two literal ASCII
# phrases that bracket the glyphs ("Enter to select" and "to navigate")
# rather than the exact unicode middle-dot/arrow characters in between,
# because tmux/terminal pane capture is not guaranteed to round-trip
# non-ASCII glyphs byte-for-byte across every locale/terminfo — the two
# phrases co-occurring is already a highly specific signal of this one
# prompt UI, and matching on them is robust to that capture variance. Checks
# each phrase independently of order: Claude Code's real footer renders
# "to navigate" before "Enter to select" (e.g. "↑/↓ to navigate · Enter to
# select · Esc to close"), so an ordered single-glob match never fires.
cv_text_has_interactive_prompt_stall() {
  case "$1" in
    *'Enter to select'*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *'to navigate'*) return 0 ;;
    *) return 1 ;;
  esac
}

# cv_text_has_usage_limit_stall TEXT — exit 0 if TEXT contains the literal
# system banner Claude Code prints in a live session's pane when the whole
# provider account hits a usage limit, exit 1 otherwise. Same detection-
# PRIMITIVE style as cv_text_has_interactive_prompt_stall above: classifies a
# text blob handed to it (e.g. a `gc session peek` capture) and performs no
# session I/O of its own. Confirmed against two real captured occurrences
# that froze every session city-wide on the same claude.ai account
# (2026-09-25 ~19:25-20:05 EDT and 2026-09-26 ~15:17-16:25 EDT) — both the
# initial banner ("Usage limit reached · continuing automatically at <time> ·
# esc or type to cancel") and the repeat ("Usage limit reached again after
# you continued · ...") share this one literal substring, so matching on it
# is robust to which of the two variants is on screen without depending on
# the volatile reset-time suffix.
cv_text_has_usage_limit_stall() {
  case "$1" in
    *'Usage limit reached'*) return 0 ;;
    *) return 1 ;;
  esac
}

# cv_session_shows_usage_limit_stall SESSION_ID — exit 0 if a live peek of
# SESSION_ID's captured pane currently shows the provider usage-limit banner
# (cv_text_has_usage_limit_stall). Used by con-voyage-review-watchdog.sh to
# sample one candidate session before treating a batch of stalled lanes as N
# independent failures instead of one city-wide freeze.
#
# FAIL-SAFE: exit 1 (no freeze signal) for an empty SESSION_ID, a peek call
# that fails, or unparseable/empty output — an inability to peek a session
# must never itself manufacture a freeze signal.
cv_session_shows_usage_limit_stall() {
  local session_id="$1"
  [ -n "${session_id// /}" ] || return 1
  local json
  json=$("$GC" --city "$GC_CITY" session peek "$session_id" --json --lines 60 2>/dev/null) || json=""
  [ -n "$json" ] || return 1
  local output_text
  output_text="$(printf '%s' "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('')
    raise SystemExit(0)
if not isinstance(d, dict):
    print('')
    raise SystemExit(0)
print(d.get('output') or '')
" 2>/dev/null)"
  cv_text_has_usage_limit_stall "$output_text"
}

# cv_lane_has_open_blocking_dependency LANE_ID — exit 0 if LANE_ID currently
# has at least one "blocks"-type dependency whose own status is not "closed"
# (the lane is NOT yet ready to be worked). A fan-out graph.v2 lane bead is
# created with status=open at scope-creation time, before its own blocking
# steps (e.g. the build phase, or review setup) have closed, so `status=open`
# alone never means ready — con-voyage-review-watchdog.sh uses this to hold
# off starting a lane's stall clock until every blocking dependency is
# closed. Exit 1 (the lane IS ready) when every "blocks" dependency is
# closed, or there are none.
#
# FAIL-SAFE: exit 0 (treated as NOT ready, i.e. no watchdog action this
# cycle) for an empty LANE_ID, a `bd show` failure, or unparseable JSON —
# same "when in doubt, do nothing" posture as is_stale's fail-to-non-stale
# default above. A transient lookup failure must never itself cause a false
# stall action; the normal staleness/escalation gates remain the real safety
# net once the lookup succeeds on a later cycle.
cv_lane_has_open_blocking_dependency() {
  local lane_id="$1"
  [ -n "${lane_id// /}" ] || return 0
  local json
  json=$("$GC" bd show "$lane_id" --json 2>/dev/null) || json=""
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    sys.exit(0)
for dep in (data.get('dependencies') or []):
    if not isinstance(dep, dict):
        continue
    dtype = dep.get('dependency_type') or dep.get('type') or ''
    if dtype != 'blocks':
        continue
    if (dep.get('status') or '') != 'closed':
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}
# ---------------------------------------------------------------------------
# Non-routable WORK BEAD owner identity (fk-9f2n): setup-con-voyage-review's
# WORK_BEAD lifecycle block used to run `bd update $WORK_BEAD --claim`, which
# assigns the work bead to the CALLING run-operator session. The work bead
# carries no graph.v2 step metadata (empty gc.root_bead_id/gc.routed_to/
# gc.continuation_group), so that same session's NEXT `gc hook --claim`
# immediately re-surfaced the identical bead as fresh routed work — a live
# dispatch loop confirmed recurring across three separate con-voyage runs.
# Assigning the work bead to THIS fixed identity instead of the caller's own
# means no session's resume-my-own-in-progress-work claim fallback ever
# matches it again. No live gc session is ever identified by this string.
# Like CV_COMMUNAL_DUTY_REMINDER above, the workflow markdown asset that uses
# this value is static text, not shell, so it cannot source this constant
# directly — tests/con-voyage-lib.test.sh diffs it against the literal value
# instead.
CV_WORK_BEAD_OWNER='con-voyage:work-bead'

# cv_bead_claim_non_routable BEAD_ID — idempotently claim BEAD_ID (status=
# in_progress) under the fixed CV_WORK_BEAD_OWNER identity instead of the
# caller's own session identity (fk-9f2n; see CV_WORK_BEAD_OWNER above for
# why). Deliberately does NOT use `bd update --claim`, which always sets
# assignee to the caller.
#
# FAIL-SAFE: warns to stderr and no-ops — never aborts the caller — for an
# empty BEAD_ID, a bead unknown to `bd show`, or a bead that is already closed
# (idempotent: re-running the same setup step twice never errors). A `bd
# update` failure itself is also swallowed (warn only), matching
# cv_bead_mark_in_progress's posture.
cv_bead_claim_non_routable() {
  local bead_id="$1"
  [ -n "${bead_id// /}" ] || { echo "cv_bead_claim_non_routable: empty bead id, skipping" >&2; return 0; }
  local bead_state
  IFS=$'\x1f' read -r bead_state _ <<< "$(bead_status "$bead_id" assignee)"
  if [ -z "$bead_state" ]; then
    echo "cv_bead_claim_non_routable: bead ${bead_id} not found, skipping" >&2
    return 0
  fi
  if [ "$bead_state" = "closed" ]; then
    echo "cv_bead_claim_non_routable: bead ${bead_id} already closed, skipping" >&2
    return 0
  fi
  local gc_bin="${GC:-gc}"
  "$gc_bin" bd update "$bead_id" --assignee "$CV_WORK_BEAD_OWNER" --status in_progress >/dev/null 2>&1 \
    || echo "cv_bead_claim_non_routable: failed to claim ${bead_id}" >&2
  return 0
}

# cv_build_pr_feedback_body PR_URL HEAD_REF FEEDBACK_SUMMARY IDEMPOTENCY_KEY
# Composes the routed bead body for a human-PR-comment routing event
# (con-voyage-pr-watch.sh Part B). Extracted out of the scan loop so it is
# directly unit-testable without re-running PR discovery.
cv_build_pr_feedback_body() {
  local pr_url="$1" head_ref="$2" feedback_summary="$3" idempotency_key="$4"
  cat <<BODY
New human review feedback on PR ${pr_url} (branch: ${head_ref}).

Please read and respond to the following comments. Address any requested
changes on the branch '${head_ref}' using TDD. Push the fix — do NOT merge.

New feedback:
${feedback_summary}

${CV_PR_REPLY_INTEGRITY_REMINDER}

${CV_COMMUNAL_DUTY_REMINDER}

${CV_SHELL_SAFETY_REMINDER}

${CV_NO_INTERACTIVE_PROMPT_REMINDER}

Routing from con-voyage-pr-watch (idempotency: ${idempotency_key})
BODY
}

# shellcheck disable=SC2034  # ST_* globals are consumed by the sourcing
# scripts (con-voyage-pr-watch.sh, con-voyage-repair-watchdog.sh), invisible
# to shellcheck when this file is checked standalone (same posture as
# finalize_read's FS_* disable below).
state_read() {
  local dedup_key="$1"
  local state_file="${CV_STATE_DIR}/${dedup_key}.state"
  local legacy_file="${CV_STATE_DIR}/${dedup_key}.minted"
  ST_IMPLEMENTOR=""
  ST_INFLIGHT=""
  ST_LAST_STATE="unknown"
  ST_PR_AUTHOR=""
  ST_REPAIR_ROUTE=""
  ST_REPO_FULL=""
  ST_PR_NUMBER=""
  ST_BRANCH=""
  ST_ATTEMPT_COUNT="0"
  ST_ESCALATED="0"
  ST_LAST_DISPATCH_AT=""
  if [ -f "$state_file" ]; then
    local k v
    while IFS='=' read -r k v || [ -n "$k" ]; do
      case "$k" in
        implementor_session) ST_IMPLEMENTOR="$v" ;;
        inflight_rework) ST_INFLIGHT="$v" ;;
        last_handled_state) [ -n "$v" ] && ST_LAST_STATE="$v" ;;
        pr_author) ST_PR_AUTHOR="$v" ;;
        repair_route) ST_REPAIR_ROUTE="$v" ;;
        repo_full) ST_REPO_FULL="$v" ;;
        pr_number) ST_PR_NUMBER="$v" ;;
        branch) ST_BRANCH="$v" ;;
        attempt_count) [ -n "$v" ] && ST_ATTEMPT_COUNT="$v" ;;
        escalated) [ -n "$v" ] && ST_ESCALATED="$v" ;;
        last_dispatch_at) ST_LAST_DISPATCH_AT="$v" ;;
      esac
    done < "$state_file"
  elif [ -f "$legacy_file" ]; then
    ST_INFLIGHT="$(cat "$legacy_file" 2>/dev/null || true)"
  fi

  # SECURITY (fk-lfan B2): attempt_count/escalated are read from an on-disk
  # file this process does not exclusively own (con-voyage-pr-watch.sh and
  # con-voyage-repair-watchdog.sh both write it, under a predictable path).
  # Both fields are later used in bash arithmetic (`$((ST_ATTEMPT_COUNT + 1))`,
  # `-ge` comparisons), and bash arithmetic recursively expands anything that
  # LOOKS like an array subscript inside the expression — an
  # attacker-controlled value such as `dedup_key[$(touch /tmp/PWNED)]`
  # executes arbitrary commands (dedup_key is the watchdog's own already-bound
  # loop variable, which is what lets the subscript evaluate instead of
  # tripping `set -u`'s unbound-variable guard first — proven live). Coerce
  # both to a validated base-10 integer HERE, at read time, so no unvalidated
  # value ever reaches arithmetic context downstream. A non-digit value (or
  # empty) resets to "0" rather than aborting the whole pass — same fail-safe
  # posture as every other malformed-field guard in this pack.
  # Trim surrounding whitespace first so a space-padded value like "  7  "
  # still coerces to 7 instead of tripping the non-numeric fail-safe below
  # (only real non-digit content should hit the "0" reset).
  ST_ATTEMPT_COUNT="${ST_ATTEMPT_COUNT#"${ST_ATTEMPT_COUNT%%[![:space:]]*}"}"
  ST_ATTEMPT_COUNT="${ST_ATTEMPT_COUNT%"${ST_ATTEMPT_COUNT##*[![:space:]]}"}"
  ST_ESCALATED="${ST_ESCALATED#"${ST_ESCALATED%%[![:space:]]*}"}"
  ST_ESCALATED="${ST_ESCALATED%"${ST_ESCALATED##*[![:space:]]}"}"
  case "$ST_ATTEMPT_COUNT" in
    *[!0-9]*|'') ST_ATTEMPT_COUNT="0" ;;
  esac
  case "$ST_ESCALATED" in
    *[!0-9]*|'') ST_ESCALATED="0" ;;
  esac
}

# state_write DEDUP_KEY IMPLEMENTOR INFLIGHT LAST_STATE [PR_AUTHOR] [REPAIR_ROUTE]
#             [REPO_FULL] [PR_NUMBER] [BRANCH] [ATTEMPT_COUNT] [ESCALATED]
#             [LAST_DISPATCH_AT]
# The extended fields are optional (default empty / 0) so every pre-Fix-2
# call site keeps working unmodified; every call site in both scripts now
# passes them explicitly (either fresh values or the prior ones read back via
# state_read, per call site) so the choice to reset vs. preserve is visible at
# the call site, not hidden in here.
state_write() {
  local dedup_key="$1" implementor="$2" inflight="$3" last_state="$4"
  local pr_author="${5:-}" repair_route="${6:-}" repo_full="${7:-}"
  local pr_number="${8:-}" branch="${9:-}" attempt_count="${10:-0}" escalated="${11:-0}"
  local last_dispatch_at="${12:-}"
  local state_file="${CV_STATE_DIR}/${dedup_key}.state"
  {
    printf 'implementor_session=%s\n' "$implementor"
    printf 'inflight_rework=%s\n' "$inflight"
    printf 'last_handled_state=%s\n' "$last_state"
    printf 'pr_author=%s\n' "$pr_author"
    printf 'repair_route=%s\n' "$repair_route"
    printf 'repo_full=%s\n' "$repo_full"
    printf 'pr_number=%s\n' "$pr_number"
    printf 'branch=%s\n' "$branch"
    printf 'attempt_count=%s\n' "${attempt_count:-0}"
    printf 'escalated=%s\n' "${escalated:-0}"
    printf 'last_dispatch_at=%s\n' "$last_dispatch_at"
  } > "$state_file"
  rm -f "${CV_STATE_DIR}/${dedup_key}.minted"
}

# now_iso8601 — current UTC time in the same ISO-8601 'Z' format is_stale()
# (con-voyage-repair-watchdog.sh) parses. Used to stamp last_dispatch_at.
now_iso8601() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# ---------------------------------------------------------------------------
# Per-dedup_key mutual exclusion (fk-11yuv Fix 2b, originally added to
# con-voyage-repair-watchdog.sh only; lifted here by fk-8b5fl so
# con-voyage-pr-watch.sh can wrap its own read-decide-write per dedup_key
# with the SAME lock instead of keeping a second copy of the algorithm).
# `mkdir` is atomic on every POSIX filesystem this pack runs on, so it
# doubles as a lock primitive without depending on `flock` (not reliably
# available on macOS).
#
# Both CV_STATE_DIR and CV_LOCK_STALE_SECONDS are read as globals AT CALL
# TIME, not at source time (see file header) — each caller's own
# Configuration block resolves them before acquire_lock/release_lock are
# ever invoked.
# ---------------------------------------------------------------------------

# acquire_lock DEDUP_KEY — exit 0 (lock held) or 1 (held by someone else and
# not stale). A stale lock (older than CV_LOCK_STALE_SECONDS — a crashed or
# hung holder) is stolen rather than left to wedge this record forever.
acquire_lock() {
  local dedup_key="$1"
  local lock_base="${CV_STATE_DIR}/.locks"
  local lockdir="${lock_base}/${dedup_key}.lock"
  mkdir -p "$lock_base" 2>/dev/null
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\n' "$$" > "${lockdir}/pid" 2>/dev/null || true
    return 0
  fi
  # Held already (or a crashed holder's leftover). A stale-looking lock can't
  # be reclaimed by "check mtime, then rm -rf + mkdir" (or even a single
  # atomic `mv` of it): a slow straggler's OWN staleness read can still be
  # acted on after a faster stealer has already replaced the lock with a
  # fresh one — mv/mkdir don't know the thing now at this path is a different
  # instance than the one the straggler judged stale. So steal ATTEMPTS are
  # serialized behind a second, fixed-path mkdir mutex that (unlike lockdir)
  # is never removed and recreated by the swap below, and only the winner of
  # that mutex checks staleness — fresh, right then, with no other swapper
  # able to race it — before ever touching lockdir.
  local steal_mutex="${lockdir}.stealing"
  if ! mkdir "$steal_mutex" 2>/dev/null; then
    return 1
  fi
  if python3 -c "
import os, sys, time
try:
    age = time.time() - os.stat(sys.argv[1]).st_mtime
except Exception:
    sys.exit(1)
sys.exit(0 if age > float(sys.argv[2]) else 1)
" "$lockdir" "${CV_LOCK_STALE_SECONDS:-300}" 2>/dev/null; then
    rm -rf "$lockdir" 2>/dev/null
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "${lockdir}/pid" 2>/dev/null || true
      echo "con-voyage-lib: NOTICE: stole stale lock for ${dedup_key} (>${CV_LOCK_STALE_SECONDS:-300}s; prior holder presumed dead)" >&2
      rm -rf "$steal_mutex" 2>/dev/null
      return 0
    fi
  fi
  rm -rf "$steal_mutex" 2>/dev/null
  return 1
}

# release_lock DEDUP_KEY — always safe to call even if the lock was never
# acquired (e.g. a caller that skipped straight past acquire_lock's failure).
release_lock() {
  local dedup_key="$1"
  rm -rf "${CV_STATE_DIR}/.locks/${dedup_key}.lock" 2>/dev/null || true
}

# bead_status BEAD_ID FIELD — prints "<status><0x1f><FIELD-value>". FIELD is
# any top-level key `bd show --json` returns (this pack asks for "assignee"
# or "updated_at"). A non-string JSON value (e.g. the
# `is_blocked` bool) is stringified ("True"/"False") rather than passed
# through raw — Python's `True or ''` short-circuits to `True`, and
# concatenating that against the leading status string used to raise
# TypeError, which the trailing `|| printf` fallback silently swallowed into
# an empty (indistinguishable from "not blocked") result (fk-16zsa iter-2
# BLOCKING-1). Empty SEP-only output for an empty bead id, a `bd show`
# failure, or a bead unknown to gc.
bead_status() {
  local bead_id="$1" field="$2"
  local SEP=$'\x1f'
  [ -n "${bead_id// /}" ] || { printf '%s' "$SEP"; return 0; }
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" bd show "$bead_id" --json 2>/dev/null) || json=""
  if [ -z "$json" ]; then printf '%s' "$SEP"; return 0; fi
  printf '%s' "$json" | python3 -c "
import sys, json
SEP = '\x1f'
field = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print(SEP)
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    print(SEP)
    raise SystemExit(0)
field_val = data.get(field)
field_val = '' if field_val is None else str(field_val)
print((data.get('status') or '') + SEP + field_val)
" "$field" 2>/dev/null || printf '%s' "$SEP"
}

# implementor_alive SESSION_IDENT — exit 0 if a session matching this
# identifier (checked against id/alias/name/session_name) exists and is not
# closed (both active and suspended count — mail persists regardless, and
# --notify attempts a wake either way; see Task 0 findings).
implementor_alive() {
  local ident="$1"
  [ -n "${ident// /}" ] || return 1
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" --city "$GC_CITY" session list --json 2>/dev/null) || json=""
  [ -n "$json" ] || return 1
  printf '%s' "$json" | python3 -c "
import sys, json
ident = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    sys.exit(1)
for s in sessions:
    if not isinstance(s, dict):
        continue
    idents = {s.get('id'), s.get('alias'), s.get('name'), s.get('session_name')}
    if ident in idents and (s.get('state') or '') != 'closed':
        sys.exit(0)
sys.exit(1)
" "$ident"
}

# session_id_for_ident IDENT — print the canonical session `id` of a live
# session (state != closed) whose id/alias/name/session_name matches IDENT.
# Empty output if none found. Shares implementor_alive's identity-matching
# rule but resolves to the `id` field specifically, since `gc session nudge`
# documents accepting only "a session ID or session alias" and a recorded
# identity (e.g. a bead's `assignee`) is often in the longer session_name
# form instead. Used by con-voyage-review-watchdog.sh (fk-loo1 FIX-F) to turn
# a claimed review-lane bead's assignee into a nudge-able session id.
session_id_for_ident() {
  local ident="$1"
  [ -n "${ident// /}" ] || return 0
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" --city "$GC_CITY" session list --json 2>/dev/null) || json=""
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c "
import sys, json
ident = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    raise SystemExit(0)
for s in sessions:
    if not isinstance(s, dict):
        continue
    idents = {s.get('id'), s.get('alias'), s.get('name'), s.get('session_name')}
    if ident in idents and (s.get('state') or '') != 'closed':
        print(s.get('id') or '')
        raise SystemExit(0)
" "$ident"
}

# cv_session_route_handle IDENT — print the rig-scoped `name` (falling back
# to `alias`) of a live session (state != closed) whose id/alias/name/
# session_name matches IDENT. Empty output if none found or not alive.
#
# WHY THIS EXISTS (review fk-pbadx BLOCKING-1): a bead's bare
# `gc.session_name` metadata (e.g. "gc__implementation-worker-rc-hd33p3") is
# the form `implementor_alive`/`gc mail send` match against, but `gc sling`
# rejects it live ("agent ... not found in city.toml") — it only resolves a
# rig-scoped handle in "<rig>/<agent>" or "<rig>/<agent>.<role>-N" form (a
# live session's own `name`/`alias` field, e.g.
# "foundry-kc/gc.implementation-worker-2"). That rig-scoped form is the only
# one verified to resolve for `implementor_alive`, `gc sling`, AND `gc mail
# send` simultaneously (it is still in the id/alias/name/session_name set
# implementor_alive checks), so callers that need a handle usable for ALL
# THREE — not just the liveness check — should resolve it through this
# function instead of reading gc.session_name directly.
cv_session_route_handle() {
  local ident="$1"
  [ -n "${ident// /}" ] || { printf ''; return 0; }
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" --city "$GC_CITY" session list --json 2>/dev/null) || json=""
  [ -n "$json" ] || { printf ''; return 0; }
  printf '%s' "$json" | python3 -c "
import sys, json
ident = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    raise SystemExit(0)
for s in sessions:
    if not isinstance(s, dict):
        continue
    idents = {s.get('id'), s.get('alias'), s.get('name'), s.get('session_name')}
    if ident in idents and (s.get('state') or '') != 'closed':
        print(s.get('name') or s.get('alias') or '')
        raise SystemExit(0)
" "$ident"
}

# first_alive_session_id_for_route ROUTE — print the `id` of the first live
# session (state != closed) whose `template` equals ROUTE (the "<rig>/<role>"
# form recorded as a lane bead's gc.routed_to metadata). Empty output means
# the routed pool has no live session at all — the unambiguous "pool is
# drained" signal con-voyage-review-watchdog.sh uses to decide re-route
# (gc sling) vs. a direct nudge to an already-alive pool member.
first_alive_session_id_for_route() {
  local route="$1"
  [ -n "${route// /}" ] || return 0
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" --city "$GC_CITY" session list --json 2>/dev/null) || json=""
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c "
import sys, json
route = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
sessions = data.get('sessions') if isinstance(data, dict) else data
if not isinstance(sessions, list):
    raise SystemExit(0)
for s in sessions:
    if not isinstance(s, dict):
        continue
    if (s.get('template') or '') == route and (s.get('state') or '') != 'closed':
        print(s.get('id') or '')
        raise SystemExit(0)
" "$route"
}

# close_if_open BEAD_ID REASON [PR_LABEL] [KNOWN_STATUS] [FORCE] — closes
# BEAD_ID if it is currently open (any status other than empty/unknown or
# "closed"). No-op if BEAD_ID is empty or already closed/unknown. When
# PR_LABEL is given, logs a standard SUPERSEDE line tagged with it
# (con-voyage-pr-watch.sh's 3 call sites, which share this one "read status,
# close if open, log" sequence across the clean-PR path, the genuinely-in-
# flight supersede, and the legacy stale-marker sweep); omitted, the caller
# logs its own labeled line instead (con-voyage-repair-watchdog.sh's call
# site). KNOWN_STATUS lets a caller that already fetched this SAME bead's
# status earlier in the same iteration (e.g. the watchdog's tracked-bead
# DEAD/STALLED branch, which already called `bead_status ... updated_at` to
# decide it needs closing) skip the redundant second `bd show` — when empty
# (the default), the status is fetched fresh, same as before.
#
# FORCE (fk-c1xa): when non-empty, retries with `--force` to `bd close` —
# but ONLY after confirming the assignee mismatch is actually the sole
# blocker. `bd close --force` is not assignee-scoped: per `bd close --help`
# it also "Force close[s] pinned issues or unsatisfied gates", and a plain
# `bd close` refuses a bead whose `assignee` differs from the caller's own
# actor ("cannot close %s: assignee is %q, actor is %q; reclaim or use
# --force to override") — con-voyage's own setup step claims a work bead as
# `con-voyage:work-bead`, so this monitor's own actor (e.g. "mayor") never
# matches and every close silently no-ops without --force. Live evidence:
# fk-8b5fl/#100, fk-htx5p/#101, fk-q2pon/#103, fk-o9ntx/#105 all sat
# in_progress with a merged PR and a live finalize record until force-closed
# by hand. Only pass FORCE for beads this monitor exclusively owns the
# lifecycle of once a PR reaches a terminal state (the work bead + its
# convoy) — never for a repair bead another lens/session may still be
# working, which is why every OTHER close_if_open call site in this pack
# leaves FORCE unset (unchanged behavior).
#
# fk-16zsa iter-2/3/4: three iterations in a row tried to detect a human
# `pinned` hold or an unresolved dependency/gate block by comparing the
# already-fetched `status` field against a literal string ("pinned",
# "blocked", `is_blocked`) — every one of those was dead code, because none
# of those states is what real `bd show --json` actually sets: `pinned` is
# an orthogonal flag never surfaced in `status` at all (only via `bd list
# --pinned`), and a genuinely dependency/gate-blocked bead's `status` stays
# `open`. This can't be a `status`-field compare, so instead it's
# BEHAVIOR-based: try a PLAIN `bd close` first (no --force) and inspect
# bd's own refusal text. Only retry with --force when bd refused for
# exactly the assignee-mismatch reason this FORCE param exists to override
# ("... reclaim or use --force to override"); any other refusal (a real
# pin, an unsatisfied gate, or anything else) is left alone — the bead
# stays open (non-zero CV_CLOSE_RC) for the caller's normal escalation path
# (fk-22bq4) instead of `bd close --force` silently overriding a hold it
# was never meant to.
#
# fk-16zsa iter-5: the behavior-based check above is not sufficient by
# itself. Real `bd` 1.3.0 returns the assignee-mismatch refusal text FIRST
# when a bead is BOTH assignee-mismatched and pinned/gate-blocked, so the
# pin/gate refusal is never emitted and the grep above matches anyway —
# `--force` fires and silently overrides the hold. Every FORCE call site
# hits this: con-voyage's setup step claims every work bead as
# `CV_WORK_BEAD_OWNER`, so this monitor's actor is *always*
# assignee-mismatched relative to the work bead, whether or not it is also
# held. Before retrying `--force` on an assignee-mismatch refusal, also
# positively confirm the bead is neither pinned nor gate-blocked via
# `bead_pinned_or_blocked` (the real primitives: `bd blocked` and `bd list
# --pinned`), not the refusal text alone.
#
# CV_CLOSE_RC (fk-7v3r): set on every call to the real `bd close` exit status
# — 0 for a no-op (empty id / already closed) and for a successful close,
# non-zero when `bd close` itself fails OR the FORCE path refuses to
# override a non-assignee refusal (fk-22bq4). The function's OWN return value
# stays 0 in every case: con-voyage-pr-watch.sh calls this as a bare statement
# under `set -e` and must never abort mid-scan over a single PR's failed
# close. A caller that must not proceed past a failed close (e.g.
# con-voyage-finalize.sh deleting its retry record) checks CV_CLOSE_RC
# immediately after the call instead of the call's own return code.
# bead_pinned_or_blocked BEAD_ID — exit 0 (true) if BEAD_ID is currently
# pinned (`bd list --pinned`) or dependency/gate-blocked (`bd blocked`).
# close_if_open's FORCE path uses this to distinguish "assignee-mismatched
# only" (safe to --force) from "assignee-mismatched AND held" (must not
# --force) once bd's own refusal text is ambiguous between the two (see
# close_if_open's header comment, fk-16zsa iter-5).
#
# FAIL-SAFE: exit 0 (treated as pinned/blocked, i.e. refuse to force) for an
# empty BEAD_ID or either `bd` lookup failing/returning unparseable JSON —
# force-closing a bead this check failed to positively clear is the unsafe
# direction, unlike cv_lane_has_open_blocking_dependency above where
# fail-safe means "take no watchdog action".
bead_pinned_or_blocked() {
  local bead_id="$1"
  [ -n "${bead_id// /}" ] || return 0
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" bd blocked --json 2>/dev/null) || {
    echo "bead_pinned_or_blocked: WARNING: bd blocked lookup failed for ${bead_id}; treating as blocked" >&2
    return 0
  }
  if printf '%s' "$json" | python3 -c "
import sys, json
bead_id = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for item in data:
    if isinstance(item, dict) and item.get('id') == bead_id:
        sys.exit(0)
sys.exit(1)
" "$bead_id"; then
    return 0
  fi

  json=$("$gc_bin" bd list --pinned --json 2>/dev/null) || {
    echo "bead_pinned_or_blocked: WARNING: bd list --pinned lookup failed for ${bead_id}; treating as blocked" >&2
    return 0
  }
  if printf '%s' "$json" | python3 -c "
import sys, json
bead_id = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for item in data:
    if isinstance(item, dict) and item.get('id') == bead_id:
        sys.exit(0)
sys.exit(1)
" "$bead_id"; then
    return 0
  fi

  return 1
}

close_if_open() {
  local bead_id="$1" reason="$2" pr_label="${3:-}" known_status="${4:-}" force="${5:-}"
  CV_CLOSE_RC=0
  [ -n "${bead_id// /}" ] || return 0
  local bead_state="$known_status"
  if [ -z "$bead_state" ]; then
    IFS=$'\x1f' read -r bead_state _ <<< "$(bead_status "$bead_id" assignee)"
  fi
  [ -n "$bead_state" ] && [ "$bead_state" != "closed" ] || return 0
  local gc_bin="${GC:-gc}"

  local close_output close_rc
  if [ -n "$force" ]; then
    if close_output="$("$gc_bin" bd close "$bead_id" --reason "$reason" 2>&1)"; then
      close_rc=0
    else
      close_rc=$?
      if printf '%s' "$close_output" | grep -q -- 'reclaim or use --force to override' \
         && ! bead_pinned_or_blocked "$bead_id"; then
        if close_output="$("$gc_bin" bd close "$bead_id" --reason "$reason" --force 2>&1)"; then
          close_rc=0
        else
          close_rc=$?
        fi
      else
        CV_CLOSE_RC=1
        echo "close_if_open: WARNING: refusing to --force close ${bead_id} (status=${bead_state}); bd close refused for a non-assignee reason, likely a pin or unsatisfied gate, leaving it open for retry/escalation: ${close_output}" >&2
        return 0
      fi
    fi
  else
    if close_output="$("$gc_bin" bd close "$bead_id" --reason "$reason" 2>&1)"; then
      close_rc=0
    else
      close_rc=$?
    fi
  fi

  if [ "$close_rc" -eq 0 ]; then
    if [ -n "$pr_label" ]; then
      echo "con-voyage-pr-watch: [PART A] ${pr_label}: closed prior open repair bead ${bead_id} (was status=${bead_state})"
    fi
    if [ -n "$force" ] && [ -n "$close_output" ]; then
      echo "close_if_open: --force close of ${bead_id} succeeded; bd close output: ${close_output}"
    fi
  else
    CV_CLOSE_RC=$close_rc
    echo "close_if_open: WARNING: bd close failed for ${bead_id} (status=${bead_state}, rc=${CV_CLOSE_RC}); leaving it open for retry" >&2
    if [ -n "$close_output" ]; then
      echo "close_if_open: bd close output: ${close_output}" >&2
    fi
  fi
  return 0
}

# cv_close_workflow_root ROOT_BEAD_ID REASON — full teardown of a graph.v2
# workflow's root bead and every other still-OPEN bead tagged with its
# `gc.root_bead_id` (fk-bkz94: con-voyage-finalize used to close only the
# dashboard-facing work bead + synthetic input convoy on PR land — three
# SEPARATE beads from the graph.v2 compiled root the con-voyage formula
# actually runs under. The root stayed in_progress forever and its review
# loop kept dispatching fresh synthesis/apply-review-findings rounds against
# an already-merged PR, because nothing ever told that workflow the PR had
# landed).
#
# Sweeps descendants FIRST (best-effort: a hiccup here must never block
# retrying the root-bead close below, and a lane/step bead another lens may
# still be mid-task on is left alone by close_if_open's own pin/gate check —
# same safety net every other FORCE close in this pack relies on), then
# closes the root bead itself.
#
# CV_CLOSE_RC reflects ONLY the root bead's own close outcome — the gate a
# caller checks before treating this workflow as fully torn down and
# discarding its retry record, mirroring close_if_open's own CV_CLOSE_RC
# contract. The descendant sweep's own failures are logged, not gated: an
# orphaned lane bead this sweep could not close must not block the root
# bead (and therefore the caller's finalize record) from ever completing.
cv_close_workflow_root() {
  local root_id="$1" reason="$2"
  CV_CLOSE_RC=0
  [ -n "${root_id// /}" ] || return 0
  local gc_bin="${GC:-gc}"

  local list_json
  list_json=$("$gc_bin" bd list --status open --metadata-field "gc.root_bead_id=${root_id}" --json --limit 0 2>/dev/null) || list_json=""
  if [ -n "$list_json" ]; then
    local ids
    ids=$(printf '%s' "$list_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for item in data:
    if isinstance(item, dict) and item.get('id'):
        print(item['id'])
" 2>/dev/null) || ids=""
    if [ -n "${ids// /}" ]; then
      while IFS= read -r descendant_id; do
        [ -n "${descendant_id// /}" ] || continue
        close_if_open "$descendant_id" "$reason" "" "open" 1
        if [ "$CV_CLOSE_RC" -ne 0 ]; then
          echo "cv_close_workflow_root: WARNING: could not close descendant ${descendant_id} of root ${root_id} (continuing sweep)" >&2
        fi
      done <<< "$ids"
    fi
  else
    echo "cv_close_workflow_root: WARNING: could not list open descendants of root ${root_id} (bd list failed); sweeping root bead only" >&2
  fi

  # Close the root bead itself LAST — CV_CLOSE_RC from here on is what the
  # caller's completion gate reads, independent of the descendant sweep above.
  close_if_open "$root_id" "$reason" "" "" 1
}

# ===========================================================================
# GLOBAL BEAD-STATE-EVENT HELPERS (fk-7mw7 FIX-A)
#
# OPERATOR DIRECTIVE (north star): beads MUST update deterministically on
# formula STATE EVENTS as a GLOBAL pack norm — a step/work bead goes
# in_progress when its step starts (never left sitting at READY) and CLOSES on
# terminal (landed / abandoned / no-op / superseded). These two helpers are
# the foundation every workflow step in this pack should call at claim time
# and at each terminal exit, instead of hand-rolling `bd update`/`bd close`
# per call site. The primary consumer is con-voyage-ci-repair (the "Repair
# GitHub PR ..." bead that con-voyage-pr-watch.sh mints and slings the ci-repair
# formula onto): that workflow closed only `{{convoy_id}}` — a gc-internal
# work-item id, NOT the human-facing repair bead — at every exit, so the
# repair bead itself was left open forever. That was the #1 driver of a batch
# of orphaned ko-*/va-* repair beads found in a live sweep.
# ===========================================================================

# cv_bead_mark_in_progress BEAD_ID — idempotently claim BEAD_ID (assignee=you,
# status=in_progress) the moment a step starts working it, so a routed bead is
# never left sitting at READY for the duration of the work. `bd update
# --claim` is already idempotent for the same actor (see con-voyage's own
# {target}.setup-con-voyage-review.md "Claim -> in_progress (idempotent)"
# precedent), so this does not special-case an already-in_progress bead —
# re-claiming it is a harmless no-op. It DOES pre-check existence/terminal
# state (below) before calling `bd update` at all.
#
# FAIL-SAFE: warns to stderr and no-ops — never aborts the caller — for an
# empty BEAD_ID, a bead unknown to `bd show` (gc hiccup or bad id), or a bead
# that is already closed (a terminal bead never reopens here). A `bd update`
# failure itself is also swallowed (warn only) so a transient gc/bd error
# never fails the step that is just trying to mark its own progress.
cv_bead_mark_in_progress() {
  local bead_id="$1"
  [ -n "${bead_id// /}" ] || { echo "cv_bead_mark_in_progress: empty bead id, skipping" >&2; return 0; }
  local bead_state
  IFS=$'\x1f' read -r bead_state _ <<< "$(bead_status "$bead_id" assignee)"
  if [ -z "$bead_state" ]; then
    echo "cv_bead_mark_in_progress: bead ${bead_id} not found, skipping" >&2
    return 0
  fi
  if [ "$bead_state" = "closed" ]; then
    echo "cv_bead_mark_in_progress: bead ${bead_id} already closed, skipping" >&2
    return 0
  fi
  local gc_bin="${GC:-gc}"
  "$gc_bin" bd update "$bead_id" --claim >/dev/null 2>&1 \
    || echo "cv_bead_mark_in_progress: failed to claim ${bead_id}" >&2
  return 0
}

# cv_bead_close BEAD_ID OUTCOME REASON — idempotently close BEAD_ID with a
# reason stamped "<OUTCOME>: <REASON>" (mirrors cv_close_reason_for_pr's
# existing "landed: PR #N merged" / "abandoned: PR #N closed without merge"
# shape, so every bead-close reason in this pack reads the same way). OUTCOME
# is the GLOBAL pack vocabulary from the OPERATOR DIRECTIVE above: landed |
# abandoned | no-op | superseded — this helper does not hard-enforce the enum,
# a caller passes whichever token fits its own terminal state.
#
# FAIL-SAFE: warns to stderr and no-ops — never aborts the caller — for an
# empty BEAD_ID, a bead unknown to `bd show`, or a bead that is already closed
# (idempotent: re-running the same terminal exit twice never errors). A
# `bd close` failure itself is also swallowed (warn only).
cv_bead_close() {
  local bead_id="$1" outcome="$2" reason="$3"
  [ -n "${bead_id// /}" ] || { echo "cv_bead_close: empty bead id, skipping" >&2; return 0; }
  local bead_state
  IFS=$'\x1f' read -r bead_state _ <<< "$(bead_status "$bead_id" assignee)"
  if [ -z "$bead_state" ]; then
    echo "cv_bead_close: bead ${bead_id} not found, skipping" >&2
    return 0
  fi
  if [ "$bead_state" = "closed" ]; then
    echo "cv_bead_close: bead ${bead_id} already closed, skipping" >&2
    return 0
  fi
  local gc_bin="${GC:-gc}"
  "$gc_bin" bd close "$bead_id" --reason "${outcome}: ${reason}" >/dev/null 2>&1 \
    || echo "cv_bead_close: failed to close ${bead_id}" >&2
  return 0
}

# cv_sweep_repair_beads_by_title REPO PR_NUMBER REASON [EXCLUDE_ID] — close
# EVERY still-open bead whose title matches "Repair GitHub PR
# <REPO>#<PR_NUMBER> (" (case-insensitive), other than EXCLUDE_ID (when given —
# a bead the caller already closed itself, e.g. its ".state" record's own
# tracked inflight_rework; skipping it here avoids one redundant close call,
# since cv_bead_close already checks live status before acting either way).
# This covers orphans regardless of whether they are the one this monitor's
# own ".state" record currently tracks (fk-nrfio: replicated-docs accumulated
# 212 open,
# unassigned repair beads for the SAME merged PR #4580 because the per-PR
# ".state" record's `inflight_rework` field is overwritten on every re-mint —
# ONLY the most recently minted bead is ever tracked, so every earlier mint
# from a retry storm — e.g. the fk-zvkmd unbounded-retry window, before the
# mint-attempt cap landed — falls out of tracking and is orphaned forever, even
# though the ".state" record itself still exists and still resolves this PR).
#
# `bd list --title-contains` is a case-insensitive substring match, so a bare
# "PR <repo>#83" would also match "#830", "#831", etc. Anchoring on the
# trailing " (" (the literal character that always follows the PR number in
# the title this pack mints — see con-voyage-pr-watch.sh's `repair_title`)
# makes the match exact on the PR number while still being agnostic to the
# failure_kind/title text that follows.
#
# FAIL-SAFE: an empty REPO/PR_NUMBER, a `bd list` failure, or no matches is a
# silent no-op — never aborts the caller. Each matched bead is closed via
# cv_bead_close (outcome "superseded"), which is itself idempotent, so running
# this twice (e.g. once from the ".finalize" work-bead loop and once from the
# ".state" repair loop for the same repo+PR) is always safe: the second call
# finds nothing left open.
cv_sweep_repair_beads_by_title() {
  local repo="$1" pr_number="$2" reason="$3" exclude_id="${4:-}"
  [ -n "${repo// /}" ] && [ -n "${pr_number// /}" ] || return 0
  case "$pr_number" in
    ''|*[!0-9]*) return 0 ;;
  esac
  local gc_bin="${GC:-gc}"
  local title_prefix="Repair GitHub PR ${repo}#${pr_number} ("
  local json
  json=$("$gc_bin" bd list --title-contains "$title_prefix" --limit 0 --json 2>/dev/null) || json=""
  [ -n "$json" ] || return 0
  local ids
  ids=$(printf '%s' "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if isinstance(data, dict):
    data = data.get('issues') or data.get('items') or []
if not isinstance(data, list):
    data = []
for item in data:
    if isinstance(item, dict) and item.get('id'):
        print(item['id'])
" 2>/dev/null) || ids=""
  [ -n "${ids// /}" ] || return 0
  while IFS= read -r id; do
    [ -n "${id// /}" ] || continue
    [ -n "${exclude_id// /}" ] && [ "$id" = "$exclude_id" ] && continue
    cv_bead_close "$id" "superseded" "$reason"
  done <<< "$ids"
  return 0
}

# ===========================================================================
# WORK-BEAD LIFECYCLE HELPERS (fk-p7j9 / fk-hsca)
#
# The helpers above track REPAIR beads (CI failures). The helpers below track
# the WORK BEAD itself — the bead a con-voyage delivers — across its full
# lifecycle (setup -> reviewing -> awaiting_merge -> closed on PR land) so it
# moves on the dashboard, carries a real description, and is closed when its PR
# merges/closes instead of sitting open forever.
#
# Bead-id note (verified against a live con-voyage run, fk-c0t): the con-voyage
# graph.v2 formula's `{{convoy_id}}` token resolves to a SYNTHETIC input convoy
# (e.g. fk-8ba: `gc.synthetic=true`, `issue_type=convoy`) that `tracks` the REAL
# work bead (e.g. fk-2co). cv_resolve_work_bead() below maps convoy_id -> the
# real work bead; the con-voyage-finalize monitor and the con-voyage workflow
# steps both go through it so the lifecycle acts on the right bead.
# ===========================================================================

# cv_resolve_work_bead CONVOY_ID — print the REAL work bead id for a con-voyage
# `{{convoy_id}}`. If CONVOY_ID is a synthetic input convoy (or otherwise an
# issue_type=convoy bead), the work bead is its first `tracks` dependency;
# otherwise CONVOY_ID is already the work bead and is echoed unchanged.
#
# FAIL-SAFE: on any error (empty id, `bd show` failure, unparseable JSON, no
# dependency found) this echoes the INPUT id unchanged rather than an empty
# string, so a caller never accidentally runs a lifecycle `bd` command against
# an empty/garbage id. A caller that must distinguish "resolved to a different
# bead" from "fell back to the input" can compare the output to the input.
cv_resolve_work_bead() {
  local convoy_id="$1"
  [ -n "${convoy_id// /}" ] || { printf '%s' "$convoy_id"; return 0; }
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" bd show "$convoy_id" --json 2>/dev/null) || json=""
  if [ -z "$json" ]; then printf '%s' "$convoy_id"; return 0; fi
  printf '%s' "$json" | python3 -c "
import sys, json
convoy_id = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print(convoy_id); raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    print(convoy_id); raise SystemExit(0)
meta = data.get('metadata') or {}
synthetic = str(meta.get('gc.synthetic', '')).lower() in ('true', '1', 'yes')
is_convoy = (data.get('issue_type') or '') == 'convoy'
if synthetic or is_convoy:
    for dep in (data.get('dependencies') or []):
        if not isinstance(dep, dict):
            continue
        # A single-item input convoy 'tracks' exactly one work bead. Prefer a
        # 'tracks' edge; fall back to the first dependency id if the type field
        # is absent (older records) but never to an empty/self id.
        dtype = dep.get('dependency_type') or dep.get('type') or ''
        dep_id = dep.get('id') or ''
        if dep_id and dep_id != convoy_id and (dtype == 'tracks' or dtype == ''):
            print(dep_id); raise SystemExit(0)
    # Convoy with no usable dependency — fail safe to the input id.
    print(convoy_id); raise SystemExit(0)
# Not a convoy: convoy_id is already the work bead.
print(convoy_id)
" "$convoy_id" 2>/dev/null || printf '%s' "$convoy_id"
}

# cv_bead_work_dir BEAD_ID — print BEAD_ID's `work_dir` metadata value: the
# absolute worktree path do-work's prepare-worktree step (and, for a fresh
# con-voyage build, the con-voyage build phase itself — fk-9aunv) persists on
# a source anchor bead via `bd update <id> --set-metadata work_dir=<path>`.
# Note this is the BARE `work_dir` key, not `gc.`-namespaced — it must match
# the key do-work/prepare-worktree.md writes so a prior do-work build on the
# same convoy is discoverable.
#
# FAIL-SAFE: prints empty — never aborts the caller — for an empty BEAD_ID, a
# bead unknown to `bd show`, unparseable JSON, or the field simply unset. An
# empty result is itself meaningful ("no worktree resolved yet"), so callers
# branch on it directly instead of treating it as an error.
cv_bead_work_dir() {
  local bead_id="$1"
  [ -n "${bead_id// /}" ] || { printf ''; return 0; }
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" bd show "$bead_id" --json 2>/dev/null) || json=""
  [ -n "$json" ] || { printf ''; return 0; }
  printf '%s' "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    raise SystemExit(0)
meta = data.get('metadata') or {}
val = meta.get('work_dir') or ''
if isinstance(val, str):
    print(val)
" 2>/dev/null
}

# cv_find_prior_built_anchor WORK_BEAD_ID EXCLUDE_CONVOY_ID — among every
# convoy that already `tracks` WORK_BEAD_ID (excluding EXCLUDE_CONVOY_ID —
# normally the CURRENT sling's own fresh input convoy), find the newest one
# that both carries a `work_dir` metadata value and has `cv-worktree-prep.sh
# built` confirm that worktree's HEAD is ahead of its base. Prints "<anchor_id>
# <work_dir>" (space-separated, one line) for the first such match, or
# nothing if none qualify.
#
# fk-ki8je: a fresh `gc sling ... --on con-voyage` always creates a NEW input
# convoy with no work_dir of its own — do-work closes ITS OWN source anchor
# when it finishes, so that state never carries onto the fresh convoy, and
# {target}.prepare-build.md's short-circuit (which only ever checked THIS
# convoy's own work_dir via cv_bead_work_dir) never fired for the normal
# do-work -> con-voyage handoff. This is the missing half: the work bead's
# OTHER `tracks` dependents — its past source anchors, closed or still open —
# are exactly where that finished state actually lives.
#
# Sort key is each candidate's own `created_at`; bd's ISO-8601 UTC timestamps
# compare correctly as plain strings, so no date parsing is needed. When
# several candidates qualify, this picks the newest and logs every candidate
# it rejects along the way (to stderr) plus the one it finally chooses.
#
# FAIL-SAFE: prints nothing (never aborts) for an empty WORK_BEAD_ID, a `bd
# show` failure, no qualifying dependents, or a missing/non-executable
# cv-worktree-prep.sh — every fail-safe outcome means "build fresh instead",
# never a hard error. Does not itself check `EXCLUDE_CONVOY_ID`'s own
# work_dir — that is cv_bead_work_dir's job, left to the caller exactly as
# prepare-build.md already does it, so this function only ever answers "is
# there an EARLIER anchor to reuse".
cv_find_prior_built_anchor() {
  local work_bead_id="$1" exclude_id="${2:-}"
  [ -n "${work_bead_id// /}" ] || return 0
  local gc_bin="${GC:-gc}"

  local prep_script
  prep_script="$(cv_pack_script cv-worktree-prep.sh)"
  if [ -z "$prep_script" ] || [ ! -x "$prep_script" ]; then
    echo "cv-lib: cv_find_prior_built_anchor: cv-worktree-prep.sh not found — skipping prior-anchor reuse" >&2
    return 0
  fi

  local json
  json=$("$gc_bin" bd show "$work_bead_id" --json --include-dependents 2>/dev/null) || json=""
  [ -n "$json" ] || return 0

  local ids
  ids="$(printf '%s' "$json" | python3 -c '
import sys, json
exclude_id = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    raise SystemExit(0)
for dep in (data.get("dependents") or []):
    if not isinstance(dep, dict):
        continue
    dep_id = dep.get("id") or ""
    dtype = dep.get("dependency_type") or ""
    if dep_id and dep_id != exclude_id and dtype == "tracks":
        print(dep_id)
' "$exclude_id" 2>/dev/null)"
  [ -n "$ids" ] || return 0

  # Enrich each candidate id with its own created_at + work_dir via a direct
  # bd show (the --include-dependents summary above does not reliably carry
  # per-dependent timestamps). A plain command substitution around the whole
  # loop captures its stdout correctly regardless of bash/zsh pipeline-subshell
  # differences — no variable needs to survive past the loop itself.
  local rows
  rows="$(
    printf '%s\n' "$ids" | while IFS= read -r cand_id; do
      [ -n "$cand_id" ] || continue
      cjson=$("$gc_bin" bd show "$cand_id" --json 2>/dev/null) || continue
      [ -n "$cjson" ] || continue
      printf '%s' "$cjson" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    raise SystemExit(0)
meta = data.get("metadata") or {}
work_dir = meta.get("work_dir") or ""
created = data.get("created_at") or ""
bead_id = data.get("id") or ""
if work_dir and bead_id:
    print("%s\t%s\t%s" % (created, bead_id, work_dir))
'
    done
  )"
  [ -n "$rows" ] || return 0

  local created cand_id work_dir
  while IFS=$'\t' read -r created cand_id work_dir; do
    [ -n "$cand_id" ] || continue
    if [ -d "$work_dir" ] && "$prep_script" built "$work_dir" >&2; then
      echo "cv-lib: cv_find_prior_built_anchor: chose ${cand_id} at ${work_dir} (created ${created})" >&2
      printf '%s %s\n' "$cand_id" "$work_dir"
      return 0
    fi
    echo "cv-lib: cv_find_prior_built_anchor: candidate ${cand_id} at ${work_dir:-<unset>} is not usable (missing dir or not ahead of base) — checking older candidates" >&2
  done < <(printf '%s\n' "$rows" | LC_ALL=C sort -r)

  echo "cv-lib: cv_find_prior_built_anchor: no qualifying prior anchor found for ${work_bead_id}" >&2
  return 0
}

# cv_anchor_too_stale DIR [MAX_BEHIND] [BASE-REF] — fk-2klp2: the staleness
# guard prepare-build runs before short-circuiting onto an adopted
# source-anchor branch (either the current convoy's own EXISTING_WORK_DIR, or
# an earlier anchor found via cv_find_prior_built_anchor).
#
# EVIDENCE (fk-0f1 / con-voyage root fk-vzgjt, 2026-09-30): prepare-build
# adopted a work bead's old source-anchor branch that was ~146 commits behind
# origin/main (built on release 0.5.0), with no staleness guard, so it
# short-circuited straight into the review pipeline and could only end in a
# big rebase conflict.
#
# Prints "<behind_count> <would_conflict:0|1>" on stdout and returns 0 (TOO
# STALE — do not short-circuit) when EITHER:
#   - DIR is more than MAX_BEHIND commits behind the resolved base, or
#   - a non-destructive merge-tree check says merging DIR onto the base would
#     conflict.
# Returns 1 (fine to adopt) otherwise, INCLUDING the fail-safe case where no
# base ref can be resolved at all — an unmeasurable anchor is not proof of
# staleness.
#
# MAX_BEHIND: an empty or non-numeric value falls back to the
# CV_STALE_ANCHOR_MAX_BEHIND env var, then to a built-in default of 50.
#
# Delegates the two underlying measurements to cv-worktree-prep.sh's own
# behind-count/would-conflict subcommands (already unit-tested directly in
# tests/cv-worktree-prep.test.sh) rather than reimplementing the git plumbing
# here.
cv_anchor_too_stale() {
  local dir="$1" max_behind="${2:-}" base_arg="${3:-}"

  local prep_script
  prep_script="$(cv_pack_script cv-worktree-prep.sh)"
  if [ -z "$prep_script" ] || [ ! -x "$prep_script" ]; then
    echo "cv-lib: cv_anchor_too_stale: cv-worktree-prep.sh not found — failing safe (not stale)" >&2
    return 1
  fi

  case "$max_behind" in
    ''|*[!0-9]*) max_behind="${CV_STALE_ANCHOR_MAX_BEHIND:-50}" ;;
  esac
  case "$max_behind" in
    ''|*[!0-9]*) max_behind=50 ;;
  esac

  local behind_count behind_rc
  behind_count="$("$prep_script" behind-count "$dir" "$base_arg" 2>/dev/null)"
  behind_rc=$?
  if [ "$behind_rc" -ne 0 ]; then
    echo "cv-lib: cv_anchor_too_stale: no base ref resolved for ${dir} — failing safe (not stale)" >&2
    return 1
  fi
  case "$behind_count" in
    ''|*[!0-9]*) behind_count=0 ;;
  esac

  local would_conflict=0
  if "$prep_script" would-conflict "$dir" "$base_arg" >/dev/null 2>&1; then
    would_conflict=1
  fi

  printf '%s %s\n' "$behind_count" "$would_conflict"

  if [ "$behind_count" -gt "$max_behind" ] || [ "$would_conflict" = "1" ]; then
    return 0
  fi
  return 1
}

# cv_discard_stale_anchor_worktree DIR BRANCH_NAME — review con-voyage/fk-29ts8
# iteration 3 BLOCKING-1/BLOCKING-3: the fix for a too-stale EXISTING_WORK_DIR
# (DIR == DEFAULT_WORKTREE for a convoy's own anchor) must not just remove the
# worktree directory — `git worktree remove` never deletes the branch ref, so
# BRANCH_NAME survives at the stale commit and the downstream
# `git worktree add --detach HEAD` + `cv-worktree-prep.sh ensure-branch`
# sequence then finds that stale ref already pointing somewhere other than the
# fresh detached HEAD and refuses to move it (`ensure-branch` `die`s), turning
# "rebuild fresh" into "abort the whole build." Deleting the stale branch ref
# here lets ensure-branch recreate it fresh, matching the prior-anchor path's
# behavior (its branch never survives because it is never DEFAULT_WORKTREE's
# own ref).
#
# Also surfaces (not silently discards) a dirty tree or an in-progress
# rebase/merge in DIR before the force-remove: `git worktree remove --force`
# bypasses git's normal refusal to touch a worktree with uncommitted state,
# and this exact scenario (a too-stale anchor left mid an interrupted rebase)
# has already happened once in this codebase (review-fix-summary.md,
# iteration-2 apply pass) with zero observability.
#
# Returns 0 and removes both the worktree and BRANCH_NAME's ref on success.
# Returns 1 (and leaves DIR in place) if `git worktree remove --force` fails —
# the caller must treat that as fatal, same as before this helper existed.
cv_discard_stale_anchor_worktree() {
  local dir="$1" branch_name="$2"

  local dirty_state=""
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    dirty_state="uncommitted change(s)"
  fi
  if git -C "$dir" rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1; then
    dirty_state="${dirty_state:+${dirty_state}, }an in-progress rebase"
  fi
  if git -C "$dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    dirty_state="${dirty_state:+${dirty_state}, }an in-progress merge"
  fi
  if [ -n "$dirty_state" ]; then
    echo "cv-lib: cv_discard_stale_anchor_worktree: removing too-stale worktree ${dir} with ${dirty_state} — discarding them" >&2
  fi

  git worktree remove --force "$dir" || return 1
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  return 0
}

# cv_dependency_outcome BEAD_ID DEP_TITLE — print the `gc.outcome` metadata
# value of BEAD_ID's direct dependency whose `title` exactly matches
# DEP_TITLE, or empty if no such dependency exists, it has no recorded
# outcome, or anything fails to resolve.
#
# WHY MATCH BY TITLE: a formula step's `title` is the static string set once
# in its formula TOML (`title = "..."`), stable across every attempt. Its
# `gc.step_ref`/`gc.control_for` are not: a ralph-wrapped (checked/retried)
# step gains a per-attempt `iteration.N` suffix while a plain step's
# `gc.step_ref` has no such suffix, so the same key means different things on
# different step types. Title is the one identifier both share (fk-03g4s).
#
# WHY THIS EXISTS: a `needs` edge in graph.v2 is satisfied once the upstream
# bead is CLOSED, regardless of its outcome — a failed prepare-build does not,
# by itself, stop the build step from being routed and claimed. build.md and
# setup-con-voyage-review.md call this to check their own direct dependency's
# outcome BEFORE doing any real investigation, so a known-failed upstream step
# is a near-free close instead of a full worktree/context investigation
# (fk-03g4s: a torn-down run burned a claim + investigation on every
# downstream step before a human intervened).
#
# FAIL-SAFE: prints empty — never aborts the caller — on any lookup failure.
# Callers must treat empty as "unknown", not "confirmed pass": only skip work
# when this prints a non-empty value that is not "pass".
cv_dependency_outcome() {
  local bead_id="$1" dep_title="$2"
  : "${GC:=gc}"
  [ -n "${bead_id// /}" ] || { printf ''; return 0; }
  local json
  json=$("$GC" bd show "$bead_id" --json 2>/dev/null) || json=""
  [ -n "$json" ] || { printf ''; return 0; }
  printf '%s' "$json" | python3 -c "
import sys, json
title = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    raise SystemExit(0)
for dep in (data.get('dependencies') or []):
    if not isinstance(dep, dict):
        continue
    if dep.get('title') == title:
        meta = dep.get('metadata') or {}
        val = meta.get('gc.outcome') or ''
        if isinstance(val, str):
            print(val)
        raise SystemExit(0)
" "$dep_title" 2>/dev/null
}

# cv_bead_metadata BEAD_ID KEY — print BEAD_ID's metadata[KEY] value (a string
# printed as-is; any other JSON type re-encoded as JSON), or empty when the
# bead is unknown, bd show fails, the JSON is unparseable, or KEY is absent.
# Fail-safe: never aborts the caller. Also defaults $GC to "gc" itself (fk-4q6ib
# BLOCKING-2) rather than trusting every caller to set it first — a caller-side
# omission (main.publish.md did not) silently resolved this to an empty binary
# name and made the whole call a no-op.
#
# WHY THIS EXISTS (fk-4q6ib): a `{var}`-style token in a description_file only
# gets substituted when gc inlines that file's content into the bead body —
# and gc does NOT inline a description_file above its own size threshold
# (confirmed: a real dispatched bead whose description_file was 8130 bytes
# rendered only the generic "External Prompt Required" wrapper, never the
# file's own content). Every step template in this pack is well above that
# threshold, so a `{convoy_id}` (or similar) token inside one is a permanent
# no-op, not a rendering nuance to work around with different brace styles.
# The only reliable way to get a per-instance value into such a step is to
# read it back from bead metadata at runtime — this is the shared primitive
# for that, generalizing the single-key readers already in this file
# (cv_bead_work_dir's bare `work_dir`, the inline gc.root_bead_id lookup
# duplicated across build.md/prepare-build.md/publish.md/setup-review.md).
cv_bead_metadata() {
  local bead_id="$1" key="$2"
  [ -n "${bead_id// /}" ] || { printf ''; return 0; }
  local gc_bin="${GC:-gc}"
  local json
  json=$("$gc_bin" bd show "$bead_id" --json 2>/dev/null) || json=""
  [ -n "$json" ] || { printf ''; return 0; }
  printf '%s' "$json" | python3 -c "
import sys, json
key = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    raise SystemExit(0)
meta = data.get('metadata') or {}
if key not in meta or meta[key] is None:
    raise SystemExit(0)
val = meta[key]
print(val if isinstance(val, str) else json.dumps(val))
" "$key" 2>/dev/null
}

# cv_flatten_roster_vars_from_json RAW_VARS_JSON -> prints
# "key=value,key=value,..." built from RAW_VARS_JSON (a gc.graphv2_vars.v1
# metadata value, itself a JSON object of formula vars), restricted to the
# enable_*/code_lens/implementation_target/cv_lens_* keys a later re-review
# round needs to reproduce the SAME multi-lens roster against a new commit
# (fk-pubvq). Empty input or unparseable JSON -> empty output (fail-safe).
#
# This is the pure transform shared by cv_flatten_roster_vars below (used by
# main.publish.md, which reads metadata with no --city flag like every other
# bare "gc bd show" call in that file) and con-voyage-rereview-watch.sh's own
# flatten_roster_vars (which must keep its "$GC" --city "$GC_CITY" bd show
# call — it runs outside the rig's own cwd). The two callers' bd-show
# invocations legitimately differ; only the JSON-parse-and-filter logic was
# duplicated, and had already drifted cosmetically between them (review
# fk-n74o9 BLOCKING-2).
cv_flatten_roster_vars_from_json() {
  local raw="${1:-}"
  [ -n "$raw" ] || raw='{}'
  printf '%s' "$raw" | python3 -c "
import json, sys
try:
    vars_ = json.loads(sys.stdin.read() or '{}')
except Exception:
    vars_ = {}
if not isinstance(vars_, dict):
    vars_ = {}
keep_exact = ('code_lens', 'implementation_target', 'cv_lens_claim_seconds',
              'cv_lens_max_redispatch', 'cv_lens_escalate_target')
parts = []
for k in sorted(vars_):
    if k in keep_exact or k.startswith('enable_'):
        parts.append('{}={}'.format(k, vars_[k]))
print(','.join(parts))
" 2>/dev/null
}

# cv_flatten_roster_vars ROOT_BEAD_ID -> cv_flatten_roster_vars_from_json
# applied to ROOT_BEAD_ID's own gc.graphv2_vars.v1 metadata (read via
# cv_bead_metadata, no --city flag). Empty on any resolution failure.
cv_flatten_roster_vars() {
  local root_bead_id="$1"
  [ -n "${root_bead_id// /}" ] || { printf ''; return 0; }
  cv_flatten_roster_vars_from_json "$(cv_bead_metadata "$root_bead_id" gc.graphv2_vars.v1)"
}

# cv_root_bead_id BEAD_ID — print BEAD_ID's workflow root: its
# gc.root_bead_id metadata value, or BEAD_ID itself when that key is absent
# (BEAD_ID already IS the root, or the lookup failed outright). Fail-safe:
# always falls back to BEAD_ID (which may itself be empty) rather than
# aborting the caller.
cv_root_bead_id() {
  local bead_id="$1"
  local root
  root="$(cv_bead_metadata "$bead_id" gc.root_bead_id)"
  printf '%s' "${root:-$bead_id}"
}

# cv_known_roster_vars — print, one per line, every `enable_*` roster var
# name declared as a `[vars.enable_X]` table in con-voyage.formula.toml
# (fk-ed0c5). Read from the formula directly (via cv_pack_root) rather than
# hardcoded, so this stays in sync as roster lenses are added/removed.
# Fail-safe: formula not found -> empty output, not an error.
cv_known_roster_vars() {
  local formula
  formula="$(cv_pack_root)/formulas/con-voyage.formula.toml"
  [ -f "$formula" ] || return 0
  grep -o '^\[vars\.enable_[a-zA-Z0-9_]*\]' "$formula" 2>/dev/null \
    | sed -E 's/^\[vars\.(enable_[a-zA-Z0-9_]*)\]$/\1/'
}

# cv_known_lenses — print, one per line, every `con-voyage.cv-*` run-target
# name available as a dispatchable lens agent under this pack (derived from
# the agents/ directory, not a hardcoded list, so a new lens agent is picked
# up automatically). Fail-safe: agents dir not found -> empty output.
cv_known_lenses() {
  local agents_dir
  agents_dir="$(cv_pack_root)/agents"
  [ -d "$agents_dir" ] || return 0
  ( cd "$agents_dir" 2>/dev/null && for d in cv-*/; do
      [ -d "$d" ] || continue
      printf 'con-voyage.%s\n' "${d%/}"
    done )
}

# cv_unknown_roster_vars ROOT_ID — print, space-separated, every bare
# `enable_*` name set as `gc.var.enable_*` metadata on ROOT_ID that is NOT
# one of cv_known_roster_vars's declared names (fk-ed0c5: a misspelled
# `--var enable_sre_reliability=true` silently no-ops instead of enabling the
# `enable_sre`-gated SRE lane). Empty output = every roster var set is
# declared (or none are set). Fail-safe: bd show failure / unparseable JSON
# -> empty (an unconfirmable lookup is never reported as a false positive).
cv_unknown_roster_vars() {
  local root_id="$1"
  [ -n "${root_id// /}" ] || { printf ''; return 0; }
  local gc_bin="${GC:-gc}"
  # fk-9q90j BLOCKING-1: bound this store call the same way every other
  # possibly-stalling external call in this pack already is (e.g. the
  # git-fetch call site above) — this runs on every con-voyage journey's
  # setup-review step, so an unbounded stall here degrades every concurrent
  # journey at once under store/pool contention, not just this one.
  local cv_lens_store_timeout="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
  case "$cv_lens_store_timeout" in
    *[!0-9]*|'') cv_lens_store_timeout="30" ;;
  esac
  local json
  json=$(cv_with_timeout "$cv_lens_store_timeout" "$gc_bin" bd show "$root_id" --json 2>/dev/null) || json=""
  [ -n "$json" ] || { printf ''; return 0; }
  local known
  known="$(cv_known_roster_vars | tr '\n' ' ')"
  printf '%s' "$json" | python3 -c "
import sys, json
known = set(sys.argv[1].split())
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    raise SystemExit(0)
meta = data.get('metadata') or {}
unknown = []
for key in meta:
    if key.startswith('gc.var.enable_'):
        name = key[len('gc.var.'):]
        if name not in known:
            unknown.append(name)
print(' '.join(sorted(unknown)))
" "$known" 2>/dev/null
}

# cv_unknown_code_lens ROOT_ID — print ROOT_ID's `gc.var.code_lens` value IFF
# it is set and is NOT one of cv_known_lenses's declared names; empty
# otherwise (unset, known, or lookup failure — fail-safe, never a false
# positive).
cv_unknown_code_lens() {
  local root_id="$1"
  # fk-9q90j BLOCKING-1: bound this store call the same way the sibling
  # roster-validation checks below are — see cv_unknown_roster_vars's note.
  local cv_lens_store_timeout="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
  case "$cv_lens_store_timeout" in
    *[!0-9]*|'') cv_lens_store_timeout="30" ;;
  esac
  local lens
  lens="$(cv_with_timeout "$cv_lens_store_timeout" cv_bead_metadata "$root_id" gc.var.code_lens)"
  [ -n "$lens" ] || { printf ''; return 0; }
  local known
  known="$(cv_known_lenses)"
  if printf '%s\n' "$known" | grep -qxF -- "$lens"; then
    printf ''
  else
    printf '%s' "$lens"
  fi
}

# cv_active_roster_vars ROOT_ID — print, one per line, the title of every
# roster lane whose formula condition var (`{{enable_X}}` in
# con-voyage.formula.toml) is truthy on ROOT_ID's `gc.var.enable_X` metadata
# (fk-ed0c5). This reads the formula's OWN condition/title pairing, so it
# reports what graph.v2 actually compiled into the workflow — not a second,
# possibly-drifted guess at lens names from var-name prefixes. Fail-safe:
# formula/bd show failure -> empty output.
cv_active_roster_vars() {
  local root_id="$1"
  [ -n "${root_id// /}" ] || { printf ''; return 0; }
  local formula
  formula="$(cv_pack_root)/formulas/con-voyage.formula.toml"
  [ -f "$formula" ] || { printf ''; return 0; }
  local gc_bin="${GC:-gc}"
  # fk-9q90j BLOCKING-1: bound this store call the same way the sibling
  # roster-validation checks above are — see cv_unknown_roster_vars's note.
  local cv_lens_store_timeout="${CV_LENS_STORE_TIMEOUT_SECONDS:-30}"
  case "$cv_lens_store_timeout" in
    *[!0-9]*|'') cv_lens_store_timeout="30" ;;
  esac
  local json
  json=$(cv_with_timeout "$cv_lens_store_timeout" "$gc_bin" bd show "$root_id" --json 2>/dev/null) || json=""
  [ -n "$json" ] || { printf ''; return 0; }
  python3 -c "
import sys, json, re
formula_path, meta_json = sys.argv[1], sys.argv[2]
with open(formula_path) as f:
    text = f.read()
mapping = {}
for block in text.split('[[template.children]]')[1:]:
    title_m = re.search(r'^title\s*=\s*\"([^\"]*)\"', block, re.M)
    cond_m = re.search(r'^condition\s*=\s*\"\"\"\{\{(\w+)\}\}\"\"\"', block, re.M)
    if title_m and cond_m:
        mapping[cond_m.group(1)] = title_m.group(1)
try:
    data = json.loads(meta_json)
except Exception:
    data = {}
if isinstance(data, list):
    data = data[0] if data else {}
meta = (data.get('metadata') or {}) if isinstance(data, dict) else {}
for name, title in mapping.items():
    val = str(meta.get('gc.var.' + name, '') or '').strip().lower()
    if val in ('true', '1', 'yes'):
        print(title)
" "$formula" "$json" 2>/dev/null
}

# cv_close_reason_for_pr PR_STATE PR_NUMBER — canonical work-bead close reason
# for a finalized PR. PR_STATE is the GitHub PR state ("MERGED" or "CLOSED",
# case-insensitive). Any merged state -> "landed: PR #N merged"; a closed-
# without-merge state -> "abandoned: PR #N closed without merge". These strings
# match the reasons the facilitator runbook and the operator already use by
# hand (README Phase 6 / orchestration template).
cv_close_reason_for_pr() {
  local pr_state="$1" pr_number="$2"
  local lc
  lc="$(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]')"
  if [ "$lc" = "merged" ]; then
    printf 'landed: PR #%s merged' "$pr_number"
  else
    printf 'abandoned: PR #%s closed without merge' "$pr_number"
  fi
}

# cv_repair_close_reason_for_pr PR_STATE PR_NUMBER — the REASON half (no
# outcome prefix) for closing a repair bead once its PR reaches a terminal
# state (fk-f1vp FIX-B). Unlike cv_close_reason_for_pr, a repair bead's own
# OUTCOME is always "superseded" regardless of merged vs. closed-without-merge
# — the CI failure it existed to fix is moot either way once the PR itself is
# terminal — so the caller passes this string to cv_bead_close's own REASON
# argument (which prepends the outcome): cv_bead_close "$bead" "superseded"
# "$(cv_repair_close_reason_for_pr "$state" "$num")".
cv_repair_close_reason_for_pr() {
  local pr_state="$1" pr_number="$2"
  local lc
  lc="$(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]')"
  if [ "$lc" = "merged" ]; then
    printf 'PR #%s merged' "$pr_number"
  else
    printf 'PR #%s closed' "$pr_number"
  fi
}

# pr_finalize_state REPO PR_NUMBER — resolve a PR's terminal state via ONE
# `gh pr view`. Prints "<state><0x1f><merged_at><0x1f><closed_at>" where state
# is one of MERGED | CLOSED | OPEN | "" (unknown/error). merged_at/closed_at are
# the raw ISO timestamps (empty when absent). A gh failure, timeout, or
# unparseable body yields an empty state (SEP-only) so the caller FAILS SAFE —
# never treats an unknown PR as merged/closed. GitHub reports a merged PR as
# state=CLOSED with a non-null mergedAt, so this normalizes that to MERGED for
# the caller.
#
# fk-2c937 review (SRE LOW-2): the gh call is bounded by CV_GH_TIMEOUT_SECONDS
# (default 30) via whichever of `timeout`/`gtimeout` is installed, so one
# stalled poll (GitHub partition, gh auth re-prompt, rate-limit stall) can't
# block an entire sweep — and, since fk-2c937 now runs this once per
# registered rig in a single pass, can't stall every rig at once either. A
# host with neither binary (e.g. stock macOS) degrades to the prior unwrapped
# call — fail soft, matching this file's posture elsewhere, not a hard
# dependency.
pr_finalize_state() {
  local repo="$1" pr_number="$2"
  local SEP=$'\x1f'
  [ -n "${repo// /}" ] && [ -n "${pr_number// /}" ] || { printf '%s%s' "$SEP" "$SEP"; return 0; }
  # PR number must be numeric — never interpolate anything else into the gh call.
  case "$pr_number" in
    ''|*[!0-9]*) printf '%s%s' "$SEP" "$SEP"; return 0 ;;
  esac
  local json timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi
  if [ -n "$timeout_bin" ]; then
    json=$("$timeout_bin" "${CV_GH_TIMEOUT_SECONDS:-30}" "$GH" pr view "$pr_number" --repo "$repo" --json state,mergedAt,closedAt 2>/dev/null) || json=""
  else
    json=$("$GH" pr view "$pr_number" --repo "$repo" --json state,mergedAt,closedAt 2>/dev/null) || json=""
  fi
  if [ -z "$json" ]; then printf '%s%s' "$SEP" "$SEP"; return 0; fi
  printf '%s' "$json" | python3 -c "
import sys, json
SEP = '\x1f'
try:
    d = json.load(sys.stdin)
except Exception:
    print(SEP + SEP, end=''); raise SystemExit(0)
if not isinstance(d, dict):
    print(SEP + SEP, end=''); raise SystemExit(0)
state = (d.get('state') or '').upper()
merged_at = d.get('mergedAt') or ''
closed_at = d.get('closedAt') or ''
# GitHub returns MERGED directly in the GraphQL 'state' for gh>=2, but older
# gh reports a merged PR as CLOSED with a non-null mergedAt — normalize both.
if merged_at:
    state = 'MERGED'
print(state + SEP + merged_at + SEP + closed_at, end='')
" 2>/dev/null || printf '%s%s' "$SEP" "$SEP"
}

# ---------------------------------------------------------------------------
# Per-PR FINALIZE record (fk-p7j9 / fk-hsca). File:
# "<CV_STATE_DIR>/<dedup_key>.finalize", plain key=value lines:
#   work_bead=<the real work bead id the con-voyage delivers>
#   convoy_id=<the con-voyage {{convoy_id}} = synthetic input convoy id>
#   repo_full=<owner/repo>
#   pr_number=<PR number>
#   pr_author=<the PR author login recorded at publish time>
#   implementor_session=<the long-lived implementor to release on land, or empty>
#   last_phase=<the last cv=<phase> the finalize monitor set on the work bead:
#     reviewing | awaiting_merge | repairing — used to avoid a redundant
#     set-state every poll (idempotence), or empty for a fresh record>
#
# This is a SEPARATE record type from the repair ".state" file: the repair
# state only exists for PRs with an actionable CI failure, so it cannot serve
# as the work-bead<->PR map for a clean, review-approved PR that is simply
# awaiting a human merge. The publish step writes THIS record for EVERY
# con-voyage PR it opens (via the finalize-record snippet in publish.md), and
# the con-voyage-finalize monitor is the sole consumer/GC of it.
#
# dedup_key convention: "cv-finalize-<owner>-<repo>-<pr_number>" (mirrors the
# repair state's "cv-ci-repair-..." shape). The monitor globs "*.finalize".
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # FS_* globals are consumed by the sourcing script
# (con-voyage-finalize.sh), invisible to shellcheck when this file is checked
# standalone.
finalize_read() {
  local dedup_key="$1"
  local f="${CV_STATE_DIR}/${dedup_key}.finalize"
  FS_WORK_BEAD=""
  FS_CONVOY_ID=""
  FS_REPO_FULL=""
  FS_PR_NUMBER=""
  FS_PR_AUTHOR=""
  FS_IMPLEMENTOR=""
  FS_LAST_PHASE=""
  FS_ROOT_BEAD_ID=""
  FS_ROSTER_VARS=""
  FS_LAST_REVIEWED_HEAD_SHA=""
  FS_REVIEW_ROUND=""
  FS_REREVIEW_ROOT_BEAD_ID=""
  [ -f "$f" ] || return 0
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      work_bead) FS_WORK_BEAD="$v" ;;
      convoy_id) FS_CONVOY_ID="$v" ;;
      repo_full) FS_REPO_FULL="$v" ;;
      pr_number) FS_PR_NUMBER="$v" ;;
      pr_author) FS_PR_AUTHOR="$v" ;;
      implementor_session) FS_IMPLEMENTOR="$v" ;;
      last_phase) FS_LAST_PHASE="$v" ;;
      root_bead_id) FS_ROOT_BEAD_ID="$v" ;;
      roster_vars) FS_ROSTER_VARS="$v" ;;
      last_reviewed_head_sha) FS_LAST_REVIEWED_HEAD_SHA="$v" ;;
      review_round) FS_REVIEW_ROUND="$v" ;;
      rereview_root_bead_id) FS_REREVIEW_ROOT_BEAD_ID="$v" ;;
    esac
  done < "$f"
}

# finalize_write DEDUP_KEY WORK_BEAD CONVOY_ID REPO_FULL PR_NUMBER PR_AUTHOR
#                IMPLEMENTOR LAST_PHASE [ROOT_BEAD_ID] [ROSTER_VARS]
#                [LAST_REVIEWED_HEAD_SHA] [REVIEW_ROUND] [REREVIEW_ROOT_BEAD_ID]
#
# ROOT_BEAD_ID (fk-bkz94) is the graph.v2 compiled root bead the con-voyage
# formula actually runs under — a THIRD bead distinct from WORK_BEAD and
# CONVOY_ID (see cv_close_workflow_root's header comment above). Optional and
# appended last so every pre-existing positional call site keeps working
# unchanged; empty means "unresolved/older record", in which case the
# finalize monitor skips the root-bead teardown entirely (unchanged prior
# behavior) rather than guessing an id.
#
# ROSTER_VARS/LAST_REVIEWED_HEAD_SHA/REVIEW_ROUND/REREVIEW_ROOT_BEAD_ID
# (fk-pubvq) exist so con-voyage-rereview-watch.sh can detect a post-publish
# code-changing push to the PR head and re-run the SAME review roster against
# it after the original workflow root has already closed:
#   roster_vars             - the original root's enable_*/code_lens formula
#                             vars, flattened to a single comma-separated
#                             "key=value,key=value,..." string (opaque to this
#                             lib; con-voyage-rereview-watch.sh is the only
#                             reader/writer of the flattened shape) so a later
#                             re-review round can re-sling the identical
#                             roster. Empty for records written before this
#                             field existed.
#   last_reviewed_head_sha  - the PR head commit SHA this roster last actually
#                             reviewed (publish time initially, then advanced
#                             by each completed re-review round). Comparing
#                             this against the PR's CURRENT head is how the
#                             watch script tells "nothing new" from "a new
#                             commit landed".
#   review_round            - the next aggregated-comment round number
#                             (publish posts round 1; each triggered
#                             re-review round increments it) so
#                             cv-pr-comment.sh comment-aggregate's round
#                             marker stays unique per PR.
#   rereview_root_bead_id   - the graph.v2 root bead id of an IN-FLIGHT
#                             re-review round, or empty when none is running.
#                             Sling-time dedup guard: a non-empty value means
#                             a round is already underway for this PR and the
#                             watch script must not sling a second one.
finalize_write() {
  local dedup_key="$1" work_bead="$2" convoy_id="$3" repo_full="$4"
  local pr_number="$5" pr_author="$6" implementor="${7:-}" last_phase="${8:-}"
  local root_bead_id="${9:-}" roster_vars="${10:-}"
  local last_reviewed_head_sha="${11:-}" review_round="${12:-}"
  local rereview_root_bead_id="${13:-}"
  local f="${CV_STATE_DIR}/${dedup_key}.finalize"
  {
    printf 'work_bead=%s\n' "$work_bead"
    printf 'convoy_id=%s\n' "$convoy_id"
    printf 'repo_full=%s\n' "$repo_full"
    printf 'pr_number=%s\n' "$pr_number"
    printf 'pr_author=%s\n' "$pr_author"
    printf 'implementor_session=%s\n' "$implementor"
    printf 'last_phase=%s\n' "$last_phase"
    printf 'root_bead_id=%s\n' "$root_bead_id"
    printf 'roster_vars=%s\n' "$roster_vars"
    printf 'last_reviewed_head_sha=%s\n' "$last_reviewed_head_sha"
    printf 'review_round=%s\n' "$review_round"
    printf 'rereview_root_bead_id=%s\n' "$rereview_root_bead_id"
  } > "$f"
}

# ===========================================================================
# PORTABLE CALL TIMEOUT (fk-rri7q LOW-D follow-up to fk-jsdw2)
#
# Several hosts running this pack have no `timeout(1)` binary at all (this is
# a real, observed environment, not a hypothetical), so a fanned-out external
# call (one `gc ... bd list` per registered rig, in con-voyage-review-
# watchdog.sh) had no way to bound a single hung store — one stuck NFS mount
# or long writer lock could stall an entire discovery cycle. cv_with_timeout
# is a minimal background+kill reimplementation for those hosts.
# ===========================================================================

# cv_with_timeout SECONDS CMD [ARGS...] — run CMD with a wall-clock bound.
# CMD's stdout/stderr pass through unchanged. Returns CMD's own exit status if
# it finishes within SECONDS; if it has to be killed, returns 124 (the same
# convention GNU coreutils' `timeout` uses for its own kill case, so a caller
# already familiar with that tool reads this the same way) — this is a
# best-effort mapping, not full parity with the real tool: a command that
# happens to die from an unrelated signal of its own is also reported as 124,
# since this cannot tell the two apart.
#
# FAIL-SAFE: a malformed or non-positive SECONDS runs CMD with NO timeout at
# all (fail-open on bad config — a caller cannot be given a bound it did not
# actually ask for) rather than guessing at a default the caller never chose;
# each caller (e.g. con-voyage-review-watchdog.sh's CV_LENS_STORE_TIMEOUT_SECONDS)
# owns coercing its own env var to a sane default before calling this.
#
# KNOWN LIMITATION: this signals CMD's own PID plus its DIRECT children (via
# `pgrep -P`, when available) — not a full process-group/tree kill. A CMD that
# forks a child which itself forks further descendants of its own (a
# grandchild two levels down from CMD) can still outlive the bound. Every real
# caller in this pack wraps a single external binary directly (the `gc` CLI)
# expected to make at most one level of internal subprocess call, so this is
# not a hypothetical gap being papered over — it is what this function's own
# tests exercise directly (a stub that forks `sleep` as a real child, the same
# shape as anything that shells out once internally).
#
# Portable poll+kill implementation (no `timeout(1)`, no background "watcher"
# process of its own — an earlier version used a sibling `sleep`-then-kill
# subshell, but killing that subshell while ITS OWN sleep was still active
# left the sleep as an orphan holding the caller's command-substitution pipe
# open for however long was left of the bound, which reproduces as a real,
# multi-second hang, not just a theoretical one). Polling in THIS function's
# own shell instead means every `sleep 1` here always completes on its own
# before the next check — nothing of this function's own ever gets killed
# mid-sleep, so it can never orphan anything itself. Works identically under
# bash and zsh (`kill -0`/`wait`/`sleep` are POSIX, not bash-only).
cv_with_timeout() {
  local secs="$1"; shift
  case "$secs" in
    *[!0-9]*|'') secs="" ;;
  esac
  if [ -z "$secs" ] || [ "$secs" -le 0 ]; then
    "$@"
    return "$?"
  fi
  "$@" &
  local cmd_pid=$!
  # fk-jjumm (iter-2 qa-test B1): the common case is a command that has
  # already exited by the first check, but the exited child stays a zombie
  # (still visible to `kill -0`) until this function's own `wait` reaps it,
  # which only ever ran after the loop below — so every fast call still paid
  # one full `sleep 1` waiting for a reap that couldn't happen until the very
  # sleep it was waiting out was over. Tapering the poll interval up from a
  # fraction of a second (instead of a flat 1s from the first check) gives
  # the shell many more, much earlier chances to reap the child between
  # checks, without changing the ceiling: the slowest this can ever detect a
  # timeout is one poll interval late, capped at 1s, identical to before.
  #
  # fk-jjumm review iteration 3 (BLOCKING-1/2): tracking the taper as
  # fractional-second strings via `awk` was both a locale bug (`awk`'s
  # `%.3f` honors LC_NUMERIC; a comma-decimal locale produces a value
  # `sleep` rejects outright, turning the poll into a busy-spin that fires
  # the timeout against wall-clock time never actually slept through) and a
  # needless latency tax (each fork/exec eats back the fast-path savings the
  # taper exists to deliver). The sequence is a fixed integer progression
  # (50, 100, 200, 400, 800, 1000, 1000, ...ms), so it's tracked in native
  # bash integer arithmetic instead; only `sleep`'s own argument needs a
  # fractional-seconds string, produced by the `printf` builtin (locale-safe,
  # no fork).
  local waited_ms=0
  local poll_ms=50
  # fk-i7d7b review iteration 4 (BLOCKING-1): bash's arithmetic evaluator
  # applies C-style octal parsing to any leading-zero digit string (a rule
  # the `awk` this replaced never had), so an operator-supplied "010" here
  # silently misparses as decimal 8 and "08" hard-crashes the arithmetic
  # expansion after the child is already backgrounded, orphaning it. The
  # `10#` base-10 literal prefix forces decimal interpretation regardless of
  # leading zeros.
  local secs_ms=$((10#$secs * 1000))
  # fk-4i2er: `poll_s` must be declared ONCE, outside this loop. Under zsh,
  # re-declaring a `local` that is already local to the enclosing function
  # (as a fresh `local poll_s` on every iteration was doing) makes zsh treat
  # it as an inspection form and print "poll_s=<value>" to stdout instead of
  # silently redeclaring it the way bash does — corrupting any caller that
  # captures this function's stdout (e.g. `WORK_BEAD=$(cv_with_timeout ...)`).
  local poll_s
  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [ "$waited_ms" -ge "$secs_ms" ]; then
      if command -v pgrep >/dev/null 2>&1; then
        local child_pid
        for child_pid in $(pgrep -P "$cmd_pid" 2>/dev/null); do
          kill -TERM "$child_pid" 2>/dev/null
        done
      fi
      kill -TERM "$cmd_pid" 2>/dev/null
      wait "$cmd_pid" 2>/dev/null
      return 124
    fi
    printf -v poll_s '%d.%03d' $((poll_ms / 1000)) $((poll_ms % 1000))
    sleep "$poll_s"
    waited_ms=$((waited_ms + poll_ms))
    poll_ms=$((poll_ms * 2))
    [ "$poll_ms" -gt 1000 ] && poll_ms=1000
  done
  wait "$cmd_pid" 2>/dev/null
  return "$?"
}
