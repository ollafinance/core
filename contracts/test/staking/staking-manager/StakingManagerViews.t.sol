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

    function test_HasFinalizedUnstakes_ReturnsFalseWhenOnlyPending() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Promote Queued -> Active
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        bool hasFinalized = stakingManager.hasFinalizedUnstakes();
        assertFalse(hasFinalized, "hasFinalizedUnstakes should be false with only pending exits");
    }

    function test_HasFinalizedUnstakes_ReturnsFalseBeforeRefresh() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Promote Queued -> Active
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        bool hasFinalized = stakingManager.hasFinalizedUnstakes();
        assertFalse(hasFinalized, "hasFinalizedUnstakes should be false before refresh finalizes exits");
    }

    function test_HasFinalizedUnstakes_ReturnsTrueAfterRefreshFinalizesExit() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Refresh finalizes the exit (mock sets exitableAt to block.timestamp)
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        bool hasFinalized = stakingManager.hasFinalizedUnstakes();
        assertTrue(hasFinalized, "hasFinalizedUnstakes should be true after refresh finalizes an exit");
    }

    function test_HasFinalizedUnstakes_ReturnsFalseAfterClaim() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        stakingManager.refreshAttesterState(_attesterAddresses(1));
        assertTrue(stakingManager.hasFinalizedUnstakes(), "should be true after finalization");

        // Claim resets _pendingClaimAmount
        vm.prank(core);
        stakingManager.getUnstakedFunds();

        assertFalse(stakingManager.hasFinalizedUnstakes(), "should be false after claim drains pending");
    }

    function test_HasFinalizedUnstakes_ReturnsFalseWhenActiveExitNotExitable() external {
        _setupActiveAttester();

        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        bool hasFinalized = stakingManager.hasFinalizedUnstakes();
        assertFalse(hasFinalized, "hasFinalizedUnstakes should be false for active pending exits");
    }

    /*//////////////////////////////////////////////////////////////
                        STAKING STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetStakingState_ReturnsCorrectValuesAfterStake() external {
        _setupMultipleActiveAttesters(3);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * 3);
        assertEq(state.pendingUnstakeAmount, 0);
    }

    function test_GetStakingState_ReturnsCorrectValuesAfterUnstake() external {
        _setupMultipleActiveAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * 1);
        assertEq(state.pendingUnstakeAmount, ACTIVATION_THRESHOLD * 2);
    }

    /*//////////////////////////////////////////////////////////////
                    TOTAL STAKED WITH QUEUED ATTESTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Queued attesters contribute to totalStaked() but not to getActivatedAttesterCount().
    ///         Promoting to Active does not change totalStaked().
    function test_TotalStaked_IncludesQueuedAttesters() external {
        // Stake 2 attesters (both Queued)
        _setupMultipleStakedAttesters(2);

        // Queued attesters contribute to totalStaked
        assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD * 2, "totalStaked includes queued");
        // But are not counted as active
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "queued not counted as active");

        // Promote 1 to Active via refresh
        address[] memory oneAttester = new address[](1);
        oneAttester[0] = address(uint160(1));
        stakingManager.refreshAttesterState(oneAttester);

        // totalStaked unchanged (same amount, different status)
        assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD * 2, "totalStaked unchanged after promotion");
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "1 active after promotion");
    }

    /// @notice totalStaked remains consistent across Queued, Active, and Exiting statuses.
    function test_TotalStaked_ConsistentAcrossQueuedActiveExiting() external {
        // Stake 3 attesters (all Queued)
        _setupMultipleStakedAttesters(3);

        // Promote all to Active
        stakingManager.refreshAttesterState(_attesterAddresses(3));
        assertEq(stakingManager.getActivatedAttesterCount(), 3, "3 active");

        // Unstake 1 (Active -> Exiting)
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // totalStaked = stakedAmount + pendingUnstakeAmount + pendingClaimAmount
        // = 2*THRESHOLD + 1*THRESHOLD + 0 = 3*THRESHOLD
        assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD * 3, "totalStaked includes exiting");
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "2 active after unstake");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "1 exiting after unstake");
    }

    /*//////////////////////////////////////////////////////////////
                    STAKING STATE WITH DELAYED EXIT
    //////////////////////////////////////////////////////////////*/

    function test_GetStakingState_ReturnsCorrectValuesWithDelayedExit() external {
        _setupMultipleActiveAttesters(2);

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
