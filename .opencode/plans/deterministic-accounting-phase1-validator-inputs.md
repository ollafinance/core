# Phase 1: Validator State Read and Accounting Inputs

**Issue**: #59 - feat: Validator state read + accounting inputs

## Scope

- Read validator deltas from Aztec rollup (`rewardsDelta`, `slashingDelta`).
- Emit validator state event with deltas and timestamp.
- Assemble accounting inputs: `bufferedAssets`, `StakingManager.totalStaked()`, `RewardsVault.balance()` (or `getAvailableFunds()`).

## Prerequisites

- Add StakingManager view(s) that compute validator deltas by reading rollup validator state.

## Implementation Steps

1. **Extend Aztec rollup interface**
   - Add a minimal method in `contracts/src/staking/interfaces/IAztecRollup.sol` matching the deployed rollup:

```solidity
function getValidatorState() external view returns (uint256 rewardsDelta, uint256 slashingDelta);
```

2. **Provide validator deltas via StakingManager**
   - Use `IStakingManager.getClaimableRewards()` for current rewards.
   - OllaCore computes `rewardsDelta = currentRewards - lastReportRewards` using its stored report snapshot.
   - Add a StakingManager view that reads rollup validator state for `slashingDelta`.

3. **Read and validate deltas**
   - In `OllaCore.updateAccounting()`, query current rewards and slashing delta.
   - Revert on invalid slashing delta (e.g., decreasing vs last snapshot), to avoid masking rollup inconsistencies.

4. **Assemble accounting inputs**
   - Read `stakingManager.totalStaked()`.
   - Read `rewardsVault.balance()` or `getAvailableFunds()` depending on the vault interface used.
   - Update `_accountingState` buckets with these on-chain values prior to total assets calculation.

5. **Emit validator state event**
   - Emit `AttestersStateRead(rewardsDelta, slashingDelta, timestamp)`.

## Test Cases from Issue

- [ ] Validator state read and event emitted.
- [ ] Negative slashing deltas are clamped or rejected.

## Acceptance Criteria

- [ ] Accounting inputs match the totalAssets formula listed in the milestone scope.

## Verification

```bash
forge test --match-path "contracts/test/core/OllaCore.t.sol"
forge test --match-path "contracts/test/integration/AztecInterfaceCompatibility.integration.t.sol"
```
