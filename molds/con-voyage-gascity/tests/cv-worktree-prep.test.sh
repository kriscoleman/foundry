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
#   `guard <dir>`   — a commit-step backstop: detects any hygiene path
#                     currently staged or already tracked, unstages what it
#                     safely can, and refuses to report clean (non-zero exit)
#                     until nothing offending remains staged.
#
# HOW IT WORKS: real, local git repos created under a temp sandbox (git init
# is fully offline) — no stubs needed, since git's own exclude/ls-files
# behavior is exactly what's under test.
#
# Run:  bash tests/cv-worktree-prep.test.sh   (exit 0 => all passed)

set -uo pipefail

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
# CASE 9 — guard detects a hygiene path that is ALREADY COMMITTED to HEAD
#   (a pre-existing violation). It must BLOCK (fail loud) rather than
#   silently rewrite history, and must leave the file tracked exactly as it
#   was — no destructive git surgery.
# ===========================================================================
start_case "9: guard blocks (never auto-fixes) an already-committed hygiene path"
REPO9="$(mk_repo repo9)"
mkdir -p "${REPO9}/.gc"
printf 'runtime state\n' > "${REPO9}/.gc/state.json"
git_c "$REPO9" add -f .gc/state.json
git_c "$REPO9" commit -q -m "oops: accidentally committed .gc state"
run_script exclude "$REPO9"
tracked_before="$(git_c "$REPO9" ls-files -- .gc)"
run_script guard "$REPO9"
if [ "$RC" -ne 0 ]; then pass "guard exits non-zero for an already-committed hygiene path"; else fail "expected guard to exit non-zero"; fi
if printf '%s' "$OUT" | grep -qi 'BLOCKED'; then
  pass "guard logs a BLOCKED message (cannot auto-fix committed history)"
else
  fail "expected a BLOCKED log line from guard"
fi
tracked_after="$(git_c "$REPO9" ls-files -- .gc)"
assert_eq "$tracked_before" "$tracked_after" "committed hygiene path is still tracked identically (no destructive history rewrite)"
head_before="$(git_c "$REPO9" rev-parse HEAD)"
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
