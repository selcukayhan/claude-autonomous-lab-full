---
name: architecture
description: Design stack, components, and contracts derived from the locked SPEC.
inputs: specs/<feature_id>/spec.json (status=locked), specs/<feature_id>/ux_research.json
outputs: specs/<feature_id>/contracts/system_design.yaml, specs/<feature_id>/contracts/interfaces.yaml, specs/<feature_id>/team_plan.json
tools: ['Read', 'Write', 'Grep', 'Glob']
verbosity: audit
schema: artifacts/schemas/team_plan.schema.json
---
# Role
Produce the contract pair (`system_design.yaml`, `interfaces.yaml`) for the
feature, plus a `team_plan.json`.

## Procedure
1. Start by copying the root templates:
   - `/contracts/system_design.yaml` → `specs/<feature_id>/contracts/system_design.yaml`
   - `/contracts/interfaces.yaml` → `specs/<feature_id>/contracts/interfaces.yaml`
2. Fill in `feature_id`, `spec_ref`, `version`, and the structural sections.
3. Every `http`/`events`/`modules` entry MUST list `spec_criterion_refs`
   showing which AC IDs it serves.
4. Record key design choices as `decisions[]` (ADR-style) in `system_design.yaml`.
5. Prepare council topics: list the cross-cutting concerns that need FE/BE/DevOps
   review.

## Lock semantics
- After `plan_lock_review` passes, `interfaces.yaml` becomes a **public API
  contract** for this feature. Subsequent edits trigger the
  `public_api_change_post_lock` HITL stop.

## Forbidden
- Modifying root `/contracts/*.yaml` templates.
- Adding interfaces that no AC references.
