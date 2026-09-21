#!/usr/bin/env bash
# con-voyage-pr-watch.test.sh — hermetic, offline test proving the PR monitor
# only ever acts on the operator's own PRs (author scoping).
#
# This is a security-critical test: an earlier unfiltered version of the monitor
# acted on 43 PRs it did not own and got the operator removed from the org. The
# script under test (pack/assets/scripts/con-voyage-pr-watch.sh) enforces a hard
# author-scoping invariant, and this suite proves it.
#
# HOW IT WORKS (no network, no real gc/gh):
#   - We build recording STUB executables named `gh` and `gc` in a temp dir.
#     Each stub returns canned JSON per subcommand AND appends its full argv to
#     a per-binary call-log. The tests assert on those logs.
#   - The script honors GH= / GC= (GH="${GH:-gh}", GC="${GC:-gc}") so we point
#     it at the stubs. GC_CITY and CV_STATE_DIR point at temp dirs.
#   - Stub behavior is switched per test case via env vars read by the stubs
#     (STUB_GH_USER_LOGIN, STUB_PRLIST_MODE, STUB_BACKFILL_MODE, etc.), so a
#     single pair of stubs covers every scenario deterministically.
#
# Run:  bash tests/con-voyage-pr-watch.test.sh   (exit 0 => all cases passed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test relative to this test file.
# ---------------------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLD_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${MOLD_DIR}/pack/assets/scripts/con-voyage-pr-watch.sh"
REAL_SAMPLE_FIXTURE="${TEST_DIR}/fixtures/real-backfill-sample-2026-09-15.json"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script under test not found at ${SCRIPT}" >&2
  exit 2
fi

if [ ! -f "$REAL_SAMPLE_FIXTURE" ]; then
  echo "FATAL: real-sample fixture not found at ${REAL_SAMPLE_FIXTURE}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Hermetic sandbox: one temp root, cleaned up on exit.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cv-pr-watch-test.XXXXXX")"
STUBDIR="${SANDBOX}/stubbin"
mkdir -p "$STUBDIR"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The `gh` stub. Records argv, returns canned JSON, and varies its output by
# subcommand + env-var switches so one stub serves every test case.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gh" <<'GH_STUB'
#!/usr/bin/env bash
# Recording gh stub. Appends full argv (one space-joined line per invocation)
# to $STUB_GH_LOG, then emulates gh. Newlines within an arg are squashed to
# spaces so each invocation stays on exactly one line (grep-friendly).
{ line=""; for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done; printf '%s\n' "$line"; } >> "${STUB_GH_LOG}"

# Helper: read the value following a flag in the argv (e.g. --repo X).
flagval() {
  local want="$1"; shift
  local prev=""
  for a in "$@"; do
    if [ "$prev" = "$want" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  return 1
}

sub="${1:-}"
case "$sub" in
  auth)
    # `gh auth status` — always OK in tests.
    exit 0
    ;;
  api)
    apisub="${2:-}"
    if [ "$apisub" = "graphql" ]; then
      # `gh api graphql -f query=... -F owner=O -F repo=R -F num=N` — PART B's
      # best-effort inline review-thread (reviewThreads) fetch. Returns the
      # GraphQL envelope shape the script's merge step unwraps
      # (data.repository.pullRequest.reviewThreads.nodes). Returns one inline
      # thread comment from a human so the merged payload exercises the
      # reviewThreads path end-to-end.
      #
      # C10 (fk-bhz): each inline comment now also carries `databaseId` (the
      # REST review-comment id `cv-pr-comment.sh reply-thread --comment-id`
      # needs) plus `path`/`line`, so PART B can surface the exact reply target
      # per item. The node `id` (PRRC_test_11) remains the dedup key; databaseId
      # (556677) is the reply target. Real gh returns databaseId as a JSON
      # NUMBER, so it is unquoted here on purpose.
      #
      # STUB_GQL_THREADS_FAIL=1 simulates a GraphQL failure so the fix's
      # best-effort fallback is exercised: the script must degrade to
      # reviews+comments only (empty threads) and STILL route, never aborting.
      if [ "${STUB_GQL_THREADS_FAIL:-0}" = "1" ]; then
        exit 1
      fi
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"comments":{"nodes":[{"id":"PRRC_test_11","databaseId":556677,"path":"src/retry.go","line":42,"author":{"login":"a-human-reviewer"},"body":"inline: rename this var"}]}}]}}}}}
JSON
      exit 0
    fi
    # `gh api user --jq .login` — configurable login for default-resolution tests.
    # STUB_GH_USER_LOGIN unset/empty => emit nothing (simulates unresolvable).
    # STUB_GH_USER_FAIL=1 => exit non-zero.
    if [ "${STUB_GH_USER_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    if [ -n "${STUB_GH_USER_LOGIN:-}" ]; then
      printf '%s\n' "${STUB_GH_USER_LOGIN}"
    fi
    exit 0
    ;;
  pr)
    prsub="${2:-}"
    case "$prsub" in
      list)
        # `gh pr list --repo R --author A --state open --json ...`
        # Vary by --author to prove filtering: only the configured operator's
        # PRs are returned; any other author yields an empty list.
        #
        # STUB_PRLIST_LEAK=1 simulates a leaky/bypassed upstream --author
        # filter: the returned PR carries a DIFFERENT author than requested, so
        # the script's defensive per-PR author re-check must drop it before
        # routing. The `author` object mirrors gh's `--json author` shape.
        author="$(flagval --author "$@")"
        if [ "${STUB_PRLIST_LEAK:-0}" = "1" ]; then
          # Upstream filter "leaked": PR #999 authored by someone else slips in
          # even though we asked for the operator's PRs. The defensive re-check
          # must drop it (no comment fetch, no sling).
          cat <<'JSON'
[{"number":999,"headRefName":"feature/not-ours","url":"https://github.com/kriscoleman/foundry/pull/999","isDraft":false,"author":{"login":"someone-else"}}]
JSON
        elif [ "$author" = "kriscoleman" ]; then
          # Operator owns only PR #11 (open, non-draft), authored by kriscoleman.
          cat <<'JSON'
[{"number":11,"headRefName":"fix/con-voyage-author-scope-pr-monitor","url":"https://github.com/kriscoleman/foundry/pull/11","isDraft":false,"author":{"login":"kriscoleman"}}]
JSON
        else
          # Any non-operator author sees nothing.
          printf '[]\n'
        fi
        exit 0
        ;;
      view)
        # Two shapes:
        #   gh pr view <n> --repo R --json author,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup (PART A)
        #   gh pr view <n> --repo R --json reviews,comments            (PART B)
        num="${3:-}"
        jsonfields="$(flagval --json "$@")"
        if printf '%s' "$jsonfields" | grep -q 'reviewThreads'; then
          # TRIPWIRE (regression guard): FAITHFUL to real gh 2.89, `gh pr view
          # --json` validates every requested field and REJECTS any it does not
          # know. `reviewThreads` is NOT a valid `gh pr view --json` field (it
          # only exists via the GraphQL API) — real gh errors 'Unknown JSON
          # field: "reviewThreads"' and exits non-zero, taking reviews/comments
          # down with it. The fixed script must never request reviewThreads here
          # (it fetches reviewThreads separately via `gh api graphql` below), so
          # this branch firing at all means the fix regressed.
          echo 'Unknown JSON field: "reviewThreads"' >&2
          exit 1
        fi
        if printf '%s' "$jsonfields" | grep -q 'reviews'; then
          # PART B comment fetch (PRIMARY: reviews,comments only — the only
          # valid fields; reviewThreads comes from the graphql stub below).
          #
          # STUB_GH_VIEW_COMMENTS_FAIL=1 simulates a real gh failure (e.g. an
          # unsupported --json field set, or a transient API error) so the PART B
          # resilience fix can be proven: the script must surface this exact
          # stderr text in its WARNING instead of a generic "skipping" message.
          if [ "${STUB_GH_VIEW_COMMENTS_FAIL:-0}" = "1" ]; then
            echo "${STUB_GH_VIEW_COMMENTS_ERR:-GraphQL: Field 'reviewThreads' does not exist on type 'PullRequest' (reviewThreads)}" >&2
            exit 1
          fi
          # Return one human comment for the operator's PR, PLUS one bot-banner
          # comment authored by the operator's own login (kriscoleman) — exactly
          # what cv-pr-comment.sh posts under the PAT. This proves PART B does
          # not re-route the bot's own automated replies as new human feedback.
          # reviewThreads is supplied separately by the `gh api graphql` stub
          # below.
          cat <<'JSON'
{"reviews":[],"comments":[{"id":"IC_test_11","author":{"login":"a-human-reviewer"},"body":"please fix the null check"},{"id":"IC_test_bot","author":{"login":"kriscoleman"},"body":"🤖 **Automated con-voyage agent** (con-voyage-ci-repair / foundry-kc/worker)\n\nFixed a thing."}]}
JSON
          exit 0
        fi
        # PART A author + review-gate resolution (C6 actionable filter). Maps
        # PR number -> author login (unchanged mapping), PLUS — for the C6
        # fixture PRs (900-906) only — canned reviewDecision/mergeable/
        # mergeStateStatus/statusCheckRollup signals. Every pre-existing PR
        # number keeps the SAFE DEFAULT reviewDecision="" (can never satisfy
        # the C6 skip condition, which requires reviewDecision exactly
        # "REVIEW_REQUIRED"), so none of the pre-existing cases are affected.
        review_decision=""
        mergeable_val="MERGEABLE"
        merge_state_status_val="CLEAN"
        checks_rollup_json="[]"
        case "$num" in
          11)  pr_author_val="kriscoleman" ;;   # operator — KEEP
          12)  pr_author_val="kriscoleman" ;;   # operator (states: dirty) — KEEP
          13)  pr_author_val="kriscoleman" ;;   # operator (states: behind) — KEEP
          14)  pr_author_val="kriscoleman" ;;   # operator (states: blocked) — KEEP
          15)  pr_author_val="kriscoleman" ;;   # operator (states: trust-gc precedence) — KEEP
          16)  pr_author_val="kriscoleman" ;;   # operator (field-shift: empty title) — KEEP
          17)  pr_author_val="kriscoleman" ;;   # operator (field-shift: empty head_sha) — KEEP
          18)  pr_author_val="kriscoleman" ;;   # operator (fallback classifier: state=failed) — KEEP
          90001|90002|90003|90004|90005)
               pr_author_val="kriscoleman" ;;   # operator (LOW-2 real-sample gate fixture) — KEEP
          500) pr_author_val="evansmungai" ;;   # other human — DROP
          501) pr_author_val="evansmungai" ;;   # other human (states: dirty) — DROP
          502) pr_author_val="evansmungai" ;;   # other human (states: behind) — DROP
          503) pr_author_val="evansmungai" ;;   # other human (states: blocked) — DROP
          600) pr_author_val="dependabot[bot]" ;; # bot — DROP
          700) pr_author_val="kriscoleman2" ;;  # near-match — DROP (exact match only)
          701) pr_author_val="KRISCOLEMAN" ;;   # case variant — DROP (case-sensitive)
          800) pr_author_val="" ;;              # unresolved author — DROP (fail closed)
          900)
               # C6: all-green + MERGEABLE + REVIEW_REQUIRED + up to date -> SKIP.
               pr_author_val="kriscoleman"
               review_decision="REVIEW_REQUIRED"
               mergeable_val="MERGEABLE"
               merge_state_status_val="BLOCKED"
               checks_rollup_json='[{"conclusion":"SUCCESS"},{"conclusion":"NEUTRAL"}]'
               ;;
          901)
               # C6 clause 3 (no regression): classified checks_failed (a real
               # failing check exists) despite REVIEW_REQUIRED -> gate never
               # runs (only applies to failure_kind=blocked) -> must mint.
               pr_author_val="kriscoleman"
               review_decision="REVIEW_REQUIRED"
               mergeable_val="MERGEABLE"
               merge_state_status_val="BLOCKED"
               checks_rollup_json='[{"conclusion":"SUCCESS"}]'
               ;;
          902)
               # blocked + REVIEW_REQUIRED + MERGEABLE but a check is actually
               # FAILING live -> not all green -> must still mint.
               pr_author_val="kriscoleman"
               review_decision="REVIEW_REQUIRED"
               mergeable_val="MERGEABLE"
               merge_state_status_val="BLOCKED"
               checks_rollup_json='[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"}]'
               ;;
          903)
               # blocked + REVIEW_REQUIRED + MERGEABLE + all green but BEHIND
               # base live -> not up to date -> must still mint.
               pr_author_val="kriscoleman"
               review_decision="REVIEW_REQUIRED"
               mergeable_val="MERGEABLE"
               merge_state_status_val="BEHIND"
               checks_rollup_json='[{"conclusion":"SUCCESS"}]'
               ;;
          904)
               # blocked + CHANGES_REQUESTED (NOT REVIEW_REQUIRED) + otherwise
               # clean -> the AC scopes the skip to REVIEW_REQUIRED only ->
               # must still mint.
               pr_author_val="kriscoleman"
               review_decision="CHANGES_REQUESTED"
               mergeable_val="MERGEABLE"
               merge_state_status_val="BLOCKED"
               checks_rollup_json='[{"conclusion":"SUCCESS"}]'
               ;;
          905)
               # blocked + REVIEW_REQUIRED + all green but NOT mergeable
               # (CONFLICTING) -> must still mint.
               pr_author_val="kriscoleman"
               review_decision="REVIEW_REQUIRED"
               mergeable_val="CONFLICTING"
               merge_state_status_val="DIRTY"
               checks_rollup_json='[{"conclusion":"SUCCESS"}]'
               ;;
          906)
               # Same green/mergeable/REVIEW_REQUIRED signals as #900, but
               # authored by a NON-operator -> the author gate must DROP it
               # before the C6 gate ever runs (no "awaiting-human" SKIP log).
               pr_author_val="evansmungai"
               review_decision="REVIEW_REQUIRED"
               mergeable_val="MERGEABLE"
               merge_state_status_val="BLOCKED"
               checks_rollup_json='[{"conclusion":"SUCCESS"}]'
               ;;
          *)   pr_author_val="" ;;
        esac
        printf '{"author":{"login":"%s"},"reviewDecision":"%s","mergeable":"%s","mergeStateStatus":"%s","statusCheckRollup":%s}\n' \
          "$pr_author_val" "$review_decision" "$mergeable_val" "$merge_state_status_val" "$checks_rollup_json"
        exit 0
        ;;
    esac
    ;;
esac
# Unknown call — record already done; succeed quietly.
exit 0
GH_STUB
chmod +x "${STUBDIR}/gh"

# ---------------------------------------------------------------------------
# The `gc` stub. Records argv, returns canned backfill JSON, and no-ops sling.
# ---------------------------------------------------------------------------
cat > "${STUBDIR}/gc" <<'GC_STUB'
#!/usr/bin/env bash
# Recording gc stub. Appends full argv (one space-joined line per invocation)
# to $STUB_GC_LOG, then emulates gc. Newlines within an arg are squashed to
# spaces so each invocation stays on exactly one line (grep-friendly).
#
# STDIN CAPTURE: `gc sling ... --stdin` reads the bead title/body from stdin
# (first line = title, rest = body). The recorded argv alone would only show
# `sling <target> --stdin`, hiding the routed content, so when --stdin is present
# we drain stdin and APPEND its (newline-squashed) content to the same log line.
# This keeps content assertions (e.g. the "Human PR feedback on ..." title)
# working after the PART B fix that switched off the (nonexistent) --body flag.
stdin_capture=""
for _a in "$@"; do
  if [ "$_a" = "--stdin" ]; then
    stdin_capture="$(cat)"
    break
  fi
