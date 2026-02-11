// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerSyncAttestersTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                        SYNC ATTESTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CleanActivatedAttesters_RemovesExitedAttesters() external {
        uint256 total = 3;
        uint256 exited = 2;
        _setupStakedAttestersWithExits(total, exited);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), total - exited);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);
    }

    function test_CleanActivatedAttesters_NoExits() external {
        _setupMultipleStakedAttesters(2);

        uint256 activatedBefore = stakingManager.getActivatedAttesterCount();
        uint256 pendingBefore = stakingManager.getPendingUnstakeCount();

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), activatedBefore);
        assertEq(stakingManager.getPendingUnstakeCount(), pendingBefore);
    }

    function test_CleanActivatedAttesters_ExitPresent_MarksExiting() external {
        uint256 total = 2;
        _setupMultipleStakedAttesters(total);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertTrue(stakingManager.isUnstakePending(keys[0].attester), "exited attester should be exiting");
        assertFalse(stakingManager.isUnstakePending(keys[1].attester), "non-exited attester should remain active");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "pending count should match exited attesters");
    }

    function test_CleanActivatedAttesters_Bounded_ActiveSyncCursorResumes() external {
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
            vm.prank(core);
            (bool success,) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.syncAttesters, ()));
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

        uint256 cursorBefore = _getActiveSyncCursor();

        vm.prank(core);
        stakingManager.syncAttesters{ gas: selectedGas }();

        uint256 cursorAfterFirst = _getActiveSyncCursor();
        uint256 pendingAfterFirst = stakingManager.getPendingUnstakeCount();

        assertEq(cursorBefore, 0, "cursor should start at 0");
        assertEq(pendingAfterFirst, pendingObserved, "pending count should match probe");
        assertGt(pendingAfterFirst, 0, "should move some attesters to exiting");
        assertLt(pendingAfterFirst, total, "should not process all attesters under low gas");
        assertGt(cursorAfterFirst, 0, "cursor should advance after partial sync");
        assertLt(cursorAfterFirst, total, "cursor should remain within bounds");

        vm.prank(core);
        stakingManager.syncAttesters{ gas: selectedGas }();

        uint256 cursorAfterSecond = _getActiveSyncCursor();
        uint256 pendingAfterSecond = stakingManager.getPendingUnstakeCount();

        assertGt(pendingAfterSecond, pendingAfterFirst, "sync should resume across calls");
        assertTrue(
            cursorAfterSecond == 0 || cursorAfterSecond > cursorAfterFirst,
            "cursor should advance or reset after completion"
        );
    }

    function test_CleanActivatedAttesters_NoActive_ResetsActiveSyncCursor() external {
        _setActiveSyncCursor(7);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(_getActiveSyncCursor(), 0, "cursor should reset when no active attesters");
    }

    function test_CleanActivatedAttesters_Bounded_LowGasCompletesAcrossCalls() external {
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
            vm.prank(core);
            (bool success,) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.syncAttesters, ()));
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
            vm.prank(core);
            stakingManager.syncAttesters{ gas: 2_000_000 }();

            assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
            assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(core);
        stakingManager.syncAttesters{ gas: selectedGas }();

        uint256 pendingAfterFirst = stakingManager.getPendingUnstakeCount();
        assertEq(pendingAfterFirst, pendingObserved, "pending count should match probe");
        assertGt(pendingAfterFirst, 0, "should move some exited attesters");
        assertLt(pendingAfterFirst, exited, "should not move all exited attesters under low gas");

        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == exited) {
                break;
            }
            vm.prank(core);
            stakingManager.syncAttesters{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
        assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
    }

    function test_CleanActivatedAttesters_ExternallyExited_CanBeClaimed() external {
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

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), total - exited);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * exited);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
        for (uint256 i; i < exited; ++i) {
            assertFalse(stakingManager.isUnstakePending(keys[i].attester));
        }
    }

    function test_CleanActivatedAttesters_AllExits() external {
        uint256 total = 2;
        uint256 exited = 2;
        _setupStakedAttestersWithExits(total, exited);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);
    }

    function test_CleanActivatedAttesters_EmptyActivated() external {
        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_RevertWhen_CleanActivatedAttesters_Unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        stakingManager.syncAttesters();
    }
}
