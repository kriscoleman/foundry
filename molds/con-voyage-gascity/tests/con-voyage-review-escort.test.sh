#!/usr/bin/env bash
# con-voyage-review-escort.test.sh — hermetic, offline contract tests for
# fk-aygo23 (review-only escort for PRs con-voyage didn't build).
#
# WHY: con-voyage-rereview always runs main.apply-review-findings.md, which
# commits fixes and rebases/syncs the PR branch. Pointed at a teammate's PR,
# that would silently become "push commits to your teammate's branch." This
# formula must never create, commit to, rebase, or push any branch, and must
# never register the PR with con-voyage-finalize/pr-watch/ci-repair/
# rereview-watch (con-voyage doesn't own this PR). This suite proves those
# invariants hold in the new formula's own description_files, textually —
# the same hermetic style every other workflow-prose suite in this pack uses
# (see con-voyage-lane-no-pr-comment.test.sh): these .md files are prompts
# for an LLM operator, not executable scripts, so the only thing a test can
# assert is what text is/isn't present.
#
# Run:  bash tests/con-voyage-review-escort.test.sh   (exit 0 => all cases passed)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WORKFLOWS_DIR="${MOLD_DIR}/pack/assets/workflows/con-voyage"
FORMULA="${MOLD_DIR}/pack/formulas/con-voyage-review-escort.formula.toml"
SEED_MD="${WORKFLOWS_DIR}/main.review-escort-seed.md"
LOOP_MD="${WORKFLOWS_DIR}/main.review-escort-loop.md"
FINALIZE_MD="${WORKFLOWS_DIR}/main.review-escort-finalize.md"

for f in "$FORMULA" "$SEED_MD" "$LOOP_MD" "$FINALIZE_MD"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: expected file not found: ${f}" >&2
    exit 2
  fi
done

FAILURES=0
start_case() { echo; echo "=== CASE: $1 ==="; }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label (not found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "  FAIL: $label (still found verbatim in $file)" >&2
    FAILURES=$((FAILURES+1))
  else
    echo "  PASS: $label"
  fi
}

assert_count() {
  local file="$1" pattern="$2" expected="$3" label="$4"
  local actual
  actual="$(grep -oF -- "$pattern" "$file" | wc -l | tr -d ' ')"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label (count=${actual})"
  else
    echo "  FAIL: $label (expected count=${expected}, got ${actual})" >&2
    FAILURES=$((FAILURES+1))
  fi
}

start_case "the seed step never creates, moves, or pushes a branch"
for needle in "git push" "git commit" "git rebase" "git merge " "worktree add -B" "worktree add -b"; do
  assert_not_contains "$SEED_MD" "$needle" "seed does not contain '${needle}'"
done
assert_contains "$SEED_MD" "refs/pull/\${PR_NUMBER}/head" "seed fetches the PR head ref"
assert_contains "$SEED_MD" "worktree add -q --detach" "seed attaches a DETACHED worktree"

start_case "the review-escort loop never waits on an apply-review-findings bead"
assert_not_contains "$LOOP_MD" "APPLY_STEP_ID" "loop defines no APPLY_STEP_ID to poll for"
assert_not_contains "$LOOP_MD" "code_review.fix_commit" "loop never gates on a fix commit"
for needle in "git push" "git commit" "git rebase" "git merge "; do
  assert_not_contains "$LOOP_MD" "$needle" "loop does not contain '${needle}'"
done

start_case "the finalize step never pushes, commits, rebases, merges, or opens a PR"
for needle in "git push" "git commit " "git rebase" "git merge " "cv-pr-comment.sh create" "finalize_write"; do
  assert_not_contains "$FINALIZE_MD" "$needle" "finalize does not contain '${needle}'"
done
assert_not_contains "$FINALIZE_MD" "con-voyage-pr-watch.sh" "finalize never calls con-voyage-pr-watch.sh"
assert_not_contains "$FINALIZE_MD" "con-voyage-ci-repair-guard.sh" "finalize never calls con-voyage-ci-repair-guard.sh"
assert_not_contains "$FINALIZE_MD" "con-voyage-rereview-watch.sh" "finalize never calls con-voyage-rereview-watch.sh"

start_case "the finalize step posts exactly one aggregated comment"
assert_count "$FINALIZE_MD" '"$CV_BIN" comment-aggregate' "1" "finalize calls comment-aggregate exactly once"
assert_contains "$FINALIZE_MD" "--formula con-voyage-review-escort" "finalize identifies itself by formula name"

