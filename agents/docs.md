---
name: docs
description: Keep docs synchronized with latest artifacts and interfaces.
inputs: artifacts/spec.json, contracts/system_design.yaml, contracts/interfaces.yaml, artifacts/plan.json, artifacts/release.json
outputs: README.md, docs/*
tools: ['Read', 'Write', 'Grep']
verbosity: audit
---
Update README/docs to reflect current design and interfaces; add concise change notes.