done
{
  line=""
  for a in "$@"; do a="${a//$'\n'/ }"; line="${line}${a} "; done
  if [ -n "$stdin_capture" ]; then
    sc="${stdin_capture//$'\n'/ }"
    line="${line}STDIN: ${sc} "
  fi
  printf '%s\n' "$line"
} >> "${STUB_GC_LOG}"

# gc is invoked as: gc [--city <dir>] [--rig <rig>] <subcommand> ...
# Both --city and --rig are TOP-LEVEL flags that precede the subcommand (the
# script emits `--city <dir>` first, and — after the cross-rig fix — `--rig
# <rig>` on the repair-bead `bd create`). Skip ALL leading `--city X`/`--rig X`
# pairs (order-independent) to find the real subcommand, and capture the --rig
# value so `bd create` can mint an id with the matching rig prefix.
args=("$@")
i=0
rig_flag=""
while :; do
  case "${args[$i]:-}" in
    --city)
      i=$((i+2))
      ;;
    --rig)
      rig_flag="${args[$((i+1))]:-}"
      i=$((i+2))
      ;;
    *)
      break
      ;;
  esac
done
sub="${args[$i]:-}"

# Map a rig NAME to its bead prefix (mirrors the city's real rig prefixes).
# No --rig (city store) mints an "rc"-prefixed bead — exactly the mis-homed
# prefix that triggers the real cross-rig routing failure this stub emulates.
rig_prefix_for() {
  case "$1" in
    "")                rc_pfx="rc" ;;   # no rig => city store
    vandoor)           rc_pfx="va" ;;
    foundry|foundry-kc) rc_pfx="fk" ;;
    embedded-cluster)  rc_pfx="emc" ;;
    kurl)              rc_pfx="ku" ;;
    *)                 rc_pfx="xx" ;;   # unknown rig => sentinel prefix
  esac
  printf '%s' "$rc_pfx"
}

case "$sub" in
  github)
    # gc --city X github pr backfill --json
    if [ "${args[$((i+1))]:-}" = "pr" ] && [ "${args[$((i+2))]:-}" = "backfill" ]; then
      case "${STUB_BACKFILL_MODE:-full}" in
        empty)
          printf '{"results":[]}\n'
          ;;
        full)
          # Mixed authors + actionability. Exactly the cases the test needs.
          #
          # STUB_HEAD_SHA overrides ONLY PR #11's head_sha (defaults to the
          # historical "aaa111" so every pre-existing case is unaffected). This
          # lets a test advance #11's branch head between cycles. Dedup is keyed
          # on repo+PR NUMBER only (not head-sha) — see CASE 9 — so a new head
          # alone never re-keys the mint; it only re-mints once the previously
          # tracked bead is no longer genuinely in-flight.
          # #11's line is emitted via printf (so the env var expands); the rest
          # stay in a single-quoted heredoc (byte-identical, no expansion).
          # repair_route carries a real "<rig>/<agent>" prefix (vandoor/...). The
          # script derives the mint rig ("vandoor") from the part before the
          # first "/", so the bead is minted with the "va" prefix and routes
          # same-rig. (Pre-fix fixtures used a bare "gc.implementation-worker"
          # with no rig — which the fixed script now correctly SKIPS as
          # underivable; real backfill routes always carry the rig.)
          #
          # Every row also carries state/failed_checks/merge_state_status (real
          # backfill always includes them — `state` is a required field per the
          # gc schema). All of them classify as failure_kind=checks_failed here
          # (non-empty failed_checks), since this fixture predates per-state
          # classification (CV-B) and its cases are about AUTHOR SCOPING, not
          # state variety — STUB_BACKFILL_MODE=states below covers state variety.
          printf '{"results":[\n'
          printf '  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":11,"title":"author-scope pr monitor","head_ref_name":"fix/con-voyage-author-scope-pr-monitor","head_sha":"%s","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":["ci"],"merge_state_status":"UNSTABLE"},\n' "${STUB_HEAD_SHA:-aaa111}"
          cat <<'JSON'
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":500,"title":"someone elses pr","head_ref_name":"feature/x","head_sha":"bbb500","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":["ci"],"merge_state_status":"UNSTABLE"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":600,"title":"dep bump","head_ref_name":"deps/y","head_sha":"ccc600","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":["ci"],"merge_state_status":"UNSTABLE"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":700,"title":"near match author","head_ref_name":"feature/z","head_sha":"ddd700","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":["ci"],"merge_state_status":"UNSTABLE"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":701,"title":"case variant author","head_ref_name":"feature/w","head_sha":"eee701","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":["ci"],"merge_state_status":"UNSTABLE"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":800,"title":"unresolved author","head_ref_name":"feature/u","head_sha":"fff800","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":["ci"],"merge_state_status":"UNSTABLE"},
  {"actionable":false,"owner":"kriscoleman","repo":"foundry","number":999,"title":"not actionable","head_ref_name":"feature/na","head_sha":"999999","repair_route":"vandoor/gc.implementation-worker"}
]}
JSON
          ;;
        norig)
          # A single actionable operator PR whose repair_route has NO "<rig>/"
          # prefix, so the script cannot derive a target rig. Exercises the
          # CROSS-RIG MINT GUARD: the script must SKIP with a WARNING and mint
          # NOTHING (creating a bead would mis-home it and fail cross-rig routing).
          cat <<'JSON'
{"results":[
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":11,"title":"no rig in route","head_ref_name":"fix/con-voyage-author-scope-pr-monitor","head_sha":"aaa111","repair_route":"gc.implementation-worker","state":"blocked","failed_checks":["ci"],"merge_state_status":"UNSTABLE"}
]}
JSON
          ;;
        flip)
          # FIX-C fixture (fk-zyh5): a single operator PR (#11, SAME head_sha
          # across cycles) whose failure_kind is pinned directly by
          # STUB_FLIP_KIND (default "blocked") — gc-provided, so the
          # classifier trusts it as-is regardless of state/failed_checks.
          # Lets a test drive #11 through consecutive cycles with a DIFFERENT
          # classification each time (e.g. blocked -> checks_failed ->
          # blocked) with NO head movement, reproducing kots#6067's observed
          # blocked<->checks_failed oscillation on a ~10min classifier
          # cooldown. PR #11 gets no canned reviewDecision from the gh stub
          # (that table only covers 900-906), so the safe-default
          # reviewDecision="" never trips the C6 awaiting-human skip here.
          printf '{"results":[{"actionable":true,"owner":"kriscoleman","repo":"foundry","number":11,"title":"oscillating pr","head_ref_name":"fix/con-voyage-author-scope-pr-monitor","head_sha":"%s","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"UNSTABLE","failure_kind":"%s"}]}\n' \
            "${STUB_HEAD_SHA:-aaa111}" "${STUB_FLIP_KIND:-blocked}"
          ;;
        states)
          # Native-monitor parity fixtures (R3/CV-B, fk-08o): one operator PR per
          # state (failing-CI/DIRTY/BEHIND/BLOCKED) plus a matching non-operator
          # PR per state, so R5.1/R5.2/R5.4/R5.5 can assert the classifier AND
          # the author gate together.
          #
          # REAL-SAMPLE FINDING (verify-gate, design doc §1c decision 6): a live
          # `gc github pr backfill --json` against this city's own configured
          # monitors shows gc ALREADY emits `failure_kind` directly (exactly
          # this vocabulary — checks_failed/merge_conflict/blocked confirmed
          # live) and `state` values that do NOT match the design doc's
          # strings-recovered guess (`failed`, not a bare `failed_checks[]`
          # signal alone; `conflicted`, not `dirty`). These rows carry
          # `failure_kind` directly, same as real gc, so they exercise the
          # PRIMARY (trust-gc) classification path. `behind_base`/"behind" was
          # not observed live (no monitored PR was in that state at
          # sample-time) — same gc mechanism, just unconfirmed by a live
          # sample; flagged in the implementation summary's Remaining Risks.
          # #20 is actionable:false (clean) to prove no-churn (R5.4). All
          # routes carry the "vandoor/" rig prefix so mint/sling behave like
          # every other case here.
          cat <<'JSON'
{"results":[
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":11,"title":"failing checks pr","head_ref_name":"fix/cv-b-checks","head_sha":"s11","repair_route":"vandoor/gc.implementation-worker","state":"failed","failed_checks":["build"],"merge_state_status":"BLOCKED","failure_kind":"checks_failed"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":12,"title":"dirty pr","head_ref_name":"fix/cv-b-dirty","head_sha":"s12","repair_route":"vandoor/gc.implementation-worker","state":"conflicted","failed_checks":[],"merge_state_status":"DIRTY","failure_kind":"merge_conflict"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":13,"title":"behind pr","head_ref_name":"fix/cv-b-behind","head_sha":"s13","repair_route":"vandoor/gc.implementation-worker","state":"behind","failed_checks":[],"merge_state_status":"BEHIND","failure_kind":"behind_base"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":14,"title":"blocked pr","head_ref_name":"fix/cv-b-blocked","head_sha":"s14","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"BLOCKED","failure_kind":"blocked"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":500,"title":"failing checks pr (not ours)","head_ref_name":"feature/x500","head_sha":"s500","repair_route":"vandoor/gc.implementation-worker","state":"failed","failed_checks":["build"],"merge_state_status":"BLOCKED","failure_kind":"checks_failed"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":501,"title":"dirty pr (not ours)","head_ref_name":"feature/x501","head_sha":"s501","repair_route":"vandoor/gc.implementation-worker","state":"conflicted","failed_checks":[],"merge_state_status":"DIRTY","failure_kind":"merge_conflict"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":502,"title":"behind pr (not ours)","head_ref_name":"feature/x502","head_sha":"s502","repair_route":"vandoor/gc.implementation-worker","state":"behind","failed_checks":[],"merge_state_status":"BEHIND","failure_kind":"behind_base"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":503,"title":"blocked pr (not ours)","head_ref_name":"feature/x503","head_sha":"s503","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"BLOCKED","failure_kind":"blocked"},
  {"actionable":false,"owner":"kriscoleman","repo":"foundry","number":20,"title":"clean pr","head_ref_name":"feature/clean","head_sha":"s20","repair_route":"vandoor/gc.implementation-worker","state":"clean","failed_checks":[],"merge_state_status":"CLEAN"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":15,"title":"trust-gc pr","head_ref_name":"fix/cv-b-trust-gc","head_sha":"s15","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":["build"],"merge_state_status":"BLOCKED","failure_kind":"blocked"}
]}
JSON
          ;;
        reviewgate)
          # C6 actionable-filter fixtures (fk-t9f/fk-0dl): every row here is
          # gc-classified failure_kind=blocked (the ambiguous catch-all) EXCEPT
          # #901 (checks_failed) — the gh stub (see the `view` case above)
          # layers the reviewDecision/mergeable/mergeStateStatus/
          # statusCheckRollup signals that make each one either a genuine
          # awaiting-human no-op (#900) or a real defect that must still mint
          # (#901-#906, one violated precondition each — see the gh stub
          # comments for which). None of these are BEHIND/DIRTY at the gc
          # backfill classification layer itself (that's a separate, already-
          # covered case in "states"); the live-vs-backfill BEHIND distinction
          # for #903 is deliberately only visible in the gh stub's live view.
          cat <<'JSON'
{"results":[
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":900,"title":"awaiting human review","head_ref_name":"fix/cv-c6-900","head_sha":"s900","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"BLOCKED","failure_kind":"blocked"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":901,"title":"review required but failing check","head_ref_name":"fix/cv-c6-901","head_sha":"s901","repair_route":"vandoor/gc.implementation-worker","state":"failed","failed_checks":["build"],"merge_state_status":"DIRTY","failure_kind":"checks_failed"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":902,"title":"review required but a check is actually failing","head_ref_name":"fix/cv-c6-902","head_sha":"s902","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"BLOCKED","failure_kind":"blocked"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":903,"title":"review required but branch behind base","head_ref_name":"fix/cv-c6-903","head_sha":"s903","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"BLOCKED","failure_kind":"blocked"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":904,"title":"changes requested, not review required","head_ref_name":"fix/cv-c6-904","head_sha":"s904","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"BLOCKED","failure_kind":"blocked"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":905,"title":"review required but not mergeable","head_ref_name":"fix/cv-c6-905","head_sha":"s905","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"BLOCKED","failure_kind":"blocked"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":906,"title":"non-operator, otherwise identical to 900","head_ref_name":"fix/cv-c6-906","head_sha":"s906","repair_route":"vandoor/gc.implementation-worker","state":"blocked","failed_checks":[],"merge_state_status":"BLOCKED","failure_kind":"blocked"}
]}
JSON
          ;;
        fieldshift)
          # BLOCKING-1 regression fixtures (fk-4xq): gc's schema marks
          # title/head_sha/repair_route OPTIONAL. The PART A python->bash
          # field handoff previously joined fields with a TAB, and tab is
          # "IFS whitespace" — bash's `read` COLLAPSES consecutive tabs and
          # strips leading/trailing runs, so an EMPTY optional field shifts
          # every LATER field left by one and failure_kind (the last field)
          # silently lands empty, tripping the empty-failure_kind guard and
          # DROPPING a PR we must repair (proven live on an operator DIRTY PR
          # with an empty title). #16 has an EMPTY title; #17 has an EMPTY
          # head_sha. Both are operator PRs and BOTH must still classify
          # correctly and mint a bead — the fix (a non-whitespace \x1f
          # delimiter) must preserve empty fields regardless of position.
          cat <<'JSON'
{"results":[
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":16,"title":"","head_ref_name":"fix/cv-b-empty-title","head_sha":"s16","repair_route":"vandoor/gc.implementation-worker","state":"failed","failed_checks":["build"],"merge_state_status":"BLOCKED","failure_kind":"checks_failed"},
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":17,"title":"empty sha pr","head_ref_name":"fix/cv-b-empty-sha","head_sha":"","repair_route":"vandoor/gc.implementation-worker","state":"conflicted","failed_checks":[],"merge_state_status":"DIRTY","failure_kind":"merge_conflict"}
]}
JSON
          ;;
        failedstate)
          # LOW-1 regression fixture (fk-4xq): state=="failed" with EMPTY
          # failed_checks[] and NO gc-provided failure_kind field. The
          # fallback derivation must still classify this as checks_failed
          # (matching the documented vocabulary) instead of falling through
          # to the empty/undifferentiated case.
          cat <<'JSON'
{"results":[
  {"actionable":true,"owner":"kriscoleman","repo":"foundry","number":18,"title":"failed state, no failed_checks list","head_ref_name":"fix/cv-b-failed-state","head_sha":"s18","repair_route":"vandoor/gc.implementation-worker","state":"failed","failed_checks":[],"merge_state_status":"BLOCKED"}
]}
JSON
          ;;
        realsample)
          # LOW-2 real-sample gate (cv-b-fk-08o decision 6 / fk-4xq): emits the
          # SANITIZED, REAL-captured backfill sample from
          # tests/fixtures/real-backfill-sample-2026-09-15.json (built by the
          # test setup below via STUB_REALSAMPLE_JSON), so the classifier is
          # exercised against actual observed gc output shapes, not just
          # hand-authored fixtures.
          #
          # NOTE: intentionally NOT `${STUB_REALSAMPLE_JSON:-{...}}` — a
          # default word containing unescaped braces confuses bash's
          # parameter-expansion brace-matching (it closes the expansion at
          # the FIRST unescaped '}' inside the default word, leaking a stray
          # trailing '}' into the output). A plain conditional sidesteps it.
          if [ -n "${STUB_REALSAMPLE_JSON:-}" ]; then
            printf '%s' "$STUB_REALSAMPLE_JSON"
          else
            printf '{"results":[]}'
          fi
          ;;
      esac
      exit 0
    fi
    exit 0
    ;;
  bd)
    # `gc [--city X] [--rig <rig>] bd create "<title>" --priority N --silent`
    # Faithful stub of the repair-bead pre-create step: --silent makes real gc
    # print ONLY the new bead id on stdout. We mint a deterministic fake id so
    # the sling step (below) has a real positional bead to attach the formula to.
    #
    # RIG-AWARE PREFIX (crux of the cross-rig fix): the minted id's PREFIX is
    # derived from the top-level --rig value (captured above as $rig_flag) via
    # rig_prefix_for. With --rig vandoor the id is "va-newbead"; with NO --rig it
    # is "rc-newbead" (city store) — exactly the mis-homed prefix that makes the
    # subsequent same-target sling fail the cross-rig gate below. This lets the
    # test distinguish a correctly-homed mint (fix) from a city mint (old bug).
    # STUB_BD_CREATE_ID still overrides the whole id verbatim when a test needs a
    # fixed value regardless of rig.
    #
    # STUB_BD_CREATE_FAIL=1 simulates a failed pre-create (gc prints nothing and
    # exits non-zero), so the script's empty-id guard is exercised: it must abort
    # the mint before slinging and leave NO dedup marker (so the mint is retried).
    if [ "${args[$((i+1))]:-}" = "create" ]; then
      if [ "${STUB_BD_CREATE_FAIL:-0}" = "1" ]; then
        exit 1
      fi
      if [ -n "${STUB_BD_CREATE_ID:-}" ]; then
        printf '%s\n' "${STUB_BD_CREATE_ID}"
      else
        printf '%s-newbead\n' "$(rig_prefix_for "$rig_flag")"
      fi
      exit 0
    fi
    # STUB_BD_UPDATE_FAIL=1 simulates a failed `bd update` (e.g. the FIX-C
    # in-place title/failure_kind update on a still-open tracked bead), so the
    # retry discipline can be proven: the script must NOT advance
    # last_handled_state, must NOT fall back to a fresh mint, and must NOT
    # supersede the tracked bead either — the same update is simply retried
    # next cycle.
    if [ "${args[$((i+1))]:-}" = "update" ] && [ "${STUB_BD_UPDATE_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    # `gc [--city X] bd show <id> --json` — faithful stub of the PR-scoped
    # dedup in-flight check (C5). STUB_BDSHOW_MAP is a newline-delimited
    # lookup table of "<id>|<status>|<assignee>" entries (pipe-separated so
    # ids/statuses never collide with the delimiter). A bead id with no
    # matching entry returns an empty JSON object (unknown/never-minted bead).
    # `bd close`/`bd update` are deliberately NOT special-cased beyond the
    # STUB_BD_UPDATE_FAIL check above — they fall through to the generic
    # `exit 0` below, which is all the script under test requires; the argv is
    # still recorded in $STUB_GC_LOG by the universal logging above, so
    # close/update calls remain assertable.
    if [ "${args[$((i+1))]:-}" = "show" ]; then
      show_id="${args[$((i+2))]:-}"
      match=""
      if [ -n "${STUB_BDSHOW_MAP:-}" ]; then
        match="$(printf '%s\n' "$STUB_BDSHOW_MAP" | awk -F'|' -v id="$show_id" '$1==id{print; exit}')"
      fi
      if [ -n "$match" ]; then
        show_status="$(printf '%s' "$match" | awk -F'|' '{print $2}')"
        show_assignee="$(printf '%s' "$match" | awk -F'|' '{print $3}')"
        printf '{"id":"%s","status":"%s","assignee":"%s"}\n' "$show_id" "$show_status" "$show_assignee"
      else
        printf '{}\n'
      fi
      exit 0
    fi
    exit 0
    ;;
  sling)
    # Faithful stub of `gc sling` v2-formula validation (gc 1.4.1).
    #
    # This is the crux of the bug the fix addresses. Real gc 1.4.1 REJECTS a
    # v2 formula that references {{convoy_id}} (like con-voyage-ci-repair) when
    # it is inline-created with `--on <formula>` and no positional bead — it errors
    # with "inline text requires explicit target" and exits non-zero, so NO bead is
    # ever minted. The correct form supplies a PRE-CREATED bead as the positional:
    #     gc sling <target> <BEAD> --on <formula> --var ...
    #
    # We emulate exactly that acceptance rule so the tests go RED against the old
    # (no-bead) invocation and GREEN against the fixed (bead-positional) one.
    #
    # Parse the args after the subcommand: sling <target> [<bead>] [flags...]
    # (the leading `--city <dir>` is already accounted for by $i).
    has_on=0
    on_val=""
    # sling positional target/bead are the non-flag args immediately after `sling`.
    # Collect up to two leading positionals before the first flag.
    positionals=()
    j=$((i+1))
    seen_flag=0
    prev_flag=""
    while [ "$j" -lt "${#args[@]}" ]; do
      cur="${args[$j]}"
      case "$cur" in
        --on)
          has_on=1
          prev_flag="--on"
          seen_flag=1
          ;;
        --*)
          # A value-taking flag we care about: capture --on's value on next arg.
          prev_flag="$cur"
          seen_flag=1
          ;;
        *)
          if [ "$prev_flag" = "--on" ]; then
            on_val="$cur"
            prev_flag=""
          elif [ "$seen_flag" -eq 0 ]; then
            # Leading positional (target or bead), before any flag.
            positionals+=("$cur")
          else
            # value for some other flag; ignore
            prev_flag=""
          fi
          ;;
      esac
      j=$((j+1))
    done

    if [ "$has_on" -eq 1 ]; then
      # v2-formula attach path. Require a positional BEAD in addition to the
      # target — i.e. at least two leading positionals (target + bead).
      if [ "${#positionals[@]}" -lt 2 ]; then
        # Mirror real gc 1.4.1's rejection.
        echo "gc sling: inline text requires explicit target; usage: gc sling <target> <bead> --on <formula>" >&2
        exit 1
      fi
      # target = positionals[0], bead = positionals[1].
      sling_target="${positionals[0]}"
      sling_bead="${positionals[1]}"

      # CROSS-RIG ROUTING GATE (crux of the fk-974 fix, emulating REAL gc): gc
      # refuses to route a bead to an agent in a DIFFERENT rig. The target's rig
      # is the part BEFORE the first "/" (e.g. "vandoor" in
      # "vandoor/gc.implementation-worker") -> its prefix via rig_prefix_for. The
      # bead's rig is its id prefix (the part BEFORE the first "-", e.g. "rc" in
      # "rc-newbead", "va" in "va-newbead"). If they differ, real gc prints the
      # "cross-rig routing" error and exits non-zero WITHOUT routing — so no
      # marker is written and the OLD (no --rig -> "rc" bead) form goes RED here.
      target_rig="${sling_target%%/*}"
      target_pfx="$(rig_prefix_for "$target_rig")"
      bead_pfx="${sling_bead%%-*}"
      if [ "$bead_pfx" != "$target_pfx" ]; then
        echo "cross-rig routing — bead ${sling_bead} (prefix \"${bead_pfx}\") → agent ${sling_target} (rig prefix \"${target_pfx}\")" >&2
        exit 1
      fi
      # Well-formed, same-rig mint.
      #
      # STUB_SLING_FAIL=1 makes ONLY this well-formed bead-positional formula
      # mint fail (routing to the ci-repair convoy fails after the bead was
      # already created). This is deliberately scoped to the --on formula path
      # so PART B's plain `sling <target> --stdin` route (which never sets
      # has_on) is unaffected — exactly like a transient routing error that hits
      # the repair mint but not comment routing. Exercises the script's contract
      # that the .minted dedup marker is written ONLY after a successful
      # mint+route, so a failed sling is retried (no marker) next cycle.
      if [ "${STUB_SLING_FAIL:-0}" = "1" ]; then
        echo "gc sling: failed to route bead to con-voyage-ci-repair convoy (simulated)" >&2
        exit 1
      fi
      # Accept.
      exit 0
    fi

    # Non-formula path (PART B). Accept plain text/stdin routes.
    exit 0
    ;;
  session)
    sessub="${args[$((i+1))]:-}"
    if [ "$sessub" = "list" ]; then
      # `gc session list --json` — implementor_alive resolution (Task 2,
      # fk-4o74 Fix 1). STUB_SESSION_LIST_JSON lets a test supply the exact
      # sessions array (real shape: {"sessions":[{"id":...,"alias":...,
      # "name":...,"session_name":...,"state":"active|suspended|closed"}]});
      # default is an empty list (no sessions => nobody is alive).
      if [ -n "${STUB_SESSION_LIST_JSON:-}" ]; then
        printf '%s' "$STUB_SESSION_LIST_JSON"
      else
        printf '{"ok":true,"sessions":[]}'
      fi
      exit 0
    fi
    exit 0
    ;;
  mail)
    mailsub="${args[$((i+1))]:-}"
    if [ "$mailsub" = "send" ]; then
      # `gc mail send <target> -s ... -m ... --notify` — Task 3 reuse-dispatch
      # (fk-4o74 Fix 1). STUB_MAIL_SEND_FAIL=1 simulates a delivery failure
      # (e.g. the target address no longer resolves), mirroring the existing
      # STUB_SLING_FAIL pattern for the fallback path.
      if [ "${STUB_MAIL_SEND_FAIL:-0}" = "1" ]; then
        echo "gc mail send: failed to deliver (simulated)" >&2
        exit 1
      fi
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
GC_STUB
chmod +x "${STUBDIR}/gc"

