# Claude Autonomous Lab — Spec-Driven Edition

A **language-agnostic, Claude-native, spec-driven, multi-agent development framework** that runs locally in Claude Code.

Every feature starts as a spec, locks at human review, decomposes into a plan and executable tasks, fans out to **real parallel subagents** for coding, and only merges after a third human gate. The framework's own learning is captured in versioned artifacts so the next session resumes with full context.

```
constitution → spec (locked) → plan (locked) → tasks → coding → test → release
       │            │              │             │         │        │
       │            └─ HITL ──────┘             └─── HITL ─────────┘
       └─ amendment HITL                                 │
                                                        on merge
```

---

## Three architectural pillars

### 1. Spec-driven traceability
No code without a `status: locked` spec. Every change traces upward:
`change_set → task → plan → spec → constitution`.
Validator + CI reject any artifact that breaks the chain.

### 2. Real parallel multi-agent execution
17 role-specific subagents live in `.claude/agents/` (Claude Code subagent registry). The orchestrator spawns them via the `Agent` tool — they run in **their own context windows** with **scoped tool grants** and **no memory of the orchestrator's chat**. Tasks fan out by `owner` and `depends_on` DAG.

### 3. Cross-session persistence
The framework remembers: `runs/learned_patterns.json` (cross-feature lessons), `runs/benefit_report.json` (run metrics), `runs/telemetry.jsonl` (per-task execution telemetry — agent, model, duration, tokens, tool uses), and per-feature `feature_summary.md` (canonical "you are here" doc). A fresh Claude session orients in seconds by reading these.