start_case "the finalize step verifies the PR head was never moved by this formula"
assert_contains "$FINALIZE_MD" "ls-remote origin \"refs/pull/\${PR_NUMBER}/head\"" "finalize re-reads the PR's live remote head"
assert_contains "$FINALIZE_MD" "gc.review_escort.pr_head_sha" "finalize compares against the seeded head sha"

start_case "the finalize step mails the mayor regardless of verdict (review fk-hbsmk BLOCKING-8)"
assert_contains "$FINALIZE_MD" "gc mail send mayor" "finalize mails the mayor"
assert_contains "$FINALIZE_MD" "REVIEW-ESCORT COMPLETE: \${REPO_FULL}#\${PR_NUMBER}" "verdict mail subject line names the repo and PR"
assert_contains "$FINALIZE_MD" "\${OVERALL_LINE}" "verdict mail body carries the derived overall_line, not a placeholder"

start_case "the finalize step never re-posts the aggregated comment on a retry (review fk-hbsmk BLOCKING-7)"
assert_contains "$FINALIZE_MD" "cv_claim_once" "finalize gates the comment post on cv_claim_once"
assert_contains "$FINALIZE_MD" "gc.review_escort.comment_posted" "finalize uses a dedicated idempotency flag for the comment post"
assert_not_contains "$FINALIZE_MD" "<path to the assembled JSON manifest" "finalize no longer embeds a prose placeholder in the --manifest argument"

start_case "the finalize step cleans up the review-escort worktree (review fk-hbsmk BLOCKING-2)"
assert_contains "$FINALIZE_MD" "git worktree remove --force" "finalize removes the attached worktree"

start_case "the finalize step resolves concrete overall_line/report-path values, not bracket placeholders (review fk-hbsmk BLOCKING-3/4/5)"
assert_not_contains "$FINALIZE_MD" "<overall_line from review-synthesis.md>" "no unresolved overall_line placeholder"
assert_not_contains "$FINALIZE_MD" "<final report path>" "no unresolved report-path placeholder in the close metadata"
assert_contains "$FINALIZE_MD" "gc.build.review_report_path=\${REVIEW_REPORT_PATH}" "close metadata references a resolved variable"

start_case "the seed step gates on the PR author's trust level before attaching a worktree (review fk-hbsmk BLOCKING-1)"
assert_contains "$SEED_MD" "authorAssociation" "seed checks the PR author's GitHub authorAssociation"
assert_contains "$SEED_MD" "OWNER|MEMBER|COLLABORATOR" "seed only proceeds for a trusted author association"

start_case "the formula declares no apply-review-findings node and no push/open_pr vars"
assert_not_contains "$FORMULA" 'id = "{target}.apply-review-findings"' "formula does not declare an apply-review-findings node"
assert_not_contains "$FORMULA" "vars.push" "formula declares no push var (this formula never pushes)"
assert_not_contains "$FORMULA" "vars.open_pr" "formula declares no open_pr var (this formula never opens a PR)"
assert_not_contains "$FORMULA" "vars.finalize_key" "formula declares no finalize_key var (no .finalize record)"

start_case "the formula wires seed -> setup -> loop -> finalize in order"
assert_contains "$FORMULA" 'id = "{target}.review-escort-seed"' "formula declares the seed node"
assert_contains "$FORMULA" 'needs = ["{target}.review-escort-seed"]' "setup needs the seed node"
assert_contains "$FORMULA" 'needs = ["{target}.setup-con-voyage-review"]' "the review loop needs setup"
assert_contains "$FORMULA" 'needs = ["{target}.review-escort-loop"]' "finalize needs the review loop"
assert_contains "$FORMULA" 'description_file = "../assets/workflows/con-voyage/main.setup-con-voyage-review.md"' "formula reuses setup-con-voyage-review.md unchanged"
assert_contains "$FORMULA" 'description_file = "../assets/workflows/con-voyage/main.synthesize-review.md"' "formula reuses synthesize-review.md unchanged"
assert_contains "$FORMULA" 'description_file = "../assets/workflows/con-voyage/main.security-review.md"' "formula reuses the security-review lane unchanged"
assert_contains "$FORMULA" 'description_file = "../assets/workflows/con-voyage/main.code-review.md"' "formula reuses the code-review lane unchanged"

if [ "$FAILURES" -gt 0 ]; then
  echo
  echo "FAILED: ${FAILURES} case(s)" >&2
  exit 1
fi

echo
echo "All con-voyage-review-escort cases passed."
exit 0
