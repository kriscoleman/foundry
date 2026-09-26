#!/usr/bin/env bash
set -euo pipefail

ROOT_ID="${GC_BEAD_ID:-}"
ATTEMPT="${GC_ITERATION:-}"

if [ -z "$ROOT_ID" ]; then
  echo "review check: GC_BEAD_ID is required" >&2
  exit 1
fi

if [ -z "$ATTEMPT" ]; then
  ATTEMPT="0"
fi

metadata_value() {
  local json="$1"
  local key="$2"
  printf '%s\n' "$json" | jq -r --arg key "$key" '
    (if type == "array" then (.[0] // {}) else . end)
    | .metadata[$key] // empty
  ' 2>/dev/null
}

ROOT_JSON="$(bd show "$ROOT_ID" --json 2>/dev/null || true)"
PARENT_ROOT="$(metadata_value "$ROOT_JSON" "gc.root_bead_id")"
if [ -z "$PARENT_ROOT" ]; then
  PARENT_ROOT="$ROOT_ID"
fi
PARENT_JSON="$ROOT_JSON"
if [ "$PARENT_ROOT" != "$ROOT_ID" ]; then
  PARENT_JSON="$(bd show "$PARENT_ROOT" --json 2>/dev/null || true)"
fi
STEP_ID="$(metadata_value "$ROOT_JSON" "gc.step_id")"
SCOPE_REF="$(metadata_value "$ROOT_JSON" "gc.scope_ref")"
if [ -z "$SCOPE_REF" ]; then
  SCOPE_REF="$(metadata_value "$ROOT_JSON" "gc.step_ref")"
fi

MATCHES="$(bd list --all --metadata-field "gc.root_bead_id=$PARENT_ROOT" --json --limit=0 2>/dev/null || printf '[]')"

# code_review.verdict is written by two independent producers under the same
# key: apply-review-findings owns it with the done|iterate vocabulary (its
# contract), but the review-loop's own per-iteration body bead (this
# attempt's ROOT_ID/STEP_ID bead itself, always present in MATCHES) separately
# ends up carrying a same-named code_review.verdict using the approve|iterate
# lane-rollup vocabulary. Without scoping to the apply-review-findings bead
# specifically, "last" over an unordered bd list result can pick either one —
# picking the rollup let a real no-op approval ("done") get shadowed by
# "approve", which this script does not recognize, dispatching a whole extra
# iteration. Derive the sibling apply-review-findings step id from this
# bead's own step id ("<target>.con-voyage-review-loop" ->
# "<target>.apply-review-findings") and require an exact match so only that
# bead's value is ever considered.
STEP_PREFIX="${STEP_ID%.con-voyage-review-loop}"
if [ "$STEP_PREFIX" != "$STEP_ID" ]; then
  APPLY_STEP_ID="${STEP_PREFIX}.apply-review-findings"
else
  APPLY_STEP_ID=""
  echo "implementation-review-approved: gc.step_id '$STEP_ID' does not match expected *.con-voyage-review-loop suffix; falling back to LANE_STATUS" >&2
fi

VERDICT="$(printf '%s\n' "$MATCHES" | jq -r --arg attempt "$ATTEMPT" --arg apply_step "$APPLY_STEP_ID" '
  [
    .[]
    | select((.metadata["gc.attempt"] // "") == $attempt)
    | select($apply_step != "" and (.metadata["gc.step_id"] // "") == $apply_step)
    | select((.metadata["code_review.verdict"] // "") != "")
    | .metadata["code_review.verdict"]
  ] | last // ""
' 2>/dev/null)"

REPORT="$(printf '%s\n' "$MATCHES" | jq -r --arg attempt "$ATTEMPT" '
  [
    .[]
    | select((.metadata["gc.attempt"] // "") == $attempt)
    | select((.metadata["code_review.report_path"] // "") != "")
    | .metadata["code_review.report_path"]
  ] | last // ""
' 2>/dev/null)"

REVIEW_MODE="$(metadata_value "$ROOT_JSON" "gc.var.review_mode")"
if [ -z "$REVIEW_MODE" ]; then
  REVIEW_MODE="$(metadata_value "$PARENT_JSON" "gc.var.review_mode")"
fi
if [ "$REVIEW_MODE" = "report" ]; then
  REPORT_MODE_PATH="$(metadata_value "$PARENT_JSON" "gc.build.code_review_report_path")"
  if [ -z "$REPORT_MODE_PATH" ]; then
    REPORT_MODE_PATH="$(metadata_value "$PARENT_JSON" "gc.build.review_report_path")"
  fi
  if [ -z "$REPORT_MODE_PATH" ]; then
    REPORT_MODE_PATH="$(metadata_value "$PARENT_JSON" "gc.var.report_path")"
  fi
  if [ -z "$REPORT_MODE_PATH" ]; then
    REPORT_MODE_PATH="$(printf '%s\n' "$MATCHES" | jq -r --arg attempt "$ATTEMPT" '
      [
        .[]
        | select((.metadata["gc.attempt"] // "") == $attempt)
        | (
            .metadata["code_review.review_report_path"] //
            .metadata["code_review.report_path"] //
            .metadata["code_review.output_path"] //
            ""
          )
        | select(. != "")
      ] | last // ""
    ' 2>/dev/null)"
  fi
  if [ -n "$REPORT_MODE_PATH" ]; then
    echo "Implementation review report mode satisfied: $REPORT_MODE_PATH"
    exit 0
  fi
  echo "Implementation review report mode needs a review report path"
  exit 1
fi

# LANE_STATUS scans every code_review.<lane>_verdict key present on any
# current-iteration bead (not a fixed list of 3) — con-voyage adds
# security_verdict and code_verdict on top of build-basic-review's
# acceptance/test_evidence/simplicity floor, plus up to twelve conditional
# roster lanes (product_owner, dev_ex, qa_test, ...), each under its own
# "<lane>_verdict" key. A fixed 3-key struct silently ignored every lane
# con-voyage itself added (fk-w31l7: code_review.code_verdict=iterate was
# still on the board when a "done" self-report let the loop exit anyway).
LANE_STATUS="$(printf '%s\n' "$MATCHES" | jq -r \
  --arg root "$PARENT_ROOT" \
  --arg attempt "$ATTEMPT" \
  --arg scope "$SCOPE_REF" \
  --arg step "$STEP_ID" '
  def current_loop:
    select(.metadata["gc.root_bead_id"] == $root)
    | select(($attempt == "") or ((.metadata["gc.attempt"] // "") == $attempt))
    | select(
        if $attempt != "" and $step != "" then
          ((.metadata["gc.ralph_step_id"] // "") == $step) or
          ((.metadata["gc.step_id"] // "") == $step) or
          (((.metadata["gc.scope_ref"] // "") | startswith($step + ".iteration.")))
        elif $attempt != "" and $scope != "" then
          ((.metadata["gc.scope_ref"] // "") == $scope) or
          ((.metadata["gc.step_ref"] // "") == $scope)
        elif $step != "" then
          ((.metadata["gc.ralph_step_id"] // "") == $step) or
          (((.metadata["gc.scope_ref"] // "") | startswith($step + ".iteration.")))
        elif $scope != "" then
          ((.metadata["gc.scope_ref"] // "") == $scope)
        else
          true
        end
      );
  def approved($value):
    (($value // "") | ascii_downcase) as $v
    | ($v == "approve" or $v == "approved" or $v == "pass" or $v == "done");
  [
    .[]
    | current_loop
    | .metadata
    | to_entries[]
    | select(.key | test("^code_review\\..+_verdict$"))
    | select(.value != null and .value != "")
  ] as $entries
  | (reduce $entries[] as $e ({}; . + {($e.key): $e.value})) as $latest
  | ($latest | keys) as $lane_keys
  | if ($lane_keys | length) == 0 then
      ""
    else
      if ([$lane_keys[] | approved($latest[.])] | all) then
        "approved"
      else
        "iterate: " + ([$lane_keys[] | select(approved($latest[.]) | not) | "\(.)=\($latest[.])"] | join(", "))
      end
    end
' 2>/dev/null)"

# FIX_COMMIT is set by apply-review-findings only when it actually committed
# a fix this attempt. Lanes fan out BEFORE apply-review-findings runs within
# a cycle (see {target}.con-voyage-review-loop.md), so a fix commit recorded
# on THIS attempt's apply-review-findings bead structurally cannot have been
# seen by any lane in this same attempt — "done" is never trustworthy
# alongside one, regardless of what any lane verdict says.
FIX_COMMIT="$(printf '%s\n' "$MATCHES" | jq -r --arg attempt "$ATTEMPT" --arg apply_step "$APPLY_STEP_ID" '
  [
    .[]
    | select((.metadata["gc.attempt"] // "") == $attempt)
    | select($apply_step != "" and (.metadata["gc.step_id"] // "") == $apply_step)
    | select((.metadata["code_review.fix_commit"] // "") != "")
    | .metadata["code_review.fix_commit"]
  ] | last // ""
' 2>/dev/null)"

case "$VERDICT" in
  done|approved|pass)
    if [ -n "$FIX_COMMIT" ]; then
      echo "Implementation review needs another iteration: apply-review-findings recorded fix commit ${FIX_COMMIT} this attempt, which no lane has reviewed yet"
      exit 1
    fi
    if [ -n "$LANE_STATUS" ] && [ "$LANE_STATUS" != "approved" ]; then
      echo "Implementation review needs another iteration: $LANE_STATUS"
      exit 1
    fi
    echo "Implementation review approved"
    exit 0
    ;;
  "")
    if [ -n "$FIX_COMMIT" ]; then
      echo "Implementation review needs another iteration: apply-review-findings recorded fix commit ${FIX_COMMIT} this attempt, which no lane has reviewed yet"
      exit 1
    fi
    if [ "$LANE_STATUS" = "approved" ]; then
      echo "Implementation review approved from lane verdicts"
      exit 0
    fi
    echo "Implementation review needs another iteration: ${LANE_STATUS:-missing verdict}"
    exit 1
    ;;
  *)
    echo "Implementation review needs another iteration: $VERDICT"
    exit 1
    ;;
esac
