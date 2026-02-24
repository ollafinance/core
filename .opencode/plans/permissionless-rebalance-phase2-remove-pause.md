# Phase 2: Remove Rebalance Pause & Make State Machine Resilient

## Scope

Remove the rebalance pause mechanism entirely. User operations (deposit, redeem, requestRedeem) are no longer blocked during rebalance. Admin parameter changes are blocked during rebalance via a new `whenRebalanceDone` modifier. Make the state machine resilient to concurrent user operations by recomputing `stakeRemaining`/`unstakeRemaining` from current state.

## Prerequisites

Phase 1 must be complete (PullUnstaked double-counting fixed — this was the reason the pause existed).

## Implementation Steps

### 1. Remove pause state variables

File: `contracts/src/core/OllaCore.sol`

Remove:
- `bool private _rebalancePaused`
- `RebalancePauseReason private _rebalancePauseReason`
- `uint256 private _rebalanceRequiredBufferSnapshot`
- `uint256 private _rebalancePauseStartTimestamp`

### 2. Remove `whenNotRebalancePaused` modifier

File: `contracts/src/core/OllaCore.sol` (line ~145)

Delete the modifier entirely. Remove it from all user functions:
- `deposit`
- `depositWithPermit`
- `requestRedeem`
- `requestRedeemWithPermit`
- `redeem`
- `redeemWithPermit`

### 3. Add `whenRebalanceDone` modifier

File: `contracts/src/core/OllaCore.sol`

```solidity
modifier whenRebalanceDone() {
    if (_rebalanceProgress.step != IOllaCore.RebalanceStep.Done) {
        revert OllaCore__RebalanceInProgress();
    }
    _;
}
```

Apply to admin functions that change parameters the state machine relies on:
- `setProtocolFeeBP`
- `setTreasuryFeeSplitBP`
- `proposeGovernance`
- `acceptGovernance`
- `cancelGovernanceProposal`
- `setSafetyModule`
- `setTargetBufferedAssets`
- `setRebalanceGasThreshold`
- `setInstantRedemptionFeeBP`
- `reconcileBufferedAssets`
- `recoverStAztec`

### 4. Remove pause logic from `rebalance()` entry

File: `contracts/src/core/OllaCore.sol` (lines ~637-643)

Remove the block that sets `_rebalancePaused = true` when a new cycle starts.

### 5. Remove auto-unpause from rebalance completion

File: `contracts/src/core/OllaCore.sol` (lines ~818-824)

Remove the unpause logic. Keep the accounting auto-update:

```solidity
if (_rebalanceCompletionSatisfied(progressSnapshot)) {
    _updateAccountingInternal();
}
```

### 6. Rename `forceRebalanceUnpause()` to `forceRebalanceReset()`

File: `contracts/src/core/OllaCore.sol` (lines ~393-408)

Simplify to just reset the state machine to Done without any pause/unpause logic:

```solidity
function forceRebalanceReset() external override onlyRole(GUARDIAN_ROLE) {
    _rebalanceProgress.step = IOllaCore.RebalanceStep.Done;
    // Reset remaining amounts
    _rebalanceProgress.stakeRemaining = 0;
    _rebalanceProgress.unstakeRemaining = 0;
    emit RebalanceReset();
}
```

### 7. Remove pause types from interface

File: `contracts/src/core/interfaces/IOllaCore.sol`

Remove:
- `RebalancePauseReason` enum
- `RebalancePauseUpdated` event
- `forceRebalanceUnpause()` function signature

Add:
- `error OllaCore__RebalanceInProgress()`
- `event RebalanceReset()`
- `function forceRebalanceReset() external`

### 8. Make StakeSurplus step resilient

File: `contracts/src/core/OllaCore.sol` (line ~738)

Always recompute `stakeRemaining` from current state:

```solidity
if (progress.step == IOllaCore.RebalanceStep.StakeSurplus) {
    // Always recompute from current state to handle concurrent user operations
    (uint256 requiredBuffer,) = _computeRequiredBuffer();
    progress.stakeRemaining = _computeStakeRemaining(requiredBuffer);
    if (progress.stakeRemaining == 0) {
        progress.step = IOllaCore.RebalanceStep.ComputeAttesterState;
    }
    // ... rest of staking logic
}
```

### 9. Make InitiateUnstake step resilient

File: `contracts/src/core/OllaCore.sol`

Similarly recompute `unstakeRemaining`:

```solidity
if (progress.step == IOllaCore.RebalanceStep.InitiateUnstake) {
    (uint256 requiredBuffer,) = _computeRequiredBuffer();
    progress.unstakeRemaining = _computeUnstakeRemaining(requiredBuffer);
    if (progress.unstakeRemaining == 0) {
        progress.step = IOllaCore.RebalanceStep.StakeSurplus;
    }
    // ... rest of unstaking logic
}
```

### 10. Fix `_stakeSurplus` catch block

File: `contracts/src/core/OllaCore.sol` (line ~1306)

Change from `revert` to `return 0`:

```solidity
} catch {
    // Buffer may have been reduced by concurrent user operations.
    // Return 0 so the state machine can advance gracefully.
    return 0;
}
```

## Test Cases

1. User can `deposit()` during in-progress rebalance
2. User can `redeem()` during in-progress rebalance
3. User can `requestRedeem()` during in-progress rebalance
4. Admin `setProtocolFeeBP()` reverts with `OllaCore__RebalanceInProgress` during rebalance
5. Admin `setTargetBufferedAssets()` reverts during rebalance
6. `forceRebalanceReset()` resets state machine to Done
7. `forceRebalanceReset()` only callable by GUARDIAN_ROLE
8. Concurrent deposit between StakeSurplus calls: `stakeRemaining` recomputed correctly
9. Concurrent instant redemption between StakeSurplus calls: `stakeRemaining` reduced correctly
10. `_stakeSurplus` returns 0 when buffer insufficient (catch block), state machine advances

## Acceptance Criteria

- [x] No user-facing functions are blocked during rebalance
- [x] Admin parameter changes are blocked during rebalance via `whenRebalanceDone`
- [x] State machine handles concurrent bufferedAssets changes gracefully
- [x] `_stakeSurplus` catch block returns 0 instead of reverting
- [x] `forceRebalanceReset()` replaces `forceRebalanceUnpause()`

## Verification

```bash
forge build
forge test --match-contract OllaCoreRebalance -vvv
forge test --match-contract OllaCorePermissionlessRebalance -vvv
```
