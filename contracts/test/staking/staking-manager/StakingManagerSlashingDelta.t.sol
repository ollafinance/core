// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerSlashingDeltaTest
/// @notice Comprehensive tests for StakingManager.getSlashingDelta() functionality.
contract StakingManagerSlashingDeltaTest is StakingManagerBaseTest {
    using stdStorage for StdStorage;

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setupStakedAttesters(uint256 count) internal returns (IStakingManager.KeyStore[] memory keys) {
        keys = _createMockKeys(count);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * count;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        return keys;
    }

    function _getSlashingDeltaCursor() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 slashingDeltaCursorSlot = bytes32(cursorSlot + 3);
        return uint256(vm.load(address(stakingManager), slashingDeltaCursorSlot));
    }

    function _setSlashingDeltaCursor(uint256 value) internal {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 slashingDeltaCursorSlot = bytes32(cursorSlot + 3);
        vm.store(address(stakingManager), slashingDeltaCursorSlot, bytes32(value));
    }

    function _getSlashingDeltaAccumulated() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 slashingDeltaAccumulatedSlot = bytes32(cursorSlot + 4);
        return uint256(vm.load(address(stakingManager), slashingDeltaAccumulatedSlot));
    }

    function _getStakedTotalAccumulated() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 stakedTotalAccumulatedSlot = bytes32(cursorSlot + 5);
        return uint256(vm.load(address(stakingManager), stakedTotalAccumulatedSlot));
    }

    function _setAttestersLength(uint256 length) internal {
        bytes32 attestersLengthSlot = bytes32(uint256(6));
        vm.store(address(stakingManager), attestersLengthSlot, bytes32(length));
    }

    function _computeSlashingDelta() internal returns (uint256 slashingDelta, bool completed) {
        vm.prank(defaultAdmin);
        return stakingManager.computeSlashingDelta();
    }

    /*//////////////////////////////////////////////////////////////
                           SLASHING DELTA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetSlashingDelta_ReturnsZeroWithNoAttesters() external {
        _computeSlashingDelta();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 0, "Should be 0 with no attesters");
    }

    function test_GetSlashingDelta_ComputesFromActivatedAttesters() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 10 ether, block.timestamp);

        _computeSlashingDelta();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 10 ether, "Should include slashing from activated attesters");
        assertEq(
            stakingManager.totalStaked(), 2 * ACTIVATION_THRESHOLD, "totalStaked counts eligible activated attesters"
        );
    }

    function test_GetSlashingDelta_IncludesPendingUnstakeRequests() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        vm.startPrank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 15 ether, block.timestamp);

        _computeSlashingDelta();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 15 ether, "Should include slashing from pending attesters");
        assertEq(
            stakingManager.totalStaked(), 2 * ACTIVATION_THRESHOLD, "totalStaked counts activated and pending attesters"
        );
    }

    function test_GetSlashingDelta_MonotonicCumulative() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 10 ether, block.timestamp);

        _computeSlashingDelta();
        vm.prank(core);
        uint256 first = stakingManager.getSlashingDelta();
        assertEq(first, 10 ether, "initial slashing captured");

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        _computeSlashingDelta();
        vm.prank(core);
        uint256 second = stakingManager.getSlashingDelta();
        assertEq(second, first, "cumulative slashing does not decrease");
    }

    /// @notice Tests that slashing delta is computed using the original staked amount,
    ///         not the current activation threshold, when threshold changes between stakes.
    function test_GetSlashingDelta_UsesOriginalStakedAmount() external {
        // Stake first attester at 100 ether threshold
        IStakingManager.KeyStore[] memory keys1 = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys1);

        uint256 originalThreshold = ACTIVATION_THRESHOLD; // 100 ether
        aztec.mint(core, originalThreshold);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), originalThreshold);
        stakingManager.stake(originalThreshold);
        vm.stopPrank();

        // Change activation threshold to 150 ether
        uint256 newThreshold = 150 ether;
        rollup.setActivationThreshold(newThreshold);

        // Stake second attester at new threshold
        IStakingManager.KeyStore[] memory keys2 = new IStakingManager.KeyStore[](1);
        keys2[0] = IStakingManager.KeyStore({
            attester: address(uint160(100)),
            publicKeyG1: G1Point({ x: 100, y: 101 }),
            publicKeyG2: G2Point({ x0: 100, x1: 101, y0: 102, y1: 103 }),
            proofOfPossession: G1Point({ x: 110, y: 111 })
        });
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys2);

        aztec.mint(core, newThreshold);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), newThreshold);
        stakingManager.stake(newThreshold);
        vm.stopPrank();

        // totalStaked should be sum of original amounts: 100 + 150 = 250
        assertEq(
            stakingManager.totalStaked(), originalThreshold + newThreshold, "totalStaked should sum original amounts"
        );

        // Simulate slashing: attester1 lost 10 ether, attester2 lost 20 ether
        uint256 attester1Remaining = originalThreshold - 10 ether; // 90 ether
        uint256 attester2Remaining = newThreshold - 20 ether; // 130 ether

        rollup.setExternalExit(keys1[0].attester, attester1Remaining, block.timestamp);
        rollup.setExternalExit(keys2[0].attester, attester2Remaining, block.timestamp);

        _computeSlashingDelta();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        // Slashing delta should be: (100 - 90) + (150 - 130) = 10 + 20 = 30
        // NOT: (150 - 90) + (150 - 130) = 60 + 20 = 80 (if using current threshold)
        assertEq(slashingDelta, 30 ether, "slashing delta should use original staked amounts");
    }

    function test_GetSlashingDelta_BoundedPartialUpdatesOnCompletion() external {
        uint256 attesterCount = 6;
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(attesterCount);

        for (uint256 i; i < attesterCount; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD - 1 ether, block.timestamp);
        }

        uint256 expectedDelta = attesterCount * 1 ether;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[6] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000, 320_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (bool success, bytes memory data) = address(stakingManager).call{ gas: gasOptions[i] }(
                abi.encodeCall(stakingManager.computeSlashingDelta, ())
            );
            if (!success) {
                continue;
            }
            (uint256 deltaCandidate, bool completed) = abi.decode(data, (uint256, bool));
            uint256 cursorAfter = _getSlashingDeltaCursor();
            if (!completed && deltaCandidate == 0 && cursorAfter > 0) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (uint256 deltaFull, bool completed) = stakingManager.computeSlashingDelta();
            assertTrue(completed, "slashing delta should complete in one call");
            assertEq(deltaFull, expectedDelta, "slashing delta should complete in one call");
            assertEq(_getSlashingDeltaCursor(), 0, "cursor should reset after completion");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(defaultAdmin);
        (uint256 first, bool completedFirst) = stakingManager.computeSlashingDelta{ gas: selectedGas }();
        uint256 cursorAfterFirst = _getSlashingDeltaCursor();

        assertEq(first, 0, "partial pass should return prior cumulative");
        assertFalse(completedFirst, "partial pass should not complete");
        assertGt(cursorAfterFirst, 0, "cursor should advance under partial pass");

        vm.prank(defaultAdmin);
        (uint256 second, bool completedSecond) = stakingManager.computeSlashingDelta();
        assertTrue(completedSecond, "slashing delta should complete");

        assertEq(second, expectedDelta, "cumulative should update after completion");
        assertEq(_getSlashingDeltaCursor(), 0, "cursor should reset after completion");
    }

    function test_GetSlashingDelta_CursorResetsWhenOutOfRange() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 5 ether, block.timestamp);

        _setSlashingDeltaCursor(10);

        _computeSlashingDelta();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 5 ether, "slashing delta should compute from start when cursor is out of range");
        assertEq(_getSlashingDeltaCursor(), 0, "cursor should reset when out of range");
    }

    function test_GetSlashingDelta_CursorResetsWhenNoAttesters() external {
        _setupStakedAttesters(2);

        _setSlashingDeltaCursor(1);
        _setAttestersLength(0);

        _computeSlashingDelta();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 0, "slashing delta should be zero when no attesters remain");
        assertEq(_getSlashingDeltaCursor(), 0, "cursor should reset when length is zero");
    }

    function test_GetSlashingDelta_SkipsInactiveAttestersAndAdvancesCursor() external {
        uint256 attesterCount = 4;
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(attesterCount);

        vm.startPrank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        stakingManager.getUnstakedFunds();
        vm.stopPrank();

        for (uint256 i = 1; i < attesterCount; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD - 2 ether, block.timestamp);
        }

        uint256 expectedDelta = (attesterCount - 1) * 2 ether;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        _setSlashingDeltaCursor(0);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[6] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000, 320_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (bool success, bytes memory data) = address(stakingManager).call{ gas: gasOptions[i] }(
                abi.encodeCall(stakingManager.computeSlashingDelta, ())
            );
            if (!success) {
                continue;
            }
            (uint256 deltaCandidate, bool completed) = abi.decode(data, (uint256, bool));
            uint256 cursorAfter = _getSlashingDeltaCursor();
            if (!completed && deltaCandidate == 0 && cursorAfter > 0) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (uint256 deltaFull, bool completed) = stakingManager.computeSlashingDelta();
            assertTrue(completed, "slashing delta should complete in one call");
            assertEq(deltaFull, expectedDelta, "slashing delta should skip inactive attester");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(defaultAdmin);
        (uint256 first, bool completedFirst) = stakingManager.computeSlashingDelta{ gas: selectedGas }();
        uint256 cursorAfterFirst = _getSlashingDeltaCursor();

        assertEq(first, 0, "partial pass should return prior cumulative");
        assertFalse(completedFirst, "partial pass should not complete");
        assertGt(cursorAfterFirst, 0, "cursor should advance after skipping inactive attester");

        vm.prank(defaultAdmin);
        (uint256 second, bool completedSecond) = stakingManager.computeSlashingDelta();
        assertTrue(completedSecond, "slashing delta should complete");

        assertEq(second, expectedDelta, "slashing delta should skip inactive attester");
    }

    function test_GetSlashingDelta_AccumulatorResetsAfterCompletion() external {
        uint256 attesterCount = 3;
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(attesterCount);

        for (uint256 i; i < attesterCount; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD - 3 ether, block.timestamp);
        }

        uint256 expectedDelta = attesterCount * 3 ether;

        (uint256 computed, bool completed) = _computeSlashingDelta();
        assertTrue(completed, "slashing delta should complete");

        vm.prank(core);
        uint256 first = stakingManager.getSlashingDelta();

        assertEq(computed, expectedDelta, "slashing delta should match expected total");
        assertEq(first, expectedDelta, "slashing delta should match expected total");
        assertEq(_getSlashingDeltaCursor(), 0, "cursor should reset after completion");
        assertEq(_getSlashingDeltaAccumulated(), 0, "slashing delta accumulator should reset after completion");
        assertEq(_getStakedTotalAccumulated(), 0, "staked total accumulator should reset after completion");

        vm.prank(core);
        uint256 second = stakingManager.getSlashingDelta();

        assertEq(second, first, "second full pass should not carry over accumulation");
        assertEq(_getSlashingDeltaCursor(), 0, "cursor should remain reset after subsequent calls");
        assertEq(_getSlashingDeltaAccumulated(), 0, "slashing delta accumulator should remain reset");
        assertEq(_getStakedTotalAccumulated(), 0, "staked total accumulator should remain reset");
    }
}
