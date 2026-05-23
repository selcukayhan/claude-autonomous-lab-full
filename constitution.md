# Constitution — Claude Autonomous Lab

This is the **immutable foundation** for all spec-driven work in this repository.
Every feature spec, plan, task, and change set is governed by these principles.
Changes here require an explicit HITL approval and a recorded amendment.

> Version: 1.0.0
> Last amended: 2026-05-24
> Amendment policy: see `policies/quality-gates.json#constitution_amendment`

---

## I. Spec-First Principle
No code is written before a `spec.md` is **locked**.
No task is scheduled before a `plan.md` is **locked**.
No change set is merged before its `task_ref` is **closed** and every modified
file traces back to a `spec_criterion_ref` in the active spec.

## II. Traceability Principle
Every artifact carries an explicit upstream reference:
- `plan.md` → `spec_ref`
- `tasks.json` → `plan_ref` + per-task `spec_criterion_refs[]`
- `change_set.json` → `task_ref` + `spec_criterion_refs[]`
- `test_plan.json` → `task_refs[]`

Validation tools refuse artifacts that break the chain.

## III. Human-in-the-Loop Stops
Auto-execution pauses for human review at exactly these gates:
1. **spec_lock_review** — after `requirements`, before `architecture`.
2. **plan_lock_review** — after `planning`, before `coding`.
3. **pre_merge_review** — after `test`, before promotion to `main`.
4. **constitution_amendment** — any edit to this file.
5. **public_api_change_post_lock** — any change to `contracts/interfaces.yaml`
   after `plan_lock_review` passed.

Agents must **stop and emit a `hitl_request`** rather than proceed past a gate.

## IV. Artifact Discipline
- All agent writes land in `specs/<feature_id>/staging/` first.
- The orchestrator promotes to `specs/<feature_id>/` only after schema validation
  AND traceability validation pass.
- JSON must validate against the matching schema in `artifacts/schemas/`.
- YAML contracts must validate against the templates in `contracts/`.
- No chain-of-thought in artifacts. Summarize reasoning, cite evidence.

## V. Ownership Principle
- **FE** edits `src/frontend/**` only.
- **BE** edits `src/backend/**` only.
- **DevOps** edits `runner/**`, `.github/**`, infra paths only.
- **Docs** edits `README.md`, `docs/**`, and per-feature `spec.md`/`plan.md`.
- Cross-boundary edits require an explicit `team_plan.json` entry plus
  reconciliation by the `architecture` agent.

## VI. Scope Discipline
- A feature spec may not silently grow new acceptance criteria post-lock.
  If new criteria are needed, the spec must be re-opened, re-reviewed, and
  re-locked, with the version bumped (`major` for breaking, `minor` otherwise).
- Tasks may not bypass their plan. New tasks require a plan amendment.
- Change sets that touch files outside their `task_ref`'s declared scope are rejected.

## VII. Quality Gates (binding)
- `min_coverage_delta` and `critical_tests_pass` from `policies/quality-gates.json`
  are binding. Failing gates block promotion.
- HIGH-severity vulnerabilities block merge unless an explicit HITL waiver is
  recorded in `specs/<feature_id>/evidence/waivers.json`.
- License allowlist is binding (`policies/quality-gates.json#license_allowlist`).

## VIII. Learning Loop
- The `context-manager` summarizes each run into `runs/learned_patterns.json`
  and `runs/benefit_report.json`.
- The `experiment` agent may propose non-destructive variants only.
- The `policy` agent approves/rejects promotion of experiments per
  `policies/context-governance.json#allow_auto_promotion`.

## IX. Reproducibility
- Every run produces a `specs/<feature_id>/evidence/run_<timestamp>.json` record.
- The runner is deterministic given the same inputs and the same locked artifacts.
- No agent may rely on hidden state outside the repository.

## X. Amendment Procedure
To amend this constitution:
1. Open a `specs/<id>-constitution-amendment/` directory.
2. Write the amendment as a normal spec with full HITL flow.
3. On `pre_merge_review` approval, bump the version above and update
   `Last amended`.
4. Constitution amendments are the only artifact that may modify this file.
