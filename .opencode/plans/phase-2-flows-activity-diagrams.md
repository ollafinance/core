# Phase 2 — Update `flows.md` Activity Diagrams (End-State)

Scope
- Update sequence diagrams under "Activity diagrams" in `research/technical/architecture/flows.md`.

Edits
- Deposit: include SafetyModule deposit cap checks and mint path.
- Withdrawal request + claim: reflect async queue finalization and claim via core.
- Rebalance/operator flows:
  - Split into the end-state operator actions (even if the implementation is currently split/stubbed): harvest rewards, withdraw rewards to core, finalize withdrawals, stake, unstake, clean activated attesters, claim unstaked funds.
  - Show which functions are `OPERATOR_ROLE` vs `CORE_ROLE`.

Acceptance
- All mermaid sequence diagrams render.
- Function names and participants consistent with the top-level diagram.
