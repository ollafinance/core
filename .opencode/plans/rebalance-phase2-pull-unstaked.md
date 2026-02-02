# Phase 2: Rebalance Pull-Unstaked Step

**Issue**: #63 - feat: Rebalance pull-unstaked step

## Scope

Implement pulling of unstaked funds during rebalance:
- Call `StakingManager.getUnstakedFunds()`
- Increase `bufferedAssets` by the received amount
- Emit `UnstakedFundsClaimed` event for received funds
- Ensure proper order: called after harvest, before finalization

## Repo Status

- [x] `StakingManager.getUnstakedFunds()` implemented (`contracts/src/staking/StakingManager.sol`).
- [ ] `IOllaCore` defines `UnstakedFundsClaimed` event.
- [ ] `OllaCore` implements `_pullUnstakedFunds()` and buffered assets accounting.
- [ ] `rebalance()` integrates the pull-unstaked step.
- [ ] Phase 2 tests added in `contracts/test/core/OllaCoreRebalance.t.sol`.

## Prerequisites

- Phase 1 (Harvest) must be complete
- `StakingManager.getUnstakedFunds()` must transfer assets to OllaCore and return amount received
- `OllaCore` must have proper accounting state management

## Implementation Steps

### Step 1: Add `UnstakedFundsClaimed` event to IOllaCore.sol

```solidity
/// @notice Emitted when unstaked funds are claimed during rebalance.
/// @param amount The amount of unstaked funds received.
event UnstakedFundsClaimed(uint256 amount);
```

### Step 2: Implement `_pullUnstakedFunds()` internal function in OllaCore.sol

```solidity
/// @notice Pulls unstaked funds from the staking manager.
/// @return receivedAmount The amount of unstaked funds received.
function _pullUnstakedFunds() internal returns (uint256 receivedAmount) {
    uint256 balanceBefore = _modules.asset.balanceOf(address(this));
    
    // Call staking manager to claim matured unstakes
    // Funds are transferred directly to this contract
    receivedAmount = _modules.stakingManager.getUnstakedFunds();
    
    // Verify the balance increased by the claimed amount
    uint256 balanceAfter = _modules.asset.balanceOf(address(this));
    uint256 actualReceived = balanceAfter - balanceBefore;
    
    // If StakingManager returns a value, it should match actual transfer
    // Some implementations may return 0 and rely on balance checks
    if (receivedAmount != 0 && receivedAmount != actualReceived) {
        revert OllaCore__UnstakedFundsMismatch(receivedAmount, actualReceived);
    }
    
    // Use actual received amount for accounting
    if (actualReceived > 0) {
        _accountingState.bufferedAssets += actualReceived;
        emit UnstakedFundsClaimed(actualReceived);
    }
    
    return actualReceived;
}
```

### Step 3: Add error for mismatch (if not already present)

```solidity
/// @notice Thrown when claimed unstaked funds don't match expected.
error OllaCore__UnstakedFundsMismatch(uint256 expected, uint256 actual);
```

### Step 4: Update `rebalance()` function

Update the rebalance function to include the pull-unstaked step:

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
    
    // TODO: Phase 3 - Finalize withdrawals
    uint256 finalizedAmount = 0;
    
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

## Test Cases from Issue

- [ ] **Unstaked funds increase buffer**
  - Mock StakingManager to simulate transfer of 5 ETH
  - Verify `getUnstakedFunds()` is called
  - Verify `bufferedAssets` increases by 5 ETH
  - Verify `UnstakedFundsClaimed(5 ETH)` event is emitted

- [ ] **No-op when nothing available**
  - Mock StakingManager to return 0 and transfer nothing
  - Verify `bufferedAssets` remains unchanged
  - Verify no event emitted (or emitted with 0)
  - Verify no errors occur

## Acceptance Criteria

- [ ] Unstaked funds are pulled before withdrawal finalization
- [ ] `bufferedAssets` is increased by the received amount
- [ ] `UnstakedFundsClaimed` event emitted with actual received amount
- [ ] No-op when no unstaked funds available
- [ ] Balance verification ensures accounting accuracy

## Code Changes Summary

| File | Change |
|------|--------|
| `IOllaCore.sol` | Add `UnstakedFundsClaimed` event; add `OllaCore__UnstakedFundsMismatch` error |
| `OllaCore.sol` | Add `_pullUnstakedFunds()` function; update `rebalance()` to call it |

## Test Implementation

```solidity
// contracts/test/core/OllaCoreRebalance.t.sol

function test_Rebalance_PullUnstakedFunds() public {
    uint256 unstakedAmount = 5 ether;
    
    // Setup: Give StakingManager some funds to transfer
    deal(address(asset), address(stakingManager), unstakedAmount);
    
    // Mock harvest to return 0 for this test
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
    
    // Mock getUnstakedFunds to transfer and return amount
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.getUnstakedFunds.selector),
        abi.encode(unstakedAmount)
    );
    
    // Expect the transfer from StakingManager to OllaCore
    vm.expectCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.getUnstakedFunds.selector)
    );
    
    uint256 bufferBefore = ollaCore.accountingState().bufferedAssets;
    
    vm.prank(operator);
    vm.expectEmit(true, true, true, true);
    emit UnstakedFundsClaimed(unstakedAmount);
    ollaCore.rebalance();
    
    // Verify buffer increased
    assertEq(
        ollaCore.accountingState().bufferedAssets, 
        bufferBefore + unstakedAmount
    );
}

function test_Rebalance_PullUnstakedFunds_NoOp() public {
    // Mock harvest to return 0
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
    
    // Mock no unstaked funds
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.getUnstakedFunds.selector),
        abi.encode(0)
    );
    
    uint256 bufferBefore = ollaCore.accountingState().bufferedAssets;
    
    vm.prank(operator);
    ollaCore.rebalance();
    
    // Verify buffer unchanged
    assertEq(ollaCore.accountingState().bufferedAssets, bufferBefore);
}
```

## Verification

```bash
forge test --match-test test_Rebalance_PullUnstaked -vvv
```

## Order Verification

The pull-unstaked step must occur AFTER harvest and BEFORE finalization:

```solidity
// Verify order in rebalance():
// 1. Harvest (adds to RewardsVault, not buffered)
// 2. Pull Unstaked (adds to bufferedAssets)
// 3. Finalize Withdrawals (uses bufferedAssets)
// 4. Stake Surplus (uses remaining bufferedAssets)
```

## Dependencies for Next Phase

- This phase must be complete before Phase 3 (Finalize Withdrawals)
- The pulled unstaked amount directly increases available liquidity for finalization
