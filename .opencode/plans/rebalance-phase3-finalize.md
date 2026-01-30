# Phase 3: Rebalance Finalize Withdrawals Step

**Issue**: #66 - feat: Rebalance finalize withdrawals step

## Scope

Implement finalization of pending withdrawals using available liquidity:
- Compute `availableForWithdrawals = bufferedAssets + safetyBuffer` (safetyBuffer = 0 in V1)
- Call `WithdrawalQueue.finalizeWithdrawals(availableForWithdrawals)`
- Update `bufferedAssets` by the amount used
- Track the amount returned for the summary event

## Prerequisites

- Phase 2 (Pull Unstaked) must be complete
- `WithdrawalQueue.finalizeWithdrawals()` must be implemented
- `WithdrawalQueue.previewFinalizeWithdrawals()` should return expected usage
- SafetyModule queue ratio checks must be working

## Implementation Steps

### Step 1: Implement `_finalizeWithdrawals()` internal function in OllaCore.sol

```solidity
/// @notice Finalizes pending withdrawal requests using available liquidity.
/// @return finalizedAmount The amount of assets used to finalize withdrawals.
function _finalizeWithdrawals() internal returns (uint256 finalizedAmount) {
    // Sync buffered assets with actual balance before finalization
    _syncBufferedWithBalance();
    
    uint256 bufferedAssets = _accountingState.bufferedAssets;
    
    // In V1, safetyBuffer is 0. In future versions, this could be configurable
    uint256 safetyBuffer = 0;
    uint256 availableForWithdrawals = bufferedAssets + safetyBuffer;
    
    if (availableForWithdrawals == 0) {
        return 0;
    }
    
    // Get pending queue amount for safety check
    uint256 queued = _modules.withdrawalQueue.totalPendingAssets();
    uint256 total = totalAssets();
    
    // Check queue ratio via SafetyModule
    ISafetyModule(_modules.safetyModule).checkQueueRatio(queued, total);
    
    // Preview how much will be used
    uint256 previewUsed = _modules.withdrawalQueue.previewFinalizeWithdrawals(availableForWithdrawals);
    if (previewUsed == 0) {
        return 0;
    }
    
    // Ensure we have enough buffered assets
    if (previewUsed > bufferedAssets) {
        revert OllaCore__InsufficientBucketBalance(
            Bucket.Buffered, 
            previewUsed, 
            bufferedAssets
        );
    }
    
    // Perform finalization
    finalizedAmount = _modules.withdrawalQueue.finalizeWithdrawals(availableForWithdrawals);
    
    // Verify actual matches preview
    if (finalizedAmount != previewUsed) {
        revert OllaCore__FinalizeAmountMismatch(previewUsed, finalizedAmount);
    }
    
    // Update accounting: reduce buffered assets by amount used
    _accountingState.bufferedAssets = bufferedAssets - finalizedAmount;
    
    emit WithdrawalFinalized(availableForWithdrawals, finalizedAmount);
    
    return finalizedAmount;
}
```

### Step 2: Update `rebalance()` function

Update the rebalance function to include the finalization step:

```solidity
/// @notice Operator-triggered rebalance flow.
/// @dev Executes: harvest -> pull unstaked -> finalize withdrawals -> stake surplus
function rebalance() 
    external 
    override 
    onlyRole(OPERATOR_ROLE) 
    whenNotPaused 
    nonReentrant 
{
    // Step 1: Harvest rewards
    uint256 harvestedAmount = _harvestRewards();
    
    // Step 2: Pull unstaked funds  
    uint256 unstakedAmount = _pullUnstakedFunds();
    
    // Step 3: Finalize withdrawals (uses available liquidity)
    uint256 finalizedAmount = _finalizeWithdrawals();
    
    // TODO: Phase 4 - Stake surplus
    uint256 stakedAmount = 0;
    
    emit Rebalanced(
        harvestedAmount,
        finalizedAmount,
        stakedAmount, 
        _accountingState.bufferedAssets
    );
}
```

### Step 3: Update `finalizeWithdrawals()` external function

The existing external `finalizeWithdrawals(uint256 available)` function should be reviewed. With the new flow, finalization is primarily called internally during `rebalance()`. Consider:

1. Keep the external function for flexibility
2. Have it call the internal `_finalizeWithdrawals()` with custom available amount
3. Or deprecate if rebalance is the only path

For now, keep both but ensure consistency:

