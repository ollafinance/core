# Phase 3: Reentrancy Safety

## Goal

Ensure all external-call paths are reentrancy-safe and tested with malicious contracts.

## Work Items

- Produce a reentrancy matrix for:
  - `stake`, `unstake`, `cleanActivatedAttesters`, `getUnstakedFunds`, `harvestRewards`
- Add malicious mocks:
  - RewardsVault reentering during `postReceiveFundsHook`
  - Rollup reentering during `deposit/initiateWithdraw/finalizeWithdraw/claimSequencerRewards`

## Tests

- Each malicious reentrancy attempt must revert due to `nonReentrant`.
