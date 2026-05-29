# /specs — Per-Feature Spec-Driven Workspace

Every feature gets its own directory under `specs/`, named with the pattern
`NNN-kebab-name` (e.g., `001-task-manager`, `002-export-csv`).

## Lifecycle

```
draft → in_review → locked → (amended)* → completed
```

Each feature progresses through these phases — see `flows/default.flow.yaml`.

## Directory layout

```
specs/<feature_id>/
├── state.json              # current lifecycle state — see state.schema.json
├── spec.md                 # human-readable spec  (REQUIRED)
├── spec.json               # machine-readable spec (REQUIRED; validates against spec.schema.json)
├── plan.md                 # human-readable plan
├── plan.json               # machine-readable plan (validates against plan.schema.json)
├── tasks.json              # decomposed executable tasks (validates against tasks.schema.json)
├── contracts/
│   ├── system_design.yaml  # copied from /contracts/system_design.yaml template, filled in
│   └── interfaces.yaml     # copied from /contracts/interfaces.yaml template, filled in
├── evidence/
│   ├── change_sets/        # one JSON per task (validates against change_set.schema.json)
│   ├── test_plan.json
│   ├── security_summary.json (optional)
│   ├── waivers.json        (optional, HITL-recorded)
│   └── run_<timestamp>.json # reproducibility record per run
└── staging/                # agents write here first; orchestrator promotes after validation
```

## HITL stops

Three mandatory gates (see `constitution.md` §III):

| Gate | After phase | Approves |
|------|-------------|----------|
| `spec_lock_review`  | requirements | spec.md / spec.json |
| `plan_lock_review`  | planning     | plan.md / plan.json / tasks.json |
| `pre_merge_review`  | test         | evidence/* → main |

## Creating a new feature

1. Copy `specs/000-template/` to `specs/NNN-your-feature/`.
2. Fill in `spec.md`. Run the requirements agent to emit `spec.json`.
3. Wait for `spec_lock_review`. Approve or send back with comments in
   `spec.md → ## Review`.
4. Continue through the flow.

## Why per-feature directories?

- Spec-driven flows treat each feature as an independent unit of work.
- Parallel features don't collide on shared artifacts.
- Each feature's evidence trail is self-contained for audit and rollback.
