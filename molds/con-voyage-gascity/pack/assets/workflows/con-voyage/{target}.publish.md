Publish the con-voyage review result.

Read push {{push}} and open_pr {{open_pr}} from the workflow vars.

Con-voyage posture: push=true causes the reviewed work branch to be pushed to
the remote origin. open_pr=true causes a GitHub PR to be opened against the
base branch. Neither action triggers an auto-merge — the merge_queue="observe"
city.toml monitor watches the PR for CI results and human feedback only. A
human must land the PR.

If push is true:
- Before pushing, run the artifact-hygiene guard as a last line of defense —
  it fails loud if a local tooling path (`.beads/`, `.gc/`, `.claude/`, dolt
  data) is staged or tracked in what is about to go upstream:

  ```bash
  CV_GUARD="$(command -v cv-worktree-prep.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-worktree-prep.sh 2>/dev/null | head -1)"
  if [ -n "$CV_GUARD" ] && [ -x "$CV_GUARD" ]; then
    "$CV_GUARD" guard "$(pwd)" || { echo "hygiene violation detected — fix it before pushing" >&2; exit 1; }
  fi
  ```
- Push the work branch to origin using create-if-absent or lease-checked
  semantics. Fail closed if the remote cannot enforce atomic or lease-safe
  push.

If open_pr is true (requires push to have succeeded):
- Open a PR only after push succeeds.
- Use the final review report for the PR title and body. The title must be a
  conventional-commit title derived from the work bead. The body must include
  the review verdict (APPROVED), the active reviewer roster, the number of
  review cycles completed, and any LOW findings surfaced to the human.
- The PR body is posted under the operator's GitHub PAT, exactly like every
  other piece of text con-voyage writes to GitHub — it MUST lead with the
  machine-identity banner. Do NOT run raw `gh pr create` with an unbannered
  body. Assemble the body, then open the PR through `cv-pr-comment.sh create`
  so the banner is guaranteed:

  ```bash
  CV_BIN="$(command -v cv-pr-comment.sh 2>/dev/null || find "${GC_CITY:-.}" -maxdepth 6 -name cv-pr-comment.sh 2>/dev/null | head -1)"
  if [ -z "$CV_BIN" ] || [ ! -x "$CV_BIN" ]; then
    echo "cv-pr-comment.sh not found — refusing to open the PR without the banner (do NOT fall back to raw gh pr create)" >&2
    exit 1
  fi
  "$CV_BIN" create --repo <owner/repo> --title "<conventional-commit title>" \
    --body-file <path to the assembled PR body> --base <base-branch> --head <work-branch> \
    --formula con-voyage --agent "<rig>/gc.publisher"
  ```
- Do not auto-merge. The PR is opened in ready state for human review only.

If push is false or open_pr is false, record a no-op publish outcome and
preserve the approved con-voyage review result without mutating remotes.

Required workflow root metadata (update before closing):
- gc.build.publish_status=published|noop|failed
- gc.build.publish_action=push|pr|push_pr|noop|failed
- gc.build.publish_recorded_at=<UTC timestamp>
- gc.build.publish_artifact_path=<publish result artifact path>
- gc.build.publish_reason=<short machine-readable reason>

For disabled publishing use gc.build.publish_status=noop,
gc.build.publish_action=noop, and reason push=false_open_pr=false.

Close only after the push, PR creation, or explicit no-op is recorded on both
the workflow root and this publish step.

Do not merge the branch. Do not invoke provider-native subagents.
