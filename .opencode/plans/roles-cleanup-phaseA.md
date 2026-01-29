# Roles Cleanup 2 - Phase A (Implementation Notes)

## Phase A objective

Ship the mechanical refactor with minimal behavior change.

## Steps

1. Add `contracts/src/shared/RolesLib.sol`.

   - `bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");`
   - `bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");`
   - `bytes32 internal constant STAKING_PROVIDER_ADMIN_ROLE = keccak256("STAKING_PROVIDER_ADMIN_ROLE");`

2. Update contracts to use `RolesLib` for role ids.

   - `contracts/src/core/OllaCore.sol`
   - `contracts/src/safetymodule/SafetyModule.sol`
   - `contracts/src/staking/StakingManager.sol`
   - (any other file defining the same role ids)

3. Replace core-to-module `AccessControl` role gating with `onlyCore`.

   - `contracts/src/core/RewardsVault.sol`: replace `onlyRole(CORE_ROLE)` with `onlyCore`
   - `contracts/src/core/WithdrawalQueue.sol`: replace `onlyRole(CORE_ROLE)` with `onlyCore`
   - `contracts/src/staking/StakingManager.sol`: replace `onlyRole(CORE_ROLE)` with `onlyCore` on core-only entrypoints
   - Keep provider admin access control unchanged.

4. Keep `DEFAULT_ADMIN_ROLE`-based upgrade authorization unchanged.

## Acceptance checks

- Grep: no more duplicated `"GUARDIAN_ROLE"`, `"OPERATOR_ROLE"`, etc.
- Grep: `onlyRole(CORE_ROLE)` removed from modules that already have a `core` address.
- Unit/integration tests still pass.
