# Phase 3 — Update Interfaces and Roles Doc

Scope
- Update `research/technical/architecture/interfaces-and-roles.md`.

Edits
- Make the function tables match the intended end-state interfaces:
  - `IOllaCore`, `IStakingManager`, `IWithdrawalQueue`, `IRewardsVault`, `ISafetyModule`, `IStAztec`.
- Update the roles/permissions matrix:
  - Explicitly list role holders (governance, guardian multisig, operator wallet, provider admin, core).
  - Document `StAztec` auth model for end-state (and note current `immutable OLLA_CORE` if different).

Acceptance
- No functions listed that don’t exist in the end-state design.
- Role matrix matches the diagram + contracts naming.
