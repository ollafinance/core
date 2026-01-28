# Research Docs Update Plan

Goal: bring `research/` back in sync with the contracts in `contracts/src/`, prioritizing correctness for implementers and auditors.

Guiding rules
- Treat `contracts/src/**` as the source of truth.
- For `research/technical/architecture/flows.md`, document the intended end-state (even if some wiring is currently stubbed).
- Prefer explicit call paths and role gates over prose.
- For each phase: keep diffs small, re-render mermaid diagrams after changes.

Known deltas to reconcile (examples)
- Operator flows are not a single `rebalance()`; intended end-state should clearly sequence: harvest rewards -> withdraw rewards to core (if applicable) -> finalize withdrawals -> stake/unstake -> update accounting.
- `StAztec` is authorized via `immutable OLLA_CORE` (not role-based) today; if end-state intends roles, docs should state the planned model and the current one.
- `RewardsVault` in code uses `recordRewards()` + `withdrawToCore()`; docs currently mention hooks/treasury functionality.
- `StakingManager` uses `IAztecRollupRegistry.getCanonicalRollup()`; diagrams should include the registry.

Phase list
- Phase 1: Update top-level diagram in `research/technical/architecture/flows.md` (end-state)
- Phase 2: Update the remaining `flows.md` activity diagrams to match the end-state
- Phase 3: Update `research/technical/architecture/interfaces-and-roles.md` to match end-state APIs + access control
- Phase 4: Update component specs in `research/technical/architecture/components/*.md`
- Phase 5: Update `research/technical/architecture/invariants.md` and accounting narrative
- Phase 6: Repo-wide consistency sweep across `research/**`

Deliverables
- One short phase file per phase under `.opencode/plans/`.
- Each phase file: scope, concrete edits, acceptance checklist.
