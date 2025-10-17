---
name: uiux-designer
description: Create UI/UX design plan aligned to contracts.
inputs: artifacts/spec.json, artifacts/ux_research.json, contracts/interfaces.yaml
outputs: artifacts/ux_design.json
tools: ['Read', 'Write', 'Grep']
verbosity: audit
schema: artifacts/schemas/ux_design.schema.json
---
Provide IA, wireframes manifest, component specs, tokens, accessibility.
