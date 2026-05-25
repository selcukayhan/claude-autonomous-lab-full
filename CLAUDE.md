# CLAUDE.md — Conventions & Operating Rules (Spec-Driven Mode)

This repo runs in **spec-driven development** mode. The flow is:

```
constitution → spec (locked) → plan (locked) → tasks → tech_briefs → coding → test → release
```

Every step is gated by either an automated validator or a Human-in-the-Loop
(HITL) review. The orchestrator never lets an agent skip a gate.

**Model tiering.** Each agent declares its model in `.claude/agents/<name>.md` frontmatter. Opus for reasoning (`orchestrator`, `requirements`, `architecture`, `planning`, `task-architect`, `policy`, `test`), Sonnet for execution (`coding-*`, `uiux-*`, `security`, `release`, `experiment`), Haiku for mechanical work (`bootstrap`, `context-manager`, `docs`). The `task-architect` agent is the linchpin: it produces a per-task tech brief on Opus so the `coding-*` agents can execute on Sonnet without re-deriving design.

## Resuming work (read first if you're a fresh session)

If you're a Claude session newly opened in this repo, orient by reading in this order:

1. **This file** (`CLAUDE.md`) — conventions + ownership.
2. **`constitution.md`** — immutable principles, HITL stops, ownership rules.
3. **`runs/learned_patterns.json`** — cross-feature lessons learned in prior sessions.
4. **`runs/benefit_report.json`** — current run-count and aggregate metrics.
5. **`specs/`** — list directories to discover active features. For each `specs/<feature_id>/`:
   - `state.json` — current lifecycle, phase, HITL state.
   - `evidence/feature_summary.md` — the canonical "you are here" doc with all completed work, locked decisions, ready-now tasks, and cross-cutting context for agents.
6. **`.claude/agents/<role>.md`** — your role's system prompt if you were spawned as a subagent.

The **feature_summary.md** in each feature's `evidence/` directory is the most important per-feature read. The orchestrator maintains it as agents complete work; subagents must read it before starting any task so they understand what's been built and why.

## Persistence layer (what survives session end)

| Where | What | Updated by |
|---|---|---|
| `git` on `feat/*` branches | All artifacts + code | Runner auto-commits |
| `constitution.md` | Principles | Constitution amendment HITL |
| `specs/<id>/state.json#history` | Chronological phase log | Orchestrator at each transition |
| `specs/<id>/evidence/feature_summary.md` | Detailed feature context for agents | Orchestrator after each phase / subagent return |
| `specs/<id>/spec.md#Decisions` | Per-feature decisions with CQ traceability | Requirements agent on lock |
| `specs/<id>/plan.md` ADRs + risks | Architectural decisions | Architecture + planning agents |
| `runs/learned_patterns.json` | Cross-feature lessons (strings) | Context-manager + orchestrator |
| `runs/benefit_report.json` | Aggregate metrics across runs | Context-manager |
| `runs/telemetry.jsonl` | Per-task execution telemetry (agent, model, duration, tokens, tool_uses) | `runner/task-update.sh` (called by coding agents + orchestrator) |
| Trello cards | Task status + DoD + AC refs (live) | `runner/task-update.sh` per-task; `runner/trello-sync.sh` for full re-syncs |

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
Ownership is resolved per-feature, not globally. Look it up in this order:

1. **`specs/<feature_id>/team_plan.json#ownership[<role>]`** — per-feature override (written by `architecture`).
2. **`policies/project-shapes/<team_plan.project_shape>.json#ownership[<role>]`** — the shape preset (web-fullstack / monorepo / cli / library / ml-pipeline). See `policies/project-shapes/README.md`.
3. **`policies/agents.config.json#default_ownership[<role>]`** — global fallback for non-coding roles (docs, requirements, planning, architecture, policy, etc.).

Coding-role ownership (`coding-fe`, `coding-be`, `coding-devops`) is INTENTIONALLY absent from the global default — every feature must pick a `project_shape` or declare its own coding-role globs so work isn't silently routed to paths that don't exist on disk.

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
