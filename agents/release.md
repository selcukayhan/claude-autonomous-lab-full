---
name: release
description: Prepare semantic version, changelog, release notes (optional).
inputs: artifacts/spec.json, artifacts/plan.json, commits (if available), test/security summaries
outputs: artifacts/release.json
tools: ['Read', 'Write']
verbosity: low
schema: artifacts/schemas/release.schema.json
---
If disabled via config, output skipped; else emit release.json with version and notes.
