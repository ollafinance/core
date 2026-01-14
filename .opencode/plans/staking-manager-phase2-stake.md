# Phase 2: Implement Stake Flow

**Issue**: #12 - feat: Implement stake flow

## Scope

From issue #12:
- Route assets to staking layer
- Update totals
- Emit events

## Prerequisites

- Phase 1 complete (core contract structure, interfaces, libraries)

## Implementation Steps

### Step 1: Update `_stakeInternal` in StakingManager

Replace the placeholder `_stakeInternal` function with full implementation:

```solidity
function _stakeInternal(uint256 amount) internal {
    // Get activation threshold from rollup
    uint256 activationThreshold = IStaking(rollup).getActivationThreshold();
    
    // Calculate how many validators we can stake
    uint256 validatorsToStake = amount / activationThreshold;
    if (validatorsToStake == 0) {
        revert StakingManager__InsufficientAmount();
    }
    
    // Check we have enough keys
    uint256 availableKeys = _providerQueue.length();
    if (availableKeys < validatorsToStake) {
        revert StakingManager__InsufficientKeys();
    }
    
    // Transfer assets from core to this contract
    stakingAsset.safeTransferFrom(core, address(this), amount);
    
    // Approve rollup to spend
    stakingAsset.approve(rollup, amount);
    
    // Stake each validator
    uint256 totalStaked = 0;
    for (uint256 i; i < validatorsToStake; ++i) {
        // Dequeue a key
        KeyStore memory keyStore = _providerQueue.dequeue();
        
        // Deposit to rollup
        IStaking(rollup).deposit(
            keyStore.attester,
            address(this),  // StakingManager is the withdrawer
            keyStore.publicKeyG1,
            keyStore.publicKeyG2,
            keyStore.proofOfPossession,
            true  // moveWithRollup
        );
        
        // Track active validator
        _addActiveValidator(keyStore.attester);
        
        totalStaked += activationThreshold;
        
        emit StakedWithProvider(keyStore.attester, activationThreshold);
    }
    
    _totalStakedPrincipal += totalStaked;
    
    // Return any excess to core
    uint256 excess = amount - totalStaked;
    if (excess > 0) {
        stakingAsset.safeTransfer(core, excess);
    }
}
```

### Step 2: Add IStaking Interface

Create `contracts/src/interfaces/IStaking.sol`:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { BN254Lib } from "src/libraries/BN254Lib.sol";

/// @title IStaking
/// @notice Minimal interface for Aztec rollup staking operations.
/// @author Olla Core contributors
interface IStaking {
    function deposit(
        address _attester,
        address _withdrawer,
        BN254Lib.G1Point memory _publicKeyG1,
        BN254Lib.G2Point memory _publicKeyG2,
        BN254Lib.G1Point memory _signature,
        bool _moveWithRollup
    ) external;

    function initiateWithdraw(address _attester, address _recipient) external;

    function finaliseWithdraw(address _attester) external;

    function claimSequencerRewards(address _sequencer) external;

    function getActivationThreshold() external view returns (uint256);
}
```

### Step 3: Add Active Validator Tracking

Add helper functions for validator tracking:

```solidity
function _addActiveValidator(address attester) internal {
    if (!_isActiveValidator[attester]) {
        _validatorIndex[attester] = _activeValidators.length;
        _activeValidators.push(attester);
        _isActiveValidator[attester] = true;
    }
}

function _removeActiveValidator(address attester) internal {
    if (_isActiveValidator[attester]) {
        uint256 index = _validatorIndex[attester];
        uint256 lastIndex = _activeValidators.length - 1;
        
        if (index != lastIndex) {
            address lastValidator = _activeValidators[lastIndex];
            _activeValidators[index] = lastValidator;
            _validatorIndex[lastValidator] = index;
        }
        
        _activeValidators.pop();
        delete _validatorIndex[attester];
        _isActiveValidator[attester] = false;
    }
}

