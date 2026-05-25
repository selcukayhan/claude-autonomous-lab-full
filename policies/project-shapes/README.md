# Project-shape templates

A **project shape** is the directory layout + role mix for a feature. The framework ships five canonical shapes here; the `architecture` agent picks one when authoring `specs/<feature_id>/team_plan.json`, or writes a custom `ownership` map if none fit.

| Shape | When to pick |
|---|---|
| `web-fullstack`   | Two-tier client/server app (web, mobile, desktop). FE + BE + tests + infra. |
| `monorepo`        | Multiple apps and/or services in one repo. `apps/` + `services/` + shared packages. |
| `cli`             | Single-binary command-line tool. No frontend; code under `src/` or `cmd/`. |
| `library`         | Publishable library / SDK. Public API + tests + examples. No long-running server. |
| `ml-pipeline`     | Data / ML project: notebooks, pipelines, models, datasets. |

## Resolution order (what the validator checks)

For each change_set, the effective ownership for the role is resolved as:

1. **Per-feature override** — `specs/<feature_id>/team_plan.json#ownership[<role>]`, if declared
2. **Shape preset** — `policies/project-shapes/<team_plan.project_shape>.json#ownership[<role>]`, if `project_shape` is set
3. **Global default** — `policies/agents.config.json#default_ownership[<role>]`

If none of the three define the role, the validator emits a warning and skips path-cross-check for that change_set (compatible with legacy features that pre-date this system).

## Adding a new shape

Drop a JSON file into this directory matching `artifacts/schemas/project_shape.schema.json`. The architecture agent will pick it up automatically.

## Customizing per-feature

The shape is a default. The architecture agent can override `ownership[<role>]` partially or fully in `team_plan.json` — per-feature overrides win.
