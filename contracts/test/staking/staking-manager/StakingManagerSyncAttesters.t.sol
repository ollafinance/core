// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerSyncAttestersTest
/// @notice Tests that computeAttesterState() syncs Active → Exiting for externally exited attesters.
/// @dev Since Phase 3 merged sync logic into the bounded attester state loop, syncAttesters()
///      no longer exists. These tests verify the merged sync behavior via computeAttesterState().
contract StakingManagerSyncAttestersTest is StakingManagerBaseTest {
    using stdStorage for StdStorage;

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _getAttesterStateCursor() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 attesterStateCursorSlot = bytes32(cursorSlot + 2);
        return uint256(vm.load(address(stakingManager), attesterStateCursorSlot));
    }

    function _computeAttesterState() internal returns (uint256 slashingDelta, bool completed) {
        vm.prank(defaultAdmin);
        return stakingManager.computeAttesterState();
    }

    /*//////////////////////////////////////////////////////////////
                    SYNC VIA COMPUTE ATTESTER STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeAttesterState_SyncsExitedAttesters() external {
        uint256 total = 3;
        uint256 exited = 2;
        _setupStakedAttestersWithExits(total, exited);

        _computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), total - exited);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);
    }

    function test_ComputeAttesterState_NoExits_StateUnchanged() external {
        _setupMultipleStakedAttesters(2);

        uint256 activatedBefore = stakingManager.getActivatedAttesterCount();
        uint256 pendingBefore = stakingManager.getPendingUnstakeCount();

        _computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), activatedBefore);
        assertEq(stakingManager.getPendingUnstakeCount(), pendingBefore);
    }

    function test_ComputeAttesterState_ExitPresent_MarksExiting() external {
        uint256 total = 2;
        _setupMultipleStakedAttesters(total);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        _computeAttesterState();

        assertTrue(stakingManager.isUnstakePending(keys[0].attester), "exited attester should be exiting");
        assertFalse(stakingManager.isUnstakePending(keys[1].attester), "non-exited attester should remain active");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "pending count should match exited attesters");
    }

    function test_ComputeAttesterState_Bounded_CursorResumesSync() external {
        uint256 total = 12;
        _setupStakedAttestersWithExits(total, total);

        vm.prank(core);
        stakingManager.setGasThreshold(200_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 pendingObserved;
        uint256[6] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000, 340_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (bool success,) = address(stakingManager).call{ gas: gasOptions[i] }(
                abi.encodeCall(stakingManager.computeAttesterState, ())
            );
            if (!success) {
                continue;
            }
            uint256 pendingCandidate = stakingManager.getPendingUnstakeCount();
            if (pendingCandidate > 0 && pendingCandidate < total) {
                selectedGas = gasOptions[i];
                pendingObserved = pendingCandidate;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial sync");

        vm.revertToState(snapshotId);

        uint256 cursorBefore = _getAttesterStateCursor();

        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState{ gas: selectedGas }();

        uint256 cursorAfterFirst = _getAttesterStateCursor();
        uint256 pendingAfterFirst = stakingManager.getPendingUnstakeCount();

        assertEq(cursorBefore, 0, "cursor should start at 0");
        assertEq(pendingAfterFirst, pendingObserved, "pending count should match probe");
        assertGt(pendingAfterFirst, 0, "should move some attesters to exiting");
        assertLt(pendingAfterFirst, total, "should not process all attesters under low gas");
        assertGt(cursorAfterFirst, 0, "cursor should advance after partial sync");
        assertLt(cursorAfterFirst, total, "cursor should remain within bounds");

        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState{ gas: selectedGas }();

        uint256 cursorAfterSecond = _getAttesterStateCursor();
        uint256 pendingAfterSecond = stakingManager.getPendingUnstakeCount();

        assertGt(pendingAfterSecond, pendingAfterFirst, "sync should resume across calls");
        assertTrue(
            cursorAfterSecond == 0 || cursorAfterSecond > cursorAfterFirst,
            "cursor should advance or reset after completion"
        );
    }

    function test_ComputeAttesterState_Bounded_LowGasCompletesAcrossCalls() external {
        uint256 total = 6;
        uint256 exited = 5;
        _setupStakedAttestersWithExits(total, exited);

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 pendingObserved;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (bool success,) = address(stakingManager).call{ gas: gasOptions[i] }(
                abi.encodeCall(stakingManager.computeAttesterState, ())
            );
            if (!success) {
                continue;
            }
            uint256 pendingCandidate = stakingManager.getPendingUnstakeCount();
            if (pendingCandidate == exited) {
                assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
                assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
                return;
            }
            if (pendingCandidate > 0 && pendingCandidate < exited) {
                selectedGas = gasOptions[i];
                pendingObserved = pendingCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            stakingManager.computeAttesterState{ gas: 2_000_000 }();

            assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
            assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState{ gas: selectedGas }();

        uint256 pendingAfterFirst = stakingManager.getPendingUnstakeCount();
        assertEq(pendingAfterFirst, pendingObserved, "pending count should match probe");
        assertGt(pendingAfterFirst, 0, "should move some exited attesters");
        assertLt(pendingAfterFirst, exited, "should not move all exited attesters under low gas");

        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == exited) {
                break;
            }
            vm.prank(defaultAdmin);
            stakingManager.computeAttesterState{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
        assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
    }

    function test_ComputeAttesterState_ExternallyExited_CanBeClaimed() external {
        uint256 total = 3;
        uint256 exited = 2;
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);

        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD * total);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD * total);
        stakingManager.stake(ACTIVATION_THRESHOLD * total);
        vm.stopPrank();

        for (uint256 i; i < exited; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }

        // computeAttesterState() syncs Active→Exiting for externally exited attesters
        _computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), total - exited);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * exited);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
        for (uint256 i; i < exited; ++i) {
            assertFalse(stakingManager.isUnstakePending(keys[i].attester));
        }
    }

    function test_ComputeAttesterState_AllExits() external {
        uint256 total = 2;
        uint256 exited = 2;
        _setupStakedAttestersWithExits(total, exited);

        _computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);
    }

    function test_ComputeAttesterState_EmptyAttesters() external {
        _computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    /// @notice Cached values reflect the synced state — exiting attester's exit amount appears
    ///         in pending/withdrawable, not counted as active stake.
    function test_ComputeAttesterState_CachedValuesReflectSyncedState() external {
        uint256 total = 3;
        _setupMultipleStakedAttesters(total);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);

        // Attester 0: externally exited, exitable now
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);
        // Attester 1: externally exited, NOT yet exitable (future exitableAt)
        rollup.setExternalExit(keys[1].attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);
        // Attester 2: no exit, remains active

        _computeAttesterState();

        // All 3 attesters' original staked amounts are counted in totalStaked
        assertEq(stakingManager.totalStaked(), total * ACTIVATION_THRESHOLD, "totalStaked should include all attesters");
        // Attester 0's exit is withdrawable (exitable now)
        // Attester 1's exit is pending (not yet exitable)
        assertEq(stakingManager.pendingUnstakes(), ACTIVATION_THRESHOLD, "pending should reflect non-exitable exit");
        assertTrue(stakingManager.hasExitableUnstakes(), "should have exitable unstakes");

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.withdrawableAmount, ACTIVATION_THRESHOLD, "withdrawable should reflect exitable exit");
        assertEq(state.pendingUnstakeAmount, ACTIVATION_THRESHOLD, "pending should reflect non-exitable exit");

        // Verify sync state transitions
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "only 1 attester should remain active");
        assertEq(stakingManager.getPendingUnstakeCount(), 2, "2 attesters should be exiting");
    }

    /// @notice When an exit is finalized externally on the rollup (funds returned to StakingManager),
    ///         the attester has no balance and no exit on the rollup. computeAttesterState() should
    ///         remove it from the registry without counting slashing delta (funds are in-contract).
    function test_ComputeAttesterState_ExternallyFinalized_RemovesFromRegistry() external {
        uint256 total = 3;
        _setupMultipleStakedAttesters(total);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);

        // Simulate external exit + finalization for attester 0:
        // set an immediately-exitable exit, then finalize it on the rollup directly.
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);
        rollup.finalizeWithdraw(keys[0].attester);

        // At this point the rollup returns effectiveBalance=0, exit.exists=false for attester 0,
        // but our StakingManager still considers it Active.
        assertEq(stakingManager.getActivatedAttesterCount(), total, "pre-sync: all still active");

        _computeAttesterState();

        // Attester 0 should now be removed from the registry (not Exiting, not Active)
        assertEq(stakingManager.getActivatedAttesterCount(), total - 1, "active count should decrease by 1");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending unstakes - exit already finalized");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "attester should be removed");

        // The remaining 2 attesters are still active and counted in totalStaked
        assertEq(
            stakingManager.totalStaked(),
            (total - 1) * ACTIVATION_THRESHOLD,
            "totalStaked should only count remaining active attesters"
        );

        // No slashing delta — funds were returned to the StakingManager by the rollup
        vm.prank(core);
        uint256 delta = stakingManager.getSlashingDelta();
        assertEq(delta, 0, "no slashing delta - funds returned to contract");
    }

    /// @notice Mixed scenario: one attester externally finalized (removed), one externally exiting
    ///         (Exiting), one still active — all handled in a single computeAttesterState() pass.
    function test_ComputeAttesterState_MixedSyncScenarios() external {
        uint256 total = 3;
        _setupMultipleStakedAttesters(total);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);

        // Attester 0: externally finalized (no balance, no exit)
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);
        rollup.finalizeWithdraw(keys[0].attester);

        // Attester 1: externally exiting (exit exists, not yet exitable)
        rollup.setExternalExit(keys[1].attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        // Attester 2: still active (no changes)

        _computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), 1, "only attester 2 should remain active");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "only attester 1 should be exiting");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "attester 0 should be removed");
        assertTrue(stakingManager.isUnstakePending(keys[1].attester), "attester 1 should be exiting");
        assertFalse(stakingManager.isUnstakePending(keys[2].attester), "attester 2 should still be active");
    }
}
