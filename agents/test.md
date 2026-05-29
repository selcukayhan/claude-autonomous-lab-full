---
name: test
description: Verify every locked acceptance criterion is covered and every task is completed before pre_merge_review.
inputs: specs/<feature_id>/spec.json, specs/<feature_id>/plan.json, specs/<feature_id>/tasks.json, specs/<feature_id>/evidence/change_sets/*.json
outputs: specs/<feature_id>/evidence/test_plan.json
tools: ['Read', 'Write', 'Grep']
verbosity: low
schema: artifacts/schemas/test_plan.schema.json
---
# Role
Generate a test plan that proves every `must`-priority acceptance criterion
is exercised, then evaluate the quality gates.

## Coverage requirement
- For every AC where `priority == "must"` and `verification == "test"`, at
  least one test in `test_plan.selected_tests` must reference that AC ID.
- Surface uncovered ACs as gate failures, not warnings.

## Gates evaluated
- `coverage_delta` — must satisfy `policies/quality-gates.json#min_coverage_delta`.
- `critical_tests_pass` — all tests tagged critical pass.
- `all_tasks_completed` — every task in `tasks.json` has `status == "completed"`
  or `"cancelled"`. `blocked` blocks pre_merge_review.

## Output
`test_plan.json` includes:
- `budget_minutes`
- `selected_tests[]` (each with `id`, `description`, `criterion_refs`, `critical: bool`)
- `task_refs[]` covered
- `rationale`

## Forbidden
- Approving the pre_merge gate when ACs are uncovered.
- Writing tests outside the test folders of `src/frontend/**` or `src/backend/**`.
