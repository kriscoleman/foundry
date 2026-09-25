#!/usr/bin/env bash
# cv-worktree-prep.test.sh — hermetic, offline test proving con-voyage's
# external-rig / worktree artifact hygiene: local scratch directories used by
# this toolchain (.beads/, .gc/, .claude/, dolt data paths) never get
# committed to a target repo's history.
#
# Two-layer contract under test:
#   `exclude <dir>` — writes hygiene patterns into <dir>'s LOCAL
#                     .git/info/exclude (resolved via `git rev-parse
#                     --git-path info/exclude`, never a hardcoded
#                     <dir>/.git/info/exclude — that path is wrong for a
#                     linked worktree, where .git is a file, not a dir).
#                     Never touches the tracked .gitignore.
#   `guard <dir> [base-ref]`
#                   — a commit-step backstop. A STAGED-but-uncommitted hygiene
#                     path is always unstaged (DROPPED); that check is
#                     base-independent. A COMMITTED hygiene path is only an
#                     offense (BLOCKED) if THIS branch ADDED it relative to its
#                     base — a hygiene path that already exists in the base
#                     (e.g. an upstream repo that legitimately tracks
#                     .claude/agents+commands) is NOT flagged. Base is the
#                     optional 3rd arg, else auto-derived from origin/HEAD ->
#                     origin/main -> main, else the empty tree (fail-safe).
#
# HOW IT WORKS: real, local git repos created under a temp sandbox (git init
# is fully offline) — no stubs needed, since git's own exclude/ls-files/diff
# behavior is exactly what's under test.
#
# Run:  bash tests/cv-worktree-prep.test.sh   (exit 0 => all passed)

set -uo pipefail

# Hermetic / offline: never prompt for credentials, never read a developer's
# system git config. Every repo below is a throwaway under a temp sandbox with
# inline user.name/email (see git_c) — no network, no gh, no real remotes, no
# sleeps, no unbounded loops.
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/cv-worktree-prep.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-worktree-prep-test.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

# git -C "$repo" commands in this suite intentionally run without inheriting
# a developer's global excludesfile/config quirks.
git_c() { git -C "$1" -c user.email=test@example.com -c user.name="Test" "${@:2}"; }

