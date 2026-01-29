# Role Cleanup 1 (Refactor Plan)

## Goal
Make role usage consistent and easy to reason about by:
- having a single compile-time source of truth for role ids
- removing `CORE_ROLE`-based AccessControl for purely inter-module calls (replace with `onlyCore`)

## In scope
- Add `RolesLib.sol` containing shared role identifiers:
  - `GUARDIAN_ROLE`
  - `OPERATOR_ROLE`
  - `STAKING_PROVIDER_ADMIN_ROLE`
  - (temporary) `CORE_ROLE` only if still needed by any module
- Update modules to import and use shared role ids instead of redefining `keccak256("...")` constants.
- Replace `onlyRole(CORE_ROLE)` in satellite modules with a direct core caller check:
  - `RewardsVault`
  - `WithdrawalQueue`
  - `StakingManager` (for core-only entrypoints)
  - optionally `SafetyModule` if we decide to store a `core` address instead of using AccessControl for `CORE_ROLE`
- Update docs diagram to reflect the new access pattern (`onlyCore`).

## Out of scope (for now)
- Governance/operator/guardian rotation workflows.
- Any changes to what addresses are initially assigned roles.

## Success criteria
- No duplicated `keccak256("...ROLE")` strings across contracts.
- All core-to-module calls are gated by `msg.sender == core` (where applicable).
- Role gating remains only for human/admin actions (guardian/operator/provider admin/default admin).

## Risks / gotchas
- Upgradable modules: ensure storage layout is not broken (add new vars only if needed).
- If `core` address can be updated in the future, make sure `onlyCore` tracks that change (or document it as immutable).
- Tests/deploy scripts may assume `CORE_ROLE` is grantable; update them accordingly.
