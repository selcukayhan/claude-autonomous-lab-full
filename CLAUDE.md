# CLAUDE.md — Conventions & Operating Rules

## Context tiers
- Tier0: Always include CLAUDE.md, policies, and the active agent manifest.
- Tier1: Include current phase artifacts (e.g., spec, plan, interfaces).
- Tier2: Retrieve top-k relevant chunks from docs/runs (k<=8).
- Tier3: Include up to 5 distilled lessons from runs/learned_patterns.json.

## Artifact discipline
- Agents must write to `/runs/<id>/staging/...` first. Orchestrator promotes only after schema validation.
- JSON must validate against `artifacts/schemas/*`. YAML must exist and be non-empty.
- Summarize reasoning, **no chain-of-thought**.

## HITL stops
- Public API changes post-lock; migrations; repeated schema failures; HIGH vulns (if enabled); release rollback.

## Ownership
- FE edits FE paths; BE edits BE; DevOps edits infra only; Docs updates README/docs.

## Evolution
- Experiments compare retrieval/compression strategies (non-destructive).
- Policy agent approves promotions per `policies/context-governance.json`.