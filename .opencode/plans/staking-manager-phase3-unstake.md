# Phase 3: Implement Unstake Flow

**Issue**: #11 - feat: Implement unstake flow

## Scope

From issue #11:
- Request unstake
- Update totals
- Emit events

## Prerequisites

- Phase 1 complete (core contract structure)
- Phase 2 complete (stake flow with active validator tracking)

## Implementation Steps

### Step 1: Add Unstake Tracking State

Add to StakingManager state variables:

```solidity
// Unstake tracking
struct UnstakeRequest {
    address attester;
    uint256 amount;
    uint256 initiatedAt;
}

UnstakeRequest[] private _pendingUnstakeRequests;
mapping(address attester => bool isPending) private _isUnstakePending;
```

### Step 2: Update `_unstakeInternal`

Replace the placeholder with full implementation:

```solidity
function _unstakeInternal(uint256 amount) internal {
    if (amount > _totalStakedPrincipal - _pendingUnstakes) {
        revert StakingManager__InsufficientStake();
    }
    
    uint256 activationThreshold = IStaking(rollup).getActivationThreshold();
    uint256 validatorsToUnstake = (amount + activationThreshold - 1) / activationThreshold; // Round up
    
    // Limit to available active validators
    uint256 availableValidators = _activeValidators.length;
    if (validatorsToUnstake > availableValidators) {
        validatorsToUnstake = availableValidators;
    }
    
    uint256 actualUnstakeAmount = 0;
    
    for (uint256 i; i < validatorsToUnstake; ++i) {
        // Get last active validator (more efficient removal)
        address attester = _activeValidators[_activeValidators.length - 1];
        
        // Initiate withdrawal on rollup
        IStaking(rollup).initiateWithdraw(attester, address(this));
        
        // Track pending unstake
        _pendingUnstakeRequests.push(UnstakeRequest({
            attester: attester,
            amount: activationThreshold,
            initiatedAt: block.timestamp
        }));
        _isUnstakePending[attester] = true;
        
        // Remove from active validators
        _removeActiveValidator(attester);
        
        actualUnstakeAmount += activationThreshold;
        
        emit UnstakeInitiated(attester, activationThreshold);
    }
    
    _pendingUnstakes += actualUnstakeAmount;
    _totalStakedPrincipal -= actualUnstakeAmount;
}
```

### Step 3: Update `_claimUnstakedFunds`

Replace placeholder with full implementation:

```solidity
function _claimUnstakedFunds() internal returns (uint256 claimed) {
    uint256 i = 0;
    claimed = 0;
    
    while (i < _pendingUnstakeRequests.length) {
        UnstakeRequest memory request = _pendingUnstakeRequests[i];
        
        // Try to finalize this withdrawal
        // Note: In production, we'd check if the withdrawal is ready
        // For now, we assume all pending withdrawals can be finalized
        try IStaking(rollup).finaliseWithdraw(request.attester) {
            claimed += request.amount;
            _isUnstakePending[request.attester] = false;
            
            // Remove from pending list (swap and pop)
            uint256 lastIndex = _pendingUnstakeRequests.length - 1;
            if (i != lastIndex) {
                _pendingUnstakeRequests[i] = _pendingUnstakeRequests[lastIndex];
            }
            _pendingUnstakeRequests.pop();
            
            // Don't increment i, we moved a new element to this position
        } catch {
            // Withdrawal not ready yet, skip
            ++i;
        }
    }
    
    if (claimed > 0) {
        _pendingUnstakes -= claimed;
        // Transfer claimed funds to core
        stakingAsset.safeTransfer(core, claimed);
        emit UnstakedFundsClaimed(claimed);
    }
    
    return claimed;
}
```

### Step 4: Add View Functions

Add to interface and implementation:

```solidity
/// @notice Returns the number of pending unstake requests.
/// @return The count of pending requests.
function getPendingUnstakeCount() external view returns (uint256) {
    return _pendingUnstakeRequests.length;
}

/// @notice Checks if an attester has a pending unstake.
/// @param attester The attester address.
/// @return True if unstake is pending.
function isUnstakePending(address attester) external view returns (bool) {
    return _isUnstakePending[attester];
}
```

### Step 5: Update Tests

Add to `StakingManager.t.sol`:

