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

# -- Agent manifest invariants ------------------------------------------------
# Static lint of .claude/agents/*.md frontmatter. Catches regressions like
# "orchestrator silently lost its Agent tool" or "coding-fe loses Bash and
# starts failing to call runner/task-update.sh". Cheap, runs every commit.
echo "[Validate] Agent manifests"

# Extract the comma-separated `tools:` value from an agent's frontmatter
# (first --- block). Returns empty string if no tools line.
agent_tools() {
  awk 'BEGIN{c=0} /^---$/{c++; if(c==2) exit; next} c==1 && /^tools:/{
    sub(/^tools:[[:space:]]*/,""); print; exit
  }' "$1"
}

has_tool() {
  echo ",$1," | grep -q ",[[:space:]]*$2[[:space:]]*,"
}

# All agents seen on disk.
declare_count=0
for f in .claude/agents/*.md; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .md)
  tools=$(agent_tools "$f")
  # Normalize: surround with commas so has_tool can do safe substring match.
  tools_n=",${tools// /},"
  declare_count=$((declare_count + 1))

  case "$name" in
    orchestrator)
      has_tool "$tools_n" "Agent" \
        || fail "$f: orchestrator must declare 'Agent' in tools (regression: subagent spawning would silently fall back to impersonation)"
      ;;
    *)
      if has_tool "$tools_n" "Agent"; then
        fail "$f: only orchestrator may declare 'Agent' (prevents recursive subagent spawning)"
      fi
      ;;
  esac

  # Any agent whose body invokes a runner/*.sh helper must declare Bash.
  if grep -qE '`?bash runner/[a-z_-]+\.sh' "$f"; then
    has_tool "$tools_n" "Bash" \
      || fail "$f: body invokes 'bash runner/...sh' but Bash is not in tools"
  fi

  # Every agent that has an entry in policies/agents.config.json#default_ownership
  # should expose Read+Write+Edit since ownership implies write authority.
  if [ -f policies/agents.config.json ] && \
     jq -e --arg n "$name" '.default_ownership[$n]' policies/agents.config.json >/dev/null 2>&1; then
    for required in Read Write Edit; do
      has_tool "$tools_n" "$required" \
        || fail "$f: $name owns paths in policies/agents.config.json#default_ownership but lacks '$required' in tools"
    done
  fi
done

[ "$declare_count" -gt 0 ] || fail ".claude/agents/ has no agent manifests"

# Every role with declared default_ownership must have a manifest file on disk.
if [ -f policies/agents.config.json ]; then
  while IFS= read -r role; do
    [ -f ".claude/agents/$role.md" ] \
      || fail "policies/agents.config.json declares default_ownership for '$role' but .claude/agents/$role.md is missing"
  done < <(jq -r '.default_ownership | keys[]' policies/agents.config.json)
fi

# -- Project-shape templates --------------------------------------------------
# Validate every policies/project-shapes/*.json against the schema (best-effort)
# and check that its filename basename equals its `name` field. Cheap sanity.
echo "[Validate] Project shapes"
for shape in policies/project-shapes/*.json; do
  [ -f "$shape" ] || continue
  if [ -n "$AJV" ] && [ -f artifacts/schemas/project_shape.schema.json ]; then
    $AJV validate -s artifacts/schemas/project_shape.schema.json -d "$shape" >/dev/null \
      || fail "$shape fails project_shape.schema.json"
  fi
  expected=$(basename "$shape" .json)
  got=$(jq -r .name "$shape")
  [ "$expected" = "$got" ] || fail "$shape: name '$got' must equal filename basename '$expected'"
done

# -- Effective-ownership resolver --------------------------------------------
# Given a feature_id and a role, print the role's effective path globs (one per
# line). Resolution order:
#   1. specs/<fid>/team_plan.json#ownership[<role>]      (per-feature override)
#   2. policies/project-shapes/<team_plan.project_shape>.json#ownership[<role>]
#   3. policies/agents.config.json#default_ownership[<role>]
# Empty output = no globs declared anywhere; caller decides whether to enforce.
resolve_ownership() {
  local fid="$1" role="$2"
  local tp="specs/$fid/team_plan.json" globs
  if [ -f "$tp" ]; then
    globs=$(jq -r --arg r "$role" '.ownership[$r][]? // empty' "$tp")
    [ -n "$globs" ] && { printf '%s\n' "$globs"; return; }
    local shape
    shape=$(jq -r '.project_shape // empty' "$tp")
    if [ -n "$shape" ] && [ -f "policies/project-shapes/$shape.json" ]; then
      globs=$(jq -r --arg r "$role" '.ownership[$r][]? // empty' "policies/project-shapes/$shape.json")
      [ -n "$globs" ] && { printf '%s\n' "$globs"; return; }
    fi
  fi
  if [ -f policies/agents.config.json ]; then
    jq -r --arg r "$role" '.default_ownership[$r][]? // empty' policies/agents.config.json
  fi
}

# Does path "$1" match any of the globs on stdin? Supports trailing `/**`
# (recursive prefix), single-segment `/*`, and exact literal match. Other
# shell-glob meta is treated as literal — keep patterns simple in shape files.
#
# Globs may use `{feature_id}` as a placeholder; caller is responsible for
# substituting it before piping in (so the same matcher can resolve against
# different features).
path_in_globs() {
  local path="$1" glob
  while IFS= read -r glob; do
    [ -z "$glob" ] && continue
    if [[ "$glob" == *'/**' ]]; then
      local prefix="${glob%/\*\*}"
      case "$path" in
        "$prefix"/*) return 0 ;;
        "$prefix")   return 0 ;;
      esac
    elif [[ "$glob" == *'/*' ]]; then
      local prefix="${glob%/\*}"
      case "$path" in
        "$prefix"/*) return 0 ;;
      esac
    elif [[ "$glob" == *'*'* ]]; then
      # Single-segment wildcard in middle, e.g. specs/*/spec.md
      local re
      re=$(printf '%s' "$glob" | sed 's/\./\\./g; s/\*\*/[A-Z]/g; s/\*/[^\/]*/g; s/\[A-Z\]/.*/g')
      [[ "$path" =~ ^$re$ ]] && return 0
    else
      [ "$path" = "$glob" ] && return 0
    fi
  done
  return 1
}

