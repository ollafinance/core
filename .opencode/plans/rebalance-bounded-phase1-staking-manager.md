# Phase 1: StakingManager Bounded Loops

**Issue**: #181 - improvement: bound rebalance work and enforce gas coordination

## Scope

- Convert stake loop to bounded work per call.
- Convert unstake loop to bounded work per call.
- Persist progress/cursors so subsequent calls continue where previous ended.
- Ensure every while loop involved in staking/unstaking is explicitly bounded.

## Prerequisites

- None.

## Implementation Steps

1. Add bounded-work configuration and progress storage.
   - Update `contracts/src/staking/StakingManager.sol` storage layout to include:
     - `uint256 private _unstakeCursor;`
     - `uint256 private _finalizeCursor;`
     - `uint256 private gasThreshold;` (set by OllaCore)

1a. Enumerate while loops to bound.
   - `cleanActivatedAttesters()`
   - `_initiateUnstakeRequests()`
   - `_finalizePendingUnstakes()`
   - Any newly introduced while loops added for bounded work.

2. Bound staking work by a shared gas threshold.
   - Update `_stakeAttesters` to stop when `gasleft()` is below `gasThreshold` and return how many attesters were staked.
   - Adjust `_stake` to compute `actualStakeAmount` from the bounded count and only approve/transfer that amount.
   - Ensure `stake` returns the bounded `stakedAmount` without reverting due to low gas when progress is possible.

3. Bound unstake initiation with cursor state.
   - Modify `_initiateUnstakeRequests` to start from `_unstakeCursor` and stop when:
     - requested amount has been reached, or
     - `gasleft()` < `gasThreshold`.
   - Persist `_unstakeCursor` when exiting early so the next call continues from the same point.
   - Return `initiatedAmount` so OllaCore can track remaining work.

4. Bound pending unstake finalization.
   - Update `_finalizePendingUnstakes` to use `_finalizeCursor` and `gasThreshold`.
   - Persist cursor and only finalize as many exits as allowed by remaining gas.

4a. Bound activated-attester cleanup.
   - Apply `gasThreshold` to `cleanActivatedAttesters()` and persist cursor if needed.

5. Update external interfaces and mocks.
   - Update `contracts/src/staking/interfaces/IStakingManager.sol` to surface bounded results, for example:
     - `function stake(uint256 amount) external returns (uint256 stakedAmount);` (already returns)
     - `function unstake(uint256 amount) external returns (uint256 initiated);`
     - `function getUnstakeCursor() external view returns (uint256 cursor);`
   - Update `contracts/src/staking/mocks/MockStakingManager.sol` and `contracts/test/mocks/MockAccountingStakingManager.sol` to match the new signatures and progress reporting.

## Test Cases from Issue

- [ ] Stake is now bounded work and completes as much staking actions as it is allowed to with the gas it has
- [ ] Unstake is now bounded work and completes as much unstaking actions as it is allowed with the gas it has
- [ ] Rebalance keeps track of it's gas usage and ensure that functions have enough funds

## Acceptance Criteria

- [ ] Stake work is bounded and always makes progress when possible.
- [ ] Unstake work is bounded and always makes progress when possible.

## Verification

```bash
forge test --match-contract StakingManagerTest -vvv
forge test --match-contract StakingManagerInvariantTest -vvv
```
