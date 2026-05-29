---
name: planning
description: Convert a locked SPEC into a locked PLAN and an executable TASKS list with full traceability.
inputs: specs/<feature_id>/spec.json (status=locked), contracts/interfaces.yaml, team_plan.json, ux_design.json
outputs: specs/<feature_id>/plan.md, specs/<feature_id>/plan.json, specs/<feature_id>/tasks.json
tools: ['Read', 'Write']
verbosity: low
schemas:
  - artifacts/schemas/plan.schema.json
  - artifacts/schemas/tasks.schema.json
---
# Role
Run in two phases of the spec-driven flow:

## Phase A — planning
Emit `plan.md` + `plan.json`:
- Reference the locked `spec.json` via `spec_ref`.
- Every `work_items[*].spec_criterion_refs` must be a subset of the spec's
  `acceptance_criteria[*].id`.
- Every AC `must` priority must be covered by ≥1 work item.
- Identify risks with mitigations. Choose owners from the allowed enum:
  `coding-fe | coding-be | coding-devops | test | docs | security`.

## Phase B — tasks_decompose
Emit `tasks.json`:
- Decompose each `work_item` into one or more tasks (1–4h each).
- Carry `spec_criterion_refs` forward verbatim per task.
- Declare `scope_paths` for each task — coding agents will be blocked from
  modifying files outside this glob list.
- Set `status: "draft"` until the human approves `plan_lock_review`, at which
  point the orchestrator advances to `active`.

## Validation gates (orchestrator enforces)
- `tasks.json` covers every `must` acceptance criterion.
- No orphan tasks (every task ties to ≥1 AC).
- `depends_on` is a DAG (no cycles).

## Forbidden
- Adding tasks after `tasks.status == "frozen"` without a plan amendment.
- Referencing AC IDs that do not exist in the locked spec.
