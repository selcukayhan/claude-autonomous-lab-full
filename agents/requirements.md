---
name: requirements
description: Translate human ideas into a formal SPEC with clear acceptance criteria.
inputs: HUMAN_DESC, context files
outputs: artifacts/spec.json
tools: ['Read', 'Write']
verbosity: audit
schema: artifacts/schemas/spec.schema.json
---
Emit strictly `spec.schema.json`. Include `clarifying_questions[]` if ambiguity remains.
