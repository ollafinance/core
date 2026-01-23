# Phase 3: Reentrancy Safety

## Goal

Ensure all external-call paths are reentrancy-safe and tested with malicious contracts.

## Work Items

- Produce a reentrancy matrix for:
  - `stake`, `unstake`, `cleanActivatedAttesters`, `getUnstakedFunds`, `harvestRewards`
- Add malicious mocks:
  - RewardsVault reentering during `postReceiveFundsHook`
  - Rollup reentering during `deposit/initiateWithdraw/finalizeWithdraw/claimSequencerRewards`

## Reentrancy Matrix

| Entry point | nonReentrant | External calls | Primary reentrancy concern |
| --- | --- | --- | --- |
| `stake(uint256)` | yes | `stakingAsset.safeTransferFrom(core, this, ...)`, `rollup.deposit(...)` | Rollup could call back into any CORE_ROLE-gated entrypoint while mid-stake |
| `unstake(uint256)` | yes | `rollup.getAttesterView(...)`, `rollup.initiateWithdraw(...)` | External call occurs before internal bookkeeping moves attester to pending |
| `cleanActivatedAttesters()` | yes | `rollupRegistry.getCanonicalRollup()`, `rollup.getAttesterView(...)` | Only view/static external calls; still guarded to prevent cross-function reentrancy |
| `getUnstakedFunds()` | yes | `rollup.getAttesterView(...)`, `rollup.finalizeWithdraw(...)`, `stakingAsset.safeTransfer(core, ...)` | Rollup could call back during finalization before claim bookkeeping completes |
| `harvestRewards()` | yes | `rollup.claimSequencerRewards(rewardsVault)`, `rewardsVault.postReceiveFundsHook(...)` | RewardsVault hook could attempt to reenter and trigger nested reward claims |

## Implementation Notes

- All CORE_ROLE entrypoints above are protected by a single OpenZeppelin `nonReentrant` guard.
- Phase 3 adds malicious mocks + tests that attempt reentrancy and must revert with `ReentrancyGuardReentrantCall()`.

## Tests

- Each malicious reentrancy attempt must revert due to `nonReentrant`.