# Walk every feature directory under specs/ (excluding the template).
shopt -s nullglob
for feature_dir in specs/[0-9][0-9][0-9]-*/; do
  fid=$(basename "$feature_dir")
  [ "$fid" = "000-template" ] && continue
  echo "[Validate] Feature: $fid"

  # Project-dir existence check. Features created under the new convention
  # output code to projects/<fid>/. Skip when the feature's team_plan opts
  # out via "legacy_layout": true (preserves feat/001-pet-health-app).
  tp="$feature_dir/team_plan.json"
  legacy=false
  if [ -f "$tp" ] && [ "$(jq -r '.legacy_layout // false' "$tp")" = "true" ]; then
    legacy=true
  fi
  if [ "$legacy" = "false" ] && [ -f "$feature_dir/state.json" ]; then
    phase=$(jq -r '.phase // "bootstrap"' "$feature_dir/state.json")
    if [ "$phase" != "bootstrap" ] && [ "$phase" != "constitution_check" ]; then
      [ -d "projects/$fid" ] \
        || fail "feature $fid is past bootstrap (phase=$phase) but projects/$fid/ does not exist. Either create it (mkdir -p projects/$fid) or set team_plan.json#legacy_layout = true to opt out."
    fi
  fi

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

    cs_owner=$(jq -r .owner "$cs")

    # Tech-brief enforcement (only for coding-* roles — other roles like
    # `test`, `docs`, `security` don't go through the task-architect phase).
    case "$cs_owner" in
      coding-*)
        brief="$feature_dir"evidence/tech_briefs/"$task_ref".md
        if [ ! -f "$brief" ]; then
          fail "$cs from $cs_owner has no tech_brief at $brief — task-architect phase was skipped for task $task_ref"
        fi
        if grep -qE '^##[[:space:]]+OPEN[[:space:]]+QUESTIONS' "$brief"; then
          fail "$cs shipped against a tech_brief with unresolved OPEN QUESTIONS ($brief). Re-run task-architect for $task_ref before coding."
        fi
        # Brief must contain an Impact analysis section. This forces the
        # task-architect to do (or at least explicitly skip + state) the
        # white-box reconnaissance pass for every coding task.
        if ! grep -qE '^##[[:space:]]+Impact analysis' "$brief"; then
          fail "$brief is missing the '## Impact analysis (white-box)' section. task-architect must do source reconnaissance, not write briefs from contracts alone."
        fi
        ;;
    esac

    # Cross-check every change_set file against the resolved ownership for the
    # change_set's owner role. Skip silently when no ownership is declared
    # anywhere (legacy features authored before the project-shape system).
    globs=$(resolve_ownership "$fid" "$cs_owner")
    if [ -n "$globs" ]; then
      # Substitute {feature_id} in each glob before matching.
      globs_sub=$(printf '%s\n' "$globs" | sed "s|{feature_id}|$fid|g")
      while IFS= read -r fp; do
        [ -z "$fp" ] && continue
        if ! printf '%s\n' "$globs_sub" | path_in_globs "$fp"; then
          fail "$cs file '$fp' is outside ownership[$cs_owner] for feature $fid (resolved globs: $(echo "$globs_sub" | tr '\n' ' '))"
        fi
      done < <(jq -r '.files[].path' "$cs")
    else
      echo "[Validate] $cs: no ownership declared for role '$cs_owner' anywhere — skipping path cross-check (consider adding project_shape to specs/$fid/team_plan.json)."
    fi
  done

  # -- staging/hitl/ must be empty for the feature to be considered passing --
  hitl_files=("$feature_dir"staging/hitl/*.json)
  if [ ${#hitl_files[@]} -gt 0 ]; then
    echo "[Validate] $fid has pending HITL requests (not a failure, but commit may be blocked by runner)."
  fi
done

echo "[Validate] OK"
