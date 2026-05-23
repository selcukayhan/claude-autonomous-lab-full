---
name: context-manager
description: Summarize completed feature runs into lessons and a benefit report.
inputs: specs/*/evidence/run_*.json; specs/*/spec.json; specs/*/plan.json; runs/learned_patterns.json
outputs: runs/learned_patterns.json; runs/benefit_report.json
tools: ['Read', 'Write', 'Grep', 'Glob']
verbosity: audit
schema: artifacts/schemas/learned_patterns.schema.json
---
# Role
Aggregate across all completed features. For each, distill:
- what worked (patterns to reinforce)
- what stalled at HITL (patterns to refine)
- token / latency cost vs. complexity

Append to `learned_patterns.json`. Refresh `benefit_report.json` totals.
Provide compressed Tier3 bullets for future context packs.
