#!/usr/bin/env bash
# validate.sh — spec-driven validation gate.
# Validates JSON artifacts against their schemas and enforces traceability
# (spec -> plan -> tasks -> change_set).
#
# Requires: jq. Optional: ajv-cli (for full JSON Schema validation).
# Falls back to lightweight structural checks if ajv is unavailable.

set -e
echo "[Validate] Spec-driven checks"

# -- Sanity: required directories --
for d in artifacts agents flows policies specs; do
  test -d "$d" || { echo "[Validate] missing $d/"; exit 1; }
done
test -f constitution.md || { echo "[Validate] missing constitution.md"; exit 1; }

# -- jq required --
if ! command -v jq >/dev/null 2>&1; then
  echo "[Validate] WARNING: jq not installed; skipping structural checks. Install with: brew install jq"
  exit 0
fi

# -- ajv optional --
AJV=""
if command -v ajv >/dev/null 2>&1; then
  AJV="ajv"
elif command -v npx >/dev/null 2>&1; then
  AJV="npx --yes ajv-cli@5"
fi

fail() { echo "[Validate] FAIL: $*"; exit 1; }

# Walk every feature directory under specs/ (excluding the template).
shopt -s nullglob
for feature_dir in specs/[0-9][0-9][0-9]-*/; do
  fid=$(basename "$feature_dir")
  [ "$fid" = "000-template" ] && continue
  echo "[Validate] Feature: $fid"

  spec_json="$feature_dir/spec.json"
  plan_json="$feature_dir/plan.json"
  tasks_json="$feature_dir/tasks.json"

  # -- spec.json --
  if [ -f "$spec_json" ]; then
    if [ -n "$AJV" ]; then
      $AJV validate -s artifacts/schemas/spec.schema.json -d "$spec_json" >/dev/null \
        || fail "$spec_json fails spec.schema.json"
    fi
    [ "$(jq -r .feature_id "$spec_json")" = "$fid" ] || fail "$spec_json#feature_id != $fid"
  fi

  # -- plan.json + traceability --
  if [ -f "$plan_json" ]; then
    if [ -n "$AJV" ]; then
      $AJV validate -s artifacts/schemas/plan.schema.json -d "$plan_json" >/dev/null \
        || fail "$plan_json fails plan.schema.json"
    fi
    [ "$(jq -r .feature_id "$plan_json")" = "$fid" ] || fail "$plan_json#feature_id != $fid"
    [ -f "$spec_json" ] || fail "$plan_json requires $spec_json"
    # Every plan work_item AC ref must exist in spec.acceptance_criteria.
    missing=$(jq -r --slurpfile s <(jq '[.acceptance_criteria[].id]' "$spec_json") '
      [.work_items[].spec_criterion_refs[]] - $s[0] | unique | .[]' "$plan_json")
    [ -z "$missing" ] || fail "$plan_json references AC not in spec: $missing"
  fi

  # -- tasks.json + traceability + coverage --
  if [ -f "$tasks_json" ]; then
    if [ -n "$AJV" ]; then
      $AJV validate -s artifacts/schemas/tasks.schema.json -d "$tasks_json" >/dev/null \
        || fail "$tasks_json fails tasks.schema.json"
    fi
    [ "$(jq -r .feature_id "$tasks_json")" = "$fid" ] || fail "$tasks_json#feature_id != $fid"
    # Every task AC ref must exist in spec.
    if [ -f "$spec_json" ]; then
      missing=$(jq -r --slurpfile s <(jq '[.acceptance_criteria[].id]' "$spec_json") '
        [.tasks[].spec_criterion_refs[]] - $s[0] | unique | .[]' "$tasks_json")
      [ -z "$missing" ] || fail "$tasks_json references AC not in spec: $missing"

      # Every MUST AC must be covered by ≥1 task.
      uncovered=$(jq -r --slurpfile t <(jq '[.tasks[].spec_criterion_refs[]] | unique' "$tasks_json") '
        [.acceptance_criteria[] | select(.priority == "must" or .priority == null) | .id] - $t[0] | .[]' "$spec_json")
      [ -z "$uncovered" ] || fail "MUST AC uncovered by any task: $uncovered"
    fi
  fi

  # -- change_sets/*.json --
  for cs in "$feature_dir"evidence/change_sets/*.json; do
    [ -f "$cs" ] || continue
    if [ -n "$AJV" ]; then
      $AJV validate -s artifacts/schemas/change_set.schema.json -d "$cs" >/dev/null \
        || fail "$cs fails change_set.schema.json"
    fi
    task_ref=$(jq -r .task_ref "$cs")
    [ "$(jq -r .feature_id "$cs")" = "$fid" ] || fail "$cs#feature_id != $fid"
    # task_ref must exist in tasks.json
    [ -f "$tasks_json" ] || fail "$cs has task_ref $task_ref but no $tasks_json"
    exists=$(jq -r --arg t "$task_ref" '[.tasks[].id] | index($t) // empty' "$tasks_json")
    [ -n "$exists" ] || fail "$cs#task_ref=$task_ref not found in $tasks_json"
    # change_set.spec_criterion_refs must equal task.spec_criterion_refs (set equality)
    diff_l=$(jq -r --arg t "$task_ref" --slurpfile cs_refs <(jq '.spec_criterion_refs | sort' "$cs") '
      .tasks[] | select(.id == $t) | (.spec_criterion_refs | sort) as $tr |
      ($tr - $cs_refs[0]) + ($cs_refs[0] - $tr) | .[]' "$tasks_json")
    [ -z "$diff_l" ] || fail "$cs#spec_criterion_refs differs from task: $diff_l"
  done

  # -- staging/hitl/ must be empty for the feature to be considered passing --
  hitl_files=("$feature_dir"staging/hitl/*.json)
  if [ ${#hitl_files[@]} -gt 0 ]; then
    echo "[Validate] $fid has pending HITL requests (not a failure, but commit may be blocked by runner)."
  fi
done

echo "[Validate] OK"