# ---------------------------------------------------------------------------
# Test harness bookkeeping.
# ---------------------------------------------------------------------------
FAILURES=0
CASE_NAME=""

start_case() { CASE_NAME="$1"; echo; echo "=== CASE: ${CASE_NAME} ==="; }

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES+1)); }

# assert_eq EXPECTED ACTUAL MESSAGE
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (=$1)"; else fail "$3 (expected '$1', got '$2')"; fi
}

# Count how many stub invocations in a log match a grep -E pattern.
# Each invocation is one space-joined line in the log (see stub logging above),
# so a plain line-oriented grep -c is exact.
log_count() {
  local logfile="$1" pattern="$2"
  [ -f "$logfile" ] || { echo 0; return; }
  # grep -c prints the count and exits 1 when zero matches; capture the count
  # regardless of exit status (do NOT chain `|| echo 0`, which double-prints).
  # `--` terminates option parsing so a pattern that STARTS with a dash (e.g.
  # "--rig vandoor bd create ..." — asserting the top-level --rig on the mint) is
  # treated as the pattern, not as grep flags. Portable on BSD (macOS) and GNU.
  local n
  n="$(grep -E -c -- "$pattern" "$logfile")"
  printf '%s' "${n:-0}"
}

# assert_log_count LOGFILE PATTERN EXPECTED MESSAGE
assert_log_count() {
  local n; n="$(log_count "$1" "$2")"
  assert_eq "$3" "$n" "$4"
}

# state_field STATE_DIR DEDUP_KEY FIELD — reads one key=value field out of the
# new per-PR state record (Task 1, fk-4o74: replaces the old bead-id-only
# "<dedup_key>.minted" marker). Empty output if the file or field is absent.
state_field() {
  local f="${1}/${2}.state" field="$3"
  [ -f "$f" ] || return 0
  awk -F= -v k="$field" '$1==k{ sub(/^[^=]*=/, ""); print; exit }' "$f"
}

# Fresh per-case environment. Sets up city dir, state dir, empty logs.
CITY_DIR=""
STATE_DIR=""
GH_LOG=""
GC_LOG=""
OUT=""
RC=0

setup_case_env() {
  CITY_DIR="${SANDBOX}/city-${1}"
  STATE_DIR="${SANDBOX}/state-${1}"
  GH_LOG="${SANDBOX}/gh-${1}.log"
  GC_LOG="${SANDBOX}/gc-${1}.log"
  mkdir -p "$CITY_DIR" "$STATE_DIR"
  : > "$GH_LOG"
  : > "$GC_LOG"
  # A city.toml with one pr_monitor block so PART B has a repo to scan.
  # Unspaced assignments (owner="...") — parses under both BSD awk and gawk.
  # (The spaced variant is exercised separately by setup_case_env_spaced, which
  # guards the awk-portability fix.)
  cat > "${CITY_DIR}/city.toml" <<'TOML'
[[github.pr_monitor]]
owner="kriscoleman"
repo="foundry"
base="main"
merge_queue="observe"
TOML
}

# setup_case_env_spaced — like setup_case_env, but writes SPACED TOML
# assignments (owner = "..."). This is the fixture that catches the awk
# portability bug: the old parser used `\s`, which BSD/macOS awk treats as a
# literal 's', so it parsed ZERO repos from spaced assignments and PART B
# silently no-oped. With the [[:space:]] fix it parses correctly under BOTH
# BSD awk and gawk. Run under the system awk (this box is macOS/BSD) so the
# case actually exercises the bug.
setup_case_env_spaced() {
  setup_case_env "$1"
  cat > "${CITY_DIR}/city.toml" <<'TOML'
[[github.pr_monitor]]
owner = "replicatedhq"
repo = "x"
base = "main"
merge_queue = "observe"
TOML
}

# run_script — invoke the script under test with the stubs wired in.
# Extra args ("$@") are KEY=VAL overrides passed to `env`. To simulate an unset
# CV_PR_AUTHOR, pass CV_PR_AUTHOR="" — the script treats empty and unset
# identically (it does `${CV_PR_AUTHOR:-}` then a `-z` check), and this avoids
# BSD `env -u` operand-ordering quirks on macOS.
# Captures combined stdout+stderr into $OUT and the exit code into $RC.
run_script() {
  OUT="$(
    env \
      GH="${STUBDIR}/gh" \
      GC="${STUBDIR}/gc" \
      GC_CITY="$CITY_DIR" \
      CV_STATE_DIR="$STATE_DIR" \
      STUB_GH_LOG="$GH_LOG" \
      STUB_GC_LOG="$GC_LOG" \
      "$@" \
      bash "$SCRIPT" 2>&1
  )"
  RC=$?
}

# ===========================================================================
# CASE 1 — Fail-closed: CV_PR_AUTHOR unset AND gh api user resolves empty.
#   Expect exit 1 and ZERO pr list / pr view / gc sling calls (bail early).
# ===========================================================================
start_case "1: fail-closed when author unresolved"
setup_case_env "1"
# CV_PR_AUTHOR unset; gh api user emits nothing.
run_script CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="" STUB_GH_USER_FAIL=1
assert_eq "1" "$RC" "script exits 1 (fail closed)"
assert_log_count "$GH_LOG" 'pr list' 0 "zero 'gh pr list' calls"
assert_log_count "$GH_LOG" 'pr view' 0 "zero 'gh pr view' calls"
assert_log_count "$GC_LOG" 'sling'   0 "zero 'gc sling' calls"
if printf '%s' "$OUT" | grep -q 'FATAL: CV_PR_AUTHOR is empty'; then
  pass "prints fail-closed FATAL message"
else
  fail "expected fail-closed FATAL message in output"
fi

# ===========================================================================
# CASE 2 — PART A author drop: only the operator's PR (#11) gets a repair bead.
#   #500 (other human), #600 (bot) must NEVER be slung.
# ===========================================================================
start_case "2: PART A slings only operator PR, drops others"
setup_case_env "2"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_PRLIST_MODE="operator"
assert_eq "0" "$RC" "script exits 0"
# Exactly one CI-repair sling, and it is for PR #11.
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 1 "exactly one ci-repair sling"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11' 1 "ci-repair sling is for pr=11"
# The sling is the wire that carries PART A's resolved author into Step 0's
# {{cv_pr_author}} — if this var were dropped, typo'd, or wrong, no other
# assertion in this suite would catch it (con-voyage-ci-repair-guard.test.sh
# covers the guard's own resolution, not this forwarding step).
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11.*cv_pr_author=kriscoleman' 1 "ci-repair sling forwards cv_pr_author"
# BLOCKING-2 (fk-4xq): the operator's TOP REQUIREMENT is rebase-only, linear
# history by DEFAULT. cv_conflict_strategy must default to "rebase" on every
# mint when CV_CONFLICT_STRATEGY is not set in the environment.
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11.*cv_conflict_strategy=rebase' 1 "ci-repair sling forwards cv_conflict_strategy=rebase by default"
assert_log_count "$GC_LOG" 'sling .*pr=500' 0 "no sling for #500 (other human)"
assert_log_count "$GC_LOG" 'sling .*pr=600' 0 "no sling for #600 (bot)"

