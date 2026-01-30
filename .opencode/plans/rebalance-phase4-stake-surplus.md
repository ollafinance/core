# Phase 4: Rebalance Stake Surplus Step

**Issue**: #65 - feat: Rebalance stake surplus step

## Scope

Implement staking of buffered surplus above target buffer:
- Calculate `stakeable = bufferedAssets - targetBuffer`
- Loop staking in `VALIDATOR_STAKE_UNIT` increments until stakeable is below unit
- Call `StakingManager.stake(amount)` for each unit
- Update `bufferedAssets` and `stakedPrincipal` accounting
- Track total staked for the summary event

## Prerequisites

- Phase 3 (Finalize Withdrawals) must be complete
- `StakingManager.stake()` must be implemented and callable
- `targetBuffer` state variable must be added to OllaCore
- `VALIDATOR_STAKE_UNIT` constant must be defined

## Implementation Steps

### Step 1: Add state variables to OllaCore.sol

```solidity
/// @notice Target buffer amount to keep liquid for withdrawals.
/// @dev Configurable by governance. Set to 0 to stake all available.
uint256 public targetBuffer;

/// @notice The validator stake unit (32 ETH for Aztec).
/// @dev Fixed constant based on Aztec protocol requirements.
uint256 public constant VALIDATOR_STAKE_UNIT = 32 ether;
```

### Step 2: Add setter for targetBuffer

```solidity
/// @notice Sets the target buffer amount.
/// @param newTargetBuffer The new target buffer value.
function setTargetBuffer(uint256 newTargetBuffer) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 oldTargetBuffer = targetBuffer;
    targetBuffer = newTargetBuffer;
    emit TargetBufferUpdated(oldTargetBuffer, newTargetBuffer);
}
```

### Step 3: Add event for target buffer updates

In `IOllaCore.sol`:

```solidity
/// @notice Emitted when the target buffer is updated.
/// @param oldTargetBuffer The previous target buffer.
/// @param newTargetBuffer The new target buffer.
event TargetBufferUpdated(uint256 oldTargetBuffer, uint256 newTargetBuffer);
```

### Step 4: Add error for stake failures

```solidity
/// @notice Thrown when stake operation fails.
error OllaCore__StakeFailed(uint256 amount);
```

### Step 5: Implement `_stakeSurplus()` internal function in OllaCore.sol

```solidity
/// @notice Stakes surplus buffered assets above target buffer.
/// @return totalStaked The total amount staked during this operation.
function _stakeSurplus() internal returns (uint256 totalStaked) {
    _syncBufferedWithBalance();
    
    uint256 bufferedAssets = _accountingState.bufferedAssets;
    
    // Calculate stakeable amount (surplus above target buffer)
    uint256 stakeable;
    if (bufferedAssets > targetBuffer) {
        stakeable = bufferedAssets - targetBuffer;
    } else {
        // No surplus to stake
        return 0;
    }
    
    // Loop and stake in VALIDATOR_STAKE_UNIT increments
    uint256 unitsToStake = stakeable / VALIDATOR_STAKE_UNIT;
    
    for (uint256 i = 0; i < unitsToStake; i++) {
        // Transfer asset to staking manager and stake
        _modules.asset.safeTransfer(address(_modules.stakingManager), VALIDATOR_STAKE_UNIT);
        _modules.stakingManager.stake(VALIDATOR_STAKE_UNIT);
        
        totalStaked += VALIDATOR_STAKE_UNIT;
    }
    
    if (totalStaked > 0) {
        // Update accounting
        _accountingState.bufferedAssets = bufferedAssets - totalStaked;
        _accountingState.stakedPrincipal += totalStaked;
        
        // Note: StakingManager.stake() will handle its own staked amount tracking
        // We update our local accounting for consistency
    }
    
    return totalStaked;
}
```

### Step 6: Update `rebalance()` function

Complete the rebalance function with all steps:

