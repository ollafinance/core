# Phase 5: Rebalance End-to-End Integration

**Issue**: #62 - feat: Rebalance flow end-to-end

## Scope

Implement the full `rebalance()` flow integrating all four steps:
1. Harvest rewards via `StakingManager.harvestRewards()`
2. Pull unstaked funds via `StakingManager.getUnstakedFunds()`
3. Finalize withdrawals with `WithdrawalQueue.finalizeWithdrawals(availableForWithdrawals)`
4. Stake surplus above target buffer in `VALIDATOR_STAKE_UNIT` increments

Emit comprehensive `Rebalanced` summary event with harvested, finalized, staked, and resulting buffer totals.

## Repo Status

- [ ] `rebalance()` returns full summary tuple and emits complete `Rebalanced` event (currently stubbed and returns nothing).
- [ ] `rebalance()` integrates all four steps end-to-end in order.
- [ ] Integration tests added in `contracts/test/integration/RebalanceIntegration.t.sol`.

## Prerequisites

- Phases 1-4 must be complete
- All individual steps tested and working
- StakingManager, WithdrawalQueue, and RewardsVault properly integrated
- SafetyModule checks operational

## Implementation Steps

### Step 1: Verify complete `rebalance()` function

Ensure the `rebalance()` function is fully implemented:

```solidity
/// @notice Operator-triggered rebalance flow.
/// @dev Executes in strict order: harvest -> pull unstaked -> finalize -> stake
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
    // Step 1: Harvest rewards from AztecRollup
    harvestedAmount = _harvestRewards();
    
    // Step 2: Pull matured unstaked funds to increase liquidity
    _pullUnstakedFunds();
    
    // Step 3: Finalize pending withdrawals (prioritized before staking)
    finalizedAmount = _finalizeWithdrawals();
    
    // Step 4: Stake surplus above target buffer
    stakedAmount = _stakeSurplus();
    
    resultingBuffer = _accountingState.bufferedAssets;
    
    // Emit comprehensive summary event
    emit Rebalanced(
        harvestedAmount,
        finalizedAmount,
        stakedAmount,
        resultingBuffer
    );
    
    return (harvestedAmount, finalizedAmount, stakedAmount, resultingBuffer);
}
```

### Step 2: Ensure all internal functions are implemented

Verify these internal functions exist and are correct:

```solidity
function _harvestRewards() internal returns (uint256 harvestedAmount)
function _pullUnstakedFunds() internal returns (uint256 receivedAmount)  
function _finalizeWithdrawals() internal returns (uint256 finalizedAmount)
function _stakeSurplus() internal returns (uint256 totalStaked)
```

### Step 3: Update IOllaCore.sol interface

Ensure the interface matches the implementation:

```solidity
/// @notice Operator-triggered rebalance hook.
/// @return harvestedAmount The amount of rewards harvested.
/// @return finalizedAmount The amount used to finalize withdrawals.
/// @return stakedAmount The amount staked.
/// @return resultingBuffer The final buffered assets after rebalance.
function rebalance() external returns (
    uint256 harvestedAmount,
    uint256 finalizedAmount,
    uint256 stakedAmount,
    uint256 resultingBuffer
);
```

### Step 4: Add comprehensive integration tests

## Test Cases from Issue

### Test 1: Withdrawals prioritized before staking

```solidity
function test_Rebalance_WithdrawalsBeforeStaking() public {
    // Setup scenario:
    // - bufferedAssets: 100 ETH
    // - pending withdrawals: 40 ETH  
    // - targetBuffer: 10 ETH
    // 
    // Expected behavior:
    // 1. Finalize 40 ETH of withdrawals first
    // 2. Remaining buffer: 60 ETH
    // 3. Stakeable: 60 - 10 = 50 ETH
    // 4. Units to stake: 50 / 32 = 1 unit (32 ETH)
    // 5. Final buffer: 60 - 32 = 28 ETH
    
    uint256 depositAmount = 100 ether;
    uint256 withdrawalAmount = 40 ether;
    uint256 targetBufferAmount = 10 ether;
    
    // Deposit
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    // Request withdrawal
    uint256 withdrawalShares = ollaCore.convertToShares(withdrawalAmount);
    vm.prank(user);
    ollaCore.requestRedeem(withdrawalShares, user);
    
    // Set target buffer
    vm.prank(governance);
    ollaCore.setTargetBuffer(targetBufferAmount);
    
    // Mock harvest and unstaked
    _mockZeroHarvest();
    _mockZeroUnstaked();
    
    // Mock staking
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.stake.selector),
        abi.encode()
    );
    
    vm.prank(operator);
    (uint256 harvested, uint256 finalized, uint256 staked, uint256 buffer) = ollaCore.rebalance();
    
    // Verify withdrawals finalized BEFORE staking
    assertEq(finalized, withdrawalAmount, "Should finalize all pending withdrawals first");
    assertEq(staked, 32 ether, "Should stake 1 unit after withdrawals");
    assertEq(buffer, 28 ether, "Buffer should be 60 - 32 = 28");
}
```

