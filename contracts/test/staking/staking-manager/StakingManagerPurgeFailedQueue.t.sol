// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerPurgeFailedQueueTest
/// @notice Tests for purgeFailedQueueEntry(), which recovers from attesters whose deposit
///         was accepted by the rollup's entry queue but failed during flushEntryQueue().
///         On the real Aztec rollup, this happens ~1.5% of the time (87/5900 deposits on mainnet)
///         due to invalid BLS proofs, duplicate keys, or re-queuing already-registered attesters.
///         The function is permissionless: it verifies the attester is NONE on the rollup AND
///         not present in the entry queue before allowing the purge.
contract StakingManagerPurgeFailedQueueTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FailedQueueEntryPurged(address indexed attester, uint256 indexed recoveredAmount);

    /*//////////////////////////////////////////////////////////////
        SUCCESSFUL PURGE — ACTIVE ATTESTER WITH NONE ON ROLLUP
    //////////////////////////////////////////////////////////////*/

    /// @notice When an Active attester has Status.NONE on the rollup and is not in the entry
    ///         queue (flush failed), anyone can purge it. stakedAmount is corrected.
    function test_PurgeFailedQueueEntry_CleansUpStuckAttester() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);
        address attester = attesters[0];

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();
        assertEq(stateBefore.stakedAmount, ACTIVATION_THRESHOLD, "pre: stakedAmount = threshold");

        // Simulate failed queue flush: clear from rollup entirely
        rollup.clearAttester(attester);
        rollup.setStake(attester, 0, address(0));

        vm.expectEmit(true, true, false, false, address(stakingManager));
        emit FailedQueueEntryPurged(attester, ACTIVATION_THRESHOLD);

        // Anyone can call — using alice (not admin, not core)
        vm.prank(alice);
        stakingManager.purgeFailedQueueEntry(attester);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, 0, "stakedAmount should be 0 after purge");
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "no active attesters");
    }

    /// @notice Purge one stuck attester among multiple healthy ones.
    function test_PurgeFailedQueueEntry_OnlyAffectsTargetAttester() external {
        _setupMultipleStakedAttesters(3);
        address[] memory attesters = _attesterAddresses(3);
        address stuckAttester = attesters[0];

        rollup.clearAttester(stuckAttester);
        rollup.setStake(stuckAttester, 0, address(0));

        stakingManager.purgeFailedQueueEntry(stuckAttester);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * 2, "2 healthy attesters remain");
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "2 active attesters");
    }

    /// @notice After purging, the refunded tokens in StakingManager are swept by getUnstakedFunds().
    function test_PurgeFailedQueueEntry_RefundedTokensSwept() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);
        address attester = attesters[0];

        rollup.clearAttester(attester);
        rollup.setStake(attester, 0, address(0));
        aztec.mint(address(stakingManager), ACTIVATION_THRESHOLD);

        stakingManager.purgeFailedQueueEntry(attester);

        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, ACTIVATION_THRESHOLD, "refunded tokens swept");
        assertEq(exitAmount, 0, "no exit was finalized, so exitAmount is 0");
    }

    /*//////////////////////////////////////////////////////////////
                    REVERT CASES — INVALID PURGE TARGETS
    //////////////////////////////////////////////////////////////*/

    /// @notice Purging a non-existent attester reverts.
    function test_RevertWhen_PurgeFailedQueueEntry_UnknownAttester() external {
        address unknown = makeAddr("unknown");

        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__NotFailedQueueEntry.selector, unknown));
        stakingManager.purgeFailedQueueEntry(unknown);
    }

    /// @notice Purging an Exiting attester reverts (not Active).
    function test_RevertWhen_PurgeFailedQueueEntry_ExitingAttester() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__NotFailedQueueEntry.selector, attesters[0])
        );
        stakingManager.purgeFailedQueueEntry(attesters[0]);
    }

    /// @notice Purging a healthy VALIDATING attester reverts.
    function test_RevertWhen_PurgeFailedQueueEntry_HealthyActiveAttester() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__NotFailedQueueEntry.selector, attesters[0])
        );
        stakingManager.purgeFailedQueueEntry(attesters[0]);
    }

    /// @notice Purging an attester with an exit on the rollup reverts.
    function test_RevertWhen_PurgeFailedQueueEntry_AttesterWithExit() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);

        rollup.setExternalExit(attesters[0], ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__NotFailedQueueEntry.selector, attesters[0])
        );
        stakingManager.purgeFailedQueueEntry(attesters[0]);
    }

    /*//////////////////////////////////////////////////////////////
             ENTRY QUEUE PROTECTION — STILL QUEUED REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice An attester still in the rollup's entry queue (waiting for flush) cannot be purged.
    ///         The on-chain queue scan distinguishes "queued" from "flush-failed".
    function test_RevertWhen_PurgeFailedQueueEntry_AttesterStillInQueue() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);
        address attester = attesters[0];

        // Simulate: attester is NONE on rollup (not yet flushed) but IS in the entry queue
        rollup.clearAttester(attester);
        rollup.setStake(attester, 0, address(0));
        rollup.addToEntryQueue(attester);

        // Purge should revert — attester is still queued, not failed
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__NotFailedQueueEntry.selector, attester));
        stakingManager.purgeFailedQueueEntry(attester);
    }

    /// @notice After the queue is cleared (flush happened and failed), the purge succeeds.
    function test_PurgeFailedQueueEntry_SucceedsAfterQueueCleared() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);
        address attester = attesters[0];

        // Simulate: attester was in queue, then flush happened and failed, queue entry removed
        rollup.clearAttester(attester);
        rollup.setStake(attester, 0, address(0));
        rollup.addToEntryQueue(attester);

        // Can't purge while in queue
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__NotFailedQueueEntry.selector, attester));
        stakingManager.purgeFailedQueueEntry(attester);

        // Queue is cleared (flush processed and failed)
        rollup.clearEntryQueue();

        // Now purge succeeds
        stakingManager.purgeFailedQueueEntry(attester);

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "purged after queue cleared");
    }

    /// @notice Queue scan works correctly with multiple entries — only blocks if the target is found.
    function test_PurgeFailedQueueEntry_QueueScanIgnoresOtherEntries() external {
        _setupMultipleStakedAttesters(2);
        address[] memory attesters = _attesterAddresses(2);

        // Simulate: attester[0] flush failed, attester[1] is still queued on rollup
        rollup.clearAttester(attesters[0]);
        rollup.setStake(attesters[0], 0, address(0));
        rollup.clearAttester(attesters[1]);
        rollup.setStake(attesters[1], 0, address(0));

        // Only attester[1] is in the queue
        rollup.addToEntryQueue(attesters[1]);

        // Purge attester[0] succeeds (not in queue)
        stakingManager.purgeFailedQueueEntry(attesters[0]);
        // attester[1] still in registry as Active (even though NONE on rollup, it's still in queue)
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester[0] purged, attester[1] still active");

        // Purge attester[1] reverts (still in queue)
        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__NotFailedQueueEntry.selector, attesters[1])
        );
        stakingManager.purgeFailedQueueEntry(attesters[1]);
    }
}
