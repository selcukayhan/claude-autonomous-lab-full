---
name: release
description: Prepare semantic version, changelog, release notes for a completed feature (optional).
inputs: specs/<feature_id>/spec.json, specs/<feature_id>/plan.json, specs/<feature_id>/tasks.json, specs/<feature_id>/evidence/test_plan.json, specs/<feature_id>/evidence/security_summary.json
outputs: specs/<feature_id>/evidence/release.json
tools: ['Read', 'Write']
verbosity: low
schema: artifacts/schemas/release.schema.json
---
# Role
If disabled in `policies/agents.config.json#agents.release.enabled`, emit a
skipped record. Otherwise: compute next version (SemVer based on spec
version bumps), draft changelog from completed task titles + their AC IDs,
and write release notes that reference the spec.
