# Phase 4: Rebalance Unstake Step

**Issue**: #159 - feat: Rebalance unstake step

## Scope

Initiate unstaking when pending withdrawals exceed buffered liquidity after finalization:
- Recompute `withdrawalRequestsAmount` from `WithdrawalQueue` after finalization (remaining pending).
- Compute `amountToUnstake = max(0, withdrawalRequestsAmount - bufferedAssets)` based on the updated pending amount.
- Call `StakingManager.unstake(amountToUnstake)` (or equivalent) to initiate rollup withdrawals.
- Ensure `amountToUnstake` accounts for `pendingUnstakes` in `StakingManager`.
- Emit an event or accounting signal for initiated unstake.

## Repo Status

- [ ] OllaCore has an internal `_initiateUnstake()` step used by `rebalance()`.
- [ ] StakingManager exposes `pendingUnstakes()` (or equivalent) for accounting.
- [ ] IOllaCore includes an event for unstake initiation (or reuse existing accounting event).
- [ ] Phase 4 tests added in `contracts/test/core/OllaCoreRebalance.t.sol`.

## Prerequisites

- Phase 3 (Finalize Withdrawals) must be complete.
- `WithdrawalQueue.totalPendingAssets()` available.
- `StakingManager.unstake(uint256)` implemented and callable.

## Implementation Steps

### Step 1: Add event for unstake initiation (if no existing accounting event)

In `IOllaCore.sol`:

```solidity
/// @notice Emitted when the core initiates unstaking to satisfy withdrawals.
/// @param requested Amount requested to unstake based on pending withdrawals.
/// @param initiated Amount actually initiated (after pendingUnstakes adjustments).
event UnstakeInitiated(uint256 requested, uint256 initiated);
```

### Step 2: Implement `_initiateUnstake()` in `OllaCore.sol`

```solidity
/// @notice Initiates unstaking when pending withdrawals exceed buffered assets.
/// @return initiated Amount actually initiated for unstake.
function _initiateUnstake() internal returns (uint256 initiated) {
    uint256 pendingWithdrawals = _modules.withdrawalQueue.totalPendingAssets();
    uint256 bufferedAssets = _accountingState.bufferedAssets;

    if (pendingWithdrawals <= bufferedAssets) {
        return 0;
    }

    uint256 amountToUnstake = pendingWithdrawals - bufferedAssets;

    // Account for pending unstakes already initiated in StakingManager
    uint256 pendingUnstakes = _modules.stakingManager.pendingUnstakes();
    if (pendingUnstakes >= amountToUnstake) {
        return 0;
    }

    initiated = amountToUnstake - pendingUnstakes;

    if (initiated > 0) {
        _modules.stakingManager.unstake(initiated);
        emit UnstakeInitiated(amountToUnstake, initiated);
    }

    return initiated;
}
```

### Step 3: Integrate into `rebalance()` order

Place the unstake step after finalization and before staking surplus:

```solidity
// Step 1: Harvest rewards
uint256 harvestedAmount = _harvestRewards();

// Step 2: Pull matured unstaked funds
uint256 unstakedAmount = _pullUnstakedFunds();

// Step 3: Finalize withdrawals
uint256 finalizedAmount = _finalizeWithdrawals();

// Step 4: Initiate unstake if needed
uint256 initiatedUnstake = _initiateUnstake();
```

## Test Cases from Issue

- [ ] **Unstake when pending exceeds buffer**
  - Setup: `bufferedAssets = 10`, `totalPendingAssets = 25`.
  - Expect `unstake(15)` called.

- [ ] **No-op when buffer covers pending**
  - Setup: `bufferedAssets = 30`, `totalPendingAssets = 25`.
  - Expect no call to `unstake`.

- [ ] **Pending unstakes reduce initiation**
  - Setup: `amountToUnstake = 20`, `pendingUnstakes = 12`.
  - Expect `unstake(8)` called.

## Acceptance Criteria

- [ ] Unstake step occurs after `finalizeWithdrawals()` and before staking.
- [ ] `amountToUnstake` computed from pending withdrawals and buffered assets.
- [ ] Pending unstakes reduce the new unstake initiation.
- [ ] Event or accounting update reflects initiated unstake.

## Code Changes Summary

| File | Change |
|------|--------|
| `contracts/src/core/OllaCore.sol` | Add `_initiateUnstake()`; update `rebalance()` order |
| `contracts/src/core/interfaces/IOllaCore.sol` | Add `UnstakeInitiated` event (if needed) |
| `contracts/src/staking/StakingManager.sol` | Ensure `pendingUnstakes()` exists and accurate |

## Verification

```bash
forge test --match-test test_Rebalance_Unstake -vvv
```

## Dependencies for Next Phase

- This phase must be complete before Phase 5 (Stake Surplus)
- Initiated unstakes settle for future rebalance pulls
