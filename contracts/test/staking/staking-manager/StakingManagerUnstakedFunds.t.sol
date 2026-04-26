// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Vm } from "@forge-std/Test.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerUnstakedFundsTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                        GET UNSTAKED FUNDS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetUnstakedFunds_ClaimsMaturedWithdrawals() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_GetUnstakedFunds_EmitsEvent() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // Record logs to capture UnstakedFundsClaimed from getUnstakedFunds
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
        (uint256 claimed,) = stakingManager.getUnstakedFunds();
        assertEq(claimed, 0);
    }

    function test_GetUnstakedFunds_MultipleAttesters() external {
        _setupMultipleActiveAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 3);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        stakingManager.refreshAttesterState(_attesterAddresses(3));

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * 3);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD * 3);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_GetUnstakedFunds_PartialExitReadiness_ClaimsOnlyReady() external {
        _setupMultipleActiveAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        // Make attester[0] not yet exitable; attester[1] stays immediately exitable in the mock.
        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        stakingManager.refreshAttesterState(_attesterAddresses(2));

        assertEq(stakingManager.getPendingUnstakeCount(), 1);
        assertTrue(stakingManager.isUnstakePending(keys[0].attester));
        assertFalse(stakingManager.isUnstakePending(keys[1].attester));

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);

        vm.warp(block.timestamp + 2 days);

        stakingManager.refreshAttesterState(_attesterAddresses(2));

        coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        (claimed,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
        assertFalse(stakingManager.isUnstakePending(keys[0].attester));
    }

    function test_GetUnstakedFunds_ExternalExitReconciliation() external {
        // Scenario: An attester is unstaked via unstake(), then someone externally
        // calls rollup.finalizeWithdraw() before the StakingManager does. When
        // refreshAttesterState() is called, it detects the exit was already finalized
        // (exit no longer exists on rollup) and removes the attester. The funds
        // that were sent to the StakingManager by the external finalization are
        // then swept to core via getUnstakedFunds().
        _setupMultipleActiveAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        // Unstake one attester through the StakingManager
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        assertEq(stakingManager.getActivatedAttesterCount(), 1, "active count should decrease after unstake");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "exiting count should increase after unstake");

        // Find which attester was unstaked (unstake iterates from end)
        address unstakedAttester = keys[1].attester;
        assertTrue(stakingManager.isUnstakePending(unstakedAttester), "attester should be marked exiting");

        // External party finalizes the withdraw on the rollup directly
        vm.prank(alice);
        rollup.finalizeWithdraw(unstakedAttester);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        // refreshAttesterState detects the exit was already finalized and removes the attester
        stakingManager.refreshAttesterState(_attesterAddresses(2));

        vm.recordLogs();

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

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
        assertFalse(stakingManager.isUnstakePending(unstakedAttester), "exited attester should be inactive");
    }

    function test_GetUnstakedFunds_ExternalFinalizeBeforeManagerFinalize() external {
        _setupActiveAttester();
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

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD, "claimed should include externally finalized exit");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD, "core should receive funds");
        assertEq(aztec.balanceOf(address(stakingManager)), 0, "manager should not retain funds");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "attester should be inactive");
    }

    function test_GetUnstakedFunds_ExternalFinalize_NoUnstakeFinalizedEvent() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.prank(alice);
        rollup.finalizeWithdraw(keys[0].attester);

        vm.recordLogs();

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

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

    function test_GetUnstakedFunds_DoesNotSweepUnaccountedBalanceWhenNoPendingExits() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.prank(alice);
        rollup.finalizeWithdraw(keys[0].attester);

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should be cleared");

        vm.prank(core);
        (uint256 claimedFirst,) = stakingManager.getUnstakedFunds();

        assertEq(claimedFirst, ACTIVATION_THRESHOLD, "initial claim should sweep external finalize");

        vm.prank(core);
        aztec.transfer(address(stakingManager), ACTIVATION_THRESHOLD);

        assertEq(
            aztec.balanceOf(address(stakingManager)), ACTIVATION_THRESHOLD, "manager should hold pre-existing balance"
        );
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending exits before sweep");

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, 0, "should not sweep unaccounted balance");
        assertEq(aztec.balanceOf(core), coreBalanceBefore, "core should not receive unaccounted funds");
        assertEq(
            aztec.balanceOf(address(stakingManager)), ACTIVATION_THRESHOLD, "manager should retain unaccounted funds"
        );
    }

    function test_GetUnstakedFunds_MixedFinalizePaths_SweepsAllFunds() external {
        _setupMultipleActiveAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        vm.prank(bob);
        rollup.finalizeWithdraw(keys[0].attester);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        stakingManager.refreshAttesterState(_attesterAddresses(2));

        vm.prank(core);
        (uint256 claimed,) = stakingManager.getUnstakedFunds();

        uint256 expected = ACTIVATION_THRESHOLD * 2;
        assertEq(claimed, expected, "claimed should include external and internal finalizations");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + expected, "core should receive all funds");
        assertEq(aztec.balanceOf(address(stakingManager)), 0, "manager should not retain funds");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "externally finalized attester inactive");
        assertFalse(stakingManager.isUnstakePending(keys[1].attester), "internally finalized attester inactive");
    }

    function test_GetUnstakedFunds_RestakeAfterExit_CreatesNewEntry() external {
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

        // Refresh to finalize exit
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        vm.prank(core);
        stakingManager.getUnstakedFunds();

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "attester should be removed after exit");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after exit");

        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // After restake, promote Queued -> Active
        stakingManager.refreshAttesterState(_attesterAddresses(1));
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester should be active again");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "attester should not be exiting");
    }

    function test_GetUnstakedFunds_ActivatedExits_FinalizesAll() external {
        uint256 attesterCount = 6;
        _setupMultipleActiveAttesters(attesterCount);

        // External exits are NOT reflected in running state until unstake() + refreshAttesterState()
        // Internal state still shows all attesters as active after rollup-side exits
        assertEq(stakingManager.getActivatedAttesterCount(), attesterCount, "all attesters still active before unstake");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending unstakes before unstake");

        uint256 expectedTotal = ACTIVATION_THRESHOLD * attesterCount;

        // Unstake all attesters through the StakingManager to move them to Exiting state
        vm.prank(core);
        stakingManager.unstake(expectedTotal);

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be exiting after unstake");
        assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "exiting count should match attesters");

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        stakingManager.refreshAttesterState(_attesterAddresses(attesterCount));

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "remaining exits should complete");

        // Now sweep all funds to core
        vm.prank(core);
        (uint256 totalClaimed,) = stakingManager.getUnstakedFunds();

        assertEq(totalClaimed, expectedTotal, "total claimed should match exits");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + totalClaimed, "core should receive claimed funds");
    }

    function test_GetUnstakedFunds_Bounded_LowGasCompletesAcrossCalls() external {
        uint256 attesterCount = 5;
        _setupMultipleActiveAttesters(attesterCount);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * attesterCount);

        uint256 expectedTotal = ACTIVATION_THRESHOLD * attesterCount;
        address[] memory attesters = _attesterAddresses(attesterCount);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        stakingManager.refreshAttesterState(attesters);

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "all pending unstakes should be finalized");

        // Now sweep all funds to core
        vm.prank(core);
        (uint256 totalClaimed,) = stakingManager.getUnstakedFunds();

        assertEq(totalClaimed, expectedTotal, "total claimed should match pending exits");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + totalClaimed, "core should receive claimed funds");
    }
}
