// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerUnstakeTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                           UNSTAKE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Unstake_InitiatesWithdrawal() external {
        _setupStakedAttester();

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, stateBefore.stakedAmount - ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), 1);
    }

    function test_Unstake_EmitsEvent() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);

        // Filter events to only those from stakingManager
        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit UnstakeInitiated(keys[0].attester, ACTIVATION_THRESHOLD);

        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit UnstakeFinalized(keys[0].attester, ACTIVATION_THRESHOLD);

        stakingManager.getUnstakedFunds();
        vm.stopPrank();
    }

    function test_Unstake_NoStaked_ReturnsZero() external {
        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        vm.prank(core);
        uint256 unstakedAmount = stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(unstakedAmount, 0, "unstake should return zero when nothing is staked");
        assertEq(stateAfter.stakedAmount, stateBefore.stakedAmount, "staked amount should remain unchanged");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending unstakes should be created");
    }

    function test_RevertWhen_Unstake_ZeroAmount() external {
        _setupStakedAttester();

        vm.prank(core);
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAmount.selector));
        stakingManager.unstake(0);
    }

    function test_RevertWhen_Unstake_Unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
    }

    function test_Unstake_MultipleAttesters() external {
        _setupMultipleStakedAttesters(3);

        vm.prank(core);
        uint256 unstakedAmount = stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(unstakedAmount, ACTIVATION_THRESHOLD * 2, "unstake should return requested amount");
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        assertEq(stakingManager.getPendingUnstakeCount(), 2);
    }

    function test_Unstake_ExceedsStaked_ClampsAndUpdates() external {
        _setupMultipleStakedAttesters(2);

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        vm.prank(core);
        uint256 unstakedAmount = stakingManager.unstake(ACTIVATION_THRESHOLD * 3);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(unstakedAmount, stateBefore.stakedAmount, "unstake should clamp to staked amount");
        assertEq(stateAfter.stakedAmount, 0, "staked amount should be fully drained");
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
        assertEq(stakingManager.getPendingUnstakeCount(), 2, "pending count should match attesters");
    }

    function test_Unstake_Bounded_LowGasInitiatesSubset() external {
        uint256 attesterCount = 6;
        _setupMultipleStakedAttesters(attesterCount);

        uint256 requested = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 unstakedObserved;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.unstake, (requested)));
            if (!success) {
                continue;
            }
            uint256 unstakedCandidate = abi.decode(data, (uint256));
            if (unstakedCandidate == requested) {
                assertEq(unstakedCandidate, requested, "unstake should complete in one call");
                assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
                assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
                return;
            }
            if (unstakedCandidate > 0 && unstakedCandidate < requested) {
                selectedGas = gasOptions[i];
                unstakedObserved = unstakedCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            uint256 unstakedFull = stakingManager.unstake{ gas: 2_000_000 }(requested);

            assertEq(unstakedFull, requested, "unstake should complete in one call");
            assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
            assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(core);
        uint256 unstakedAmount = stakingManager.unstake{ gas: selectedGas }(requested);

        assertEq(unstakedAmount, unstakedObserved, "unstaked amount should match probe");
        assertGt(unstakedAmount, 0, "unstake should initiate some exits");
        assertLt(unstakedAmount, requested, "unstake should be bounded under low gas");
        assertGt(stakingManager.getActivatedAttesterCount(), 0, "activated attesters should remain");
        assertGt(stakingManager.getPendingUnstakeCount(), 0, "pending unstakes should increase");
    }

    function test_Unstake_Bounded_ResumesAcrossCalls() external {
        uint256 attesterCount = 5;
        _setupMultipleStakedAttesters(attesterCount);

        uint256 requested = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.unstake, (requested)));
            if (!success) {
                continue;
            }
            uint256 unstakedCandidate = abi.decode(data, (uint256));
            if (unstakedCandidate > 0 && unstakedCandidate < requested) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            uint256 unstakedFull = stakingManager.unstake{ gas: 2_000_000 }(requested);

            assertEq(unstakedFull, requested, "unstake should complete in one call");
            assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
            assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
            return;
        }

        vm.revertToState(snapshotId);
        uint256 totalUnstaked;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getActivatedAttesterCount() == 0) {
                break;
            }
            vm.prank(core);
            totalUnstaked += stakingManager.unstake{ gas: selectedGas }(requested);
        }

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
        assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
        assertEq(totalUnstaked, requested, "total unstaked should equal requested");
    }

    function test_Unstake_Bounded_CursorTracksProgress() external {
        uint256 attesterCount = 4;
        _setupMultipleStakedAttesters(attesterCount);

        uint256 requested = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.unstake, (requested)));
            if (!success) {
                continue;
            }
            uint256 unstakedCandidate = abi.decode(data, (uint256));
            if (unstakedCandidate > 0 && unstakedCandidate < requested) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial unstake");

        vm.revertToState(snapshotId);

        uint256 cursorBefore = stakingManager.getUnstakeCursor();

        vm.prank(core);
        stakingManager.unstake{ gas: selectedGas }(requested);

        uint256 cursorAfter = stakingManager.getUnstakeCursor();
        uint256 remaining = stakingManager.getActivatedAttesterCount();
        assertLe(cursorAfter, remaining, "cursor should stay within activated bounds");
        assertEq(cursorBefore, 0, "cursor should start at 0");

        vm.prank(core);
        stakingManager.setGasThreshold(1);
        vm.prank(core);
        stakingManager.unstake(requested);

        assertEq(stakingManager.getUnstakeCursor(), 0, "cursor should reset after completion");
    }

    function test_IsUnstakePending() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);

        assertFalse(stakingManager.isUnstakePending(keys[0].attester));

        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        assertTrue(stakingManager.isUnstakePending(keys[0].attester));
    }

    function test_Unstake_CursorDoesNotSkipAfterStateChange() external {
        _setupMultipleStakedAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        assertEq(stakingManager.getPendingUnstakeCount(), 1, "first unstake should mark one exiting");
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "two attesters should remain active");

        vm.prank(core);
        uint256 unstaked = stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        assertEq(unstaked, ACTIVATION_THRESHOLD * 2, "unstake should process remaining active attesters");
        assertEq(stakingManager.getPendingUnstakeCount(), 3, "all attesters should be exiting");
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "no active attesters should remain");
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_UnstakeAfterStake(uint8 stakeCount, uint8 unstakeCount) external {
        stakeCount = uint8(bound(stakeCount, 1, 10));
        unstakeCount = uint8(bound(unstakeCount, 1, stakeCount));

        _setupMultipleStakedAttesters(stakeCount);

        uint256 unstakeAmount = ACTIVATION_THRESHOLD * unstakeCount;

        vm.prank(core);
        stakingManager.unstake(unstakeAmount);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * (stakeCount - unstakeCount));
        assertEq(stakingManager.getActivatedAttesterCount(), stakeCount - unstakeCount);
    }
}
