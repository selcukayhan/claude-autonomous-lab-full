# CLAUDE.md — Conventions & Operating Rules (Spec-Driven Mode)

This repo runs in **spec-driven development** mode. The flow is:

```
constitution → spec (locked) → plan (locked) → tasks → coding → test → release
```

Every step is gated by either an automated validator or a Human-in-the-Loop
(HITL) review. The orchestrator never lets an agent skip a gate.

## Context tiers (assembled per phase)
- **Tier0 (always):** `CLAUDE.md`, `constitution.md`, `policies/*`, the active agent manifest.
- **Tier1:** the active phase's declared `reads:` from `flows/default.flow.yaml`.
- **Tier2:** semantic retrieval (top_k≤8) over `docs/**`, `runs/**`, sibling locked specs/plans. **Never** retrieve from `specs/*/staging/**`.
- **Tier3:** up to 5 distilled lessons from `runs/learned_patterns.json`.

## Artifact discipline
- All agent writes land in `specs/<feature_id>/staging/...` first.
- The orchestrator promotes to `specs/<feature_id>/...` only after schema
  validation **and** traceability validation pass (`runner/validate.sh`).
- JSON must validate against `artifacts/schemas/*`. YAML contracts must follow
  the templates in `contracts/`.
- Summarize reasoning; do **not** record chain-of-thought.

## Traceability (binding)
Every downstream artifact references its upstream:
- `plan.json` → `spec_ref`
- `tasks.json` → `plan_ref` + per-task `spec_criterion_refs[]`
- `change_set.json` → `task_ref` + mirrored `spec_criterion_refs[]`
- `test_plan.json` → `task_refs[]`

Validator rejects artifacts that break the chain or reference non-existent IDs.

## HITL stops
Auto-execution pauses for human review at these gates (see `constitution.md` §III):
1. `spec_lock_review` — after requirements, before architecture.
2. `plan_lock_review` — after planning + tasks_decompose, before coding.
3. `pre_merge_review` — after test, before promotion to `main`.
4. `constitution_amendment` — any edit to `constitution.md`.
5. `public_api_change_post_lock` — edits to a locked `interfaces.yaml`.

Agents must emit a `hitl_request` artifact under
`specs/<feature_id>/staging/hitl/<stop_id>.json` and pause. The runner blocks
commits while a HITL request is pending.

## Ownership (binding)
- **FE:** `src/frontend/**`
- **BE:** `src/backend/**`, `src/shared/**`
- **DevOps:** `runner/**`, `.github/**`
- **Docs:** `README.md`, `docs/**`, `specs/*/spec.md`, `specs/*/plan.md`
- **Requirements / Planning / Architecture / etc.:** see `policies/agents.config.json#ownership`

Cross-boundary edits require an explicit `team_plan.json` entry plus
reconciliation by the `architecture` agent.

## Scope discipline
- A locked spec cannot silently grow new acceptance criteria. To add ACs:
  re-open the spec, bump version (`major` for breaking, `minor` otherwise),
  go through `spec_lock_review` again.
- Tasks may not bypass their plan. New tasks require a plan amendment.
- A change_set that touches files outside the referenced task's `scope_paths`
  is rejected by `runner/validate.sh`.

## Evolution
- `experiment` proposes non-destructive variants only.
- `policy` (or a human) approves promotions per
  `policies/context-governance.json#allow_auto_promotion` (default: false).
- Constitution amendments are the only way to change `constitution.md`.

## Quick references
- New feature: copy `specs/000-template/` → `specs/NNN-your-feature/`, then
  ask the orchestrator to drive the flow.
- See `specs/README.md` for the per-feature directory layout.
- See `flows/default.flow.yaml` for the full state machine.