# --- WELL-FORMED v2-FORMULA MINT (regression guard for the fk-f7x bug) ---
# The mint MUST be the gc 1.4.1 v2-formula shape:
#   gc [--city X] sling <target> <BEAD> --on con-voyage-ci-repair --var ...
# i.e. a PRE-CREATED bead positional BETWEEN the target and --on. The old broken
# form was `sling <target> --on <formula> --title <text>` (no bead), which real
# gc rejects with "inline text requires explicit target" and mints NOTHING.
#
# 1. A repair bead was pre-created for the KEPT PR (bd create ... --silent).
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "PART A pre-creates a repair bead for the KEPT PR"
# 1a. CROSS-RIG FIX (fk-974): the bead MUST be minted in the target agent's rig,
#     i.e. `bd create` carries the top-level `--rig vandoor` derived from the
#     repair_route "vandoor/gc.implementation-worker". `--rig` is a global flag,
#     so it precedes `bd create` on the argv. Without this, the bead would be
#     minted in the city store ("rc" prefix) and the same-target sling would fail
#     the cross-rig gate (see the tripwire in CASE 12).
assert_log_count "$GC_LOG" '--rig vandoor bd create .*--silent' 1 "PART A mints the repair bead in the target rig (--rig vandoor before bd create)"
# 1b. And the mint MUST NOT be a city (no-rig) create: the old-bug shape put
#     `bd create` immediately after `--city <dir>` (no --rig in between). With the
#     fix, `--rig vandoor` always sits between them, so this old shape is absent.
assert_log_count "$GC_LOG" '--city [^ ]+ bd create' 0 "no city-store (no --rig) bd create for the repair bead"
# 2. The sling carries the real bead id (va-newbead — minted in the target rig
#    "vandoor", so it shares the target's "va" prefix) as a positional BEFORE --on.
#    The "va" prefix on the bead == the target rig's prefix is what lets the
#    cross-rig-aware stub ACCEPT the sling (RED on the old "rc" bead — CASE 12).
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker va-newbead --on con-voyage-ci-repair' 1 "ci-repair sling passes the pre-created bead positional before --on"
# 3. The mint MUST NOT use the old inline-create form (--title with --on and no bead).
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*--title' 0 "mint does not use the broken --on+--title inline form"
# 4. All PR-context vars ride on the (correct) sling for #11.
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker va-newbead --on con-voyage-ci-repair .*pr=11 .*repo=kriscoleman/foundry .*branch=fix/con-voyage-author-scope-pr-monitor' 1 "mint forwards pr/repo/branch vars on the bead-positional sling"
# 4a. fk-7mw7 FIX-A: the sling also forwards the pre-created bead's OWN id as
#     --var repair_bead=<id>, so ci-repair.md's close steps have a KNOWN bead
#     to close instead of inferring it from {{convoy_id}} (a different,
#     gc-internal work-item id) — the #1 driver of orphaned repair beads.
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker va-newbead --on con-voyage-ci-repair .*repair_bead=va-newbead' 1 "mint forwards repair_bead=<own id> (fk-7mw7)"
# 5. The KEEP log names the minted bead id (operator-observable evidence).
if printf '%s' "$OUT" | grep -q 'repair bead va-newbead created/attached and routed'; then
  pass "logs the minted repair bead id for #11"
else
  fail "expected a 'repair bead <id> created/attached and routed' log for #11"
fi

# ===========================================================================
# CASE 3 — PART A exact, case-sensitive match: #700 (kriscoleman2) and
#   #701 (KRISCOLEMAN) both dropped — no bypass via prefix or case.
# ===========================================================================
start_case "3: PART A exact case-sensitive match (no bypass)"
setup_case_env "3"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=700' 0 "no sling for #700 (kriscoleman2 near-match)"
assert_log_count "$GC_LOG" 'sling .*pr=701' 0 "no sling for #701 (KRISCOLEMAN case variant)"

# ===========================================================================
# CASE 4 — PART A unresolved author (#800): dropped, no bead.
# ===========================================================================
start_case "4: PART A drops PR with unresolved author"
setup_case_env "4"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=800' 0 "no sling for #800 (unresolved author)"
# And confirm the DROP was logged with the unresolved marker.
if printf '%s' "$OUT" | grep -q 'DROP kriscoleman/foundry#800'; then
  pass "logs explicit DROP for #800"
else
  fail "expected DROP log line for #800"
fi

# ===========================================================================
# CASE 5 — PART B author filter: gh pr list carries --author kriscoleman,
#   and comment-routing only happens for the operator's PR (#11). No
#   non-operator PR is ever viewed for comments.
# ===========================================================================
start_case "5: PART B scopes pr list + comment routing to operator"
setup_case_env "5"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
# gh pr list must be called with --author kriscoleman.
assert_log_count "$GH_LOG" 'pr list .*--author kriscoleman' 1 "gh pr list uses --author kriscoleman"
# The stub returns only #11 for that author, so a comment-routing sling should
# fire to the implementor for #11's human comment. PART B routes via
# `gc sling <target> --stdin` (gc 1.4.1 has NO --body flag); the stub captures
# stdin and appends it to the log line, so the routed title ("Human PR feedback
# on ...", the first stdin line) is grep-able here.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin' 1 "PART B routes via gc sling --stdin (not the nonexistent --body flag)"
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN: Human PR feedback on kriscoleman/foundry#11' 1 "one comment-route sling to implementor for #11"
# PART B must NOT use the old --body flag (gc 1.4.1 rejects it: unknown flag).
assert_log_count "$GC_LOG" 'sling .*--body' 0 "PART B does not use the unsupported --body flag"
# And that comment route is NOT a ci-repair (PART A) sling.
assert_log_count "$GC_LOG" 'sling .*Human PR feedback.*--on con-voyage-ci-repair' 0 "comment route is not a ci-repair sling"
# Belt-and-suspenders: a comment fetch (pr view --json reviews,...) happened for
# #11 and for no other PR number in PART B.
assert_log_count "$GH_LOG" 'pr view 11 .*reviews' 1 "comment fetch for #11 only"
assert_log_count "$GH_LOG" 'pr view 500 .*reviews' 0 "no comment fetch for #500"
# The #11 fixture also carries a bot-banner comment (IC_test_bot, authored by
# kriscoleman via the PAT, same as a genuine human comment would be) — it must
# never surface in the routed feedback (captured in GC_LOG via the --stdin
# body, not in $OUT). Without the CV_AGENT_PREFIX_PATTERN exclusion, this is
# exactly how a bot's own automated reply gets mistaken for new human feedback
# and re-routed forever.
assert_log_count "$GC_LOG" 'Automated con-voyage agent' 0 "the bot's own bannered comment (IC_test_bot) is excluded from routed feedback"
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin' 1 "still exactly one comment-route sling (the bot comment adds no extra route)"

# --- CORRECTED PART B FETCH INVOCATION (regression guard for the reviewThreads bug) ---
# The bug: PART B fetched comments with `gh pr view <n> --json reviews,comments,reviewThreads`.
# `reviewThreads` is NOT a valid `gh pr view --json` field, so real gh (2.89)
# errors 'Unknown JSON field: "reviewThreads"' and exits non-zero on EVERY cycle —
# routing never worked. The fix requests ONLY the valid fields here (reviews,comments)
# and fetches reviewThreads separately via `gh api graphql`.
#
# TRIPWIRE: the pr-view fetch for #11 MUST NOT ask gh for reviewThreads. The stub
# faithfully REJECTS `reviewThreads` in `gh pr view --json` (like real gh), so the
# old invocation goes RED (fetch fails -> no route). This assertion pins the
# corrected field set explicitly, independent of the routing assertions above.
assert_log_count "$GH_LOG" 'pr view 11 .*--json reviews,comments,reviewThreads' 0 "PART B pr view does NOT request reviewThreads (invalid gh pr view field)"
assert_log_count "$GH_LOG" 'pr view 11 --repo kriscoleman/foundry --json reviews,comments ' 1 "PART B pr view requests exactly the valid reviews,comments field set"
# reviewThreads (inline review-thread comments) is fetched via GraphQL instead.
assert_log_count "$GH_LOG" 'api graphql .*reviewThreads' 1 "PART B fetches reviewThreads via gh api graphql"
assert_log_count "$GH_LOG" 'api graphql .*num=11' 1 "the graphql reviewThreads fetch targets PR #11"

# ===========================================================================
# CASE 6 — Happy-path default: CV_PR_AUTHOR unset, gh api user => kriscoleman.
#   Script proceeds (exit 0), logs the author-scoped banner, and behaves like
#   cases 2 & 5 (slings for #11, drops others).
# ===========================================================================
start_case "6: default author resolution from gh api user"
setup_case_env "6"
run_script CV_PR_AUTHOR="" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
if printf '%s' "$OUT" | grep -q "author-scoped to PRs authored by 'kriscoleman'"; then
  pass "logs author-scoped banner with resolved login"
else
  fail "expected author-scoped banner naming kriscoleman"
fi
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11' 1 "ci-repair sling for #11 under default resolution"
# Prove the *resolved* login (not just an explicitly-set CV_PR_AUTHOR, per
# CASE 2 above) is what gets forwarded.
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11.*cv_pr_author=kriscoleman' 1 "ci-repair sling forwards the resolved cv_pr_author"
assert_log_count "$GC_LOG" 'sling .*pr=500' 0 "no sling for #500 under default resolution"
assert_log_count "$GH_LOG" 'pr list .*--author kriscoleman' 1 "PART B pr list scoped to resolved login"

# ===========================================================================
# CASE 7 — PART B awk portability: SPACED assignments (owner = "replicatedhq")
#   must parse under the system awk (this box is macOS/BSD). Before the
#   [[:space:]] fix, the `\s`-based parser matched ZERO repos here and PART B
#   no-oped ("no [[github.pr_monitor]] blocks found"). We assert the repo was
#   parsed (gh pr list --repo replicatedhq/x was called) and that the
#   no-blocks-found message is absent.
# ===========================================================================
start_case "7: PART B awk parses SPACED owner/repo (BSD-awk portability)"
setup_case_env_spaced "7"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
# The spaced fixture declares repo replicatedhq/x. If awk parsed it, PART B
# lists PRs for exactly that repo. Before the fix this count would be 0.
assert_log_count "$GH_LOG" 'pr list --repo replicatedhq/x' 1 "PART B parsed spaced repo and listed replicatedhq/x"
if printf '%s' "$OUT" | grep -q 'no \[\[github.pr_monitor\]\] blocks found'; then
  fail "PART B reported no blocks — awk failed to parse spaced assignments (the bug)"
else
  pass "PART B did not report 'no blocks found' (spaced assignments parsed)"
fi

# ===========================================================================
# CASE 8 — PART B defensive author re-check: even if the upstream
#   `gh pr list --author` filter LEAKS a PR authored by someone else, the
#   per-PR author re-check drops it before any comment fetch or routing.
#   STUB_PRLIST_LEAK=1 returns PR #999 authored by "someone-else".
# ===========================================================================
start_case "8: PART B defensive re-check drops a leaked non-operator PR"
setup_case_env "8"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_PRLIST_LEAK=1
assert_eq "0" "$RC" "script exits 0"
# The leaked PR (#999, author someone-else) must NOT be fetched for comments...
assert_log_count "$GH_LOG" 'pr view 999 .*reviews' 0 "no comment fetch for leaked #999"
# ...and must NOT be routed to the implementor.
assert_log_count "$GC_LOG" 'sling .*Human PR feedback on kriscoleman/foundry#999' 0 "no comment-route sling for leaked #999"
# And the defensive DROP was logged.
if printf '%s' "$OUT" | grep -q "DROP kriscoleman/foundry#999 (author='someone-else'"; then
  pass "logs defensive PART B DROP for leaked #999"
else
  fail "expected defensive PART B DROP log for #999"
fi

# ===========================================================================
# CASE 9 — PART A dedup is PR-NUMBER keyed (not head-sha): a per-PR STATE
#   RECORD (fk-4o74 Fix 1, replaces the old bead-id-only ".minted" marker —
#   see state_field helper) tracks at most one repair bead per PR across
#   cycles. A re-mint is blocked ONLY while the tracked bead is genuinely
#   in-flight — status != closed, REGARDLESS of assignee. This is the crux of
#   the over-mint fix: pool-routed work sits with an EMPTY assignee for an
#   unbounded time before a worker claims it (confirmed live, vandoor #10494 —
#   see design doc), so the OLD gate (open AND assignee) was never true for a
#   freshly-slung, not-yet-claimed repair and re-minted it every cycle. The
#   NEW gate trusts "open" alone. Only a CLOSED tracked bead is treated as
#   free to supersede. We drive four consecutive cycles against the SAME
#   state dir, using STUB_BDSHOW_MAP to control what `bd show` reports for
#   the previously-minted bead:
#     cycle 1: no prior state                          -> fresh mint (baseline)
#     cycle 2: prior bead OPEN + assignee (in-flight)   -> SKIP (AC: no dup mint)
#     cycle 3: prior bead CLOSED, head ADVANCED         -> fresh mint (AC: a
#                                                          stale/closed bead
#                                                          never false-skips)
#     cycle 4: prior bead OPEN, UNASSIGNED (pending      -> SKIP, no supersede
#              pool claim, NOT an orphan)                  (AC: no-duplicates /
#                                                          no-over-mint
#                                                          regression — this IS
#                                                          the confirmed live
#                                                          bug scenario)
# ===========================================================================
start_case "9: PART A dedup is PR-number keyed with in-flight/supersede semantics"
setup_case_env "9"

# --- Cycle 1: no prior state -> fresh mint. ---
GC_LOG_1="${SANDBOX}/gc-9a.log"; : > "$GC_LOG_1"
OUT="$(
  env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
    CV_STATE_DIR="$STATE_DIR" STUB_GH_LOG="${SANDBOX}/gh-9a.log" \
    STUB_GC_LOG="$GC_LOG_1" CV_PR_AUTHOR="kriscoleman" \
    STUB_GH_USER_LOGIN="kriscoleman" STUB_HEAD_SHA="aaa111" \
    STUB_BD_CREATE_ID="va-bead1" \
    bash "$SCRIPT" 2>&1
)"; RC=$?
assert_eq "0" "$RC" "cycle 1 exits 0"
assert_log_count "$GC_LOG_1" 'bd create .*--silent' 1 "cycle 1 pre-creates exactly one repair bead"
assert_log_count "$GC_LOG_1" 'sling vandoor/gc.implementation-worker va-bead1 --on con-voyage-ci-repair' 1 "cycle 1 mints one ci-repair sling for #11"
# The PR-scoped state record (no head-sha in the filename) must now exist and
# track the minted bead id as its in-flight rework, with no known implementor
# yet (this was the fallback path — nobody has claimed the bead yet).
assert_eq "va-bead1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "inflight_rework")" "cycle 1 wrote the PR-scoped state record tracking va-bead1"
assert_eq "" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "implementor_session")" "cycle 1 has no known implementor yet (fallback mint, unclaimed)"
assert_eq "checks_failed" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "last_handled_state")" "cycle 1 records last_handled_state=checks_failed"
# fk-wgqp Fix 2 (watchdog) extension: a fresh dispatch also records the
# redispatch-context fields the watchdog needs to act without any gh call
# (pr_author for its defensive author-scope re-check; repair_route/repo_full/
# pr_number/branch for a fallback re-mint), and starts its own bookkeeping at
# attempt_count=0 / escalated=0.
assert_eq "kriscoleman" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "pr_author")" "cycle 1 records the resolved pr_author"
assert_eq "vandoor/gc.implementation-worker" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "repair_route")" "cycle 1 records repair_route"
assert_eq "kriscoleman/foundry" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "repo_full")" "cycle 1 records repo_full"
assert_eq "11" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "pr_number")" "cycle 1 records pr_number"
assert_eq "fix/con-voyage-author-scope-pr-monitor" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "branch")" "cycle 1 records branch"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "attempt_count")" "cycle 1 starts the watchdog attempt_count at 0"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "escalated")" "cycle 1 starts not escalated"