```solidity
/*//////////////////////////////////////////////////////////////
                        UNSTAKE FLOW TESTS
//////////////////////////////////////////////////////////////*/

function test_Unstake_InitiatesWithdrawal() external {
    // Setup: stake first
    _setupStakedValidator();
    
    uint256 totalStakedBefore = stakingManager.totalStaked();
    
    vm.prank(core);
    stakingManager.unStake(ACTIVATION_THRESHOLD);
    
    // Verify
    assertEq(stakingManager.totalStaked(), totalStakedBefore - ACTIVATION_THRESHOLD);
    assertEq(stakingManager.getPendingUnstakes(), ACTIVATION_THRESHOLD);
    assertEq(stakingManager.getActiveValidatorCount(), 0);
    assertEq(stakingManager.getPendingUnstakeCount(), 1);
}

function test_Unstake_EmitsEvent() external {
    // Setup: stake first
    IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
    vm.prank(providerAdmin);
    stakingManager.addKeysToProvider(keys);
    
    aztec.mint(core, ACTIVATION_THRESHOLD);
    vm.startPrank(core);
    aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
    stakingManager.stake(ACTIVATION_THRESHOLD);
    
    vm.expectEmit(true, true, true, true);
    emit UnstakeInitiated(keys[0].attester, ACTIVATION_THRESHOLD);
    
    stakingManager.unStake(ACTIVATION_THRESHOLD);
    vm.stopPrank();
}

function test_RevertWhen_UnstakeExceedsStaked() external {
    vm.prank(core);
    vm.expectRevert(IStakingManager.StakingManager__InsufficientStake.selector);
    stakingManager.unStake(ACTIVATION_THRESHOLD);
}

function test_GetUnstakedFunds_ClaimsMaturedWithdrawals() external {
    // Setup: stake and unstake
    _setupStakedValidator();
    
    vm.prank(core);
    stakingManager.unStake(ACTIVATION_THRESHOLD);
    
    uint256 coreBalanceBefore = aztec.balanceOf(core);
    
    // Claim unstaked funds
    vm.prank(core);
    uint256 claimed = stakingManager.getUnstakedFunds();
    
    // Verify
    assertEq(claimed, ACTIVATION_THRESHOLD);
    assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
    assertEq(stakingManager.getPendingUnstakes(), 0);
    assertEq(stakingManager.getPendingUnstakeCount(), 0);
}

function test_GetUnstakedFunds_EmitsEvent() external {
    _setupStakedValidator();
    
    vm.prank(core);
    stakingManager.unStake(ACTIVATION_THRESHOLD);
    
    vm.expectEmit(true, true, true, true);
    emit UnstakedFundsClaimed(ACTIVATION_THRESHOLD);
    
    vm.prank(core);
    stakingManager.getUnstakedFunds();
}

function test_Unstake_MultipleValidators() external {
    // Setup: stake 3 validators
    IStakingManager.KeyStore[] memory keys = _createMockKeys(3);
    vm.prank(providerAdmin);
    stakingManager.addKeysToProvider(keys);
    
    uint256 stakeAmount = ACTIVATION_THRESHOLD * 3;
    aztec.mint(core, stakeAmount);
    
    vm.startPrank(core);
    aztec.approve(address(stakingManager), stakeAmount);
    stakingManager.stake(stakeAmount);
    
    // Unstake 2 validators
    stakingManager.unStake(ACTIVATION_THRESHOLD * 2);
    vm.stopPrank();
    
    // Verify
    assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD);
    assertEq(stakingManager.getPendingUnstakes(), ACTIVATION_THRESHOLD * 2);
    assertEq(stakingManager.getActiveValidatorCount(), 1);
    assertEq(stakingManager.getPendingUnstakeCount(), 2);
}

/*//////////////////////////////////////////////////////////////
                            HELPERS
//////////////////////////////////////////////////////////////*/

function _setupStakedValidator() internal {
    IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
    vm.prank(providerAdmin);
    stakingManager.addKeysToProvider(keys);
    
    aztec.mint(core, ACTIVATION_THRESHOLD);
    
    vm.startPrank(core);
    aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
    stakingManager.stake(ACTIVATION_THRESHOLD);
    vm.stopPrank();
}
```

### Step 6: Update MockAztecRollup

Ensure the mock properly tracks withdrawal state for testing:

```solidity
// Add to MockAztecRollup
mapping(address attester => uint256 withdrawInitiatedAt) public withdrawInitiatedAt;

function initiateWithdraw(address _attester, address) external {
    require(withdrawers[_attester] == msg.sender, "Not withdrawer");
    require(!withdrawing[_attester], "Already withdrawing");
    withdrawing[_attester] = true;
    withdrawInitiatedAt[_attester] = block.timestamp;
    emit WithdrawInitiated(_attester, msg.sender);
}

// For testing: allow immediate finalization
function setWithdrawReady(address _attester) external {
    withdrawing[_attester] = true;
}
```

## Test Cases from Issue #11

- [x] Unstake reduces totals
- [x] Excess unstake reverts
- [x] Event emitted

## Acceptance Criteria

- [x] Cannot unstake more than staked

## Notes from Issue

- Asset return integrated later (via `getUnstakedFunds`)

## Verification

```bash
# Run unstake-specific tests
forge test --match-test "test_Unstake\|test_GetUnstakedFunds" -vvv

# Run all StakingManager tests
forge test --match-contract StakingManagerTest -vvv

# Full coverage
forge coverage --match-contract StakingManager
```

## Integration with OllaCore

After all phases are complete, the OllaCore contract can use the StakingManager in its rebalance flow:

```solidity
// In OllaCore.rebalance()
function rebalance() external onlyRole(OPERATOR_ROLE) {
    // 1. Harvest rewards
    _stakingManager.harvestRewards();
    
    // 2. Claim matured unstakes
    uint256 received = _stakingManager.getUnstakedFunds();
    
    // 3. Finalize withdrawal queue with available liquidity
    uint256 availableForWithdrawals = totalAssets();
    _withdrawalQueue.finalizeWithdrawals(availableForWithdrawals);
    
    // 4. Stake excess
    uint256 excess = totalAssets() - targetBuffer;
    if (excess >= VALIDATOR_STAKE_UNIT) {
        _stakingManager.stake(excess);
    }
    
    // 5. If needed, unstake to meet withdrawal demands
    uint256 needed = _withdrawalQueue.pendingAmount();
    if (needed > totalAssets()) {
        _stakingManager.unStake(needed - totalAssets());
    }
}
```