### Test 2: Rebalance idempotent when called repeatedly

```solidity
function test_Rebalance_Idempotent() public {
    // Setup initial state
    uint256 depositAmount = 100 ether;
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    vm.prank(governance);
    ollaCore.setTargetBuffer(10 ether);
    
    _mockZeroHarvest();
    _mockZeroUnstaked();
    _mockZeroFinalize();
    
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.stake.selector),
        abi.encode()
    );
    
    // First rebalance
    vm.prank(operator);
    (uint256 h1, uint256 f1, uint256 s1, uint256 b1) = ollaCore.rebalance();
    
    // Second rebalance (no state changes)
    vm.prank(operator);
    (uint256 h2, uint256 f2, uint256 s2, uint256 b2) = ollaCore.rebalance();
    
    // Should be idempotent (no changes on second call)
    assertEq(h2, 0, "Second harvest should be 0");
    assertEq(f2, 0, "Second finalize should be 0");
    assertEq(s2, 0, "Second stake should be 0 (already staked surplus)");
    assertEq(b2, b1, "Buffer should remain same");
}
```

### Test 3: Queue drains with sufficient liquidity

```solidity
function test_Rebalance_QueueDrainsWithSufficientLiquidity() public {
    // Setup:
    // - 3 users with withdrawal requests totaling 60 ETH
    // - bufferedAssets: 100 ETH (sufficient to cover all)
    
    uint256 depositPerUser = 50 ether;
    uint256 withdrawPerUser = 20 ether;
    
    // Setup 3 users
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");
    
    for (uint i = 0; i < 3; i++) {
        address u = i == 0 ? user : (i == 1 ? user2 : user3);
        deal(address(asset), u, depositPerUser);
        vm.prank(u);
        asset.approve(address(ollaCore), depositPerUser);
        vm.prank(u);
        ollaCore.deposit(depositPerUser, u);
        
        uint256 shares = ollaCore.convertToShares(withdrawPerUser);
        vm.prank(u);
        ollaCore.requestRedeem(shares, u);
    }
    
    _mockZeroHarvest();
    _mockZeroUnstaked();
    
    // Set high target buffer to prevent staking
    vm.prank(governance);
    ollaCore.setTargetBuffer(100 ether);
    
    uint256 totalPendingBefore = withdrawalQueue.totalPendingAssets();
    assertEq(totalPendingBefore, 60 ether, "Should have 60 ETH pending");
    
    vm.prank(operator);
    ollaCore.rebalance();
    
    uint256 totalPendingAfter = withdrawalQueue.totalPendingAssets();
    assertEq(totalPendingAfter, 0, "Queue should be empty after draining");
}
```

## Additional Integration Tests

### Full Flow Test

