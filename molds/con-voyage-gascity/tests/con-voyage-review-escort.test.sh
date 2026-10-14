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

start_case "the seed step clears a stale git worktree registration before re-attaching (review fk-eruo3s LOW-2)"
assert_contains "$SEED_MD" "git worktree remove --force \"\$WORKTREE\"" \
  "seed removes any existing worktree registration at the target path"
assert_contains "$SEED_MD" "git worktree prune" \
  "seed also prunes stale registrations whose directory is already gone"

start_case "the seed step's trust-gate gh pr view call is bounded by a timeout (review fk-eruo3s LOW-5)"
assert_contains "$SEED_MD" "cv_with_timeout 30 gh pr view \"\$PR_NUMBER\"" \
  "the authorAssociation lookup is wrapped in cv_with_timeout"

start_case "the review-escort loop never waits on an apply-review-findings bead"
assert_not_contains "$LOOP_MD" "APPLY_STEP_ID" "loop defines no APPLY_STEP_ID to poll for"
assert_not_contains "$LOOP_MD" "code_review.fix_commit" "loop never gates on a fix commit"
for needle in "git push" "git commit" "git rebase" "git merge "; do
  assert_not_contains "$LOOP_MD" "$needle" "loop does not contain '${needle}'"
done

start_case "the loop resolves cv_lens_escalate_target dynamically instead of relying on dead inline substitution (review fk-eruo3s LOW-1)"
assert_not_contains "$LOOP_MD" 'CV_LENS_ESCALATE_TARGET="{cv_lens_escalate_target}"' \
  "no literal, never-substituted {cv_lens_escalate_target} token is assigned directly"
assert_count "$LOOP_MD" 'cv_bead_metadata "$ROOT_ID" gc.var.cv_lens_escalate_target' "2" \
  "both escalate-target sites (lane re-dispatch, synthesis wait) resolve it via cv_bead_metadata"
assert_count "$LOOP_MD" 'CV_LENS_ESCALATE_TARGET="human"' "2" \
  "both sites fall back to the formula var's own default (human) when metadata is unresolved"

start_case "the loop delegates the root-already-closed entry guard to the shared lib helper (review fk-eruo3s LOW-3)"
assert_contains "$LOOP_MD" 'cv_root_closed_guard "$ROOT_ID" "$CLAIMED_BEAD_ID" "review-escort loop" "review"' \
  "the entry guard calls the shared cv_root_closed_guard helper"
assert_not_contains "$LOOP_MD" "cv_close_workflow_root \"\$ROOT_ID\" \"workflow root already closed before the review-escort loop ran" \
  "the duplicated inline guard body is gone, not just renamed"

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

start_case "the finalize step's push-safety ls-remote call is bounded by a timeout (review fk-eruo3s LOW-4)"
assert_contains "$FINALIZE_MD" "cv_with_timeout 30 git ls-remote origin" \
  "the ls-remote push-safety check is wrapped in cv_with_timeout"

start_case "the finalize step mails the mayor regardless of verdict (review fk-hbsmk BLOCKING-8)"
assert_contains "$FINALIZE_MD" "gc mail send mayor" "finalize mails the mayor"
assert_contains "$FINALIZE_MD" "REVIEW-ESCORT COMPLETE: \${REPO_FULL}#\${PR_NUMBER}" "verdict mail subject line names the repo and PR"
assert_contains "$FINALIZE_MD" "\${OVERALL_LINE}" "verdict mail body carries the derived overall_line, not a placeholder"

start_case "the finalize step never re-posts the aggregated comment on a retry (review fk-hbsmk BLOCKING-7)"
assert_contains "$FINALIZE_MD" "cv_claim_once" "finalize gates the comment post on cv_claim_once"
assert_contains "$FINALIZE_MD" "gc.review_escort.comment_posted" "finalize uses a dedicated idempotency flag for the comment post"
assert_not_contains "$FINALIZE_MD" "<path to the assembled JSON manifest" "finalize no longer embeds a prose placeholder in the --manifest argument"

start_case "the finalize step escalates to the mayor when the comment_posted flag fails to persist (review fk-eruo3s BLOCKING-1)"
assert_contains "$FINALIZE_MD" "claim-unpersisted" "finalize distinguishes an unpersisted claim from a genuine one"
assert_contains "$FINALIZE_MD" "comment_posted flag failed to persist" "finalize escalates to the mayor when the comment_posted flag failed to persist"

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