function getActiveValidatorCount() external view returns (uint256) {
    return _activeValidators.length;
}
```

### Step 4: Add New Error

Add to interface:

```solidity
error StakingManager__InsufficientAmount();
```

### Step 5: Update Tests

Add to `StakingManager.t.sol`:

```solidity
/*//////////////////////////////////////////////////////////////
                        STAKE FLOW TESTS
//////////////////////////////////////////////////////////////*/

function test_Stake_RoutesAssetsToRollup() external {
    // Setup: add keys and fund core
    IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
    vm.prank(providerAdmin);
    stakingManager.addKeysToProvider(keys);

    uint256 stakeAmount = ACTIVATION_THRESHOLD * 2;
    aztec.mint(core, stakeAmount);

    vm.startPrank(core);
    aztec.approve(address(stakingManager), stakeAmount);
    stakingManager.stake(stakeAmount);
    vm.stopPrank();

    // Verify
    assertEq(stakingManager.totalStaked(), stakeAmount);
    assertEq(stakingManager.getQueueLength(), 0); // keys consumed
    assertEq(stakingManager.getActiveValidatorCount(), 2);
}

function test_Stake_ReturnsExcessToCore() external {
    // Setup: add 1 key, try to stake for 2
    IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
    vm.prank(providerAdmin);
    stakingManager.addKeysToProvider(keys);

    uint256 stakeAmount = ACTIVATION_THRESHOLD * 2;
    aztec.mint(core, stakeAmount);

    uint256 coreBalanceBefore = aztec.balanceOf(core);

    vm.startPrank(core);
    aztec.approve(address(stakingManager), stakeAmount);
    stakingManager.stake(stakeAmount);
    vm.stopPrank();

    // Verify: only 1 validator staked, excess returned
    assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD);
    assertEq(aztec.balanceOf(core), coreBalanceBefore - ACTIVATION_THRESHOLD);
}

function test_RevertWhen_StakeWithNoKeys() external {
    uint256 stakeAmount = ACTIVATION_THRESHOLD;
    aztec.mint(core, stakeAmount);

    vm.startPrank(core);
    aztec.approve(address(stakingManager), stakeAmount);
    vm.expectRevert(IStakingManager.StakingManager__InsufficientKeys.selector);
    stakingManager.stake(stakeAmount);
    vm.stopPrank();
}

function test_RevertWhen_StakeAmountBelowThreshold() external {
    IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
    vm.prank(providerAdmin);
    stakingManager.addKeysToProvider(keys);

    uint256 stakeAmount = ACTIVATION_THRESHOLD - 1;
    aztec.mint(core, stakeAmount);

    vm.startPrank(core);
    aztec.approve(address(stakingManager), stakeAmount);
    vm.expectRevert(IStakingManager.StakingManager__InsufficientAmount.selector);
    stakingManager.stake(stakeAmount);
    vm.stopPrank();
}

function test_Stake_EmitsEvent() external {
    IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
    vm.prank(providerAdmin);
    stakingManager.addKeysToProvider(keys);

    uint256 stakeAmount = ACTIVATION_THRESHOLD;
    aztec.mint(core, stakeAmount);

    vm.startPrank(core);
    aztec.approve(address(stakingManager), stakeAmount);
    
    vm.expectEmit(true, true, true, true);
    emit StakedWithProvider(keys[0].attester, ACTIVATION_THRESHOLD);
    
    stakingManager.stake(stakeAmount);
    vm.stopPrank();
}
```

## Test Cases from Issue #12

- [x] Valid stake updates totals
- [x] Zero stake reverts
- [x] Event emitted

## Acceptance Criteria

- [x] Deterministic state updates

## Notes from Issue

- Reentrancy safe (using ReentrancyGuard)

## Verification

```bash
# Run stake-specific tests
forge test --match-test "test_Stake" -vvv

# Run all StakingManager tests
forge test --match-contract StakingManagerTest -vvv
```