### 4. Live task lifecycle + telemetry
Coding agents call `runner/task-update.sh <feature_id> <task_id> {in_progress|completed|blocked}` instead of editing `tasks.json` directly. The helper holds an `mkdir`-based lock (so parallel agents don't race), pushes only the one drifted card to Trello (not a full re-sync), and — when the orchestrator stamps `--telemetry-json` after each subagent return — merges telemetry into the change_set, appends a line to `runs/telemetry.jsonl`, and posts a completion comment on the Trello card. The telemetry log is the data source for future planning calibration in the context-manager.

---

## Quick start

### 1. Install dependencies
```bash
brew install fswatch jq                          # required
npm install -g ajv-cli@5                         # optional: full JSON Schema validation
```

### 2. Open the repo in Claude Code (or Claude Desktop)
Make sure the working directory is this repo. CLAUDE.md auto-loads with a "Resuming work" section that orients the session.

### 3. (Optional) Configure Trello
```bash
cp runner/trello.config.local.json.example runner/trello.config.local.json
# Edit with your API key + token from https://trello.com/power-ups/admin
bash runner/trello-sync.sh <feature_id> --ping   # verify
```
The file is gitignored. See [Trello integration](#trello-integration) below.

### 4. Start the file watcher
```bash
bash runner/runner.sh        # macOS / Linux
.\runner\runner.ps1          # Windows
```
The runner watches `specs/`, `src/`, `docs/`, `constitution.md`. On every change it runs `runner/validate.sh` and commits when (a) all schema + traceability checks pass and (b) no HITL request is pending.

### 5. Kick off a feature
In Claude, say:

> "Use the orchestrator to start a new feature: a small calculator web app."

The orchestrator allocates `specs/001-calculator/`, drives requirements → architecture → planning → tasks, **pauses at `spec_lock_review`** for your sign-off, continues to coding (spawning subagents in parallel), pauses again at `plan_lock_review` and `pre_merge_review`.

---

## HITL stops

| Stop                          | Fires after          | You approve |
|-------------------------------|----------------------|-------------|
| `spec_lock_review`            | requirements         | `spec.md` / `spec.json` |
| `plan_lock_review`            | planning + tasks     | `plan.md` / `plan.json` / `tasks.json` |
| `pre_merge_review`            | test                 | the full evidence bundle |
| `constitution_amendment`      | edit to `constitution.md` | the amendment spec |
| `public_api_change_post_lock` | edit to a locked `interfaces.yaml` | the API change |

Approve by editing the `## Review` section of the relevant markdown file (or `lock_record` in the JSON) and removing the request file under `specs/<feature_id>/staging/hitl/`. The runner unblocks on the next file change.

---

## Subagents and parallel multi-agent work

**17 subagent definitions live in `.claude/agents/`** (one per role). The orchestrator spawns them via the `Agent` tool:

```
Agent(subagent_type='coding-fe', prompt='Execute task T001 for feature 001-pet-health-app...')
```

Each subagent:
- Has its own system prompt (the body of its `.md` file).
- Has a scoped tool grant (e.g., `coding-fe` gets `Read, Write, Edit, Bash, Grep, Glob` — no `Agent`, so no recursion).
- Runs in its **own context window** — does not see the orchestrator's chat.
- Reads `specs/<feature_id>/evidence/feature_summary.md` and `runs/learned_patterns.json` first for context.
- Reads its task by ID from `tasks.json`, implements only inside `task.scope_paths`, writes a `change_set.json` to `specs/<feature_id>/evidence/change_sets/<task_id>.json`, marks the task `status: "completed"`, returns a short summary.

### Parallel fan-out
Tasks with no overlapping `scope_paths` and satisfied `depends_on` can run in parallel. The orchestrator emits multiple `Agent` calls in a single message. Wall time ≈ slowest task; cost ≈ sum of tasks.

### Subagent registry caveat
Claude Code only loads `.claude/agents/*.md` **at session start**. New agent files require a session restart to be invokable by name. Workaround: spawn `general-purpose` with the role definition inlined in the prompt — same observable behavior.

### The 17 roles
`orchestrator` · `requirements` · `uiux-researcher` · `architecture` · `uiux-designer` · `planning` · `coding-fe` · `coding-be` · `coding-devops` · `test` · `policy` · `security` · `release` · `docs` · `context-manager` · `bootstrap` · `experiment`

Original docs at `agents/<name>.md`; runnable subagents at `.claude/agents/<name>.md`. Coding/architecture/planning use Opus; docs/bootstrap/context-manager use Haiku (cost-tiered).

---

## Repo layout

```
claude-autonomous-lab/
├── constitution.md                   # IMMUTABLE principles — amendment requires HITL
├── CLAUDE.md                         # Conventions, context tiers, ownership, resuming-work
│
├── agents/                           # Human-readable agent docs (17 roles)
├── .claude/agents/                   # Runnable Claude Code subagents (same 17 roles)
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
│   ├── agents.config.json            # global default_ownership + role enable/disable
│   └── project-shapes/               # web-fullstack / monorepo / cli / library / ml-pipeline
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
│   └── 001-pet-health-app/           # First worked example (Lean MVP RN+Node)
│       ├── state.json                # lifecycle, phase, HITL state, Trello mapping
│       ├── spec.md / spec.json       # locked v0.1.0
│       ├── plan.md / plan.json       # locked v0.1.0, 22 work items
│       ├── tasks.json                # 35 active tasks, each with trello_card_url
│       ├── contracts/
│       │   ├── system_design.yaml    # 4 components, 4 ADRs
│       │   └── interfaces.yaml       # 12 HTTP endpoints, 3 modules, 7 shapes
│       ├── evidence/
│       │   ├── feature_summary.md    # "You are here" — read first
│       │   ├── change_sets/T001.json # per-completed-task proof of work
│       │   └── ...
│       └── staging/hitl/             # gate requests when HITL pending
│
├── runner/                           # Local automation
│   ├── runner.sh / runner.ps1        # fswatch watcher + commit
│   ├── validate.sh                   # schema + traceability gate (bash 3.2 compatible)
│   ├── runner.config.json
│   ├── trello-sync.sh                # one-way push tasks.json → Trello board
│   ├── trello.config.json            # public Trello config (board topology, labels)
│   └── trello.config.local.json      # gitignored credentials
│
├── src/                              # Default source tree for web-fullstack-shaped features;
│   ├── frontend/                     #   other project_shapes use different roots
│   ├── backend/                      #   (cli → cmd/, library → lib/, monorepo → apps/+services/)
│   └── shared/                       # See policies/project-shapes/
│
├── runs/                             # Cross-feature persistence (committed)
│   ├── framework_map.json            # bootstrap agent output
│   ├── learned_patterns.json         # cross-feature lessons (strings)
│   ├── benefit_report.json           # run metrics
│   └── tmp/  cache/                  # ignored (scratch only)
│
└── .github/workflows/ci.yml          # CI mirror of runner/validate.sh
```

---

## Project shapes (build anything, not just web apps)

The framework supports any kind of software, not just two-tier web/mobile apps. Each feature picks a **project shape** when the architecture phase writes `team_plan.json`:

| Shape | When to pick | Where code lives |
|---|---|---|
| `web-fullstack` | Two-tier client/server (web, mobile, desktop) | `src/frontend/` + `src/backend/` |
| `monorepo` | Multiple apps and/or services in one repo | `apps/*/` + `services/*/` |
| `cli` | Single-binary command-line tool | `src/`, `cmd/`, `internal/`, `pkg/` |
| `library` | Publishable library / SDK | `src/`, `lib/`, `examples/` |
| `ml-pipeline` | Data / ML project with notebooks + pipelines | `pipelines/`, `notebooks/`, `models/` |

The architecture agent picks one and writes `team_plan.json#project_shape = "<name>"`. Per-feature `team_plan.json#ownership` further narrows the shape's globs (e.g. a monorepo feature scoped to `services/auth/**`).

**Resolution order** (used by `runner/validate.sh` when checking that change_sets stay in scope):

1. `specs/<feature_id>/team_plan.json#ownership[<role>]` — per-feature override
2. `policies/project-shapes/<project_shape>.json#ownership[<role>]` — shape preset
3. `policies/agents.config.json#default_ownership[<role>]` — global fallback (covers non-coding roles like `docs`, `requirements`, `planning`, etc.)

**Adding a new shape:** drop a JSON file into `policies/project-shapes/` matching `artifacts/schemas/project_shape.schema.json`. The architecture agent picks it up automatically.

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

Every downstream artifact carries refs upward. The validator (`runner/validate.sh` + CI) rejects:
- a `plan` whose `work_items` reference an AC not in the spec,
- a `tasks` file that fails to cover a `must`-priority AC,
- a `change_set` whose `task_ref` doesn't exist or whose `spec_criterion_refs` diverge from the task's,
- any change_set that modifies files outside its task's `scope_paths`.

---

## Persistence & cross-session memory

The framework is designed so a fresh Claude session — opened tomorrow, or by a teammate — can resume work without re-explanation.

| Where | What | Updated by |
|---|---|---|
| `git` on `feat/<feature_id>` | All artifacts + code | Runner auto-commits |
| `specs/<id>/state.json#history` | Chronological phase log | Orchestrator at each transition |
| `specs/<id>/evidence/feature_summary.md` | Canonical "you are here" doc | Orchestrator after each subagent return |
| `specs/<id>/spec.md#Decisions` | Per-feature decisions with CQ traceability | Requirements agent on lock |
| `specs/<id>/plan.md` ADRs + risks | Architectural decisions | Architecture + planning agents |
| `runs/learned_patterns.json` | Cross-feature lessons (strings) | Context-manager + orchestrator |
| `runs/benefit_report.json` | Aggregate metrics across runs | Context-manager |
| `runs/telemetry.jsonl` | Per-task execution telemetry (agent, model, duration, tokens) | `runner/task-update.sh` |
| Trello board | Task status + DoD + AC refs + completion comments | `runner/task-update.sh` per-task; `runner/trello-sync.sh` for full re-syncs |
| `~/.claude/projects/.../memory/` | Auto-memory: user role, feedback, project context, references | Main Claude per conversation |

**The orientation flow on session start:**
1. `CLAUDE.md` auto-loaded → its "Resuming work" section points to the rest.
2. `~/.claude/projects/.../memory/MEMORY.md` auto-loaded → who/what/preferences.
3. `runs/learned_patterns.json` → don't re-learn old mistakes.
4. `specs/<id>/evidence/feature_summary.md` → exactly where the feature is and what's next.
5. `specs/<id>/state.json` → lifecycle + HITL state.

Agents picking up tasks read items 3–5 before doing anything else (enforced in `.claude/agents/coding-*.md`, `test.md`, `orchestrator.md`).

---

## Branching

| Branch | Holds | Pushed where |
|---|---|---|
| `master` | Framework infrastructure only | `origin/main` (on demand) |
| `feat/<feature_id>` | All feature work — specs, code, evidence, runner auto-commits | Pushed when ready |

Framework changes land on `master`; per-feature work isolates on `feat/<id>`. The runner's auto-commits flow to whichever branch is checked out.

---

## Trello integration

The framework can push tasks to Trello so humans and agents see the same board.

### Setup (once per workspace)
1. Create a Power-Up at https://trello.com/power-ups/admin and grab its **API key**.
2. On the same page, generate a personal **token** authorized for that Power-Up (key + token must come from the **same** Power-Up — mismatched pairs return misleading `invalid key` errors).
3. Copy `runner/trello.config.local.json.example` → `runner/trello.config.local.json` and paste the values. (Gitignored.)
4. Verify: `bash runner/trello-sync.sh <feature_id> --ping`.

### Usage
```bash
bash runner/trello-sync.sh <feature_id>              # full sync (creates board on first run)
bash runner/trello-sync.sh <feature_id> --dry-run    # show planned actions, no API writes
bash runner/trello-sync.sh <feature_id> --ping       # auth check only

# Per-task live updates (called by coding agents + orchestrator):
bash runner/task-update.sh <feature_id> <task_id> in_progress
bash runner/task-update.sh <feature_id> <task_id> completed
bash runner/task-update.sh <feature_id> <task_id> completed \
  --telemetry-json '{"model":"claude-opus-4-7","duration_ms":337000,"total_tokens":76982,"tool_uses":46}'
bash runner/task-update.sh <feature_id> <task_id> blocked --blocked-reason "<text>"
```

`task-update.sh` acquires an `mkdir`-based lock on `tasks.json` so parallel agents don't race their writes, pushes only the one drifted card to Trello (not all 35), and — when `--telemetry-json` is supplied — merges telemetry into the change_set, appends to `runs/telemetry.jsonl`, and posts a completion comment on the Trello card.

### Board model
- **One board per feature**, named `<feature_id>` (e.g., `001-pet-health-app`).
- **4 lists**: Pending / In Progress / Blocked / Completed.
- **6 owner labels** (color-coded): `coding-fe` (blue), `coding-be` (green), `coding-devops` (purple), `test` (yellow), `docs` (sky), `security` (red).
- **Each card**: name = `<task_id> — <task title>`. Description carries DoD bullets, scope paths, AC refs, depends_on, and a back-reference to `tasks.json#<id>`.

### Sync direction
**One-way: `tasks.json` → Trello.** Moving cards in Trello will be overwritten on the next sync. tasks.json stays canonical. The script writes `trello_card_id` + `trello_card_url` back into each task for traceability.

### Gates
The sync no-ops while `tasks.status` is `draft` or `in_review` — Trello only reflects state after `plan_lock_review` lands.

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

### `runner/trello.config.json`
Public config: list names, label color mapping, board name pattern, card description template. Secrets in `trello.config.local.json` (gitignored). `enabled: false` disables the integration.

### `policies/agents.config.json`
- `spec_driven.mode` — `auto_with_hitl_stops` (default), `manual`, `autonomous`
- `agents.security.enabled` / `agents.release.enabled` — toggle optional agents
- `ownership` — explicit path globs per agent (enforced by validator)

### `policies/quality-gates.json`
- `min_coverage_delta`, `block_on_high_vuln`, `license_allowlist`
- `spec_driven.*` — toggle SDD gates individually
- `hitl_required[]` — which stops require human approval

---

## CI

`.github/workflows/ci.yml` mirrors `runner/validate.sh`. On every push and PR:
- root schemas parse cleanly,
- every feature's `spec` / `plan` / `tasks` / `change_sets` validate against their schemas,
- traceability chain is intact (AC refs, scope_paths, task_refs),
- no pending HITL request blocks merge.

---

## Worked example: 001-pet-health-app

The first feature shipped against this framework — a React Native + Node/Fastify + Postgres pet health & lifestyle app (Lean MVP: pet profiles, vaccinations, weight, dashboard, cloud sync).

| | |
|---|---|
| Branch | `feat/001-pet-health-app` |
| Lifecycle | `in_implementation` (mid-coding) |
| Spec | locked v0.1.0 — 10 must ACs, 9 deferred to v1.1+ |
| Plan | locked v0.1.0 — 22 work items, 3 milestones, 6 risks |
| Tasks | 35 tasks active; T001 (RN scaffold via `coding-fe`) completed |
| Trello | https://trello.com/b/3LYZxETW/001-pet-health-app |
| Read first | `specs/001-pet-health-app/evidence/feature_summary.md` |

Browse `specs/001-pet-health-app/` to see what a real spec-driven feature workspace looks like in practice.

---

## Design philosophy

1. **Spec first.** Code without a locked spec is rejected.
2. **Traceability always.** Every line of generated code traces back to an AC.
3. **Real agents, not roles.** Subagents run in their own context with scoped tools — no single Claude impersonating all 17.
4. **Humans at the gates.** Three HITL stops are non-negotiable.
5. **Safety by policy.** Constitution + quality gates are binding.
6. **Learning by context.** `context-manager` distills cross-feature lessons; subagents read them before acting.
7. **Reproducible.** Every run leaves an evidence record under `specs/<feature_id>/evidence/`.
8. **Resumable.** Fresh sessions read `CLAUDE.md` → `learned_patterns.json` → `feature_summary.md` and pick up where the last one left off.

---

## For Claude AI agents

- Always read `constitution.md`, `runs/learned_patterns.json`, and `specs/<feature_id>/evidence/feature_summary.md` before acting.
- Stage writes under `specs/<feature_id>/staging/`; never write directly to promoted paths.
- Stop and emit `hitl_request` rather than self-approving a HITL stop.
- Respect `policies/agents.config.json#ownership` — out-of-scope edits are rejected by the validator.
- If you're the orchestrator: spawn subagents via the `Agent` tool. Do not impersonate roles.
- If you're a subagent: do your one task, return a 2-4 sentence summary, do not run `runner/trello-sync.sh` (the orchestrator handles that).

## For human developers

- Start a feature: ask the orchestrator. It copies `specs/000-template/` and drives.
- Review HITL stops by editing the relevant `## Review` section and removing the request file under `staging/hitl/`.
- Read the per-feature `evidence/feature_summary.md` to know what's been done and what's next.
- Watch progress on the Trello board (one per feature, if integration is configured).
- Rotate Trello / API credentials in `runner/*.local.json` as you would any local secret.

---

## License

MIT © 2025–2026

---

> "Specs lead. Subagents fan out. Humans gate. The lab learns and remembers."
