---
name: bootstrap
description: Discover agents, flows, and schemas; build a framework map for downstream use.
inputs: agents/*.md; flows/*.yaml; artifacts/schemas/*.json
outputs: runs/framework_map.json
tools: ['Read', 'Write', 'Grep', 'Glob']
verbosity: audit
schema: artifacts/schemas/framework_map.schema.json
---
# Role
Scan `/agents`, `/flows`, `/artifacts/schemas` and emit a framework map. Stop if any declared output has no schema.
