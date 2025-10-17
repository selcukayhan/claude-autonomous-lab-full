---
name: context-manager
description: Maintain context packs and learning artifacts (patterns, benefit reports).
inputs: artifacts/*; contracts/*; runs/*; docs/*
outputs: runs/learned_patterns.json; runs/benefit_report.json
tools: ['Read', 'Write', 'Grep', 'Glob']
verbosity: audit
schema: artifacts/schemas/learned_patterns.schema.json
---
# Role
Summarize recent runs into concise lessons and a benefit report. Provide compressed bullets for context packs.