```solidity
/// @notice Operator-triggered rebalance flow.
/// @dev Executes: harvest -> pull unstaked -> finalize withdrawals -> stake surplus
/// @return harvestedAmount The amount of rewards harvested.
/// @return finalizedAmount The amount used to finalize withdrawals.
/// @return stakedAmount The amount staked.
/// @return resultingBuffer The final buffered assets after rebalance.
function rebalance() 
    external 
    override 
    onlyRole(OPERATOR_ROLE) 
    whenNotPaused 
    nonReentrant 
    returns (
        uint256 harvestedAmount,
        uint256 finalizedAmount,
        uint256 stakedAmount,
        uint256 resultingBuffer
    )
{
    // Step 1: Harvest rewards
    harvestedAmount = _harvestRewards();
    
    // Step 2: Pull unstaked funds  
    /* uint256 unstakedAmount = */ _pullUnstakedFunds();
    
    // Step 3: Finalize withdrawals (uses available liquidity)
    finalizedAmount = _finalizeWithdrawals();
    
    // Step 4: Stake surplus above target buffer
    stakedAmount = _stakeSurplus();
    
    resultingBuffer = _accountingState.bufferedAssets;
    
    emit Rebalanced(
        harvestedAmount,
        finalizedAmount,
        stakedAmount,
        resultingBuffer
    );
    
    return (harvestedAmount, finalizedAmount, stakedAmount, resultingBuffer);
}
```

### Step 7: Update `Rebalanced` event signature in IOllaCore.sol

Update the event to match the new implementation:

```solidity
/// @notice Emitted when a rebalance operation completes.
/// @param harvestedAmount Amount of rewards harvested.
/// @param finalizedAmount Amount of assets used for withdrawal finalization.
/// @param stakedAmount Amount of assets staked.
/// @param resultingBuffer Final buffered assets after rebalance.
event Rebalanced(
    uint256 harvestedAmount,
    uint256 finalizedAmount,
    uint256 stakedAmount,
    uint256 resultingBuffer
);
```

## Test Cases from Issue

- [ ] **Surplus staking reduces buffer**
  - Setup: bufferedAssets = 100 ETH, targetBuffer = 10 ETH
  - VALIDATOR_STAKE_UNIT = 32 ETH
  - stakeable = 90 ETH, unitsToStake = 2 (64 ETH)
  - Call rebalance
  - Verify 64 ETH is staked (2 units)
  - Verify `bufferedAssets` becomes 36 ETH (100 - 64)
  - Verify `Rebalanced` event shows stakedAmount = 64 ETH

- [ ] **No staking when below target buffer**
  - Setup: bufferedAssets = 5 ETH, targetBuffer = 10 ETH
  - Call rebalance
  - Verify 0 ETH is staked
  - Verify `bufferedAssets` remains 5 ETH
  - Verify `Rebalanced` event shows stakedAmount = 0

## Acceptance Criteria

- [ ] Staking step preserves invariants and does not exceed available buffer
- [ ] Surplus is calculated correctly: `stakeable = bufferedAssets - targetBuffer`
- [ ] Staking occurs in `VALIDATOR_STAKE_UNIT` increments only
- [ ] No staking when bufferedAssets <= targetBuffer
- [ ] `bufferedAssets` and `stakedPrincipal` accounting updated correctly
- [ ] `Rebalanced` event includes the staked amount
- [ ] Staking occurs only after withdrawals are finalized

## Code Changes Summary

| File | Change |
|------|--------|
| `IOllaCore.sol` | Update `Rebalanced` event; add `TargetBufferUpdated` event; add `OllaCore__StakeFailed` error |
| `OllaCore.sol` | Add `targetBuffer` state variable; add `VALIDATOR_STAKE_UNIT` constant; add `setTargetBuffer()`; add `_stakeSurplus()`; complete `rebalance()` function |

## Test Implementation

