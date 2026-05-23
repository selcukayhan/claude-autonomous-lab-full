# Claude Autonomous Lab — Spec-Driven Edition

A **language-agnostic, Claude-native, spec-driven development framework**.

Every feature starts as a spec, locks at human review, decomposes into a plan,
expands into trackable tasks, and only then becomes code. The orchestrator
enforces the chain end-to-end and pauses at three HITL stops so a human
stays in the loop on every promotion.

```
constitution → spec (locked) → plan (locked) → tasks → coding → test → release
       │            │              │             │         │        │
       │            └─ HITL ──────┘             └─── HITL ─────────┘
       └─ amendment HITL                                 │
                                                        on merge
```

---

## Why spec-driven?

Agentic flows produce more reliable software when the inputs are explicit.
This repo upgrades the previous "agentic SDLC" model with three guarantees:

1. **No code without a locked spec.** `runner/validate.sh` and CI refuse to
   promote a change_set unless its task traces back to an acceptance criterion
   in a `status: locked` spec.
2. **Every change is traceable.** `change_set → task → plan → spec → constitution`.
   Break the chain and validation fails.
3. **Humans stop the machine at three known places**: spec lock, plan lock,
   pre-merge. No surprise commits.

The 15-agent council (FE / BE / DevOps / Architecture / UX research+design /
Test / Security / Release / Docs / Policy / Experiment / Context-manager /
Bootstrap / Orchestrator / Requirements / Planning) is preserved — they now
operate against a strict spec-driven artifact graph.

---

## Quick start

### 1. Open in Claude Code (or Claude Desktop)
Make sure the working directory is this repo so agents can read/write files.

### 2. (Optional) Install runner deps
```bash
brew install fswatch jq
npm install -g ajv-cli@5   # enables full JSON Schema validation
```

### 3. Start the runner
```bash
bash runner/runner.sh        # macOS / Linux
.\runner\runner.ps1          # Windows
```

The runner watches `specs/`, `src/`, `docs/`, `constitution.md`. On every
change it runs `runner/validate.sh` and only commits when all schema +
traceability checks pass and no HITL request is pending.

### 4. Kick off a feature
In Claude, say something like:

> "Use the orchestrator to start a new feature: a small calculator web app."

The orchestrator will:
- allocate the next feature_id (e.g., `001-calculator`),
- copy `specs/000-template/` → `specs/001-calculator/`,
- run `requirements` to produce `spec.md` + `spec.json`,
- **stop at `spec_lock_review`** and emit a `hitl_request`,
- continue through architecture, planning, tasks, coding, test,
- **stop at `plan_lock_review`** and `pre_merge_review` for your sign-off,
- promote artifacts and commit.

---

## HITL stops

| Stop                          | Fires after          | You approve |
|-------------------------------|----------------------|-------------|
| `spec_lock_review`            | requirements         | spec.md / spec.json |
| `plan_lock_review`            | planning + tasks     | plan.md / plan.json / tasks.json |
| `pre_merge_review`            | test                 | the full evidence bundle |
| `constitution_amendment`      | edit to `constitution.md` | the amendment spec |
| `public_api_change_post_lock` | edit to a locked `interfaces.yaml` | the API change |

Approve by editing the `## Review` section of the relevant markdown file (or
the matching `lock_record` in the JSON) and removing the request file under
`specs/<feature_id>/staging/hitl/`.

---

## Repo layout

```
claude-autonomous-lab/
├── constitution.md                   # IMMUTABLE principles — amendment requires HITL
├── CLAUDE.md                         # Conventions, context tiers, ownership rules
│
├── agents/                           # 15 agent manifests (orchestrator + SDLC + learning)
├── flows/default.flow.yaml           # State machine with HITL stops
│
├── artifacts/schemas/                # JSON Schemas for every artifact
│   ├── constitution.schema.json
│   ├── spec.schema.json
│   ├── plan.schema.json
│   ├── tasks.schema.json
│   ├── change_set.schema.json
│   └── ...
│
├── contracts/                        # ROOT templates for system_design / interfaces
│   ├── system_design.yaml            # copied per-feature by architecture agent
│   └── interfaces.yaml
│
├── policies/                         # Quality gates, governance, agent ownership
│   ├── quality-gates.json
│   ├── context-governance.json
│   └── agents.config.json
│
├── specs/                            # PER-FEATURE workspace
│   ├── README.md                     # explains the lifecycle
│   ├── 000-template/                 # copy this when starting a new feature
│   │   ├── state.json
│   │   ├── spec.md / spec.json
│   │   ├── plan.md / plan.json
│   │   ├── tasks.json
│   │   ├── contracts/
│   │   ├── evidence/
│   │   └── staging/
│   └── NNN-your-feature/             # one per feature
│
├── runner/                           # Local automation
│   ├── runner.sh / runner.ps1        # watcher + commit
│   ├── validate.sh                   # schema + traceability gate
│   └── runner.config.json
│
├── src/                              # Code (FE / BE / Shared) — produced by coding agents
├── runs/                             # Cross-feature learning artifacts
│   ├── framework_map.json
│   ├── learned_patterns.json
│   └── benefit_report.json
└── .github/workflows/ci.yml          # CI mirror of runner/validate.sh
```