# Simulate the watchdog having already made one re-dispatch attempt against
# this SAME in-flight cycle (it runs on its own faster cooldown, interleaved
# with this monitor). This script must never see/touch attempt_count except
# via preserve-on-skip / reset-on-fresh-dispatch, so we poke it directly
# rather than driving the watchdog script from this suite.
sed -i.bak 's/^attempt_count=.*/attempt_count=1/' "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state" && rm -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state.bak"

# --- Cycle 2: SAME head-sha, tracked bead reported OPEN + a live assignee ->
#     genuinely in-flight -> SKIP, no duplicate mint. The assignee is also
#     opportunistically adopted as the PR's implementor (req 2: "the new
#     worker becomes the implementor") for future cycles' reuse-routing. ---
GC_LOG_2="${SANDBOX}/gc-9b.log"; : > "$GC_LOG_2"
OUT="$(
  env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
    CV_STATE_DIR="$STATE_DIR" STUB_GH_LOG="${SANDBOX}/gh-9b.log" \
    STUB_GC_LOG="$GC_LOG_2" CV_PR_AUTHOR="kriscoleman" \
    STUB_GH_USER_LOGIN="kriscoleman" STUB_HEAD_SHA="aaa111" \
    STUB_BDSHOW_MAP="va-bead1|open|gc__implementation-worker-rc-1" \
    bash "$SCRIPT" 2>&1
)"; RC=$?
assert_eq "0" "$RC" "cycle 2 exits 0"
assert_log_count "$GC_LOG_2" 'bd create .*--silent' 0 "cycle 2 creates NO duplicate repair bead"
assert_log_count "$GC_LOG_2" 'sling .*--on con-voyage-ci-repair' 0 "cycle 2 issues NO duplicate ci-repair sling for #11"
assert_log_count "$GC_LOG_2" 'mail send' 0 "cycle 2 sends no mail either (genuinely in-flight — nothing to dispatch)"
assert_log_count "$GC_LOG_2" 'bd close va-bead1' 0 "cycle 2 does not touch the in-flight bead"
if printf '%s' "$OUT" | grep -q 'SKIP kriscoleman/foundry#11 @ aaa111 — repair genuinely in-flight'; then
  pass "cycle 2 logs the in-flight SKIP for #11"
else
  fail "expected an in-flight SKIP log for #11 in cycle 2"
fi
assert_eq "va-bead1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "inflight_rework")" "state still tracks va-bead1 after the in-flight skip"
assert_eq "gc__implementation-worker-rc-1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "implementor_session")" "the claimant is adopted as the PR's implementor even on a skip cycle"
# fk-wgqp Fix 2: an in-flight skip cycle is a no-op from THIS script's point of
# view — it must carry the watchdog's attempt_count forward untouched (NOT
# reset to 0), alongside the other redispatch-context fields.
assert_eq "1" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "attempt_count")" "the watchdog's attempt_count survives an in-flight skip cycle unmodified"
assert_eq "kriscoleman" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "pr_author")" "pr_author survives an in-flight skip cycle unmodified"

# Simulate the watchdog having escalated this PR (3 failed attempts) before
# main advances again and re-conflicts it. Re-detection (req 4) must win over
# a stale escalation: a NEW problem is not the same problem the operator was
# already told about, so it deserves a fresh attempt budget.
sed -i.bak -e 's/^attempt_count=.*/attempt_count=3/' -e 's/^escalated=.*/escalated=1/' \
  "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state" && rm -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state.bak"

# --- Cycle 3: head ADVANCED to bcd222, tracked bead va-bead1 now CLOSED ->
#     not in-flight -> fresh mint despite the stale record (no false skip).
#     Implementor resets to unknown: va-bead1's claimant finished/gave up
#     without fixing it, so the fallback path runs again from scratch. ---
GC_LOG_3="${SANDBOX}/gc-9c.log"; : > "$GC_LOG_3"
OUT="$(
  env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
    CV_STATE_DIR="$STATE_DIR" STUB_GH_LOG="${SANDBOX}/gh-9c.log" \
    STUB_GC_LOG="$GC_LOG_3" CV_PR_AUTHOR="kriscoleman" \
    STUB_GH_USER_LOGIN="kriscoleman" STUB_HEAD_SHA="bcd222" \
    STUB_BDSHOW_MAP="va-bead1|closed|gc__implementation-worker-rc-1" STUB_BD_CREATE_ID="va-bead2" \
    bash "$SCRIPT" 2>&1
)"; RC=$?
assert_eq "0" "$RC" "cycle 3 exits 0"
assert_log_count "$GC_LOG_3" 'bd create .*--silent' 1 "cycle 3 pre-creates a FRESH repair bead despite the stale record"
assert_log_count "$GC_LOG_3" 'sling vandoor/gc.implementation-worker va-bead2 --on con-voyage-ci-repair' 1 "cycle 3 mints one well-formed ci-repair sling at the new head"
assert_log_count "$GC_LOG_3" 'sling vandoor/gc.implementation-worker va-bead2 --on con-voyage-ci-repair .*pr=11 .*repo=kriscoleman/foundry .*branch=fix/con-voyage-author-scope-pr-monitor' 1 "cycle 3 re-mint forwards pr/repo/branch vars"
# The already-closed bead needs no supersede close call — closing it again
# would be redundant, not incorrect, but we pin the leaner behavior here.
assert_log_count "$GC_LOG_3" 'bd close va-bead1' 0 "cycle 3 does not re-close the already-closed bead"
if printf '%s' "$OUT" | grep -q 'KEEP kriscoleman/foundry#11 .* (dedup: cv-ci-repair-kriscoleman-foundry-11)'; then
  pass "cycle 3 logs a KEEP naming the PR-scoped dedup key (no sha)"
else
  fail "expected a KEEP log naming the PR-scoped dedup key in cycle 3"
fi
assert_eq "va-bead2" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "inflight_rework")" "state now tracks the freshly-minted va-bead2"
# fk-wgqp Fix 2: the fresh re-mint is a NEW problem cycle — it must reset the
# watchdog's attempt_count/escalated bookkeeping back to 0, clearing the
# simulated prior escalation, rather than carrying it across an unrelated new
# dispatch.
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "attempt_count")" "a fresh re-mint resets attempt_count to 0, clearing the prior escalation"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "escalated")" "a fresh re-mint clears the escalated flag"

# --- Cycle 4: head ADVANCED to ccc333, tracked bead va-bead2 now OPEN but
#     UNASSIGNED. This is the CONFIRMED LIVE BUG SCENARIO (design doc: "the
#     tracked bead va-94kf was open with assignee=None, so the next cycle
#     would re-mint again" — that re-mint was the bug). Under the fix this
#     is NOT an orphan — it's a fallback-slung repair still waiting for a
#     pool worker to claim it — so it stays genuinely in-flight: SKIP, no
#     supersede, no duplicate mint. ---
GC_LOG_4="${SANDBOX}/gc-9d.log"; : > "$GC_LOG_4"
OUT="$(
  env GH="${STUBDIR}/gh" GC="${STUBDIR}/gc" GC_CITY="$CITY_DIR" \
    CV_STATE_DIR="$STATE_DIR" STUB_GH_LOG="${SANDBOX}/gh-9d.log" \
    STUB_GC_LOG="$GC_LOG_4" CV_PR_AUTHOR="kriscoleman" \
    STUB_GH_USER_LOGIN="kriscoleman" STUB_HEAD_SHA="ccc333" \
    STUB_BDSHOW_MAP="va-bead2|open|" STUB_BD_CREATE_ID="va-bead3" \
    bash "$SCRIPT" 2>&1
)"; RC=$?
assert_eq "0" "$RC" "cycle 4 exits 0"
assert_log_count "$GC_LOG_4" 'bd close va-bead1' 0 "cycle 4 does not touch the unrelated already-closed va-bead1"
assert_log_count "$GC_LOG_4" 'bd close va-bead2' 0 "cycle 4 does NOT supersede the pending (open, unassigned) va-bead2 — no-over-mint regression fix"
assert_log_count "$GC_LOG_4" 'bd create .*--silent' 0 "cycle 4 creates NO duplicate repair bead"
assert_log_count "$GC_LOG_4" 'sling .*--on con-voyage-ci-repair' 0 "cycle 4 issues NO duplicate ci-repair sling"
assert_log_count "$GC_LOG_4" 'mail send' 0 "cycle 4 sends no mail either (no known implementor, and the fallback bead is still in-flight)"
if printf '%s' "$OUT" | grep -q 'SKIP kriscoleman/foundry#11 @ ccc333 — repair genuinely in-flight'; then
  pass "cycle 4 logs the in-flight SKIP for the pending (open, unassigned) va-bead2"
else
  fail "expected an in-flight SKIP log for #11 in cycle 4 (open-unassigned must not be treated as an orphan)"
fi
assert_eq "va-bead2" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "inflight_rework")" "state still tracks va-bead2 — no supersede on a merely-unclaimed bead"

# ===========================================================================
# CASE 9b — legacy per-head-sha marker files (from the OLD dedup scheme) are
#   swept up the first time this PR mints under the NEW PR-scoped scheme: any
#   leftover "<dedup_key>-<old-sha>.minted" files are superseded (closed if
#   still open) and removed, so upgrading never leaves old orphans behind.
#   A differently-numbered PR sharing a numeric prefix (#1 vs #11) must NOT be
#   touched by #11's sweep (dash-delimited glob boundary).
# ===========================================================================
start_case "9b: legacy per-head-sha markers are superseded and swept on upgrade"
setup_case_env "9b"
LEGACY_MARKER_OLD="${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11-legacy111.minted"
printf 'va-legacy\n' > "$LEGACY_MARKER_OLD"
# A decoy for a DIFFERENT PR (#1) whose id is a numeric prefix of #11 — must
# survive #11's sweep untouched (proves the glob is dash-delimited, not a bare
# prefix match).
DECOY_MARKER="${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-1-decoy.minted"
printf 'va-decoy\n' > "$DECOY_MARKER"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_BDSHOW_MAP="va-legacy|open|" STUB_BD_CREATE_ID="va-bead-fresh"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close va-legacy .*superseded' 1 "legacy per-sha bead is superseded (closed)"
if [ -f "$LEGACY_MARKER_OLD" ]; then
  fail "legacy per-sha marker file was not removed"
else
  pass "legacy per-sha marker file was swept up"
fi
if [ -f "$DECOY_MARKER" ]; then
  pass "unrelated PR #1's decoy marker is untouched (dash-delimited glob boundary)"
else
  fail "PR #11's sweep incorrectly removed PR #1's decoy marker"
fi
assert_log_count "$GC_LOG" 'bd close va-decoy' 0 "PR #1's decoy bead is never closed by PR #11's sweep"
assert_eq "va-bead-fresh" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "inflight_rework")" "fresh PR-scoped state record created after sweeping the legacy marker"

# ===========================================================================
# CASE 10 — PART A mint failure is retried (no dedup marker on failure).
#   If the sling fails, we must NOT write the dedup marker, so the next cycle
#   retries the mint rather than silently suppressing it forever. We force a
#   failed pre-create (STUB_BD_CREATE_FAIL=1 -> gc bd create prints nothing and
#   exits non-zero); the script must abort the mint before slinging, leave no
#   marker, and log the failure.
# ===========================================================================
start_case "10: PART A leaves no dedup marker when the mint cannot proceed"
setup_case_env "10"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BD_CREATE_FAIL=1
assert_eq "0" "$RC" "script exits 0 (mint failure is non-fatal)"
# bd create was attempted, but returned empty -> the script must NOT sling and
# must NOT write a marker (so the next cycle retries).
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 0 "no ci-repair sling when bead pre-create yields no id"
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state" ]; then
  fail "state record written despite a failed mint (would suppress retries)"
else
  pass "no state record written on failed mint (mint will be retried next cycle)"
fi
if printf '%s' "$OUT" | grep -q 'failed to create repair bead for kriscoleman/foundry#11'; then
  pass "logs the bead-create failure for #11"
else
  fail "expected a bead-create failure log for #11"
fi

# ===========================================================================
# CASE 11 — PART A sling failure leaves NO dedup marker (dedicated GREEN test).
#   CASE 10 covers the bd-create-fail path (mint aborts before slinging). This
#   case covers the OTHER failure branch: the bead IS pre-created successfully,
#   but the subsequent v2-formula `sling <target> <bead> --on con-voyage-ci-repair`
#   fails (STUB_SLING_FAIL=1). The script must then:
#     * still exit 0 (a failed sling is non-fatal — best effort, retried),
#     * have actually pre-created the bead (bd create --silent == 1),
#     * write NO .minted marker (the marker is recorded ONLY after a successful
#       mint+route, so the next cycle retries rather than suppressing forever),
#     * log the 'repair-bead sling failed ... will retry' WARNING.
#   This pins the ordering invariant in the script under test: the marker write
#   sits INSIDE the `if sling; then ...` success branch. If a refactor ever moved
#   the marker write before/around the sling, this case would go RED (a marker
#   would exist after a failed sling).
# ===========================================================================
start_case "11: PART A sling failure writes no dedup marker (retryable)"
setup_case_env "11"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_SLING_FAIL=1
assert_eq "0" "$RC" "script exits 0 (sling failure is non-fatal)"
# The bead WAS pre-created (we got past pre-create and into the sling)...
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "a repair bead was pre-created for #11"
# ...and exactly one well-formed ci-repair sling was ATTEMPTED for that bead
# (the stub rejects it via STUB_SLING_FAIL, mirroring a routing failure).
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker va-newbead --on con-voyage-ci-repair' 1 "one well-formed ci-repair sling was attempted for #11"
# CRUX: because that sling failed, NO state record may be written — otherwise the
# mint would be suppressed forever and never retried.
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state" ]; then
  fail "state record written despite a FAILED sling (would suppress retries)"
else
  pass "no state record written on failed sling (mint will be retried next cycle)"
fi
# The retry WARNING must be logged (operator-observable evidence of the retry path).
if printf '%s' "$OUT" | grep -q 'repair-bead sling failed for kriscoleman/foundry#11'; then
  pass "logs the 'repair-bead sling failed ... will retry' WARNING for #11"
else
  fail "expected a 'repair-bead sling failed ... will retry' WARNING for #11"
fi
# And the success log must be ABSENT (the mint did not complete).
if printf '%s' "$OUT" | grep -q 'repair bead va-newbead created/attached and routed'; then
  fail "logged mint success despite a failed sling"
else
  pass "no 'created/attached and routed' success log on failed sling"
fi
# FAITHFULNESS GUARD: STUB_SLING_FAIL is scoped to the --on formula MINT only; it
# must NOT break PART B's plain `sling <target> --stdin` comment route. The stub
# returns a human comment for #11, so PART B must still route it successfully
# even while the PART A mint sling is failing.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN: Human PR feedback on kriscoleman/foundry#11' 1 "PART B --stdin comment route still succeeds under STUB_SLING_FAIL"
if printf '%s' "$OUT" | grep -q 'kriscoleman/foundry#11: routed to gc.implementation-worker'; then
  pass "PART B still routes #11 comment despite PART A sling failure"
