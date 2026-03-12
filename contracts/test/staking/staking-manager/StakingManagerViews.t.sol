// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerViewsTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                            VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetStakingState_InitiallyZero() external view {
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, 0);
        assertEq(state.pendingUnstakeAmount, 0);
    }

    function test_GetQueueLength_InitiallyZero() external view {
        assertEq(stakingProviderRegistry.getQueueLength(), 0);
    }

    function test_GetActivatedAttesterCount_InitiallyZero() external view {
        assertEq(stakingManager.getActivatedAttesterCount(), 0);
    }

    function test_GetPendingUnstakeCount_InitiallyZero() external view {
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_HasExitableUnstakes_ReturnsFalseWhenOnlyPending() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        bool hasExitable = stakingManager.hasExitableUnstakes();
        assertFalse(hasExitable, "hasExitableUnstakes should be false with only pending exits");
    }

    function test_HasExitableUnstakes_ReturnsFalseBeforeRefresh() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        bool hasExitable = stakingManager.hasExitableUnstakes();
        assertFalse(hasExitable, "hasExitableUnstakes should be false before refresh finalizes exits");
    }

    function test_HasExitableUnstakes_ReturnsTrueAfterRefreshFinalizesExit() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Refresh finalizes the exit (mock sets exitableAt to block.timestamp)
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        bool hasExitable = stakingManager.hasExitableUnstakes();
        assertTrue(hasExitable, "hasExitableUnstakes should be true after refresh finalizes an exit");
    }

    function test_HasExitableUnstakes_ReturnsFalseAfterClaim() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        stakingManager.refreshAttesterState(_attesterAddresses(1));
        assertTrue(stakingManager.hasExitableUnstakes(), "should be true after finalization");

        // Claim resets _pendingClaimAmount
        vm.prank(core);
        stakingManager.getUnstakedFunds();

        assertFalse(stakingManager.hasExitableUnstakes(), "should be false after claim drains pending");
    }

    function test_HasExitableUnstakes_ReturnsFalseWhenActiveExitNotExitable() external {
        _setupStakedAttester();

        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        bool hasExitable = stakingManager.hasExitableUnstakes();
        assertFalse(hasExitable, "hasExitableUnstakes should be false for active pending exits");
    }

    /*//////////////////////////////////////////////////////////////
                        STAKING STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetStakingState_ReturnsCorrectValuesAfterStake() external {
        _setupMultipleStakedAttesters(3);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * 3);
        assertEq(state.pendingUnstakeAmount, 0);
    }

    function test_GetStakingState_ReturnsCorrectValuesAfterUnstake() external {
        _setupMultipleStakedAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * 1);
        assertEq(state.pendingUnstakeAmount, ACTIVATION_THRESHOLD * 2);
    }

    function test_GetStakingState_ReturnsCorrectValuesWithDelayedExit() external {
        _setupMultipleStakedAttesters(2);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Set exit to be in the future for the attester that was unstaked
        // The unstake logic picks from the front of the array, so it's keys[0].attester (address(1))
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * 1);
        assertEq(state.pendingUnstakeAmount, ACTIVATION_THRESHOLD);
    }
}
