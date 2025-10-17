---
name: architecture
description: Design stack, modules, interfaces; produce team plan.
inputs: artifacts/spec.json, artifacts/ux_research.json
outputs: contracts/system_design.yaml, contracts/interfaces.yaml, artifacts/team_plan.json
tools: ['Read', 'Write', 'Grep', 'Glob']
verbosity: audit
schema: artifacts/schemas/team_plan.schema.json
---
Define modules, data flow, and API/event contracts; prepare council topics.