else
  fail "expected PART B to still route #11 comment under STUB_SLING_FAIL"
fi

# ===========================================================================
# CASE 12 — CROSS-RIG FIX end-to-end (GREEN): the repair bead is minted in the
#   target agent's rig (--rig vandoor), so its "va" prefix matches the target
#   "vandoor/gc.implementation-worker", the cross-rig-aware stub ACCEPTS the
#   sling, and the dedup marker IS written. This is the positive proof that the
#   full mint->route->marker chain works once the bead is correctly homed.
#   (The stub's cross-rig gate is REAL: CASE 13 shows a mis-homed "rc" bead is
#   rejected by the very same gate, so this GREEN is not a rubber stamp.)
# ===========================================================================
start_case "12: cross-rig fix — rig-homed bead routes and writes marker"
setup_case_env "12"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
# Minted in the target rig...
assert_log_count "$GC_LOG" '--rig vandoor bd create .*--silent' 1 "bead minted in target rig (--rig vandoor)"
# ...and the same-rig sling was ACCEPTED by the cross-rig-aware stub (well-formed).
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker va-newbead --on con-voyage-ci-repair' 1 "same-rig sling accepted (va bead -> vandoor target)"
# The success log appears (route completed, not rejected cross-rig).
if printf '%s' "$OUT" | grep -q 'repair bead va-newbead created/attached and routed to vandoor/gc.implementation-worker'; then
  pass "logs a successful route to vandoor/gc.implementation-worker"
else
  fail "expected a successful route log to vandoor/gc.implementation-worker"
fi
# CRUX: the state record IS written (mint+route succeeded), keyed on repo+PR.
assert_eq "va-newbead" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "inflight_rework")" "state record written after a successful same-rig mint+route"

# ===========================================================================
# CASE 13 — TRIPWIRE (RED on the OLD no-rig form): if the repair bead is minted
#   in the CITY store (prefix "rc") — exactly what the pre-fix code did with no
#   --rig — the SAME real sling to "vandoor/gc.implementation-worker" is REJECTED
#   by the cross-rig-aware stub (bead "rc" != target "va"), so NO marker is
#   written and the retry WARNING is logged.
#
#   We drive the old-bug mint shape by forcing the pre-create to return a
#   city-prefixed id (STUB_BD_CREATE_ID="rc-oldbug"), i.e. a bead that was NOT
#   homed to the target rig. Everything else (the real script's sling, the
#   marker discipline) is unchanged. This is the guard that would go RED if the
#   fix regressed to a no-rig `bd create`: the cross-rig gate rejects the sling
#   and the marker is (correctly) never written.
# ===========================================================================
start_case "13: tripwire — city-minted (rc) bead is rejected cross-rig, no marker"
setup_case_env "13"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BD_CREATE_ID="rc-oldbug"
assert_eq "0" "$RC" "script exits 0 (cross-rig sling failure is non-fatal)"
# The (mis-homed) bead WAS pre-created and the sling was ATTEMPTED with it...
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker rc-oldbug --on con-voyage-ci-repair' 1 "sling attempted with the city-minted rc bead"
# ...but the cross-rig-aware stub REJECTED it (bead prefix rc != target prefix va),
# so the mint-success log must be ABSENT.
if printf '%s' "$OUT" | grep -q 'repair bead rc-oldbug created/attached and routed'; then
  fail "logged mint success despite a cross-rig REJECTED sling"
else
  pass "no success log — cross-rig sling was rejected (as real gc would)"
fi
# CRUX: because the sling was rejected, NO state record may be written (so the
# next cycle retries rather than suppressing a never-routed bead forever).
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state" ]; then
  fail "state record written despite a cross-rig REJECTED sling (old-bug regression)"
else
  pass "no state record on the cross-rig-rejected (city-minted) sling"
fi
# And the retry WARNING is logged (operator-observable evidence of the retry path).
if printf '%s' "$OUT" | grep -q 'repair-bead sling failed for kriscoleman/foundry#11'; then
  pass "logs the 'repair-bead sling failed ... will retry' WARNING under cross-rig rejection"
else
  fail "expected a 'repair-bead sling failed ... will retry' WARNING under cross-rig rejection"
fi

# ===========================================================================
# CASE 14 — CROSS-RIG MINT GUARD (underivable rig): an actionable operator PR
#   whose repair_route has NO "<rig>/" prefix (bare "gc.implementation-worker")
#   gives the script no rig to derive. It must SKIP with a WARNING and mint
#   NOTHING (no `bd create`, no sling, no marker) — mirroring the empty-a_route
#   guard — rather than mis-home a bead in the city store that could never route.
# ===========================================================================
start_case "14: cross-rig mint guard skips a route with no rig prefix"
setup_case_env "14"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="norig"
assert_eq "0" "$RC" "script exits 0"
# No bead created, no sling issued for the underivable route.
assert_log_count "$GC_LOG" 'bd create' 0 "no repair bead created when the rig cannot be derived"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 0 "no ci-repair sling when the rig cannot be derived"
# No marker written.
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state" ]; then
  fail "state record written despite skipping an underivable-rig route"
else
  pass "no state record written for the skipped underivable-rig route"
fi
# The skip WARNING names the offending route and the reason.
if printf '%s' "$OUT" | grep -q "repair_route 'gc.implementation-worker' has no '<rig>/' prefix"; then
  pass "logs the underivable-rig skip WARNING naming the route"
else
  fail "expected the underivable-rig skip WARNING naming the route"
fi

# ===========================================================================
# CASE 14b — fk-4o74 Fix-1 round 1, finding #1: the CROSS-RIG MINT GUARD must
#   NOT block the reuse-dispatch path. Pre-seed a state record with a known,
#   ALIVE implementor (mirrors CASE 32) for the SAME rig-less route as CASE 14
#   ("norig" fixture). The reuse path (mail+notify) never mints a bead, so it
#   never needs a rig — it must still fire even though the route itself has no
#   "<rig>/" prefix. Only a fallback mint (no live implementor) would need the
#   rig, and this case never reaches that branch.
# ===========================================================================
start_case "14b: cross-rig mint guard does not block reuse-dispatch on a rig-less route"
setup_case_env "14b"
printf 'implementor_session=gc__implementation-worker-rc-9\ninflight_rework=\nlast_handled_state=behind_base\n' \
  > "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="norig" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__implementation-worker-rc-9","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send gc__implementation-worker-rc-9' 1 "the alive implementor is still mailed despite the rig-less route"
assert_log_count "$GC_LOG" 'bd create' 0 "no repair bead created — the reuse path never mints"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 0 "zero ci-repair sling — the rig-derivation guard is never reached"
assert_eq "gc__implementation-worker-rc-9" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "implementor_session")" "the known implementor is retained after a reuse dispatch"
assert_eq "checks_failed" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "last_handled_state")" "last_handled_state advances despite the rig-less route"

# ===========================================================================
# CASE 15 — R5.1 native-monitor parity: an operator PR in EACH state gets a
#   repair bead carrying the CORRECT classified failure_kind, via the PRIMARY
#   path (trusting gc's own `failure_kind` field directly — see the
#   REAL-SAMPLE FINDING comment on the "states" fixture above). Also re-proves
#   cv_pr_author is still forwarded on every one of these mints (regression on
#   the CV-A wire, now exercised across all four states, not just checks_failed).
# ===========================================================================
start_case "15: R5.1 native-monitor parity — operator PR in each state gets correct failure_kind"
setup_case_env "15"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="states"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11.*failure_kind=checks_failed' 1 "pr=11 (gc's own failure_kind) classifies checks_failed"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=12.*failure_kind=merge_conflict' 1 "pr=12 (gc's own failure_kind) classifies merge_conflict"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=13.*failure_kind=behind_base' 1 "pr=13 (gc's own failure_kind) classifies behind_base"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=14.*failure_kind=blocked' 1 "pr=14 (gc's own failure_kind) classifies blocked"
for n in 11 12 13 14; do
  assert_log_count "$GC_LOG" "sling .*pr=${n}.*cv_pr_author=kriscoleman" 1 "pr=${n} still forwards cv_pr_author"
done

# ===========================================================================
# CASE 15b — PRIMARY-over-FALLBACK precedence: PR #15 carries gc's own
#   failure_kind=blocked directly, even though state=blocked WITH a non-empty
#   failed_checks[] would derive checks_failed under the fallback order. gc's
#   own field must win — it already has richer signal than we can re-derive
#   from these two fields alone.
# ===========================================================================
start_case "15b: gc's own failure_kind takes precedence over local derivation"
setup_case_env "15b"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="states"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=15.*failure_kind=blocked' 1 "pr=15 trusts gc's own failure_kind=blocked"
assert_log_count "$GC_LOG" 'sling .*pr=15.*failure_kind=checks_failed' 0 "pr=15 does NOT re-derive checks_failed from failed_checks (gc's field wins)"

# ===========================================================================
# CASE 16 — R5.2 native-monitor parity: a non-operator PR in EACH state is
#   dropped BEFORE any mint — the author gate is state-agnostic. Belt-and-
#   suspenders total: exactly the 5 operator PRs mint (11-15), never the 4
#   non-operator ones.
# ===========================================================================
start_case "16: R5.2 native-monitor parity — non-operator PR in each state is dropped before mint"
setup_case_env "16"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="states"
assert_eq "0" "$RC" "script exits 0"
for n in 500 501 502 503; do
  assert_log_count "$GC_LOG" "sling .*pr=${n}" 0 "no sling for #${n} (non-operator, dropped before mint)"
done
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 5 "exactly 5 ci-repair slings total (the 5 operator PRs only)"

# ===========================================================================
# CASE 17 — R5.3 classifier precedence (FALLBACK path): reuses CASE 2's
#   "full" fixture, where PR #11 carries state=blocked AND a non-empty
#   failed_checks[] but NO gc-provided failure_kind field — so this exercises
#   the fallback derivation, not the primary trust-gc path (CASE 15b already
#   covers the primary path). The first-match order must still classify it as
#   checks_failed (routing to rerun/fix), never blocked (the review-escalation
#   path) — a check-failure-blocked PR is failing-CI, not review-blocked.
# ===========================================================================
start_case "17: R5.3 classifier precedence (fallback derivation) — failed_checks wins over state=blocked"
setup_case_env "17"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=11.*failure_kind=checks_failed' 1 "pr=11 classifies checks_failed despite state=blocked (fallback derivation)"
assert_log_count "$GC_LOG" 'sling .*pr=11.*failure_kind=blocked' 0 "pr=11 must NOT classify as blocked"

# ===========================================================================
# CASE 18 — R5.4 non-actionable (clean) PRs never churn: #20 is
#   actionable:false, so it's filtered out before extraction and must never
#   produce a bead, proving PART A still keys off `actionable` first.
# ===========================================================================
start_case "18: R5.4 non-actionable (clean) PR produces no bead"
setup_case_env "18"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="states"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=20' 0 "no sling for #20 (actionable=false)"

# ===========================================================================
# CASE 19 — R5.5 the minted title is state-aware: it must name the
#   failure_kind so the bead is self-describing without opening it.
# ===========================================================================
start_case "19: R5.5 minted title is state-aware (names the failure_kind)"
setup_case_env "19"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="states"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd create Repair GitHub PR kriscoleman/foundry#12 \(merge_conflict\): dirty pr' 1 "title for #12 names (merge_conflict)"
assert_log_count "$GC_LOG" 'bd create Repair GitHub PR kriscoleman/foundry#13 \(behind_base\): behind pr' 1 "title for #13 names (behind_base)"

# ===========================================================================
# CASE 20 — PART B resilience: a genuine `gh pr view` failure during comment
#   fetch must surface the REAL gh error text in the WARNING (not just a bare
#   "skipping"), so an operator reading logs can actually diagnose it. Must
#   still be non-fatal (script exits 0, continues past this PR).
# ===========================================================================
start_case "20: PART B surfaces the real gh error text on a gh pr view failure"
setup_case_env "20"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_GH_VIEW_COMMENTS_FAIL=1 \
  STUB_GH_VIEW_COMMENTS_ERR="GraphQL: Field 'reviewThreads' does not exist on type 'PullRequest' (reviewThreads)"
assert_eq "0" "$RC" "script exits 0 (a single PR's comment-fetch failure is non-fatal)"
if printf '%s' "$OUT" | grep -qF "GraphQL: Field 'reviewThreads' does not exist on type 'PullRequest' (reviewThreads)"; then
  pass "WARNING surfaces the real gh stderr text"
else
  fail "expected the real gh stderr text in the WARNING output"
fi
if printf '%s' "$OUT" | grep -q 'gh pr view failed for kriscoleman/foundry#11'; then
  pass "WARNING still names the repo/PR"
else
  fail "expected the WARNING to still name kriscoleman/foundry#11"
fi
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin' 0 "no PART B comment route when the fetch failed"

# ===========================================================================
# CASE 21 — BLOCKING-1 regression: FIELD-SHIFT from empty optional fields
#   (fk-4xq). gc's schema marks title/head_sha/repair_route OPTIONAL. Tab is
#   IFS-whitespace, so bash's `read` collapses consecutive tabs and strips
#   leading/trailing runs — an EMPTY optional field before failure_kind used
#   to shift every later field left by one, landing failure_kind empty and
#   tripping the "did not classify" guard, which SILENTLY DROPPED a PR we must
#   repair (proven live on an operator DIRTY PR with an empty title). #16 has
#   an EMPTY title; #17 has an EMPTY head_sha. Both must still classify
#   correctly and mint a bead — neither may be silently dropped.
# ===========================================================================
start_case "21: BLOCKING-1 field-shift regression — empty title/head_sha do not shift failure_kind"
setup_case_env "21"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="fieldshift"
assert_eq "0" "$RC" "script exits 0"
# #16 (empty title): failure_kind must still be checks_failed and a bead must mint.
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=16.*failure_kind=checks_failed' 1 "pr=16 (empty title) still classifies checks_failed"
assert_log_count "$GC_LOG" 'bd create Repair GitHub PR kriscoleman/foundry#16' 1 "pr=16 mints a repair bead despite empty title"
if printf '%s' "$OUT" | grep -q 'kriscoleman/foundry#16 is actionable but its state/failed_checks did not classify'; then
  fail "pr=16 (empty title) was incorrectly skipped as unclassifiable (field-shift regression)"
else
  pass "pr=16 (empty title) was not skipped as unclassifiable"
fi
# #17 (empty head_sha): failure_kind must still be merge_conflict and a bead must mint.
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=17.*failure_kind=merge_conflict' 1 "pr=17 (empty head_sha) still classifies merge_conflict"
assert_log_count "$GC_LOG" 'bd create Repair GitHub PR kriscoleman/foundry#17' 1 "pr=17 mints a repair bead despite empty head_sha"
if printf '%s' "$OUT" | grep -q 'kriscoleman/foundry#17 is actionable but its state/failed_checks did not classify'; then
  fail "pr=17 (empty head_sha) was incorrectly skipped as unclassifiable (field-shift regression)"
else
  pass "pr=17 (empty head_sha) was not skipped as unclassifiable"
fi

# ===========================================================================
# CASE 22 — LOW-1 fallback classifier: state=="failed" with NO failed_checks
#   signal must still classify as checks_failed (matches the documented
#   vocabulary), not fall through to the empty/undifferentiated case.
# ===========================================================================
start_case "22: LOW-1 fallback classifier — state=failed with empty failed_checks still classifies checks_failed"
setup_case_env "22"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="failedstate"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=18.*failure_kind=checks_failed' 1 "pr=18 (state=failed, no failed_checks) falls back to checks_failed"
if printf '%s' "$OUT" | grep -q 'kriscoleman/foundry#18 is actionable but its state/failed_checks did not classify'; then
  fail "pr=18 (state=failed) was incorrectly left unclassified"
