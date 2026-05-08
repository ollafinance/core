// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { Exit } from "src/staking/libraries/AztecTypes.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerQueuedSlashTest
/// @notice Verifies that a Queued attester slashed on the rollup before being promoted to Active
///         is correctly reconciled by refreshAttesterState. Covers two scenarios: a partial slash
///         that leaves the attester VALIDATING with a reduced effectiveBalance, and a slash with
///         a residual exit that puts the attester in ZOMBIE status on the rollup.
contract StakingManagerQueuedSlashTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
        QUEUED -> VALIDATING WITH REDUCED EFFECTIVE BALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice A Queued attester that the rollup reports as VALIDATING with effectiveBalance below
    ///         the originally staked amount (partial slash before activation snapshot) is promoted
    ///         to Active and the slash loss is reflected in stakedAmount and slashingDelta.
    function test_RefreshQueuedAttesterSlashedToValidating() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);
        address attester = attesters[0];

        // Sanity: attester is Queued with full stake recorded on the aggregate.
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "pre: attester should be Queued, not Active");

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();
        assertEq(stateBefore.stakedAmount, ACTIVATION_THRESHOLD, "pre: stakedAmount = threshold");
        assertEq(stateBefore.slashingDelta, 0, "pre: slashingDelta = 0");
        assertEq(stateBefore.pendingUnstakeAmount, 0, "pre: pendingUnstakeAmount = 0");
        assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD, "pre: totalStaked = threshold");

        // Rollup partially slashes the attester before flushing them out of the entry queue.
        // Status remains VALIDATING (effectiveBalance > localEjectionThreshold) but balance is reduced.
        uint256 slashedBalance = ACTIVATION_THRESHOLD * 60 / 100;
        uint256 slashLoss = ACTIVATION_THRESHOLD - slashedBalance;
        rollup.setStake(attester, slashedBalance, address(stakingManager));

        // Refresh promotes Queued -> Active and reconciles the partial slash.
        stakingManager.refreshAttesterState(attesters);

        // Local status: Active.
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester should be promoted to Active");
        assertFalse(stakingManager.isUnstakePending(attester), "attester should not be Exiting");

        // Aggregate accounting: stakedAmount decreased by the slash loss, slashingDelta tracks it.
        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, slashedBalance, "stakedAmount should reflect post-slash balance");
        assertEq(stateAfter.slashingDelta, slashLoss, "slashingDelta should equal the slash loss");
        assertEq(stateAfter.pendingUnstakeAmount, 0, "pendingUnstakeAmount should remain 0");

        // totalStaked() reports post-slash reality with no inflation.
        assertEq(stakingManager.totalStaked(), slashedBalance, "totalStaked should equal post-slash balance");
    }

    /*//////////////////////////////////////////////////////////////
        QUEUED -> ZOMBIE EXIT WITH RESIDUAL AMOUNT
    //////////////////////////////////////////////////////////////*/

    /// @notice A Queued attester that the rollup slashes with a residual exit (ZOMBIE status) is
    ///         transitioned to Exiting locally, the zombie exit is claimed by StakingManager, and
    ///         the slash loss plus residual exit are reflected in the aggregate accounting.
    function test_RefreshQueuedAttesterSlashedToZombie() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);
        address attester = attesters[0];

        // Sanity: attester is Queued with full stake recorded on the aggregate.
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "pre: attester should be Queued, not Active");

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();
        assertEq(stateBefore.stakedAmount, ACTIVATION_THRESHOLD, "pre: stakedAmount = threshold");
        assertEq(stateBefore.slashingDelta, 0, "pre: slashingDelta = 0");
        assertEq(stateBefore.pendingUnstakeAmount, 0, "pre: pendingUnstakeAmount = 0");
        assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD, "pre: totalStaked = threshold");

        // Rollup slashes the attester with a residual exit, leaving them in ZOMBIE status
        // (exit.exists == true && exit.isRecipient == false). exitableAt is in the future so the
        // exit cannot be finalized in the same refresh.
        uint256 residualExitAmount = ACTIVATION_THRESHOLD * 40 / 100;
        uint256 expectedSlashingDelta = ACTIVATION_THRESHOLD - residualExitAmount;
        rollup.setExternalExit(attester, residualExitAmount, block.timestamp + 1 days);

        // Verify the rollup view describes a zombie exit before refresh.
        Exit memory exitOnRollupBefore = rollup.getExit(attester);
        assertTrue(exitOnRollupBefore.exists, "pre: rollup exit should exist");
        assertFalse(exitOnRollupBefore.isRecipient, "pre: rollup exit should be a zombie (isRecipient=false)");
        assertEq(exitOnRollupBefore.amount, residualExitAmount, "pre: rollup exit amount = residual");

        // Refresh transitions Queued -> Exiting, claims the zombie, and reconciles accounting.
        stakingManager.refreshAttesterState(attesters);

        // Local status: Exiting.
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "no active attesters");
        assertTrue(stakingManager.isUnstakePending(attester), "attester should be locally Exiting");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "should have 1 pending unstake");

        // Zombie was claimed: rollup exit now has isRecipient=true and recipient=StakingManager.
        Exit memory exitOnRollupAfter = rollup.getExit(attester);
        assertTrue(exitOnRollupAfter.exists, "rollup exit should still exist after claim");
        assertTrue(exitOnRollupAfter.isRecipient, "exit should be claimed (isRecipient=true)");
        assertEq(
            exitOnRollupAfter.recipientOrWithdrawer, address(stakingManager), "exit recipient should be StakingManager"
        );
        assertEq(exitOnRollupAfter.amount, residualExitAmount, "exit amount should remain at residual");

        // Aggregate accounting: stakedAmount cleared, pendingUnstakeAmount tracks residual,
        // slashingDelta tracks the slash loss (originalStake - residualExitAmount).
        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, 0, "stakedAmount should be 0 after exit");
        assertEq(stateAfter.pendingUnstakeAmount, residualExitAmount, "pendingUnstakeAmount should equal residual");
        assertEq(stateAfter.slashingDelta, expectedSlashingDelta, "slashingDelta should equal originalStake - residual");

        // info.pendingExitAmount equals the residual: with a single exiting attester, the aggregate
        // pendingUnstakeAmount is exactly that attester's pendingExitAmount snapshot.
        assertEq(
            stateAfter.pendingUnstakeAmount,
            residualExitAmount,
            "info.pendingExitAmount should equal residual exit amount"
        );

        // totalStaked() reflects post-slash, post-exit-snapshot reality:
        // 0 stakedAmount + residual pendingUnstakeAmount + 0 pendingClaim = residualExitAmount.
        assertEq(stakingManager.totalStaked(), residualExitAmount, "totalStaked should equal residual exit amount");
    }
}
