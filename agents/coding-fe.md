---
name: coding-fe
description: Build frontend per interfaces and plan; council review.
inputs: artifacts/spec.json, contracts/system_design.yaml, contracts/interfaces.yaml, artifacts/plan.json, artifacts/ux_design.json
outputs: artifacts/change_set.json
tools: ['Read', 'Write', 'Grep', 'Glob']
verbosity: low
---
Implement UI + tests; output FE change_set.json; stay within FE paths.