else
  pass "pr=18 (state=failed) was not left unclassified"
fi

# ===========================================================================
# CASE 23 — BLOCKING-2: cv_conflict_strategy is a rig-level config knob (set
#   via CV_CONFLICT_STRATEGY in con-voyage-pr-watch.toml's [order.env]), not a
#   per-invocation flag. When CV_CONFLICT_STRATEGY=merge is set in the
#   environment, PART A must forward cv_conflict_strategy=merge on the
#   ci-repair sling instead of the rebase default (CASE 2 already proves the
#   rebase default).
# ===========================================================================
start_case "23: BLOCKING-2 cv_conflict_strategy=merge override is forwarded on the sling"
setup_case_env "23"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" CV_CONFLICT_STRATEGY="merge"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11.*cv_conflict_strategy=merge' 1 "ci-repair sling forwards the overridden cv_conflict_strategy=merge"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=11.*cv_conflict_strategy=rebase' 0 "does not also forward the default rebase value when overridden"

# ===========================================================================
# CASE 24 — LOW-2 real-sample gate (cv-b-fk-08o decision 6 / fk-4xq): the
#   classifier must correctly handle the SANITIZED, REAL-captured backfill
#   payload in tests/fixtures/real-backfill-sample-2026-09-15.json (captured
#   via a REPORT-ONLY `gc github pr backfill --json` against this city's own
#   configured monitors), not just hand-authored fixtures. Every sample must
#   mint with the recorded failure_kind and NOT be dropped as unclassifiable
#   — proving the pipeline tolerates real-world extra fields (pending_checks,
#   monitor, base_ref_name, etc.) that this fixture set didn't previously
#   exercise.
# ===========================================================================
start_case "24: LOW-2 real-sample gate — classifier handles the real captured payload"
setup_case_env "24"
REAL_SAMPLE_JSON="$(python3 -c "
import json
with open('${REAL_SAMPLE_FIXTURE}') as f:
    data = json.load(f)
print(json.dumps({'results': [s['result'] for s in data['samples']]}))
")"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="realsample" STUB_REALSAMPLE_JSON="$REAL_SAMPLE_JSON"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=90001.*failure_kind=merge_conflict' 1 "real sample #1 (conflicted/DIRTY) classifies merge_conflict"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=90002.*failure_kind=blocked' 1 "real sample #2 (blocked/BLOCKED) classifies blocked"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=90003.*failure_kind=checks_failed' 1 "real sample #3 (failed+pending/DIRTY) classifies checks_failed"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=90004.*failure_kind=checks_failed' 1 "real sample #4 (failed/DIRTY) classifies checks_failed"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=90005.*failure_kind=checks_failed' 1 "real sample #5 (failed/BLOCKED) classifies checks_failed"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 5 "all 5 real samples mint a repair bead (none silently dropped)"

# ===========================================================================
# CASE 25 — C6 actionable filter (fk-t9f/fk-0dl): a PR that is classified
#   `blocked` (gc's ambiguous catch-all) but is ACTUALLY just awaiting human
#   review — all CI green/neutral, MERGEABLE, branch up to date, and the only
#   outstanding blocker is reviewDecision=REVIEW_REQUIRED — must be skipped as
#   a no-op: no repair bead, no comment, no dedup marker. con-voyage PRs never
#   auto-merge, so every one of them would otherwise end in REVIEW_REQUIRED
#   forever and spuriously mint a repair on every single cycle (the live
#   incident: #10494, 48/48 checks green + MERGEABLE, blocked solely on
#   REVIEW_REQUIRED).
# ===========================================================================
start_case "25: R6.1 C6 actionable filter — pure REVIEW_REQUIRED (green+mergeable+up-to-date) is skipped, no bead, no marker"
setup_case_env "25"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="reviewgate"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd create Repair GitHub PR kriscoleman/foundry#900' 0 "no repair bead created for #900 (awaiting human only)"
assert_log_count "$GC_LOG" 'sling .*pr=900' 0 "no ci-repair sling for #900"
if printf '%s' "$OUT" | grep -q 'SKIP kriscoleman/foundry#900 — awaiting human review only'; then
  pass "logs the awaiting-human SKIP for #900"
else
  fail "expected an awaiting-human SKIP log for #900"
fi
if [ -f "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-900.state" ]; then
  fail "state record written for a PR that was never minted (awaiting-human skip)"
else
  pass "no state record written for the awaiting-human skip"
fi

# ===========================================================================
# CASE 26 — C6 no-regression: reviewDecision/mergeable/CI-state alone must
#   NEVER suppress a real defect. Reuses the "reviewgate" fixture's #901-#905,
#   each violating exactly ONE precondition of the awaiting-human skip (see
#   the gh stub's per-number comments above) — every one of them must still
#   mint, proving the C6 filter is narrowly scoped to the one true awaiting-
#   human combination proven skipped in CASE 25.
# ===========================================================================
start_case "26: R6.2 C6 filter does not regress real defects (failing check / bad check / behind / changes-requested / not-mergeable)"
setup_case_env "26"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="reviewgate"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=901' 1 "pr=901 mints despite REVIEW_REQUIRED (a real failing check drives repair — AC clause 3)"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=902' 1 "pr=902 mints despite REVIEW_REQUIRED (a check is actually FAILING live — not all green)"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=903' 1 "pr=903 mints despite REVIEW_REQUIRED (branch is BEHIND live — not up to date)"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=904' 1 "pr=904 mints — CHANGES_REQUESTED is not REVIEW_REQUIRED (AC scopes the skip narrowly)"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair.*pr=905' 1 "pr=905 mints despite REVIEW_REQUIRED (mergeable=CONFLICTING, not MERGEABLE)"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 5 "exactly 5 ci-repair slings (only #900 was skipped)"

# ===========================================================================
# CASE 27 — C6 never bypasses the author gate: a non-operator PR (#906) that
#   otherwise carries the EXACT same awaiting-human signals as #900 must still
#   be DROPPED for authorship first — never reach the C6 "awaiting-human" SKIP
#   path. This pins the gate ORDER (author before actionable-filter) so C6
#   can never become a side-channel that treats a stranger's PR as ours.
# ===========================================================================
start_case "27: C6 gate runs strictly after the author gate — a non-operator PR is DROPPED, not SKIPPED"
setup_case_env "27"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="reviewgate"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=906' 0 "no sling for #906 (non-operator)"
assert_log_count "$GC_LOG" 'bd create Repair GitHub PR kriscoleman/foundry#906' 0 "no repair bead for #906 (non-operator)"
if printf '%s' "$OUT" | grep -q "DROP kriscoleman/foundry#906 (author='evansmungai' != 'kriscoleman')"; then
  pass "logs the author DROP for #906 (not an awaiting-human SKIP)"
else
  fail "expected an author DROP log for #906"
fi
if printf '%s' "$OUT" | grep -q 'SKIP kriscoleman/foundry#906 — awaiting human review only'; then
  fail "logged an awaiting-human SKIP for #906 — the C6 gate ran before the author gate"
else
  pass "no awaiting-human SKIP log for #906 (author gate ran first)"
fi

# ===========================================================================
# CASE 28 — PART B graceful degradation: the reviewThreads GraphQL fetch fails,
#   but comment routing MUST still succeed from reviews+comments alone. The fix
#   makes the inline-thread (reviewThreads) fetch BEST-EFFORT: a GraphQL failure
#   is logged as a NOTE and reviewThreads defaults to [] — reviews+comments still
#   route. Without this fail-soft, a transient GraphQL error would silently drop
#   ALL human feedback for the PR that cycle. STUB_GQL_THREADS_FAIL=1 makes only
#   the graphql call exit non-zero; `gh pr view --json reviews,comments` (which
#   returns a human issue comment for #11) still succeeds.
#   (Numbered 28, not 15 or 25: this suite's CASE 15/15b cover native-monitor-
#   parity, and CASE 25-27 (added on main in parallel) cover the C6 actionable
#   filter — 28 is the next free number after rebase.)
# ===========================================================================
start_case "28: PART B routes reviews+comments even when reviewThreads GraphQL fails"
setup_case_env "28"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_GQL_THREADS_FAIL=1
assert_eq "0" "$RC" "script exits 0 (best-effort reviewThreads failure is non-fatal)"
# The valid pr-view fetch still ran (reviews,comments)...
assert_log_count "$GH_LOG" 'pr view 11 --repo kriscoleman/foundry --json reviews,comments ' 1 "pr view reviews,comments fetch still runs"
# ...the graphql fetch was ATTEMPTED (and failed, per the stub)...
assert_log_count "$GH_LOG" 'api graphql .*num=11' 1 "reviewThreads graphql fetch was attempted"
# ...and the human issue comment from reviews+comments STILL routed to the implementor.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN: Human PR feedback on kriscoleman/foundry#11' 1 "reviews+comments feedback still routes despite the graphql failure"
# The fail-soft NOTE is logged (operator-observable evidence of the degradation).
if printf '%s' "$OUT" | grep -q 'reviewThreads GraphQL fetch failed for kriscoleman/foundry#11'; then
  pass "logs the best-effort reviewThreads NOTE on graphql failure"
else
  fail "expected a best-effort reviewThreads NOTE on graphql failure"
fi
# CRUX: the PR was NOT skipped — no 'gh pr view failed ... skipping' for #11.
if printf '%s' "$OUT" | grep -q 'gh pr view failed for kriscoleman/foundry#11; skipping'; then
  fail "PART B skipped #11 on a graphql failure (should degrade, not skip)"
else
  pass "PART B did not skip #11 on the graphql failure (degraded gracefully)"
fi

# ===========================================================================
# CASE 29 — C8 regression: EVERY [[github.pr_monitor]] block must be polled.
#   Pre-fix, the repo-parse emitted a block only when the NEXT top-level header
#   appeared, but the pr_monitor Rule fired first and `next`d — so with multiple
#   consecutive blocks (comments between), every block but the LAST (via END) was
#   dropped and only one repo was ever polled by PART B.
# ===========================================================================
start_case "29: C8 — every [[github.pr_monitor]] block is polled (not just the last)"
setup_case_env "29"
cat > "${CITY_DIR}/city.toml" <<'TOML'
[[github.pr_monitor]]
owner = "kriscoleman"
repo = "foundry"
rig = "foundry-kc"
base_branches = ["main"]

# a comment line between blocks, as in the real city.toml
[[github.pr_monitor]]
owner = "replicatedhq"
repo = "vandoor"
rig = "vandoor"
base_branches = ["main"]

[[github.pr_monitor]]
owner = "replicatedhq"
repo = "kots"
rig = "kots"
base_branches = ["main"]
TOML
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
if printf '%s' "$OUT" | grep -q 'PART B\] checking kriscoleman/foundry for human comments'; then pass "polls foundry (1st block)"; else fail "did NOT poll foundry (C8: only-last-block regression)"; fi
if printf '%s' "$OUT" | grep -q 'PART B\] checking replicatedhq/vandoor for human comments'; then pass "polls vandoor (middle block)"; else fail "did NOT poll vandoor (C8 regression)"; fi
if printf '%s' "$OUT" | grep -q 'PART B\] checking replicatedhq/kots for human comments'; then pass "polls kots (last block)"; else fail "did NOT poll kots"; fi

# ===========================================================================
# CASE 30 — C9 regression: PART B routes human feedback to the repo's OWN rig
#   worker (<rig>/gc.implementation-worker), derived from the block's `rig` — not
#   a bare `gc.implementation-worker`, which is not a valid sling target
#   ("agent not found"). (CASE 28's fixture has NO rig, so it exercises the
#   empty-rig fall-back to a bare target; this one proves the rig-scoped path.)
# ===========================================================================
start_case "30: C9 — human feedback routes to the rig-scoped worker, not a bare agent"
setup_case_env "30"
cat > "${CITY_DIR}/city.toml" <<'TOML'
[[github.pr_monitor]]
owner = "kriscoleman"
repo = "foundry"
rig = "foundry-kc"
base_branches = ["main"]
TOML
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling foundry-kc/gc.implementation-worker --stdin STDIN: Human PR feedback on kriscoleman/foundry#11' 1 "routes to the RIG-scoped worker foundry-kc/gc.implementation-worker"
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin' 0 "does NOT route to a bare gc.implementation-worker"

# ===========================================================================
# CASE 31 — C10 (fk-bhz): PART B must surface the reply TARGET for each inline
#   review-thread item so the worker can reply IN-thread (not at root). Before
#   C10, the routed feedback carried only the node-id ([id:PRRC_...]) — which
#   the review-comment replies API cannot use. The fix selects the comment's
#   REST databaseId plus its path/line in the reviewThreads GraphQL query and
#   includes them per-item in the routed message, so the worker can run
#   `cv-pr-comment.sh reply-thread ... --comment-id <databaseId>`.
#
#   The graphql stub (above) returns one inline comment with databaseId=556677
#   at src/retry.go:42. The routed body is captured in GC_LOG via the --stdin
#   capture (newlines squashed to spaces), so we assert the target is present.
#
#   TRIPWIRE (mutation-proof): revert the PART B databaseId/path/line change and
#   these assertions fail — the routed message would carry only the node-id.
# ===========================================================================
start_case "31: C10 — PART B surfaces the DB comment id + path/line per inline-thread item"
setup_case_env "31"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman"
assert_eq "0" "$RC" "script exits 0"
# The inline item still routes (baseline — proves the item reached the summary).
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN:.*inline: rename this var' 1 "the inline review-thread comment is routed"
# CRUX: the routed message carries the REST databaseId (the reply target) for
# the inline item — not just the node-id. Without the PART B change this is absent.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN:.*inline.*(comment-id|comment_id|reply-id|reply target|databaseId)[^0-9]*556677' 1 "routed inline item names the DB comment-id 556677 (the reply-thread target)"
# CRUX: and the routed message names the path:line so the worker knows which
# thread/location the feedback is on.
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN:.*src/retry.go:42' 1 "routed inline item names the path:line (src/retry.go:42)"
# The node-id remains present too (it stays the dedup key) — general/summary
# (root) comment routing is unaffected by this change (proven by CASE 5 and the
# reviews+comments routing above, which have no databaseId and still route).
assert_log_count "$GC_LOG" 'sling gc.implementation-worker --stdin STDIN:.*id:PRRC_test_11' 1 "the node-id is still present in the routed message"

