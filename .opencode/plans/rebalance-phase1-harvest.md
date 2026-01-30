# Phase 1: Rebalance Harvest Step

**Issue**: #64 - feat: Rebalance harvest step

## Scope

Implement the harvest step inside `rebalance()` that:
- Calls `StakingManager.harvestRewards()`
- Receives rewards into the RewardsVault (deposited by AztecRollup)
- Emits `RewardsHarvested(harvestedAmount)` in OllaCore
- Updates cumulative rewards accounting

## Prerequisites

- `StakingManager.harvestRewards()` must be implemented and callable
- `RewardsVault.recordRewards()` must track balance changes
- `OllaCore` has the `OPERATOR_ROLE` modifier available

## Implementation Steps

### Step 1: Add `RewardsHarvested` event to IOllaCore.sol

```solidity
/// @notice Emitted when rewards are harvested during rebalance.
/// @param amount The amount of rewards harvested.
event RewardsHarvested(uint256 amount);
```

### Step 2: Implement `_harvestRewards()` internal function in OllaCore.sol

Add this internal function to perform the harvest step:

```solidity
/// @notice Harvests rewards from the staking manager.
/// @return harvestedAmount The amount of rewards harvested.
function _harvestRewards() internal returns (uint256 harvestedAmount) {
    // Trigger the actual claiming on the rollup
    // Rewards are sent directly to RewardsVault
    _modules.stakingManager.harvestRewards();
    
    // Get the actual delta from RewardsVault and update cumulative rewards
    harvestedAmount = _modules.rewardsVault.recordRewards();
    if (harvestedAmount != 0) {
        _accountingState.cumulativeRewards += harvestedAmount;
    }
    
    emit RewardsHarvested(harvestedAmount);
    return harvestedAmount;
}
```

### Step 3: Update `rebalance()` function

Replace the stub `rebalance()` function with the first step:

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
    uint256 harvestedAmount = _harvestRewards();
    
    // TODO: Phase 2 - Pull unstaked funds
    uint256 unstakedAmount = 0;
    
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

- [ ] **Harvest invoked and rewards tracked**
  - Mock StakingManager to return a specific harvest amount
  - Verify `harvestRewards()` is called on StakingManager
  - Verify `RewardsHarvested` event is emitted with correct amount
  - Verify cumulative rewards accounting is updated

- [ ] **Zero rewards handled gracefully**
  - Mock StakingManager to return 0
  - Verify no state changes or errors occur
  - Verify `RewardsHarvested(0)` is emitted

## Acceptance Criteria

- [ ] Harvest is invoked before withdrawal finalization and staking
- [ ] `RewardsHarvested` event emitted with the actual harvested amount
- [ ] Cumulative rewards tracking is updated
- [ ] Zero rewards case handled without errors

## Code Changes Summary

| File | Change |
|------|--------|
| `IOllaCore.sol` | Add `RewardsHarvested` event |
| `OllaCore.sol` | Add `_harvestRewards()` internal function; update `rebalance()` stub |

## Test Implementation

```solidity
// contracts/test/core/OllaCoreRebalance.t.sol
function test_Rebalance_HarvestRewards() public {
    uint256 expectedHarvest = 1 ether;
    
    // Mock StakingManager to return harvest amount
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.harvestRewards.selector),
        abi.encode(expectedHarvest)
    );
    
    // Mock RewardsVault to return the delta
    vm.mockCall(
        address(rewardsVault),
        abi.encodeWithSelector(IRewardsVault.recordRewards.selector),
        abi.encode(expectedHarvest)
    );
    
    vm.prank(operator);
    vm.expectEmit(true, true, true, true);
    emit RewardsHarvested(expectedHarvest);
    ollaCore.rebalance();
    
    // Verify cumulative rewards updated
    assertEq(ollaCore.accountingState().cumulativeRewards, expectedHarvest);
}

function test_Rebalance_HarvestZeroRewards() public {
    // Mock zero harvest
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
    
    vm.prank(operator);
    vm.expectEmit(true, true, true, true);
    emit RewardsHarvested(0);
    ollaCore.rebalance();
}
```

## Verification

```bash
forge test --match-test test_Rebalance_Harvest -vvv
```

## Dependencies for Next Phase

- This phase must be complete before Phase 2 (Pull Unstaked)
- The harvest amount may affect available liquidity for subsequent steps
