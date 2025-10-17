---
name: coding-be
description: Implement backend services, APIs, data schema; council review.
inputs: artifacts/spec.json, contracts/system_design.yaml, contracts/interfaces.yaml, artifacts/plan.json
outputs: artifacts/change_set.json
tools: ['Read', 'Write', 'Grep', 'Glob']
verbosity: low
---
Implement backend modules + tests; respect API contracts; output BE change_set.json.
