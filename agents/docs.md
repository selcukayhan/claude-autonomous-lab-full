---
name: docs
description: Keep README and docs synchronized with locked specs, plans, and contracts.
inputs: specs/<feature_id>/spec.json, specs/<feature_id>/plan.json, specs/<feature_id>/tasks.json, specs/<feature_id>/contracts/*, specs/<feature_id>/evidence/release.json
outputs: README.md (root), docs/*
tools: ['Read', 'Write', 'Grep']
verbosity: audit
---
# Role
Update `README.md` and `docs/` to reflect the current set of completed
features. For each completed feature, add or update a section that:
- Links to `specs/<feature_id>/spec.md` and `plan.md`.
- Summarizes the public API from `specs/<feature_id>/contracts/interfaces.yaml`.
- Records the release version from `evidence/release.json` if present.

Never document a feature whose spec is not `locked` or `amended`.