```solidity
/// @notice Operator-triggered withdrawal finalization hook with custom available amount.
/// @param available The available assets for withdrawals.
/// @return used The assets used for finalization.
function finalizeWithdrawals(uint256 available)
    external
    override
    onlyRole(OPERATOR_ROLE)
    whenNotPaused
    nonReentrant
    returns (uint256 used)
{
    _syncBufferedWithBalance();
    
    uint256 bufferedAssets = _accountingState.bufferedAssets;
    
    // Safety check via SafetyModule
    ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
    uint256 queued = _modules.withdrawalQueue.totalPendingAssets();
    uint256 total = totalAssets();
    safetyModuleRef.checkQueueRatio(queued, total);
    
    // Validate available doesn't exceed buffer
    if (available > bufferedAssets) {
        revert OllaCore__InsufficientBucketBalance(Bucket.Buffered, available, bufferedAssets);
    }
    
    used = _modules.withdrawalQueue.previewFinalizeWithdrawals(available);
    _accountingState.bufferedAssets = bufferedAssets - used;
    
    uint256 finalized = _modules.withdrawalQueue.finalizeWithdrawals(available);
    if (finalized != used) {
        revert OllaCore__FinalizeAmountMismatch(used, finalized);
    }
    
    emit WithdrawalFinalized(available, used);
    return used;
}
```

## Test Cases from Issue

- [ ] **Finalization consumes buffer before staking**
  - Setup: bufferedAssets = 10 ETH, pending withdrawals = 6 ETH
  - Call rebalance
  - Verify `bufferedAssets` becomes 4 ETH (10 - 6)
  - Verify withdrawals are finalized via queue

- [ ] **Amount used returned and tracked**
  - Verify `finalizeWithdrawals()` returns correct amount used
  - Verify `Rebalanced` event includes the finalized amount
  - Verify `WithdrawalFinalized` event is emitted

## Acceptance Criteria

- [ ] Finalization is FIFO and uses only available liquidity
- [ ] `bufferedAssets` is reduced by the amount used
- [ ] `WithdrawalFinalized` event emitted with available and used amounts
- [ ] Queue ratio safety check performed
- [ ] Preview and actual amounts match (or revert)
- [ ] Finalization occurs before staking step

## Code Changes Summary

| File | Change |
|------|--------|
| `OllaCore.sol` | Add `_finalizeWithdrawals()` internal function; update `rebalance()` to call it |

## Test Implementation

```solidity
// contracts/test/core/OllaCoreRebalance.t.sol

function test_Rebalance_FinalizeWithdrawals() public {
    // Setup: Create pending withdrawal
    uint256 depositAmount = 10 ether;
    uint256 withdrawalShares = 5 ether; // User wants to withdraw half
    
    // User deposits
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    // User requests withdrawal
    vm.prank(user);
    ollaCore.requestRedeem(withdrawalShares, user);
    
    // Mock harvest and pull unstaked to return 0
    _mockZeroHarvest();
    _mockZeroUnstaked();
    
    uint256 bufferBefore = ollaCore.accountingState().bufferedAssets;
    uint256 expectedAssets = ollaCore.convertToAssets(withdrawalShares);
    
    // Expect WithdrawalQueue.finalizeWithdrawals to be called
    vm.expectCall(
        address(withdrawalQueue),
        abi.encodeWithSelector(
            IWithdrawalQueue.finalizeWithdrawals.selector,
            bufferBefore // available = bufferedAssets
        )
    );
    
    vm.prank(operator);
    vm.expectEmit(true, true, true, true);
    emit WithdrawalFinalized(bufferBefore, expectedAssets);
    ollaCore.rebalance();
    
    // Verify buffer reduced by finalized amount
    assertEq(
        ollaCore.accountingState().bufferedAssets,
        bufferBefore - expectedAssets
    );
}

function test_Rebalance_FinalizeWithdrawals_QueueDrains() public {
    // Setup: More liquidity than pending withdrawals
    uint256 depositAmount = 20 ether;
    uint256 withdrawalAmount = 5 ether;
    
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    // Request withdrawal
    uint256 withdrawalShares = ollaCore.convertToShares(withdrawalAmount);
    vm.prank(user);
    ollaCore.requestRedeem(withdrawalShares, user);
    
    _mockZeroHarvest();
    _mockZeroUnstaked();
    
    vm.prank(operator);
    ollaCore.rebalance();
    
    // Verify queue is now empty
    assertEq(withdrawalQueue.totalPendingAssets(), 0);
}

function _mockZeroHarvest() internal {
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.harvestRewards.selector),
        abi.encode(0)
    );
    vm.mockCall(
        address(rewardsVault),
        abi.encodeWithSelector(IRewardsVault.recordRewards.selector),
        abi.encode(0)
    );
}

function _mockZeroUnstaked() internal {
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.getUnstakedFunds.selector),
        abi.encode(0)
    );
}
```

## Verification

```bash
forge test --match-test test_Rebalance_Finalize -vvv
```

## FIFO Verification

The WithdrawalQueue ensures FIFO ordering. Tests should verify:

```solidity
// Test FIFO ordering
function test_Rebalance_FinalizeWithdrawals_FIFO() public {
    // Create multiple withdrawal requests from different users
    // Ensure they are finalized in order of request
    // Verify requestId ordering matches finalization order
}
```

## Dependencies for Next Phase

- This phase must be complete before Phase 4 (Stake Surplus)
- The remaining `bufferedAssets` after finalization determines how much can be staked
