// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { Exit } from "src/staking/libraries/AztecTypes.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerSlashDuringUnstakeTest
/// @notice Verifies behavior when an attester's exit amount is reduced (slashed) while
///         the attester is already in the Exiting state. Per the StakingManager design,
///         slashingDelta does NOT capture losses for already-exiting attesters; the loss
///         manifests as fewer tokens received on finalization vs the pendingExitAmount.
contract StakingManagerSlashDuringUnstakeTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
     TEST 1: SLASH DURING PENDING UNSTAKE - FEWER TOKENS RECEIVED
    //////////////////////////////////////////////////////////////*/

    /// @notice An attester has a normal unstake in progress (Exiting state). The rollup
    ///         replaces the exit with a claimed exit at a reduced amount (simulating slash
    ///         during unstake). After finalization, the StakingManager receives fewer tokens
    ///         than the original pendingExitAmount.
    function test_SlashDuringUnstake_ReducedExitAmount() external {
        _setupMultipleActiveAttesters(2);
        address[] memory attesters = _attesterAddresses(2);

        // Initiate unstake for one attester
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Find which attester was actually unstaked
        address unstakedAttester;
        address activeAttester;
        if (stakingManager.isUnstakePending(attesters[0])) {
            unstakedAttester = attesters[0];
            activeAttester = attesters[1];
        } else {
            assertTrue(stakingManager.isUnstakePending(attesters[1]), "one attester should be Exiting");
            unstakedAttester = attesters[1];
            activeAttester = attesters[0];
        }

        IStakingManager.StakingState memory stateBeforeSlash = stakingManager.getStakingState();
        assertEq(stateBeforeSlash.pendingUnstakeAmount, ACTIVATION_THRESHOLD, "pending unstake = 100 ether");
        assertEq(stateBeforeSlash.slashingDelta, 0, "pre: no slashing");

        // Simulate slash during unstake: rollup replaces exit with reduced amount.
        // setExternalExit creates a zombie (isRecipient=false), so we also call
        // setExitRecipient to mark it as claimed (isRecipient=true).
        uint256 slashedExitAmount = 60 ether;
        rollup.setExternalExit(unstakedAttester, slashedExitAmount, block.timestamp);
        rollup.setExitRecipient(unstakedAttester, address(stakingManager));

        // Refresh finalizes the exit at the reduced amount
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfterSlash = stakingManager.getStakingState();

        // slashingDelta now captures exit-delay slashes: the difference between
        // pendingExitAmount (snapshot at initiation) and exit.amount (actual on rollup).
        uint256 expectedSlash = ACTIVATION_THRESHOLD - slashedExitAmount;
        assertEq(stateAfterSlash.slashingDelta, expectedSlash, "slashingDelta records exit-delay slash");

        // pendingUnstakeAmount is cleared (the exit was finalized)
        assertEq(stateAfterSlash.pendingUnstakeAmount, 0, "pending unstake cleared after finalization");

        // The active attester should still be staked
        assertFalse(stakingManager.isUnstakePending(activeAttester), "active attester should not be Exiting");

        // Funds are claimable at the reduced (slashed) amount
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, slashedExitAmount, "received should equal slashed exit amount");
        assertEq(exitAmount, slashedExitAmount, "exitAmount should equal slashed exit amount");
    }

    /*//////////////////////////////////////////////////////////////
     TEST 2: SLASH DURING UNSTAKE - MIXED HEALTHY AND SLASHED
    //////////////////////////////////////////////////////////////*/

    /// @notice Two attesters are unstaking. One gets slashed (reduced exit amount), the
    ///         other completes normally. The total received reflects the difference.
    function test_SlashDuringUnstake_MixedHealthyAndSlashed() external {
        uint256 numAttesters = 3;
        _setupMultipleActiveAttesters(numAttesters);
        address[] memory attesters = _attesterAddresses(numAttesters);

        // Unstake 2 attesters
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        // Find the two unstaked attesters and the one still active
        address slashTarget;
        address healthyUnstaked;
        address activeAttester;
        uint256 exitingCount;
        for (uint256 i; i < numAttesters; ++i) {
            if (stakingManager.isUnstakePending(attesters[i])) {
                if (exitingCount == 0) {
                    slashTarget = attesters[i];
                } else {
                    healthyUnstaked = attesters[i];
                }
                exitingCount++;
            } else {
                activeAttester = attesters[i];
            }
        }
        assertEq(exitingCount, 2, "exactly 2 attesters should be Exiting");
        assertTrue(activeAttester != address(0), "one attester should still be Active");

        // Slash the first exiting attester: reduce exit from 100 to 40 ether.
        // setExternalExit creates a zombie, so setExitRecipient marks it as claimed.
        uint256 slashedAmount = 40 ether;
        rollup.setExternalExit(slashTarget, slashedAmount, block.timestamp);
        rollup.setExitRecipient(slashTarget, address(stakingManager));

        // Make the healthy attester's exit exitable (normal, unslashed)
        rollup.setExitReady(healthyUnstaked, block.timestamp);

        // Refresh all attesters
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();

        // slashingDelta captures exit-delay slash: 100 - 40 = 60
        uint256 expectedSlash = ACTIVATION_THRESHOLD - slashedAmount;
        assertEq(state.slashingDelta, expectedSlash, "slashingDelta records exit-delay slash");

        // The active attester should still be staked
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD, "remaining attester still staked");

        // Claim funds: should get 40 (slashed) + 100 (healthy) = 140
        vm.prank(core);
        (uint256 received,) = stakingManager.getUnstakedFunds();
        assertEq(received, slashedAmount + ACTIVATION_THRESHOLD, "received = slashed + healthy exit amounts");
    }
}
