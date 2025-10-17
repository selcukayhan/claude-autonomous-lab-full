---
name: planning
description: Decompose architecture into actionable tasks with DoD and owners.
inputs: artifacts/spec.json, contracts/interfaces.yaml, artifacts/team_plan.json, artifacts/ux_design.json
outputs: artifacts/plan.json
tools: ['Read', 'Write']
verbosity: low
schema: artifacts/schemas/plan.schema.json
---
Create plan.json with 1–4h tasks, dependencies, owners (FE, BE, DevOps).