```solidity
// contracts/test/core/OllaCoreRebalance.t.sol

function test_Rebalance_StakeSurplus() public {
    // Setup: Deposit 100 ETH
    uint256 depositAmount = 100 ether;
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    // Set target buffer to 10 ETH
    vm.prank(governance);
    ollaCore.setTargetBuffer(10 ether);
    
    _mockZeroHarvest();
    _mockZeroUnstaked();
    _mockZeroFinalize();
    
    // Mock staking manager to accept stakes
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.stake.selector),
        abi.encode()
    );
    
    uint256 bufferBefore = ollaCore.accountingState().bufferedAssets;
    uint256 targetBuffer = ollaCore.targetBuffer();
    uint256 stakeUnit = 32 ether;
    
    // stakeable = 100 - 10 = 90
    // unitsToStake = 90 / 32 = 2
    // totalStaked = 64
    uint256 expectedStaked = 2 * stakeUnit;
    uint256 expectedBufferAfter = bufferBefore - expectedStaked;
    
    vm.prank(operator);
    (,, uint256 stakedAmount, uint256 resultingBuffer) = ollaCore.rebalance();
    
    assertEq(stakedAmount, expectedStaked, "Staked amount mismatch");
    assertEq(resultingBuffer, expectedBufferAfter, "Buffer after mismatch");
    assertEq(ollaCore.accountingState().bufferedAssets, expectedBufferAfter);
}

function test_Rebalance_StakeSurplus_BelowTarget() public {
    // Setup: Deposit 20 ETH only
    uint256 depositAmount = 20 ether;
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    // Set target buffer to 30 ETH (above our buffer)
    vm.prank(governance);
    ollaCore.setTargetBuffer(30 ether);
    
    _mockZeroHarvest();
    _mockZeroUnstaked();
    _mockZeroFinalize();
    
    uint256 bufferBefore = ollaCore.accountingState().bufferedAssets;
    
    vm.prank(operator);
    (,, uint256 stakedAmount, uint256 resultingBuffer) = ollaCore.rebalance();
    
    // Nothing should be staked when below target
    assertEq(stakedAmount, 0, "Should not stake when below target");
    assertEq(resultingBuffer, bufferBefore, "Buffer should not change");
}

function test_Rebalance_StakeSurplus_PartialUnit() public {
    // Setup: Deposit 40 ETH
    uint256 depositAmount = 40 ether;
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    // Set target buffer to 10 ETH
    vm.prank(governance);
    ollaCore.setTargetBuffer(10 ether);
    
    _mockZeroHarvest();
    _mockZeroUnstaked();
    _mockZeroFinalize();
    
    // Mock staking manager
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.stake.selector),
        abi.encode()
    );
    
    // stakeable = 40 - 10 = 30
    // unitsToStake = 30 / 32 = 0 (integer division)
    // Nothing should be staked
    
    vm.prank(operator);
    (,, uint256 stakedAmount,) = ollaCore.rebalance();
    
    assertEq(stakedAmount, 0, "Should not stake partial unit");
}

function _mockZeroFinalize() internal {
    vm.mockCall(
        address(withdrawalQueue),
        abi.encodeWithSelector(IWithdrawalQueue.finalizeWithdrawals.selector),
        abi.encode(0)
    );
    vm.mockCall(
        address(withdrawalQueue),
        abi.encodeWithSelector(IWithdrawalQueue.previewFinalizeWithdrawals.selector),
        abi.encode(0)
    );
}
```

## Verification

```bash
forge test --match-test test_Rebalance_Stake -vvv
```

## Gas Considerations

The stake surplus loop may consume significant gas if many units are staked:

```solidity
// Maximum units to stake in one call (gas limit consideration)
uint256 constant MAX_STAKE_UNITS_PER_REBALANCE = 100;

// In _stakeSurplus():
if (unitsToStake > MAX_STAKE_UNITS_PER_REBALANCE) {
    unitsToStake = MAX_STAKE_UNITS_PER_REBALANCE;
}
```

This ensures the transaction doesn't exceed block gas limits.

## Dependencies for Next Phase

- This phase completes the individual rebalance steps
- Phase 5 will integrate all steps and add comprehensive tests
