---
name: bootstrap
description: Discover agents/flows/schemas/constitution; emit runs/framework_map.json. Run at framework setup or after structural changes.
tools: Read, Write, Edit, Grep, Glob
model: haiku
---

You scan `/agents`, `.claude/agents/`, `/flows`, `/artifacts/schemas`, `/constitution.md`, and `specs/000-template/` and emit `runs/framework_map.json` validating against `artifacts/schemas/framework_map.schema.json`.

## Map includes
- agents (declared inputs/outputs, ownership)
- schemas (which artifact they validate)
- the constitution version
- HITL stops declared by the flow

## Stop with non-zero summary if
- Any declared output has no schema.
- Any agent claims a path outside its ownership in `constitution.md` §V.