# ===========================================================================
# CASE 32 — Task 2/3 (fk-4o74 Fix 1) "Reuse": when the PR's implementor is
#   alive, the monitor mails + notifies that SAME implementor instead of
#   spinning up a fresh pool worker. Pre-seed a state record with a known,
#   alive implementor and a DIFFERENT last_handled_state (behind_base) than
#   what this cycle observes (checks_failed, PR #11's default "full" fixture
#   classification) so the dedup gate does not skip — this is a genuine new
#   defect needing a fresh dispatch, and reuse (not fallback) must be chosen.
# ===========================================================================
start_case "32: Task 3 reuse — implementor alive gets mail+notify, zero pool sling"
setup_case_env "32"
printf 'implementor_session=gc__implementation-worker-rc-9\ninflight_rework=\nlast_handled_state=behind_base\n' \
  > "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__implementation-worker-rc-9","state":"active"}]}'
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send gc__implementation-worker-rc-9' 1 "exactly one mail to the known, alive implementor"
assert_log_count "$GC_LOG" 'mail send gc__implementation-worker-rc-9 .*-s .*11.*checks_failed' 1 "the mail subject names the PR and failure_kind"
assert_log_count "$GC_LOG" 'mail send gc__implementation-worker-rc-9 .*--notify' 1 "the mail is sent with --notify (durable + wake, no separate nudge call needed)"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 0 "ZERO pool ci-repair slings when the implementor is alive"
assert_log_count "$GC_LOG" 'bd create .*--silent' 0 "no fallback repair bead is created when the implementor is alive"
assert_eq "gc__implementation-worker-rc-9" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "implementor_session")" "the known implementor is retained after a reuse dispatch"
assert_eq "" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "inflight_rework")" "a mail-only reuse dispatch tracks no bead id"
assert_eq "checks_failed" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "last_handled_state")" "last_handled_state advances to the newly-observed defect"
last_dispatch_at_32="$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "last_dispatch_at")"
if [[ "$last_dispatch_at_32" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  pass "last_dispatch_at is written as a non-empty ISO-8601 UTC timestamp on the reuse dispatch"
else
  fail "expected last_dispatch_at to be a non-empty ISO-8601 timestamp (got '${last_dispatch_at_32}')"
fi

# ===========================================================================
# CASE 33 — Task 3 "Fallback": when the previously-known implementor is gone
#   (no matching, non-closed session), the monitor falls back to spawning a
#   fresh implementor via the pool con-voyage-ci-repair formula — exactly
#   today's mint path — and does NOT know its claimant yet (implementor_session
#   resets to empty; Task 2's write-back adopts it on a later cycle once gc
#   records an assignee, per CASE 9 cycle 2).
# ===========================================================================
start_case "33: Task 3 fallback — implementor gone spawns a fresh pool worker"
setup_case_env "33"
printf 'implementor_session=gc__implementation-worker-rc-9dead\ninflight_rework=\nlast_handled_state=behind_base\n' \
  > "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_SESSION_LIST_JSON='{"sessions":[]}' STUB_BD_CREATE_ID="va-newimpl"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail is sent to a dead implementor"
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "one fallback repair bead is created"
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker va-newimpl --on con-voyage-ci-repair' 1 "the fallback bead is slung to the pool ci-repair formula"
if printf '%s' "$OUT" | grep -q 'fallback — no live implementor'; then
  pass "logs that this dispatch used the fallback path (no live implementor)"
else
  fail "expected a fallback-path log line naming the reason (no live implementor)"
fi
assert_eq "" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "implementor_session")" "implementor resets to unknown until the fallback bead is claimed"
assert_eq "va-newimpl" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "inflight_rework")" "the fresh fallback bead is now tracked"

# ===========================================================================
# CASE 34 — Task 3 reuse-path failure is retryable: a failed mail delivery to
#   a live implementor must NOT update the state record (mirrors the existing
#   CASE 11 discipline for a failed sling), so the next cycle retries the
#   dispatch instead of silently losing it.
# ===========================================================================
start_case "34: Task 3 reuse mail failure leaves state untouched (retryable)"
setup_case_env "34"
printf 'implementor_session=gc__implementation-worker-rc-9\ninflight_rework=\nlast_handled_state=behind_base\n' \
  > "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_SESSION_LIST_JSON='{"sessions":[{"id":"gc__implementation-worker-rc-9","state":"active"}]}' \
  STUB_MAIL_SEND_FAIL=1
assert_eq "0" "$RC" "script exits 0 (mail failure is non-fatal)"
assert_log_count "$GC_LOG" 'mail send gc__implementation-worker-rc-9' 1 "the mail dispatch was attempted"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 0 "a failed reuse-mail does NOT fall back to a pool sling"
assert_eq "behind_base" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "last_handled_state")" "last_handled_state is unchanged after a failed dispatch (will retry)"
if printf '%s' "$OUT" | grep -q 'WARNING: mail to implementor gc__implementation-worker-rc-9 failed'; then
  pass "logs the mail-failure WARNING for the retry path"
else
  fail "expected a mail-failure WARNING for kriscoleman/foundry#11"
fi

# ===========================================================================
# CASE 35 — Task 5 (fk-4o74 Fix 1) "Leave clean alone": a clean PR (#20 in the
#   'states' fixture) is never dispatched (already proven by CASE 18) AND its
#   state record is refreshed to last_handled_state=clean, so a LATER
#   re-conflict has a real prior state to compare against (see CASE 36).
# ===========================================================================
start_case "35: Task 5 leave-clean-alone — no dispatch, and clean gets recorded"
setup_case_env "35"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="states"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'sling .*pr=20' 0 "no sling for #20 (clean)"
assert_log_count "$GC_LOG" 'bd create Repair GitHub PR kriscoleman/foundry#20' 0 "no repair bead for #20 (clean)"
assert_log_count "$GC_LOG" 'mail send' 0 "no mail for #20 either (nothing to repair)"
assert_eq "clean" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-20" "last_handled_state")" "clean PR #20's state is recorded as clean"

# ===========================================================================
# CASE 36 — Task 5 "Re-detect after clean" (req 4): a PR previously recorded
#   clean that is now actionable again must NOT be suppressed by the stale
#   clean record — last_handled_state ("clean") differs from the newly
#   observed failure_kind, so the dedup gate does not skip and a fresh
#   dispatch fires (fallback path here — no implementor is known).
# ===========================================================================
start_case "36: Task 5 re-detect after clean — a stale clean record never suppresses a real conflict"
setup_case_env "36"
printf 'implementor_session=\ninflight_rework=\nlast_handled_state=clean\n' \
  > "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BD_CREATE_ID="va-reconflict"
assert_eq "0" "$RC" "script exits 0"
if printf '%s' "$OUT" | grep -q 'SKIP kriscoleman/foundry#11'; then
  fail "a stale clean record incorrectly suppressed the re-detected conflict"
else
  pass "no SKIP logged — the clean->dirty transition was not suppressed"
fi
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "a fresh repair bead is minted after re-detecting a conflict"
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker va-reconflict --on con-voyage-ci-repair' 1 "the re-detected conflict is dispatched"
assert_eq "checks_failed" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "last_handled_state")" "state advances from clean to the newly-observed failure_kind"

# ===========================================================================
# CASE 37 — Task 5 symmetry: when a PR that had an OPEN tracked repair bead
#   transitions to clean (the repair evidently landed, but the tracked bead
#   was left open), the monitor supersedes (closes) it so it never lingers as
#   a phantom in-flight rework for a PR that no longer needs one.
# ===========================================================================
start_case "37: Task 5 clean transition supersedes a stale open tracked bead"
setup_case_env "37"
# attempt_count=2/escalated=1 simulate the watchdog having already worked this
# PR's now-resolved rework before it went clean (fk-wgqp Fix 2).
printf 'implementor_session=\ninflight_rework=va-oldbead\nlast_handled_state=merge_conflict\nattempt_count=2\nescalated=1\n' \
  > "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-20.state"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="states" \
  STUB_BDSHOW_MAP="va-oldbead|open|"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close va-oldbead .*now clean' 1 "the stale open bead is closed now that PR #20 is clean"
# fk-wgqp Fix 2: going clean resolves the problem, so the watchdog's
# attempt_count/escalated bookkeeping must reset — a LATER re-conflict must
# not inherit a stale escalation from a rework that already landed.
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-20" "attempt_count")" "going clean resets attempt_count to 0"
assert_eq "0" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-20" "escalated")" "going clean clears the escalated flag"
assert_eq "clean" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-20" "last_handled_state")" "state advances to clean"
assert_eq "" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-20" "inflight_rework")" "no bead is tracked once the PR is clean"

# ===========================================================================
# CASE 37b — Task 5 / Req 2 parity (finding #4, fk-4o74 Fix-1 round 2): same
#   clean transition as CASE 37, but the stale tracked bead now has a LIVE,
#   NON-EMPTY assignee. The clean-branch path (script ~500-501) must adopt
#   that assignee as the PR's implementor_session, exactly like the main
#   dispatch path does on a skip cycle (CASE 9b) — otherwise a claimant who
#   fixed the PR is silently forgotten the moment it goes clean, costing a
#   needless fallback mint on a later re-conflict.
# ===========================================================================
start_case "37b: Task 5 clean transition adopts a live assignee as implementor"
setup_case_env "37b"
printf 'implementor_session=\ninflight_rework=va-oldbead\nlast_handled_state=merge_conflict\n' \
  > "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-20.state"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" STUB_BACKFILL_MODE="states" \
  STUB_BDSHOW_MAP="va-oldbead|open|gc__impl-rc-5"
assert_eq "0" "$RC" "script exits 0"
assert_log_count "$GC_LOG" 'bd close va-oldbead .*now clean' 1 "the stale open bead is closed now that PR #20 is clean"
assert_eq "clean" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-20" "last_handled_state")" "state advances to clean"
assert_eq "" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-20" "inflight_rework")" "no bead is tracked once the PR is clean"
assert_eq "gc__impl-rc-5" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-20" "implementor_session")" "the stale bead's live assignee is adopted as implementor_session"

# ===========================================================================
# CASE 38 — FIX-C (fk-zyh5): a failure_kind FLIP while the tracked repair
#   bead is still OPEN must UPDATE that bead in place (title + failure_kind
#   metadata) instead of superseding it and minting a fresh one. Reproduces
#   the live kots#6067 incident: the classifier oscillated blocked<->
#   checks_failed roughly every 10-minute cooldown, and the OLD in-flight
#   gate was implicitly keyed on (PR-number, failure_kind) — every flip
#   looked like "not in-flight" and minted a brand-new orphan bead. Drive
#   THREE consecutive cycles against the SAME open, unclaimed pool bead
#   (assignee empty, mirroring the confirmed-live "still waiting to be
#   claimed" shape from CASE 9 cycle 4 — not a stale/abandoned bead):
#     cycle 1: fresh mint @ blocked                   -> ONE bead created
#     cycle 2: SAME bead open, flips to checks_failed -> UPDATE, no re-mint
#     cycle 3: SAME bead open, flips back to blocked  -> UPDATE, no re-mint
#   Across all three cycles exactly ONE repair bead is ever created — the
#   pre-fix behavior minted a second orphan on cycle 2 and a third on cycle 3.
# ===========================================================================
start_case "38: FIX-C — a failure_kind flip on an open tracked bead updates in place, never re-mints"
setup_case_env "38"
DEDUP_38="cv-ci-repair-kriscoleman-foundry-11"

# --- Cycle 1: fresh mint at failure_kind=blocked. ---
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_BACKFILL_MODE="flip" STUB_FLIP_KIND="blocked" STUB_BD_CREATE_ID="va-osc1"
assert_eq "0" "$RC" "cycle 1 exits 0"
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "cycle 1 pre-creates exactly one repair bead"
assert_log_count "$GC_LOG" 'sling vandoor/gc.implementation-worker va-osc1 --on con-voyage-ci-repair .*failure_kind=blocked' 1 "cycle 1 mints the ci-repair sling with failure_kind=blocked"
assert_eq "va-osc1" "$(state_field "$STATE_DIR" "$DEDUP_38" "inflight_rework")" "cycle 1 tracks the minted bead"
assert_eq "blocked" "$(state_field "$STATE_DIR" "$DEDUP_38" "last_handled_state")" "cycle 1 records last_handled_state=blocked"

# --- Cycle 2: SAME bead still open (unclaimed — empty assignee, the
#     confirmed-live shape), classifier flips to checks_failed. Must UPDATE
#     va-osc1 in place, not supersede/re-mint. ---
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_BACKFILL_MODE="flip" STUB_FLIP_KIND="checks_failed" \
  STUB_BDSHOW_MAP="va-osc1|open|"
assert_eq "0" "$RC" "cycle 2 exits 0"
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "cycle 2 creates NO additional repair bead (still exactly one total)"
assert_log_count "$GC_LOG" 'sling .*--on con-voyage-ci-repair' 1 "cycle 2 issues NO duplicate ci-repair sling"
assert_log_count "$GC_LOG" 'bd close va-osc1' 0 "cycle 2 never supersedes the still-open bead"
assert_log_count "$GC_LOG" 'bd update va-osc1 --title Repair GitHub PR kriscoleman/foundry#11 .*checks_failed.*oscillating pr --set-metadata failure_kind=checks_failed' 1 "cycle 2 updates the tracked bead's title + failure_kind metadata in place"
if printf '%s' "$OUT" | grep -q 'UPDATE kriscoleman/foundry#11 .* — repair still in-flight on va-osc1 .*failure_kind blocked -> checks_failed'; then
  pass "cycle 2 logs the in-place UPDATE for the blocked -> checks_failed flip"
else
  fail "expected an UPDATE log for the blocked -> checks_failed flip in cycle 2"
fi
assert_eq "va-osc1" "$(state_field "$STATE_DIR" "$DEDUP_38" "inflight_rework")" "cycle 2 still tracks the SAME bead"
assert_eq "checks_failed" "$(state_field "$STATE_DIR" "$DEDUP_38" "last_handled_state")" "cycle 2 advances last_handled_state to checks_failed"

# --- Cycle 3: SAME bead still open, classifier flips BACK to blocked. Must
#     UPDATE again in place — still no re-mint (this is the exact oscillation
#     that minted a SECOND orphan under the pre-fix behavior). ---
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_BACKFILL_MODE="flip" STUB_FLIP_KIND="blocked" \
  STUB_BDSHOW_MAP="va-osc1|open|"
assert_eq "0" "$RC" "cycle 3 exits 0"
assert_log_count "$GC_LOG" 'bd create .*--silent' 1 "cycle 3 STILL creates no additional repair bead — exactly ONE total across all three cycles (pre-fix: three)"
assert_log_count "$GC_LOG" 'bd close va-osc1' 0 "cycle 3 still never supersedes the open bead"
assert_log_count "$GC_LOG" 'bd update va-osc1 --title Repair GitHub PR kriscoleman/foundry#11 .*blocked.*oscillating pr --set-metadata failure_kind=blocked' 1 "cycle 3 updates the tracked bead back to failure_kind=blocked"
assert_eq "va-osc1" "$(state_field "$STATE_DIR" "$DEDUP_38" "inflight_rework")" "cycle 3 still tracks the SAME bead after flipping back"
assert_eq "blocked" "$(state_field "$STATE_DIR" "$DEDUP_38" "last_handled_state")" "cycle 3 advances last_handled_state back to blocked"

# ===========================================================================
# CASE 38b — FIX-C retry discipline: a FAILED bd update must not be treated as
#   applied. last_handled_state stays at the OLD value so the next cycle
#   retries the SAME update (mirrors the mint-failure discipline in CASE 10/11)
#   instead of silently losing the reclassification.
# ===========================================================================
start_case "38b: FIX-C — a failed bd update leaves last_handled_state untouched (retryable)"
setup_case_env "38b"
printf 'implementor_session=\ninflight_rework=va-osc-stuck\nlast_handled_state=blocked\n' \
  > "${STATE_DIR}/cv-ci-repair-kriscoleman-foundry-11.state"
run_script CV_PR_AUTHOR="kriscoleman" STUB_GH_USER_LOGIN="kriscoleman" \
  STUB_BACKFILL_MODE="flip" STUB_FLIP_KIND="checks_failed" \
  STUB_BDSHOW_MAP="va-osc-stuck|open|" STUB_BD_UPDATE_FAIL=1
assert_eq "0" "$RC" "script exits 0 (a failed bd update is non-fatal)"
assert_log_count "$GC_LOG" 'bd update va-osc-stuck' 1 "the update was attempted"
assert_log_count "$GC_LOG" 'bd create .*--silent' 0 "a failed update never falls back to a fresh mint"
assert_log_count "$GC_LOG" 'bd close va-osc-stuck' 0 "a failed update never supersedes the tracked bead either"
assert_eq "blocked" "$(state_field "$STATE_DIR" "cv-ci-repair-kriscoleman-foundry-11" "last_handled_state")" "last_handled_state stays at the OLD value after a failed update (will retry)"
if printf '%s' "$OUT" | grep -q 'WARNING: failed to update va-osc-stuck with the new failure_kind'; then
  pass "logs a WARNING naming the bead when the update fails"
else
  fail "expected a WARNING for the failed update on va-osc-stuck"
fi

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