---

## The spec → plan → tasks → code chain

| Artifact         | Schema                               | Locked by              |
|------------------|--------------------------------------|------------------------|
| `spec.json`      | `spec.schema.json`                   | `spec_lock_review`     |
| `plan.json`      | `plan.schema.json`                   | `plan_lock_review`     |
| `tasks.json`     | `tasks.schema.json`                  | `plan_lock_review`     |
| `change_set.json`| `change_set.schema.json`             | `pre_merge_review`     |
| `test_plan.json` | `test_plan.schema.json`              | `pre_merge_review`     |
| `release.json`   | `release.schema.json` (optional)     | release agent          |

Every downstream artifact carries refs upward. The validator (`runner/validate.sh`
+ CI) rejects:
- a `plan` whose `work_items` reference an AC not in the spec,
- a `tasks` file that fails to cover a `must`-priority AC,
- a `change_set` whose `task_ref` doesn't exist or whose `spec_criterion_refs`
  diverge from the task's,
- any change_set that modifies files outside its task's `scope_paths`.

---

## Configuration

### `runner/runner.config.json`
```json
{
  "auto_push": false,
  "commit_message_prefix": "auto: agent update",
  "watch_paths": ["specs", "src", "docs", "constitution.md"],
  "spec_driven": {
    "block_on_validation_failure": true,
    "block_on_hitl_pending": true,
    "require_locked_spec_for_src_commits": true
  }
}
```

### `policies/agents.config.json`
- `spec_driven.mode` — `auto_with_hitl_stops` (default), `manual`, `autonomous`
- `agents.security.enabled` / `agents.release.enabled` — toggle optional agents
- `ownership` — explicit path globs per agent (enforced by validator)

### `policies/quality-gates.json`
- `min_coverage_delta`, `block_on_high_vuln`, `license_allowlist`
- `spec_driven.*` — toggle the SDD gates individually
- `hitl_required[]` — list of stops that require human approval

---

## CI

`.github/workflows/ci.yml` mirrors `runner/validate.sh`. On every push and PR:
- root schemas parse cleanly,
- every feature's spec / plan / tasks / change_sets validate against schema,
- traceability chain is intact,
- no pending HITL request blocks merge.

---

## Design philosophy

1. **Spec first.** Code without a locked spec is rejected.
2. **Traceability always.** Every line of generated code traces back to an AC.
3. **Human at the gates.** Three HITL stops are non-negotiable.
4. **Safety by policy.** Constitution + quality gates are binding.
5. **Learning by context.** `context-manager` distills lessons run-over-run.
6. **Reproducible.** Every run leaves an evidence record under `specs/<feature_id>/evidence/`.

---

## For Claude AI agents

- Always read `constitution.md` and the active `flows/default.flow.yaml`
  state before acting.
- Stage writes under `specs/<feature_id>/staging/`; never write directly to
  promoted paths.
- Stop and emit `hitl_request` rather than self-approving a HITL stop.
- Respect `policies/agents.config.json#ownership` — out-of-scope edits are
  rejected by the validator.

## For human developers

- Start a feature: copy `specs/000-template/`, then ask the orchestrator to drive.
- Review HITL stops by editing the relevant `## Review` section and removing
  the request file in `staging/hitl/`.
- Read the per-feature evidence trail in `specs/<feature_id>/evidence/`.

---

## License

MIT © 2025

---

> "Specs lead. Code follows. Humans gate. The lab learns."