```solidity
function test_Rebalance_FullFlow() public {
    // Complex scenario:
    // 1. Harvest 5 ETH rewards
    // 2. Pull 10 ETH unstaked funds
    // 3. Have 30 ETH pending withdrawals
    // 4. 100 ETH buffered + 10 ETH from unstaked = 110 ETH available
    // 5. Finalize 30 ETH withdrawals
    // 6. 80 ETH remaining, targetBuffer = 20 ETH
    // 7. Stakeable = 60 ETH, units = 1 (32 ETH)
    // 8. Final: 48 ETH buffer
    
    uint256 harvestAmount = 5 ether;
    uint256 unstakedAmount = 10 ether;
    uint256 depositAmount = 100 ether;
    uint256 withdrawalAmount = 30 ether;
    uint256 targetBufferAmount = 20 ether;
    
    // Setup deposit and withdrawal
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    uint256 withdrawalShares = ollaCore.convertToShares(withdrawalAmount);
    vm.prank(user);
    ollaCore.requestRedeem(withdrawalShares, user);
    
    // Set target buffer
    vm.prank(governance);
    ollaCore.setTargetBuffer(targetBufferAmount);
    
    // Mock harvest
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.harvestRewards.selector),
        abi.encode(harvestAmount)
    );
    vm.mockCall(
        address(rewardsVault),
        abi.encodeWithSelector(IRewardsVault.recordRewards.selector),
        abi.encode(harvestAmount)
    );
    
    // Mock unstaked funds
    deal(address(asset), address(stakingManager), unstakedAmount);
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.getUnstakedFunds.selector),
        abi.encode(unstakedAmount)
    );
    
    // Mock staking
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.stake.selector),
        abi.encode()
    );
    
    // Expected:
    // harvested = 5
    // finalized = 30
    // After harvest: buffered = 100 (harvest goes to RV, not buffer)
    // After unstaked: buffered = 110
    // After finalize: buffered = 80
    // stakeable = 80 - 20 = 60
    // staked = 32 (1 unit)
    // final buffer = 48
    
    vm.prank(operator);
    (uint256 harvested, uint256 finalized, uint256 staked, uint256 buffer) = ollaCore.rebalance();
    
    assertEq(harvested, harvestAmount, "Harvest mismatch");
    assertEq(finalized, withdrawalAmount, "Finalize mismatch");
    assertEq(staked, 32 ether, "Stake mismatch");
    assertEq(buffer, 48 ether, "Final buffer mismatch");
}
```

### Event Emission Test

```solidity
function test_Rebalance_EmitsCorrectEvents() public {
    uint256 depositAmount = 100 ether;
    deal(address(asset), user, depositAmount);
    vm.prank(user);
    asset.approve(address(ollaCore), depositAmount);
    vm.prank(user);
    ollaCore.deposit(depositAmount, user);
    
    vm.prank(governance);
    ollaCore.setTargetBuffer(10 ether);
    
    _mockZeroHarvest();
    _mockZeroUnstaked();
    _mockZeroFinalize();
    
    vm.mockCall(
        address(stakingManager),
        abi.encodeWithSelector(IStakingManager.stake.selector),
        abi.encode()
    );
    
    // Expect Rebalanced event with correct parameters
    vm.expectEmit(true, true, true, true);
    emit Rebalanced(0, 0, 64 ether, 36 ether); // 2 units staked, 36 remaining
    
    vm.prank(operator);
    ollaCore.rebalance();
}
```

## Acceptance Criteria

- [ ] Rebalance step order matches harvest -> pull unstaked -> finalize -> stake
- [ ] Accounting updated for each step
- [ ] Withdrawals prioritized before staking
- [ ] Rebalance idempotent when called repeatedly
- [ ] Queue drains with sufficient liquidity
- [ ] Comprehensive `Rebalanced` event emitted with all totals
- [ ] All steps respect `whenNotPaused` and `nonReentrant` modifiers
- [ ] SafetyModule checks integrated for queue ratio and rate drop

## Verification Commands

```bash
# Run all rebalance tests
forge test --match-contract OllaCoreRebalanceTest -vvv

# Run with gas report
forge test --match-contract OllaCoreRebalanceTest --gas-report

# Run integration tests
forge test --match-contract RebalanceIntegrationTest -vvv

# Check coverage for rebalance functionality
forge coverage --match-contract OllaCore
```

## Deployment Checklist

Before deploying the complete rebalance flow:

- [ ] All unit tests passing
- [ ] Integration tests passing
- [ ] Gas profiling completed for rebalance hot path
- [ ] Fuzz tests added for edge cases
- [ ] SafetyModule properly configured
- [ ] Target buffer value set by governance
- [ ] VALIDATOR_STAKE_UNIT verified against Aztec requirements
- [ ] StakingManager integration tested on testnet
- [ ] WithdrawalQueue FIFO behavior verified
- [ ] Circuit breaker thresholds configured

## Notes

1. **Order is critical**: The strict ordering ensures user withdrawals are always prioritized over staking surplus
2. **Gas limits**: Consider adding max stake units per call to prevent hitting block gas limits
3. **Idempotency**: Rebalance should be safe to call multiple times without adverse effects
4. **Safety**: All external calls respect pause state and nonReentrant guards
5. **Events**: Comprehensive events enable off-chain monitoring and indexing
