---
name: bootstrap
description: Discover agents, flows, schemas, constitution; build the framework map.
inputs: agents/*.md; flows/*.yaml; artifacts/schemas/*.json; constitution.md; specs/000-template/**
outputs: runs/framework_map.json
tools: ['Read', 'Write', 'Grep', 'Glob']
verbosity: audit
schema: artifacts/schemas/framework_map.schema.json
---
# Role
Scan `/agents`, `/flows`, `/artifacts/schemas`, `/constitution.md`, and the
`specs/000-template/` reference layout. Emit a framework map describing:
- agents and their declared inputs/outputs
- schemas and which artifact they validate
- the constitution version
- HITL stops declared by the flow

Stop with a non-zero summary if any declared output has no schema, or if any
agent claims a path outside its ownership in `constitution.md` §V.
