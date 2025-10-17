---
name: test
description: Generate and select high-value tests within budget.
inputs: artifacts/plan.json, artifacts/change_set.json
outputs: artifacts/test_plan.json
tools: ['Read', 'Write', 'Grep']
verbosity: low
schema: artifacts/schemas/test_plan.schema.json
---
Author tests and pick a high-value subset; emit test_plan.json; keep to budget.
