// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Vm } from "@forge-std/Test.sol";
import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerUnstakedFundsTest is StakingManagerBaseTest {
    using stdStorage for StdStorage;
    /*//////////////////////////////////////////////////////////////
                        GET UNSTAKED FUNDS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetUnstakedFunds_ClaimsMaturedWithdrawals() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_GetUnstakedFunds_EmitsEvent() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // UnstakeFinalized is emitted before UnstakedFundsClaimed, so record logs instead
        vm.recordLogs();

        vm.prank(core);
        stakingManager.getUnstakedFunds();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        // Find UnstakedFundsClaimed event (amount is indexed, so it's in topics[1])
        bool foundEvent = false;
        bytes32 expectedSelector = keccak256("UnstakedFundsClaimed(uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == expectedSelector) {
                uint256 amount = uint256(entries[i].topics[1]);
                assertEq(amount, ACTIVATION_THRESHOLD);
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "UnstakedFundsClaimed event not found");
    }

    function test_GetUnstakedFunds_ReturnsZeroWhenNoPending() external {
        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();
        assertEq(claimed, 0);
    }

    function test_GetUnstakedFunds_MultipleAttesters() external {
        _setupMultipleStakedAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 3);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * 3);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD * 3);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_GetUnstakedFunds_PartialExitReadiness_ClaimsOnlyReady() external {
        _setupMultipleStakedAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        // Make attester[0] not yet exitable; attester[1] stays immediately exitable in the mock.
        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 1);
        assertTrue(stakingManager.isUnstakePending(keys[0].attester));
        assertFalse(stakingManager.isUnstakePending(keys[1].attester));

        vm.warp(block.timestamp + 2 days);

        coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
        assertFalse(stakingManager.isUnstakePending(keys[0].attester));
    }

    function test_GetUnstakedFunds_ExternalExitReconciliation() external {
        _setupMultipleStakedAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        uint256 activatedBefore = stakingManager.getActivatedAttesterCount();
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        // computeAttesterState() syncs Active→Exiting for externally exited attesters
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), activatedBefore - 1, "active count should decrease");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "exiting count should increase");
        assertTrue(stakingManager.isUnstakePending(keys[0].attester), "attester should be marked exiting");

        vm.recordLogs();

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundEvent = false;
        bytes32 expectedSelector = keccak256("UnstakedFundsClaimed(uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(stakingManager) && entries[i].topics[0] == expectedSelector) {
                uint256 amount = uint256(entries[i].topics[1]);
                assertEq(amount, ACTIVATION_THRESHOLD, "claimed amount should match exit");
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "UnstakedFundsClaimed event not found");

        assertEq(claimed, ACTIVATION_THRESHOLD, "claimed should equal exited stake");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed, "core should receive claimed funds");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "exited attester should be inactive");
    }

    function test_GetUnstakedFunds_ExternalFinalizeBeforeManagerFinalize() external {
        _setupStakedAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.prank(alice);
        rollup.finalizeWithdraw(keys[0].attester);

        assertEq(
            aztec.balanceOf(address(stakingManager)),
            ACTIVATION_THRESHOLD,
            "manager should receive externally finalized funds"
        );

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD, "claimed should include externally finalized exit");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD, "core should receive funds");
        assertEq(aztec.balanceOf(address(stakingManager)), 0, "manager should not retain funds");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "attester should be inactive");
    }

    function test_GetUnstakedFunds_ExternalFinalize_NoUnstakeFinalizedEvent() external {
        _setupStakedAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.prank(alice);
        rollup.finalizeWithdraw(keys[0].attester);

        vm.recordLogs();

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 unstakeFinalizedSelector = keccak256("UnstakeFinalized(address,uint256)");
        bytes32 unstakedFundsClaimedSelector = keccak256("UnstakedFundsClaimed(uint256)");
        bool foundUnstakeFinalized = false;
        bool foundUnstakedFundsClaimed = false;

        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != address(stakingManager)) {
                continue;
            }
            if (entries[i].topics[0] == unstakeFinalizedSelector) {
                foundUnstakeFinalized = true;
            }
            if (entries[i].topics[0] == unstakedFundsClaimedSelector) {
                uint256 amount = uint256(entries[i].topics[1]);
                assertEq(amount, ACTIVATION_THRESHOLD, "claim event amount should match exit");
                foundUnstakedFundsClaimed = true;
            }
        }

        assertFalse(foundUnstakeFinalized, "should not emit UnstakeFinalized when already finalized");
        assertTrue(foundUnstakedFundsClaimed, "should emit UnstakedFundsClaimed");
        assertEq(claimed, ACTIVATION_THRESHOLD, "claimed should include externally finalized exit");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "attester should be inactive");
    }

    function test_GetUnstakedFunds_SweepsPreExistingBalanceWhenNoPendingExits() external {
        _setupStakedAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.prank(alice);
        rollup.finalizeWithdraw(keys[0].attester);

        vm.prank(core);
        uint256 claimedFirst = stakingManager.getUnstakedFunds();

        assertEq(claimedFirst, ACTIVATION_THRESHOLD, "initial claim should sweep external finalize");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should be cleared");

        vm.prank(core);
        aztec.transfer(address(stakingManager), ACTIVATION_THRESHOLD);

        assertEq(
            aztec.balanceOf(address(stakingManager)), ACTIVATION_THRESHOLD, "manager should hold pre-existing balance"
        );
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending exits before sweep");

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD, "should sweep pre-existing balance");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD, "core should receive sweep");
        assertEq(aztec.balanceOf(address(stakingManager)), 0, "manager should clear balance");
    }

    function test_GetUnstakedFunds_MixedFinalizePaths_SweepsAllFunds() external {
        _setupMultipleStakedAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        vm.prank(bob);
        rollup.finalizeWithdraw(keys[0].attester);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        uint256 expected = ACTIVATION_THRESHOLD * 2;
        assertEq(claimed, expected, "claimed should include external and internal finalizations");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + expected, "core should receive all funds");
        assertEq(aztec.balanceOf(address(stakingManager)), 0, "manager should not retain funds");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "externally finalized attester inactive");
        assertFalse(stakingManager.isUnstakePending(keys[1].attester), "internally finalized attester inactive");
    }

    function test_GetUnstakedFunds_RestakeAfterExit_ReusesEntry() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        stakingManager.getUnstakedFunds();
        vm.stopPrank();

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "attester should be inactive after exit");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after exit");

        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester should be active again");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "attester should not be exiting");
    }

    function test_GetUnstakedFunds_ActivatedExits_PartialFinalizeResetsCursor() external {
        uint256 attesterCount = 6;
        _setupMultipleStakedAttesters(attesterCount);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(attesterCount);

        for (uint256 i; i < attesterCount; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }

        uint256 expectedTotal = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(200_000);

        // computeAttesterState() syncs Active→Exiting for externally exited attesters
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "all exits should move to exiting");
        assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "exiting count should match attesters");

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 claimedObserved;
        uint256[5] memory gasOptions = [uint256(220_000), 260_000, 300_000, 340_000, 380_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.getUnstakedFunds, ()));
            if (!success) {
                continue;
            }
            uint256 claimedCandidate = abi.decode(data, (uint256));
            if (claimedCandidate > 0 && claimedCandidate < expectedTotal) {
                selectedGas = gasOptions[i];
                claimedObserved = claimedCandidate;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial finalize");

        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 finalizeCursorSlot = bytes32(cursorSlot + 1);

        vm.revertToState(snapshotId);
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimedFirst = stakingManager.getUnstakedFunds{ gas: selectedGas }();

        assertEq(claimedFirst, claimedObserved, "claimed amount should match probe");
        assertGt(claimedFirst, 0, "initial claim should return some funds");
        assertLt(claimedFirst, expectedTotal, "initial claim should be partial");
        assertGt(stakingManager.getPendingUnstakeCount(), 0, "exiting attesters should remain after partial claim");

        uint256 totalClaimed = claimedFirst;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == 0) {
                break;
            }
            vm.prank(core);
            totalClaimed += stakingManager.getUnstakedFunds{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "remaining exits should complete across calls");
        assertEq(totalClaimed, expectedTotal, "total claimed should match exits");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + totalClaimed, "core should receive claimed funds");

        uint256 finalizeCursorAfter = uint256(vm.load(address(stakingManager), finalizeCursorSlot));
        assertEq(finalizeCursorAfter, 0, "finalize cursor should reset after completion");
    }

    function test_GetUnstakedFunds_Bounded_LowGasCompletesAcrossCalls() external {
        uint256 attesterCount = 5;
        _setupMultipleStakedAttesters(attesterCount);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * attesterCount);

        uint256 expectedTotal = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 claimedObserved;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.getUnstakedFunds, ()));
            if (!success) {
                continue;
            }
            uint256 claimedCandidate = abi.decode(data, (uint256));
            if (claimedCandidate > 0 && claimedCandidate < expectedTotal) {
                selectedGas = gasOptions[i];
                claimedObserved = claimedCandidate;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial finalize");

        vm.revertToState(snapshotId);
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimedFirst = stakingManager.getUnstakedFunds{ gas: selectedGas }();

        assertEq(claimedFirst, claimedObserved, "claimed amount should match probe");
        assertGt(claimedFirst, 0, "initial claim should return some funds");
        assertLt(claimedFirst, expectedTotal, "initial claim should be bounded under low gas");
        assertGt(stakingManager.getPendingUnstakeCount(), 0, "pending should remain after partial claim");

        uint256 totalClaimed = claimedFirst;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == 0) {
                break;
            }
            vm.prank(core);
            totalClaimed += stakingManager.getUnstakedFunds{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "all pending unstakes should be finalized");
        assertEq(totalClaimed, expectedTotal, "total claimed should match pending exits");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + totalClaimed, "core should receive claimed funds");
    }
}