mk_repo() {
  local repo="${SANDBOX}/$1"
  mkdir -p "$repo"
  git_c "$repo" init -q -b main
  printf 'placeholder\n' > "$repo/README.md"
  git_c "$repo" add README.md
  git_c "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

run_script() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

OUT=""
RC=0

# ===========================================================================
# CASE 1 — exclude on a fresh (non-worktree) repo writes hygiene patterns to
#   .git/info/exclude, and git check-ignore confirms each path is ignored.
# ===========================================================================
start_case "1: exclude writes hygiene patterns; check-ignore confirms"
REPO1="$(mk_repo repo1)"
run_script exclude "$REPO1"
assert_eq "0" "$RC" "exclude exits 0"
EXCLUDE_FILE="${REPO1}/.git/info/exclude"
if [ -f "$EXCLUDE_FILE" ]; then pass "exclude file exists at ${EXCLUDE_FILE}"; else fail "exclude file not found at ${EXCLUDE_FILE}"; fi
for p in ".beads/config.yaml" ".gc/state.json" ".claude/settings.json" ".dolt/noms/manifest"; do
  if git_c "$REPO1" check-ignore -q --no-index "$p"; then
    pass "check-ignore confirms '${p}' is ignored"
  else
    fail "check-ignore does NOT report '${p}' as ignored"
  fi
done

# ===========================================================================
# CASE 2 — idempotent: running exclude twice does not duplicate lines.
# ===========================================================================
start_case "2: exclude is idempotent (no duplicate lines on re-run)"
first_line_count="$(wc -l < "$EXCLUDE_FILE" | tr -d ' ')"
run_script exclude "$REPO1"
assert_eq "0" "$RC" "second exclude run exits 0"
second_line_count="$(wc -l < "$EXCLUDE_FILE" | tr -d ' ')"
assert_eq "$first_line_count" "$second_line_count" "exclude file line count unchanged after a second run"

# ===========================================================================
# CASE 3 — exclude never touches the tracked .gitignore.
# ===========================================================================
start_case "3: exclude never modifies the tracked .gitignore"
REPO3="$(mk_repo repo3)"
printf '*.log\n' > "${REPO3}/.gitignore"
git_c "$REPO3" add .gitignore
git_c "$REPO3" commit -q -m "add gitignore"
before_hash="$(git_c "$REPO3" hash-object .gitignore 2>/dev/null || shasum "${REPO3}/.gitignore" | awk '{print $1}')"
run_script exclude "$REPO3"
assert_eq "0" "$RC" "exclude exits 0"
after_content="$(cat "${REPO3}/.gitignore")"
assert_eq '*.log' "$after_content" "tracked .gitignore content is byte-for-byte unchanged"
status_out="$(git_c "$REPO3" status --porcelain -- .gitignore)"
assert_eq "" "$status_out" ".gitignore shows no working-tree changes after exclude"

# ===========================================================================
# CASE 4 — exclude on a LINKED WORKTREE resolves the shared
#   .git/info/exclude (git-path aware), not a nonexistent
#   <worktree>/.git/info/exclude (worktree .git is a FILE, not a dir).
# ===========================================================================
start_case "4: exclude on a linked worktree writes to the shared exclude file"
REPO4="$(mk_repo repo4)"
WT4="${SANDBOX}/repo4-worktree"
git_c "$REPO4" worktree add -q --detach "$WT4" HEAD
if [ -f "${WT4}/.git" ]; then
  pass "worktree .git is a file (linked worktree), confirming this case is meaningful"
else
  fail "expected ${WT4}/.git to be a file (linked worktree layout)"
fi
run_script exclude "$WT4"
assert_eq "0" "$RC" "exclude on the worktree exits 0"
if git_c "$WT4" check-ignore -q --no-index ".gc/state.json"; then
  pass "check-ignore from the worktree confirms .gc/ is ignored"
else
  fail "check-ignore from the worktree does not report .gc/ as ignored"
fi
if [ -f "${REPO4}/.git/info/exclude" ] && grep -q '\.gc/' "${REPO4}/.git/info/exclude"; then
  pass "patterns landed in the MAIN repo's shared .git/info/exclude"
else
  fail "patterns did not land in the shared .git/info/exclude at ${REPO4}/.git/info/exclude"
fi

# ===========================================================================
# CASE 5 — exclude on a non-git directory is a hard error.
# ===========================================================================
start_case "5: exclude on a non-git directory fails"
NOTGIT="${SANDBOX}/not-a-repo"
mkdir -p "$NOTGIT"
run_script exclude "$NOTGIT"
if [ "$RC" -ne 0 ]; then pass "exclude exits non-zero for a non-git directory"; else fail "expected non-zero exit for a non-git directory"; fi

# ===========================================================================
# CASE 6 — exclude with a missing directory argument is a hard error.
# ===========================================================================
start_case "6: exclude with no directory argument fails"
run_script exclude
if [ "$RC" -ne 0 ]; then pass "exclude exits non-zero with no directory argument"; else fail "expected non-zero exit with no directory argument"; fi

# ===========================================================================
# CASE 7 — guard on a clean repo (excludes applied, nothing offending
#   staged) reports clean and exits 0.
# ===========================================================================
start_case "7: guard is clean on a hygienic repo"
REPO7="$(mk_repo repo7)"
run_script exclude "$REPO7"
run_script guard "$REPO7"
assert_eq "0" "$RC" "guard exits 0 on a clean repo"

# ===========================================================================
# CASE 8 — guard detects a STAGED (force-added) hygiene path, unstages it,
#   and exits non-zero. The file itself must survive on disk (guard never
#   deletes data, only unstages).
# ===========================================================================
start_case "8: guard unstages a force-added hygiene path and fails loud"
REPO8="$(mk_repo repo8)"
run_script exclude "$REPO8"
mkdir -p "${REPO8}/.beads" "${REPO8}/.claude"
printf 'db: local\n' > "${REPO8}/.beads/config.yaml"
printf '{}\n' > "${REPO8}/.claude/settings.json"
git_c "$REPO8" add -f .beads/config.yaml .claude/settings.json
staged_before="$(git_c "$REPO8" diff --cached --name-only | sort)"
run_script guard "$REPO8"
if [ "$RC" -ne 0 ]; then pass "guard exits non-zero when hygiene paths are staged"; else fail "expected guard to exit non-zero"; fi
staged_after="$(git_c "$REPO8" diff --cached --name-only | sort)"
if printf '%s' "$staged_before" | grep -q '.beads/config.yaml'; then
  pass "sanity: .beads/config.yaml was staged before guard ran"
else
  fail "sanity check failed: .beads/config.yaml was not staged before guard ran"
fi
if printf '%s' "$staged_after" | grep -q '.beads/config.yaml'; then
  fail ".beads/config.yaml is still staged after guard ran"
else
  pass ".beads/config.yaml was unstaged by guard"
fi
if printf '%s' "$staged_after" | grep -q '.claude/settings.json'; then
  fail ".claude/settings.json is still staged after guard ran"
else
  pass ".claude/settings.json was unstaged by guard"
fi
if [ -f "${REPO8}/.beads/config.yaml" ]; then
  pass ".beads/config.yaml still exists on disk (guard does not delete data)"
else
  fail ".beads/config.yaml was deleted from disk — guard must only unstage, never delete"
fi
if printf '%s' "$OUT" | grep -q 'DROPPED'; then
  pass "guard logs a DROPPED message for the unstaged path"
else
  fail "expected a DROPPED log line from guard"
fi

# ===========================================================================
# CASE 9 — guard BLOCKS a hygiene path that THIS BRANCH committed on top of
#   base. It must fail loud rather than silently rewrite history, and must
#   leave the file tracked exactly as it was — no destructive git surgery.
#   (mk_repo's initial commit is on `main`; here `main` is the base and the
#   offending .gc/ commit lands on a work branch, so it is genuinely
#   branch-added relative to base.)
# ===========================================================================
start_case "9: guard blocks (never auto-fixes) a hygiene path this branch committed"
REPO9="$(mk_repo repo9)"
git_c "$REPO9" checkout -q -b work
mkdir -p "${REPO9}/.gc"
printf 'runtime state\n' > "${REPO9}/.gc/state.json"
git_c "$REPO9" add -f .gc/state.json
git_c "$REPO9" commit -q -m "oops: accidentally committed .gc state"
run_script exclude "$REPO9"
tracked_before="$(git_c "$REPO9" ls-files -- .gc)"
head_before="$(git_c "$REPO9" rev-parse HEAD)"
run_script guard "$REPO9" main
if [ "$RC" -ne 0 ]; then pass "guard exits non-zero for a branch-added committed hygiene path"; else fail "expected guard to exit non-zero"; fi
if printf '%s' "$OUT" | grep -qi 'BLOCKED'; then
  pass "guard logs a BLOCKED message (cannot auto-fix committed history)"
else
  fail "expected a BLOCKED log line from guard"
fi
tracked_after="$(git_c "$REPO9" ls-files -- .gc)"
assert_eq "$tracked_before" "$tracked_after" "committed hygiene path is still tracked identically (no destructive history rewrite)"
assert_eq "$head_before" "$(git_c "$REPO9" rev-parse HEAD)" "HEAD is unchanged by guard"

# ===========================================================================
# CASE 10 — guard does not touch unrelated, legitimately staged files.
# ===========================================================================
start_case "10: guard leaves unrelated staged files untouched"
REPO10="$(mk_repo repo10)"
run_script exclude "$REPO10"
printf 'feature code\n' > "${REPO10}/feature.go"
git_c "$REPO10" add feature.go
run_script guard "$REPO10"
assert_eq "0" "$RC" "guard exits 0 when only unrelated files are staged"
staged="$(git_c "$REPO10" diff --cached --name-only)"
if printf '%s' "$staged" | grep -q 'feature.go'; then
  pass "unrelated staged file (feature.go) remains staged after guard"
else
  fail "guard unexpectedly touched an unrelated staged file"
fi

# ===========================================================================
# CASE 11 — guard on a non-git directory / missing argument is a hard error.
# ===========================================================================
start_case "11: guard validates its arguments the same way exclude does"
run_script guard "$NOTGIT"
if [ "$RC" -ne 0 ]; then pass "guard exits non-zero for a non-git directory"; else fail "expected non-zero exit for a non-git directory"; fi
run_script guard
if [ "$RC" -ne 0 ]; then pass "guard exits non-zero with no directory argument"; else fail "expected non-zero exit with no directory argument"; fi

# ===========================================================================
# CASE 12 — unknown subcommand is rejected.
# ===========================================================================
start_case "12: unknown subcommand is rejected"
run_script frobnicate "$REPO1"
if [ "$RC" -ne 0 ]; then pass "unknown subcommand exits non-zero"; else fail "expected non-zero exit for an unknown subcommand"; fi

# ===========================================================================
# CASE 13 — THE FALSE-POSITIVE FIX. A hygiene path exists in the BASE only
#   (e.g. upstream legitimately tracks .claude/agents), and the work branch
#   adds an unrelated file. guard must report CLEAN (exit 0) — the branch did
#   not introduce the hygiene path, so blocking it would wedge every publish
#   on that repo. Base is passed explicitly.
# ===========================================================================
start_case "13: guard is CLEAN when a committed hygiene path lives only in base"
REPO13="$(mk_repo repo13)"
mkdir -p "${REPO13}/.claude"
printf 'agent config\n' > "${REPO13}/.claude/agents"
git_c "$REPO13" add -f .claude/agents
git_c "$REPO13" commit -q -m "upstream: legitimately tracks .claude/agents"
git_c "$REPO13" checkout -q -b work
printf 'feature code\n' > "${REPO13}/feature.go"
git_c "$REPO13" add feature.go
git_c "$REPO13" commit -q -m "feat: unrelated work"
run_script exclude "$REPO13"
run_script guard "$REPO13" main
assert_eq "0" "$RC" "guard exits 0 when the hygiene path is inherited from base, not branch-added"
if printf '%s' "$OUT" | grep -qi 'BLOCKED'; then
  fail "guard wrongly BLOCKED a base-inherited hygiene path (the false-positive bug)"
else
  pass "guard did not BLOCK the base-inherited hygiene path"
fi
if [ -n "$(git_c "$REPO13" ls-files -- .claude)" ]; then
  pass "sanity: .claude/agents is genuinely tracked (present in HEAD)"
else
  fail "sanity check failed: .claude/agents should be tracked"
fi

# ===========================================================================
# CASE 14 — a hygiene path that already exists in base but is ALSO newly
#   STAGED (a brand-new file under the same tree) is still DROPPED. The
#   staged-but-uncommitted check is base-independent, and a base-inherited
#   committed sibling must not shield a freshly staged offender.
# ===========================================================================
start_case "14: guard drops a staged hygiene file even when a sibling exists in base"
REPO14="$(mk_repo repo14)"
mkdir -p "${REPO14}/.claude"
printf 'agent config\n' > "${REPO14}/.claude/agents"
git_c "$REPO14" add -f .claude/agents
git_c "$REPO14" commit -q -m "upstream: legitimately tracks .claude/agents"
git_c "$REPO14" checkout -q -b work
printf '{}\n' > "${REPO14}/.claude/settings.json"   # NEW, never committed
git_c "$REPO14" add -f .claude/settings.json
run_script exclude "$REPO14"
run_script guard "$REPO14" main
if [ "$RC" -ne 0 ]; then pass "guard exits non-zero when a new hygiene file is staged"; else fail "expected guard to exit non-zero"; fi
staged_after="$(git_c "$REPO14" diff --cached --name-only)"
if printf '%s' "$staged_after" | grep -q '.claude/settings.json'; then
  fail ".claude/settings.json is still staged after guard ran"
else
  pass ".claude/settings.json (freshly staged) was unstaged by guard"
fi
if printf '%s' "$OUT" | grep -q 'DROPPED'; then
  pass "guard logs a DROPPED message for the staged file"
else
  fail "expected a DROPPED log line from guard"
fi
if [ -n "$(git_c "$REPO14" ls-files -- .claude/agents)" ]; then
  pass "base-inherited .claude/agents remains tracked and untouched"
else
  fail "guard should not have disturbed the base-inherited .claude/agents"
fi

# ===========================================================================
# CASE 15 — base AUTO-DERIVATION via origin/HEAD. With no explicit base arg
#   and a real origin whose HEAD points at main, guard derives origin/main as
#   the base: a base-inherited hygiene path is clean, and a branch-added one
#   is blocked. A bare local remote stands in for GitHub — still fully offline.
# ===========================================================================
start_case "15: guard auto-derives base from origin/HEAD"
UPSTREAM15="${SANDBOX}/repo15-upstream.git"
git init -q -b main --bare "$UPSTREAM15"
REPO15="$(mk_repo repo15)"
mkdir -p "${REPO15}/.claude"
printf 'cmds\n' > "${REPO15}/.claude/commands"
git_c "$REPO15" add -f .claude/commands
git_c "$REPO15" commit -q -m "upstream: legitimately tracks .claude/commands"
git_c "$REPO15" remote add origin "$UPSTREAM15"
git_c "$REPO15" push -q -u origin main
git_c "$REPO15" remote set-head origin main
derived_head="$(git_c "$REPO15" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
assert_eq "origin/main" "$derived_head" "origin/HEAD resolves to origin/main"
git_c "$REPO15" checkout -q -b work
printf 'code\n' > "${REPO15}/f.go"
git_c "$REPO15" add f.go
git_c "$REPO15" commit -q -m "feat: unrelated"
run_script exclude "$REPO15"
run_script guard "$REPO15"   # NO explicit base — must auto-derive origin/main
assert_eq "0" "$RC" "guard (auto-derived base) is clean when hygiene path is base-inherited"
# Now the branch ADDS a committed hygiene path — auto-derived base must block it.
mkdir -p "${REPO15}/.beads"
printf 'cfg\n' > "${REPO15}/.beads/config.yaml"
git_c "$REPO15" add -f .beads/config.yaml
git_c "$REPO15" commit -q -m "oops: branch adds .beads"
run_script guard "$REPO15"   # still no explicit base
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'BLOCKED'; then
  pass "guard (auto-derived base) BLOCKS a branch-added committed hygiene path"
else
  fail "expected guard to BLOCK a branch-added hygiene path with an auto-derived base (rc=$RC)"
fi

# ===========================================================================
# CASE 16 — DOCUMENTED FALLBACK. With no origin, no origin/main, and a branch
#   whose name is not main (so `main` never resolves either), the base cannot
#   be resolved. guard must fail SAFE: treat the empty tree as base, so ANY
#   committed hygiene path is flagged — never silently pass a real offender.
# ===========================================================================
start_case "16: guard fails SAFE (empty-tree base) when no base ref resolves"
REPO16="${SANDBOX}/repo16"
mkdir -p "$REPO16"
git_c "$REPO16" init -q -b trunk        # not 'main'; no remote at all
printf 'placeholder\n' > "${REPO16}/README.md"
git_c "$REPO16" add README.md
git_c "$REPO16" commit -q -m "init"
mkdir -p "${REPO16}/.beads"
printf 'cfg\n' > "${REPO16}/.beads/config.yaml"
git_c "$REPO16" add -f .beads/config.yaml
git_c "$REPO16" commit -q -m "committed hygiene path"
run_script exclude "$REPO16"
run_script guard "$REPO16"   # no base arg, no origin, branch != main
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'BLOCKED'; then
  pass "guard fails safe: BLOCKS a committed hygiene path when no base resolves"
else
  fail "expected fail-safe BLOCK when no base resolves (rc=$RC)"
fi

# ===========================================================================
# CASE 17 — dirty is CLEAN on a repo with no uncommitted changes.
# ===========================================================================
start_case "17: dirty is clean on a repo with nothing uncommitted"
REPO17="$(mk_repo repo17)"
run_script dirty "$REPO17"
assert_eq "0" "$RC" "dirty exits 0 on a clean repo"

# ===========================================================================
# CASE 18 — dirty FAILS LOUD on a modified tracked file (the fk-etw7 bug: an
#   applied review fix that was never committed).
# ===========================================================================
start_case "18: dirty fails on a modified tracked file"
REPO18="$(mk_repo repo18)"
printf 'changed\n' > "${REPO18}/README.md"
run_script dirty "$REPO18"
if [ "$RC" -ne 0 ]; then pass "dirty exits non-zero for a modified tracked file"; else fail "expected dirty to exit non-zero"; fi
if printf '%s' "$OUT" | grep -q 'README.md'; then
  pass "dirty reports the offending path (README.md)"
else
  fail "expected dirty's output to name the offending path"
fi

# ===========================================================================
# CASE 19 — dirty FAILS LOUD on an untracked new file (a fix that added a
#   file but never staged/committed it).
# ===========================================================================
start_case "19: dirty fails on an untracked new file"
REPO19="$(mk_repo repo19)"
printf 'new code\n' > "${REPO19}/feature.go"
run_script dirty "$REPO19"
if [ "$RC" -ne 0 ]; then pass "dirty exits non-zero for an untracked file"; else fail "expected dirty to exit non-zero"; fi
if printf '%s' "$OUT" | grep -q 'feature.go'; then
  pass "dirty reports the offending untracked path (feature.go)"
else
  fail "expected dirty's output to name the untracked path"
fi

# ===========================================================================
# CASE 20 — dirty is CLEAN when the only uncommitted state lives under
#   hygiene paths (.beads/, .gc/, .claude/, .dolt/) — that is expected local
#   scratch state, not a missed commit, and is `guard`'s concern, not dirty's.
# ===========================================================================
start_case "20: dirty ignores uncommitted state confined to hygiene paths"
REPO20="$(mk_repo repo20)"
mkdir -p "${REPO20}/.gc" "${REPO20}/.beads" "${REPO20}/.claude"
printf 'runtime\n' > "${REPO20}/.gc/state.json"
printf 'cfg\n' > "${REPO20}/.beads/config.yaml"
printf '{}\n' > "${REPO20}/.claude/settings.json"
run_script dirty "$REPO20"
assert_eq "0" "$RC" "dirty exits 0 when only hygiene paths are uncommitted"

# ===========================================================================
# CASE 21 — dirty on a non-git directory / missing argument is a hard error,
#   same validation as exclude and guard.
# ===========================================================================
start_case "21: dirty validates its arguments the same way exclude/guard do"
run_script dirty "$NOTGIT"
if [ "$RC" -ne 0 ]; then pass "dirty exits non-zero for a non-git directory"; else fail "expected non-zero exit for a non-git directory"; fi
run_script dirty
if [ "$RC" -ne 0 ]; then pass "dirty exits non-zero with no directory argument"; else fail "expected non-zero exit with no directory argument"; fi

# ===========================================================================
# CASE 22 — fk-etw7 REGRESSION: a review fix applied but never committed must
#   never reach a pushed ref, and once committed (mirroring the
#   apply-review-findings commit step) it MUST reach the pushed ref. This
#   proves the actual bug end to end: apply-findings edits a file, dirty
#   blocks the push while it is uncommitted, committing clears the block, and
#   the fix is then present on the remote after push — the exact chain that
#   was previously silently broken (fixes lived only in the worktree, publish
#   pushed stale HEAD with no error).
# ===========================================================================
start_case "22: fk-etw7 regression — uncommitted fix blocked, committed fix reaches the pushed remote"
UPSTREAM22="${SANDBOX}/repo22-upstream.git"
git init -q -b main --bare "$UPSTREAM22"
REPO22="$(mk_repo repo22)"
git_c "$REPO22" remote add origin "$UPSTREAM22"
git_c "$REPO22" push -q -u origin main
git_c "$REPO22" checkout -q -b work

# Simulate apply-review-findings applying a BLOCKING fix, WITHOUT committing
# (the pre-fk-etw7 bug: apply-findings edited the worktree and stopped here).
printf 'fixed content\n' > "${REPO22}/README.md"
run_script dirty "$REPO22"
if [ "$RC" -ne 0 ]; then
  pass "dirty blocks publish while the applied fix is uncommitted (reproduces the bug's failure mode)"
else
  fail "expected dirty to block an uncommitted applied fix"
fi

# Simulate apply-review-findings' new commit step: hygiene guard, then commit.
run_script guard "$REPO22"
assert_eq "0" "$RC" "hygiene guard is clean before the fix commit"
git_c "$REPO22" add -A
git_c "$REPO22" commit -q -m "fix: apply review finding (review test-convoy)"

# Simulate publish's new pre-push guard: must now be clean.
run_script dirty "$REPO22"
assert_eq "0" "$RC" "dirty is clean once the applied fix is committed"

# Simulate publish's push.
git_c "$REPO22" push -q -u origin work

# Verify the fix is present on the REMOTE — not just local HEAD.
pushed_content="$(git_c "$REPO22" show "origin/work:README.md")"
assert_eq "fixed content" "$pushed_content" "the committed review fix reached the pushed remote ref"

# ===========================================================================
# CASE 23 — built reports NOT BUILT (exit 1) on a fresh worktree sitting
#   exactly at the base tip (0 commits ahead) — the con-voyage build phase's
#   short-circuit signal for "this source anchor needs its first TDD round"
#   (fk-9aunv: fold the do-work build into con-voyage as its own first phase).
# ===========================================================================
start_case "23: built reports NOT BUILT on a fresh worktree with 0 commits ahead of base"
REPO23="$(mk_repo repo23)"
WT23="${SANDBOX}/repo23-worktree"
git_c "$REPO23" worktree add -q --detach "$WT23" HEAD
run_script built "$WT23" main
if [ "$RC" -ne 0 ]; then pass "built exits non-zero (not built) on a fresh detached worktree"; else fail "expected built to report NOT BUILT on a fresh worktree"; fi

# ===========================================================================
# CASE 24 — built reports BUILT (exit 0) once the worktree has a commit ahead
#   of base — the short-circuit signal for "reuse this pre-built branch,
#   skip the initial TDD round" (backward compat with the existing
#   pre-built-branch con-voyage path).
# ===========================================================================
start_case "24: built reports BUILT once a commit lands ahead of base"
printf 'impl\n' > "${WT23}/feature.go"
git_c "$WT23" add feature.go
git_c "$WT23" commit -q -m "feat: first TDD round"
run_script built "$WT23" main
assert_eq "0" "$RC" "built exits 0 once HEAD is ahead of base"

# ===========================================================================
# CASE 25 — built resolves its base the same way guard does: explicit arg,
#   then origin/HEAD, then origin/main, then main.
# ===========================================================================
start_case "25: built auto-derives base from origin/HEAD when no explicit base is given"
UPSTREAM25="${SANDBOX}/repo25-upstream.git"
git init -q -b main --bare "$UPSTREAM25"
REPO25="$(mk_repo repo25)"
git_c "$REPO25" remote add origin "$UPSTREAM25"
git_c "$REPO25" push -q -u origin main
git_c "$REPO25" remote set-head origin main
WT25="${SANDBOX}/repo25-worktree"
git_c "$REPO25" worktree add -q --detach "$WT25" HEAD
run_script built "$WT25"   # NO explicit base — must auto-derive origin/main
if [ "$RC" -ne 0 ]; then pass "built (auto-derived base) reports NOT BUILT on a fresh worktree"; else fail "expected built to report NOT BUILT with an auto-derived base"; fi
printf 'impl\n' > "${WT25}/feature.go"
git_c "$WT25" add feature.go
git_c "$WT25" commit -q -m "feat: first TDD round"
run_script built "$WT25"
assert_eq "0" "$RC" "built (auto-derived base) reports BUILT once HEAD is ahead"

# ===========================================================================
# CASE 26 — built validates its arguments the same way exclude/guard/dirty do.
# ===========================================================================
start_case "26: built validates its arguments the same way exclude/guard/dirty do"
run_script built "$NOTGIT"
if [ "$RC" -ne 0 ]; then pass "built exits non-zero for a non-git directory"; else fail "expected non-zero exit for a non-git directory"; fi
run_script built
if [ "$RC" -ne 0 ]; then pass "built exits non-zero with no directory argument"; else fail "expected non-zero exit with no directory argument"; fi

# ===========================================================================
# CASE 27 — DOCUMENTED FALLBACK. When no base ref resolves at all (same
#   degenerate case as guard's CASE 16), built fails SAFE toward "NOT BUILT"
#   (do the build) rather than toward "BUILT" (skip it) — the safer default,
#   since skipping a real TDD round is a worse failure than a redundant one.
# ===========================================================================
start_case "27: built fails SAFE toward NOT BUILT when no base ref resolves"
REPO27="${SANDBOX}/repo27"
mkdir -p "$REPO27"
git_c "$REPO27" init -q -b trunk        # not 'main'; no remote at all
printf 'placeholder\n' > "${REPO27}/README.md"
git_c "$REPO27" add README.md
git_c "$REPO27" commit -q -m "init"
WT27="${SANDBOX}/repo27-worktree"
git_c "$REPO27" worktree add -q --detach "$WT27" HEAD
printf 'impl\n' > "${WT27}/feature.go"
git_c "$WT27" add feature.go
git_c "$WT27" commit -q -m "feat: some commits exist, but no base can resolve"
run_script built "$WT27"   # no base arg, no origin, branch != main
if [ "$RC" -ne 0 ]; then pass "built fails safe: reports NOT BUILT when no base resolves"; else fail "expected fail-safe NOT BUILT when no base resolves (rc=$RC)"; fi

# ===========================================================================
# CASE 28 — `resolve-base` (fk-qppb4): exposes guard's own base-resolution
#   algorithm as a public subcommand so con-voyage-lib.sh's
#   cv_resolve_base_branch can reuse it verbatim instead of re-deriving
#   origin/HEAD -> origin/main -> main independently and risking the two
#   scripts disagreeing about what "the default base" means.
# ===========================================================================
start_case "28a: resolve-base echoes an explicit base-ref verbatim when it resolves"
REPO23A="$(mk_repo repo23a)"
git_c "$REPO23A" checkout -q -b work
printf 'code\n' > "${REPO23A}/f.txt"
git_c "$REPO23A" add f.txt
git_c "$REPO23A" commit -q -m "feat: unrelated"
run_script resolve-base "$REPO23A" main
assert_eq "0" "$RC" "resolve-base exits 0 for an explicit resolving base-ref"
assert_eq "main" "$OUT" "resolve-base echoes the explicit base-ref verbatim"

start_case "28b: resolve-base auto-derives origin/main from origin/HEAD when no explicit base is given"
UPSTREAM23B="${SANDBOX}/repo23b-upstream.git"
git init -q -b main --bare "$UPSTREAM23B"
REPO23B="$(mk_repo repo23b)"
git_c "$REPO23B" remote add origin "$UPSTREAM23B"
git_c "$REPO23B" push -q -u origin main
git_c "$REPO23B" remote set-head origin main
run_script resolve-base "$REPO23B"
assert_eq "0" "$RC" "resolve-base exits 0 when origin/HEAD resolves"
assert_eq "origin/main" "$OUT" "resolve-base auto-derives origin/main with no explicit base-ref"

start_case "28c: resolve-base fails SAFE (empty-tree hash) when nothing resolves"
REPO23C="${SANDBOX}/repo23c"
mkdir -p "$REPO23C"
git_c "$REPO23C" init -q -b trunk        # not 'main'; no remote at all
printf 'placeholder\n' > "${REPO23C}/README.md"
git_c "$REPO23C" add README.md
git_c "$REPO23C" commit -q -m "init"
run_script resolve-base "$REPO23C"
assert_eq "0" "$RC" "resolve-base exits 0 even in the fail-safe case"
assert_eq "4b825dc642cb6eb9a060e54bf8d69288fbee4904" "$OUT" "resolve-base falls back to the empty-tree hash when nothing resolves"

start_case "28d: resolve-base validates its argument the same way exclude/guard/dirty do"
run_script resolve-base
assert_eq "1" "$RC" "resolve-base with no directory argument fails usage validation"

# ===========================================================================
# Summary
# ===========================================================================
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
else
  echo "FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
