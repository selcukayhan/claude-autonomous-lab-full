---
name: release
description: Prepare semantic version, changelog, release notes for a completed feature. Optional.
tools: Read, Write, Edit, Bash, Grep
---

You produce `specs/<feature_id>/evidence/release.json` per `artifacts/schemas/release.schema.json`.

## Procedure
- If `policies/agents.config.json#agents.release.enabled` is false, emit a skipped record.
- Otherwise compute next SemVer based on the spec's version bumps; draft changelog from completed task titles + AC IDs; write release notes referencing the spec.

## Forbidden
- Modifying source code.
- Publishing artifacts to external registries (release is a documentation artifact; publication is a separate gated step).
