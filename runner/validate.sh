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
test -f CLAUDE.md || { echo "[Validate] missing CLAUDE.md"; exit 1; }

# CLAUDE.md must contain the Orchestration responsibility section that binds
# the main Claude Code session to act as orchestrator. Removing this section
# accidentally would silently revert the framework to "spawn orchestrator via
# Agent tool" which is known-broken (Agent grant strips at spawn — see
# feedback_orchestrator_top_level memory).
grep -qE '^##[[:space:]]+Orchestration responsibility' CLAUDE.md \
  || { echo "[Validate] CLAUDE.md missing '## Orchestration responsibility' section — main session must be bound as orchestrator (see feedback_orchestrator_top_level.md)"; exit 1; }
grep -qE 'Trigger phrases that activate orchestrator mode' CLAUDE.md \
  || { echo "[Validate] CLAUDE.md Orchestration section missing the 'Trigger phrases' sub-block — main session needs explicit triggers"; exit 1; }

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

WARN_COUNT=0
warn() { echo "[Validate] WARN: $*"; WARN_COUNT=$((WARN_COUNT + 1)); }

# Parse an ISO-8601 timestamp into a Unix epoch. Tries GNU date first
# (Linux/CI), falls back to BSD date (macOS). Echoes 0 on failure so callers
# can treat unknown timestamps as "very old" and skip the suspicious-modify
# check below.
iso_to_epoch() {
  local iso="$1"
  [ -z "$iso" ] && { echo 0; return; }
  local e
  e=$(date -d "$iso" +%s 2>/dev/null) && { echo "$e"; return; }
  # BSD date — try with and without the trailing Z.
  e=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) && { echo "$e"; return; }
  e=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${iso%Z}" +%s 2>/dev/null) && { echo "$e"; return; }
  echo 0
}

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
  # output code to projects/<fid>/. Skip when the feature is "legacy":
  # either team_plan.json is missing entirely (feature pre-dates the
  # architecture phase OR opted out via flow_deviation like
  # 002-webpack-migration), OR team_plan.json#legacy_layout = true
  # (explicit opt-out like 001-pet-health-app).
  tp="$feature_dir/team_plan.json"
  legacy=false
  if [ ! -f "$tp" ]; then
    legacy=true
  elif [ "$(jq -r '.legacy_layout // false' "$tp")" = "true" ]; then
    legacy=true
  fi
  if [ "$legacy" = "false" ] && [ -f "$feature_dir/state.json" ]; then
    phase=$(jq -r '.phase // "bootstrap"' "$feature_dir/state.json")
    if [ "$phase" != "bootstrap" ] && [ "$phase" != "constitution_check" ]; then
      [ -d "projects/$fid" ] \
        || fail "feature $fid is past bootstrap (phase=$phase) but projects/$fid/ does not exist. Either create it (mkdir -p projects/$fid) or set team_plan.json#legacy_layout = true to opt out."
    fi
  fi

  # -- Framework-drift checks (added 2026-05-27 after 004/005/006 shipped --
  # without feature_summary.md and with tasks.json#status stuck at locked/draft).
  #
  # These are INTENTIONALLY decoupled from `legacy_layout` (which is about the
  # per-feature `projects/<fid>/` output convention) — feature_summary.md and
  # tasks.status flips apply to ANY active SDD feature regardless of where its
  # code lives. Per-feature opt-out: `team_plan.json#legacy_drift = true`.
  #
  # A missing team_plan.json (pre-team_plan-system features like
  # 002-webpack-migration) is treated as an implicit drift opt-out, matching
  # the existing legacy_layout precedent for the project-dir check above.
  drift_optout=false
  if [ ! -f "$tp" ]; then
    drift_optout=true
  elif [ "$(jq -r '.legacy_drift // false' "$tp")" = "true" ]; then
    drift_optout=true
  fi

  # Drift check A: feature_summary.md must exist once the feature passes the
  # requirements phase. It's the canonical "you are here" doc cited by
  # CLAUDE.md tier-1 reads and orchestrator.md's per-phase protocol.
  if [ "$drift_optout" = "false" ] && [ -f "$feature_dir/state.json" ]; then
    phase=$(jq -r '.phase // "bootstrap"' "$feature_dir/state.json")
    case "$phase" in
      bootstrap|constitution_check|requirements)
        : # too early to require feature_summary.md
        ;;
      *)
        [ -f "$feature_dir/evidence/feature_summary.md" ] \
          || fail "feature $fid is past requirements (phase=$phase) but evidence/feature_summary.md is missing. Create it per .claude/agents/orchestrator.md §feature_summary.md, or set team_plan.json#legacy_drift = true to opt out."
        ;;
    esac
  fi

  # Drift check B: when state.json#plan_status == "locked", tasks.json#status
  # must have advanced past draft/locked. The orchestrator is supposed to flip
  # it to in_review (for Trello sync) and then active (for coding) per
  # .claude/agents/orchestrator.md §plan_lock_review three-step sequence.
  # Otherwise trello-sync.sh + task-update.sh silently skip every per-task push.
  if [ "$drift_optout" = "false" ] \
     && [ -f "$feature_dir/state.json" ] && [ -f "$feature_dir/tasks.json" ]; then
    plan_status=$(jq -r '.plan_status // empty' "$feature_dir/state.json")
    tasks_status=$(jq -r '.status // empty' "$feature_dir/tasks.json")
    if [ "$plan_status" = "locked" ]; then
      case "$tasks_status" in
        in_review|active|frozen|completed)
          : # ok
          ;;
        *)
          fail "feature $fid: state.json#plan_status=locked but tasks.json#status=$tasks_status. Orchestrator must flip tasks.json#status to in_review at plan_lock_review (then active on approval) so trello-sync.sh + task-update.sh push to Trello. See .claude/agents/orchestrator.md §plan_lock_review, or set team_plan.json#legacy_drift = true to opt out."
          ;;
      esac
    fi
  fi

  # Drift check C: once tasks.json#status >= in_review, every coding-* task in
  # tasks.json must have a corresponding tech_brief at evidence/tech_briefs/<id>.md.
  # The per-change_set version of this check above is reactive — it only fires
  # when an agent already shipped a change_set without a brief. This proactive
  # check catches the gap before any coding wave starts.
  if [ "$drift_optout" = "false" ] && [ -f "$feature_dir/tasks.json" ]; then
    tasks_status=$(jq -r '.status // empty' "$feature_dir/tasks.json")
    case "$tasks_status" in
      in_review|active|frozen|completed)
        # Coding-role tasks should each have a tech_brief.
        missing_briefs=$(jq -r '
          .tasks[]
          | select((.owner // .agent_role // "") | test("^coding-"))
          | .id
        ' "$feature_dir/tasks.json" | while read -r tid; do
          [ -z "$tid" ] && continue
          [ -f "$feature_dir/evidence/tech_briefs/$tid.md" ] || echo "$tid"
        done)
        if [ -n "$missing_briefs" ]; then
          missing_summary=$(echo "$missing_briefs" | tr '\n' ' ')
          fail "feature $fid: tasks.json#status=$tasks_status but coding-* tasks have no tech_brief at evidence/tech_briefs/: $missing_summary. task-architect phase was skipped or incomplete. Re-run task-architect, or set team_plan.json#legacy_drift = true to opt out."
        fi
        ;;
    esac
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
    # Skipped for features that pre-date the task-architect phase: features
    # with team_plan.json#legacy_layout = true OR no team_plan.json at all
    # (these are old features authored before the modern framework).
    if [ "$legacy" = "false" ]; then
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
    fi

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

    # -- change_set ↔ git-diff parity (agent over-reporting detector) --
    # Catches the "agent reported file modified but disk shows no change"
    # pattern. Heuristic: if a change_set claims a file was modified/created
    # AFTER its last git commit AND the working tree shows no uncommitted
    # changes for that file, the claimed modification likely never landed.
    # Concrete incidents this catches: T043/T044 (4 nav files claimed but
    # never edited), T045 (DOB swap reported but didn't ship), T046 (default
    # 09:00 + HTML5 time picker reported but didn't ship). See
    # runs/learned_patterns.json: "Agent change_set over-reporting".
    cs_finished_iso=$(jq -r '.finished_at // .started_at // empty' "$cs")
    cs_epoch=$(iso_to_epoch "$cs_finished_iso")
    if [ "$cs_epoch" -gt 0 ]; then
      while IFS=$'\t' read -r fp action lines_added; do
        [ -z "$fp" ] && continue
        # Treat null/missing action the same as modified|created (older
        # change_sets predate the action field). Skip explicit deletions.
        case "$action" in
          deleted|removed) continue ;;
        esac
        [ "${lines_added:-0}" -gt 0 ] || continue
        if [ ! -f "$fp" ]; then
          [ "$action" = "created" ] && warn "$cs claims '$fp' created but file is missing on disk"
          continue
        fi
        # If the file has any uncommitted change (modified OR untracked), the
        # claim is consistent. `git diff --quiet HEAD --` misses untracked
        # files (newly created not yet `git add`'d), so use `git status
        # --porcelain` which surfaces ALL states (?? for untracked, M/A/D for
        # tracked changes).
        if [ -n "$(git status --porcelain -- "$fp" 2>/dev/null)" ]; then
          continue
        fi
        # Working tree is clean for this file. Check whether the last commit
        # touching it is OLDER than the change_set finish time. If so, the
        # change_set claims a post-commit modification that never landed.
        last_commit_epoch=$(git log -1 --format=%ct -- "$fp" 2>/dev/null || echo 0)
        [ -z "$last_commit_epoch" ] && last_commit_epoch=0
        if [ "$cs_epoch" -gt "$last_commit_epoch" ]; then
          warn "$cs claims '$fp' modified (lines_added=$lines_added) at $cs_finished_iso but file is clean against HEAD AND last commit touching it is older — modification may not have landed on disk"
        fi
      done < <(jq -r '.files[] | [.path, (.action // "unknown"), (.lines_added // 0)] | @tsv' "$cs")
    fi
  done

  # -- staging/hitl/ must be empty for the feature to be considered passing --
  hitl_files=("$feature_dir"staging/hitl/*.json)
  if [ ${#hitl_files[@]} -gt 0 ]; then
    echo "[Validate] $fid has pending HITL requests (not a failure, but commit may be blocked by runner)."
  fi
done

# -- Drift Check D: orchestrator inline-edit surveillance ---------------------
# Flag uncommitted modifications to src/** or projects/** that aren't claimed
# by any change_set on disk. This surfaces bug-routing violations BEFORE they
# commit — the orchestrator is supposed to route bug fixes back to the
# coding-* role that owns the file, not patch them inline.
# See .claude/agents/orchestrator.md §"Bug routing protocol (binding)".
#
# Implementation: collect all paths claimed by every change_set under
# specs/*/evidence/change_sets/*.json and specs/*/staging/change_sets/*.json.
# Then walk `git status --porcelain` for modified/added src/** or projects/**
# files. Each unclaimed modification → WARN.
#
# Per-orchestrator escape hatch: set RUNNER_SKIP_DRIFT_D=1 in the environment
# to silence this check (for legitimate framework-touching-source cases, e.g.
# a refactor that crosses the orchestrator/coding boundary intentionally).
if [ "${RUNNER_SKIP_DRIFT_D:-0}" != "1" ] && command -v git >/dev/null 2>&1; then
  # Collect every file path claimed by any change_set (evidence + staging).
  claimed_paths_file=$(mktemp 2>/dev/null || echo "/tmp/validate_claimed_$$")
  for cs in specs/*/evidence/change_sets/*.json specs/*/staging/change_sets/*.json; do
    [ -f "$cs" ] || continue
    jq -r '.files[]?.path // empty' "$cs" 2>/dev/null
  done | sort -u > "$claimed_paths_file"

  # Walk uncommitted changes to src/** or projects/** and flag unclaimed paths.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # `git status --porcelain` format: "XY path" where X/Y are status codes.
    # Status code at columns 1-2; path at column 4+. Handle rename arrows.
    status_code="${line:0:2}"
    fp="${line:3}"
    # Skip deletions — no inline-edit risk.
    case "$status_code" in
      *D*|D*) continue ;;
    esac
    # Strip rename arrow if present (e.g., "old -> new").
    case "$fp" in
      *' -> '*) fp="${fp##* -> }" ;;
    esac
    # Strip surrounding quotes that git emits for paths with spaces.
    fp="${fp%\"}"; fp="${fp#\"}"
    # Only check coding-role paths.
    case "$fp" in
      src/*|projects/*) ;;
      *) continue ;;
    esac
    # Claimed by any change_set?
    if ! grep -Fxq -- "$fp" "$claimed_paths_file" 2>/dev/null; then
      warn "uncommitted edit to '$fp' is not claimed by any change_set. Route this fix back to the role that owns the file (see .claude/agents/orchestrator.md §Bug routing protocol), or set RUNNER_SKIP_DRIFT_D=1 if this is a legitimate orchestrator-level edit."
    fi
  done < <(git status --porcelain 2>/dev/null)

  rm -f "$claimed_paths_file"
fi

if [ "$WARN_COUNT" -gt 0 ]; then
  echo "[Validate] OK (with $WARN_COUNT warning$([ "$WARN_COUNT" -eq 1 ] || echo s) — review the WARN lines above)"
else
  echo "[Validate] OK"
fi
