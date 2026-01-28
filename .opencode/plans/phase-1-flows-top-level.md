# Phase 1 — Update `flows.md` Top-Level Diagram (End-State)

Scope
- Update only the "Top-level diagram" mermaid in `research/technical/architecture/flows.md`.

Edits
- Actors/roles:
  - Show `DEFAULT_ADMIN_ROLE` (governance/admin), `GUARDIAN_ROLE`, `OPERATOR_ROLE`, `STAKING_PROVIDER_ADMIN_ROLE`, and how they map to multisigs/wallets.
- Components:
  - Include `SafetyModule`, `AztecRollupRegistry`, `AztecRollup` (canonical rollup), and the on-chain modules: `OllaCore`, `StAztec`, `RewardsVault`, `StakingManager`, `WithdrawalQueue`.
- End-state flows to represent:
  - Deposit -> mint shares
  - Withdrawal request -> burn shares -> enqueue
  - Operator cycle: harvest -> move rewards to core (if design requires) -> finalize withdrawals -> stake/unstake -> update accounting + fee minting
  - Claim flow: user claims finalized request (assets transferred from core)

Acceptance
- Diagram renders (mermaid) without errors.
- Edges match the end-state semantics and name the concrete functions.
- Roles shown on control-plane edges; asset-flow edges labeled with token.
