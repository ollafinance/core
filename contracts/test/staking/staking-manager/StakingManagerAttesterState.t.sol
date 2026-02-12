// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerAttesterStateTest
/// @notice Comprehensive tests for StakingManager cached attester state (slashing delta, totalStaked, pending/withdrawable).
contract StakingManagerAttesterStateTest is StakingManagerBaseTest {
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

    function _getAttesterStateCursor() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 attesterStateCursorSlot = bytes32(cursorSlot + 2);
        return uint256(vm.load(address(stakingManager), attesterStateCursorSlot));
    }

    function _setAttesterStateCursor(uint256 value) internal {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 attesterStateCursorSlot = bytes32(cursorSlot + 2);
        vm.store(address(stakingManager), attesterStateCursorSlot, bytes32(value));
    }

    function _getSlashingDeltaAccumulated() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 slashingDeltaAccumulatedSlot = bytes32(cursorSlot + 3);
        return uint256(vm.load(address(stakingManager), slashingDeltaAccumulatedSlot));
    }

    function _getStakedTotalAccumulated() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 stakedTotalAccumulatedSlot = bytes32(cursorSlot + 4);
        return uint256(vm.load(address(stakingManager), stakedTotalAccumulatedSlot));
    }

    function _setAttestersLength(uint256 length) internal {
        bytes32 attestersLengthSlot = bytes32(uint256(6));
        vm.store(address(stakingManager), attestersLengthSlot, bytes32(length));
    }

    function _computeAttesterState() internal returns (uint256 slashingDelta, bool completed) {
        vm.prank(defaultAdmin);
        return stakingManager.computeAttesterState();
    }

    /*//////////////////////////////////////////////////////////////
                           SLASHING DELTA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetSlashingDelta_ReturnsZeroWithNoAttesters() external {
        _computeAttesterState();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 0, "Should be 0 with no attesters");
    }

    function test_GetSlashingDelta_ComputesFromActivatedAttesters() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 10 ether, block.timestamp);

        _computeAttesterState();
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

        _computeAttesterState();
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

        _computeAttesterState();
        vm.prank(core);
        uint256 first = stakingManager.getSlashingDelta();
        assertEq(first, 10 ether, "initial slashing captured");

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        _computeAttesterState();
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

        // Simulate slashing: attester1 lost 10 ether, attester2 lost 20 ether
        uint256 attester1Remaining = originalThreshold - 10 ether; // 90 ether
        uint256 attester2Remaining = newThreshold - 20 ether; // 130 ether

        rollup.setExternalExit(keys1[0].attester, attester1Remaining, block.timestamp);
        rollup.setExternalExit(keys2[0].attester, attester2Remaining, block.timestamp);

        _computeAttesterState();

        // totalStaked should be sum of original amounts: 100 + 150 = 250
        assertEq(
            stakingManager.totalStaked(), originalThreshold + newThreshold, "totalStaked should sum original amounts"
        );

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
                abi.encodeCall(stakingManager.computeAttesterState, ())
            );
            if (!success) {
                continue;
            }
            (uint256 deltaCandidate, bool completed) = abi.decode(data, (uint256, bool));
            uint256 cursorAfter = _getAttesterStateCursor();
            if (!completed && deltaCandidate == 0 && cursorAfter > 0) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (uint256 deltaFull, bool completed) = stakingManager.computeAttesterState();
            assertTrue(completed, "slashing delta should complete in one call");
            assertEq(deltaFull, expectedDelta, "slashing delta should complete in one call");
            assertEq(_getAttesterStateCursor(), 0, "cursor should reset after completion");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(defaultAdmin);
        (uint256 first, bool completedFirst) = stakingManager.computeAttesterState{ gas: selectedGas }();
        uint256 cursorAfterFirst = _getAttesterStateCursor();

        assertEq(first, 0, "partial pass should return prior cumulative");
        assertFalse(completedFirst, "partial pass should not complete");
        assertGt(cursorAfterFirst, 0, "cursor should advance under partial pass");

        vm.prank(defaultAdmin);
        (uint256 second, bool completedSecond) = stakingManager.computeAttesterState();
        assertTrue(completedSecond, "slashing delta should complete");

        assertEq(second, expectedDelta, "cumulative should update after completion");
        assertEq(_getAttesterStateCursor(), 0, "cursor should reset after completion");
    }

    function test_GetSlashingDelta_CursorResetsWhenOutOfRange() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 5 ether, block.timestamp);

        _setAttesterStateCursor(10);

        _computeAttesterState();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 5 ether, "slashing delta should compute from start when cursor is out of range");
        assertEq(_getAttesterStateCursor(), 0, "cursor should reset when out of range");
    }

    function test_GetSlashingDelta_CursorResetsWhenNoAttesters() external {
        _setupStakedAttesters(2);

        _setAttesterStateCursor(1);
        _setAttestersLength(0);

        _computeAttesterState();
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 0, "slashing delta should be zero when no attesters remain");
        assertEq(_getAttesterStateCursor(), 0, "cursor should reset when length is zero");
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

        _setAttesterStateCursor(0);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[6] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000, 320_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (bool success, bytes memory data) = address(stakingManager).call{ gas: gasOptions[i] }(
                abi.encodeCall(stakingManager.computeAttesterState, ())
            );
            if (!success) {
                continue;
            }
            (uint256 deltaCandidate, bool completed) = abi.decode(data, (uint256, bool));
            uint256 cursorAfter = _getAttesterStateCursor();
            if (!completed && deltaCandidate == 0 && cursorAfter > 0) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (uint256 deltaFull, bool completed) = stakingManager.computeAttesterState();
            assertTrue(completed, "slashing delta should complete in one call");
            assertEq(deltaFull, expectedDelta, "slashing delta should skip inactive attester");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(defaultAdmin);
        (uint256 first, bool completedFirst) = stakingManager.computeAttesterState{ gas: selectedGas }();
        uint256 cursorAfterFirst = _getAttesterStateCursor();

        assertEq(first, 0, "partial pass should return prior cumulative");
        assertFalse(completedFirst, "partial pass should not complete");
        assertGt(cursorAfterFirst, 0, "cursor should advance after skipping inactive attester");

        vm.prank(defaultAdmin);
        (uint256 second, bool completedSecond) = stakingManager.computeAttesterState();
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

        (uint256 computed, bool completed) = _computeAttesterState();
        assertTrue(completed, "slashing delta should complete");

        vm.prank(core);
        uint256 first = stakingManager.getSlashingDelta();

        assertEq(computed, expectedDelta, "slashing delta should match expected total");
        assertEq(first, expectedDelta, "slashing delta should match expected total");
        assertEq(_getAttesterStateCursor(), 0, "cursor should reset after completion");
        // Accumulators retain values after completion; deferred reset occurs at next pass start
        assertEq(
            _getSlashingDeltaAccumulated(),
            expectedDelta,
            "slashing delta accumulator should retain value until next pass"
        );
        uint256 expectedTotalStaked = attesterCount * ACTIVATION_THRESHOLD;
        assertEq(
            _getStakedTotalAccumulated(),
            expectedTotalStaked,
            "staked total accumulator should retain value until next pass"
        );

        // A new full pass should still produce correct results (accumulators reset at cursor==0)
        (uint256 recomputed, bool reCompleted) = _computeAttesterState();
        assertTrue(reCompleted, "recomputed should complete");
        assertEq(recomputed, expectedDelta, "recomputed delta should match original");

        vm.prank(core);
        uint256 second = stakingManager.getSlashingDelta();

        assertEq(second, first, "second full pass should not carry over accumulation");
        assertEq(_getAttesterStateCursor(), 0, "cursor should remain reset after subsequent calls");
    }

    /*//////////////////////////////////////////////////////////////
                        STALENESS BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetSlashingDelta_FreshAtExactThreshold() external {
        _computeAttesterState();

        (uint256 lastUpdated, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        vm.warp(lastUpdated + maxAge);

        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 0, "should return delta when exactly at max age boundary");
    }

    function test_RevertWhen_GetSlashingDelta_StaleJustPastThreshold() external {
        _computeAttesterState();

        (uint256 lastUpdated, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        vm.warp(lastUpdated + maxAge + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterStateStale.selector, lastUpdated, maxAge)
        );
        vm.prank(core);
        stakingManager.getSlashingDelta();
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ComputeSlashingDelta_UnauthorizedCaller() external {
        address unauthorized = makeAddr("unauthorized");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, stakingManager.OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        stakingManager.computeAttesterState();
    }

    function test_RevertWhen_SetSlashingDeltaMaxAge_UnauthorizedCaller() external {
        address unauthorized = makeAddr("unauthorized");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, stakingManager.OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        stakingManager.setAttesterStateMaxAge(1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                    ATTESTER STATE MAX AGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetSlashingDeltaMaxAge_UpdatesValue() external {
        uint256 newMaxAge = 6 hours;
        vm.prank(defaultAdmin);
        stakingManager.setAttesterStateMaxAge(newMaxAge);

        (uint256 lastUpdated, uint256 maxAge, bool isStale) = stakingManager.getAttesterStateLiveness();
        assertEq(maxAge, newMaxAge, "maxAge should be updated to new value");
        assertFalse(isStale, "should not be stale immediately after init");
        assertGt(lastUpdated, 0, "lastUpdated should be non-zero after initialize");
    }

    function test_RevertWhen_SetSlashingDeltaMaxAge_Zero() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAmount.selector));
        vm.prank(defaultAdmin);
        stakingManager.setAttesterStateMaxAge(0);
    }

    /*//////////////////////////////////////////////////////////////
                    ATTESTER STATE LIVENESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetSlashingDeltaLiveness_ReturnsCorrectValues() external {
        _computeAttesterState();

        (uint256 lastUpdated, uint256 maxAge, bool isStale) = stakingManager.getAttesterStateLiveness();

        assertEq(maxAge, stakingManager.DEFAULT_ATTESTER_STATE_MAX_AGE(), "maxAge should match default");
        assertFalse(isStale, "should not be stale immediately after compute");
        assertGt(lastUpdated, 0, "lastUpdated should be non-zero after compute");

        vm.warp(lastUpdated + maxAge + 1);

        (uint256 lastUpdated2, uint256 maxAge2, bool isStale2) = stakingManager.getAttesterStateLiveness();

        assertEq(lastUpdated2, lastUpdated, "lastUpdated should remain unchanged after warp");
        assertEq(maxAge2, maxAge, "maxAge should remain unchanged after warp");
        assertTrue(isStale2, "should be stale after exceeding max age");
    }

    /*//////////////////////////////////////////////////////////////
                      CACHED STAKING STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeAttesterState_CachesTotalStaked() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(3);
        // Mark attesters as having full balance (no slashing, no exit)
        for (uint256 i; i < keys.length; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }

        _computeAttesterState();

        uint256 cachedTotalStaked = stakingManager.totalStaked();
        assertEq(cachedTotalStaked, 3 * ACTIVATION_THRESHOLD, "totalStaked should return cached value after compute");
    }

    function test_ComputeAttesterState_CachesPendingUnstakes() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        // Initiate unstake for 1 attester
        vm.startPrank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Set exit as pending (not yet exitable)
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        _computeAttesterState();

        uint256 cachedPending = stakingManager.pendingUnstakes();
        assertEq(cachedPending, ACTIVATION_THRESHOLD, "pendingUnstakes should return cached pending unstake amount");
    }

    function test_ComputeAttesterState_CachesWithdrawableAmount() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        // Initiate unstake for 1 attester
        vm.startPrank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Set exit as exitable (exitableAt in the past)
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        _computeAttesterState();

        assertTrue(stakingManager.hasExitableUnstakes(), "hasExitableUnstakes should return true from cache");

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.withdrawableAmount, ACTIVATION_THRESHOLD, "withdrawableAmount should be cached correctly");
    }

    function test_ComputeAttesterState_CachesGetStakingState() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(3);

        // Initiate unstake for 1 attester
        vm.startPrank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Attester 0 exiting, exitable now (mock rollup auto-creates exit on unstake)
        // Attesters 1 and 2 remain active with full balance (no external exit set)

        _computeAttesterState();

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        // stakedAmount includes all Active + Exiting attesters
        assertEq(state.stakedAmount, 3 * ACTIVATION_THRESHOLD, "stakedAmount should include all eligible attesters");
        // Only attester 0 has an exitable exit
        assertEq(
            state.withdrawableAmount, ACTIVATION_THRESHOLD, "withdrawableAmount should reflect exitable exit amount"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    STALENESS REVERT TESTS (VIEW FUNCTIONS)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_TotalStaked_Stale() external {
        _computeAttesterState();

        (uint256 lastUpdated, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        vm.warp(lastUpdated + maxAge + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterStateStale.selector, lastUpdated, maxAge)
        );
        stakingManager.totalStaked();
    }

    function test_RevertWhen_PendingUnstakes_Stale() external {
        _computeAttesterState();

        (uint256 lastUpdated, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        vm.warp(lastUpdated + maxAge + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterStateStale.selector, lastUpdated, maxAge)
        );
        stakingManager.pendingUnstakes();
    }

    function test_RevertWhen_HasExitableUnstakes_Stale() external {
        _computeAttesterState();

        (uint256 lastUpdated, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        vm.warp(lastUpdated + maxAge + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterStateStale.selector, lastUpdated, maxAge)
        );
        stakingManager.hasExitableUnstakes();
    }

    function test_RevertWhen_GetStakingState_Stale() external {
        _computeAttesterState();

        (uint256 lastUpdated, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        vm.warp(lastUpdated + maxAge + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterStateStale.selector, lastUpdated, maxAge)
        );
        stakingManager.getStakingState();
    }

    /*//////////////////////////////////////////////////////////////
                     MULTI-PASS CACHED STATE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests that multi-pass computeAttesterState() accumulates all 4 cached values correctly
    ///         and that intermediate calls (completed=false) do NOT update cached values.
    function test_ComputeAttesterState_MultiPassAccumulatesAllValues() external {
        // Setup: stake 4 attesters
        uint256 attesterCount = 4;
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(attesterCount);

        // Initiate unstake for attester 0 (will become Exiting)
        vm.startPrank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Attester 0: exiting, exitable now (mock rollup creates immediate exit on unstake)
        // -> withdrawable += ACTIVATION_THRESHOLD

        // Attester 1: exiting externally, NOT yet exitable (future exitableAt)
        // -> pendingUnstake += ACTIVATION_THRESHOLD
        // computeAttesterState() will sync this attester from Active to Exiting automatically.
        rollup.setExternalExit(keys[1].attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        // Attester 2: active, slashed by 5 ether, exit NOT yet exitable (future exitableAt)
        // -> slashingDelta += 5 ether (stakedAmount 100e18 > remaining 95e18)
        // -> pendingUnstake += 95e18 (exit exists, not yet exitable)
        rollup.setExternalExit(keys[2].attester, ACTIVATION_THRESHOLD - 5 ether, block.timestamp + 2 days);

        // Attester 3: active, full balance (no slashing, no exit)

        // Expected values after full computation:
        // totalStaked = 4 * ACTIVATION_THRESHOLD (all Active+Exiting attesters' original staked amounts)
        // slashingDelta = 5 ether (attester 2 lost 5 ether)
        // pendingUnstake = ACTIVATION_THRESHOLD + (ACTIVATION_THRESHOLD - 5 ether) = 195e18
        //   (attester 1: 100e18 not exitable + attester 2: 95e18 not exitable)
        // withdrawable = ACTIVATION_THRESHOLD (attester 0: 100e18 exitable now)

        uint256 expectedTotalStaked = 4 * ACTIVATION_THRESHOLD;
        uint256 expectedSlashingDelta = 5 ether;
        uint256 expectedPending = ACTIVATION_THRESHOLD + (ACTIVATION_THRESHOLD - 5 ether);
        uint256 expectedWithdrawable = ACTIVATION_THRESHOLD;

        // Set high gasThreshold to force the loop to break early
        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        // Snapshot state for gas-probe approach
        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[8] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000, 320_000, 340_000, 360_000];

        // Probe for a gas limit that causes partial completion
        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(defaultAdmin);
            (bool success, bytes memory data) = address(stakingManager).call{ gas: gasOptions[i] }(
                abi.encodeCall(stakingManager.computeAttesterState, ())
            );
            if (!success) {
                continue;
            }
            (, bool completed) = abi.decode(data, (uint256, bool));
            uint256 cursorAfter = _getAttesterStateCursor();
            if (!completed && cursorAfter > 0) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        // If no partial gas found, complete in one call and verify values directly
        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            (uint256 delta, bool completed) = _computeAttesterState();
            assertTrue(completed, "should complete in one call");
            assertEq(delta, expectedSlashingDelta, "slashing delta should match");
            assertEq(stakingManager.totalStaked(), expectedTotalStaked, "totalStaked should match");
            assertEq(stakingManager.pendingUnstakes(), expectedPending, "pendingUnstakes should match");
            assertTrue(stakingManager.hasExitableUnstakes(), "hasExitableUnstakes should be true");
            IStakingManager.StakingState memory state = stakingManager.getStakingState();
            assertEq(state.withdrawableAmount, expectedWithdrawable, "withdrawable should match");
            return;
        }

        // Execute partial pass
        vm.revertToState(snapshotId);

        // Record old cached values (before any computation) - they should be 0 / stale
        // After first computeAttesterState with completed=false, cached values must remain unchanged.

        // First call: partial (completed=false)
        vm.prank(defaultAdmin);
        (uint256 firstDelta, bool firstCompleted) = stakingManager.computeAttesterState{ gas: selectedGas }();

        assertFalse(firstCompleted, "first call should be partial");
        assertEq(firstDelta, 0, "partial pass returns prior cumulative delta (0)");
        uint256 cursorAfterFirst = _getAttesterStateCursor();
        assertGt(cursorAfterFirst, 0, "cursor should advance after partial pass");

        // Verify cached values are NOT updated during intermediate call
        // Reading the raw storage for cached values (since view functions revert when
        // the staleness guard triggers or return stale values)
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();

        uint256 cachedTotalStakedRaw = uint256(vm.load(address(stakingManager), bytes32(cursorSlot + 5)));
        uint256 cachedPendingRaw = uint256(vm.load(address(stakingManager), bytes32(cursorSlot + 6)));
        uint256 cachedWithdrawableRaw = uint256(vm.load(address(stakingManager), bytes32(cursorSlot + 7)));

        assertEq(cachedTotalStakedRaw, 0, "cached totalStaked must not update on partial pass");
        assertEq(cachedPendingRaw, 0, "cached pending must not update on partial pass");
        assertEq(cachedWithdrawableRaw, 0, "cached withdrawable must not update on partial pass");

        // Complete remaining passes
        bool done;
        uint256 finalDelta;
        for (uint256 i; i < 10; ++i) {
            vm.prank(defaultAdmin);
            (finalDelta, done) = stakingManager.computeAttesterState();
            if (done) break;
        }
        assertTrue(done, "computation should complete");

        // Now verify all 4 cached values are correct
        assertEq(finalDelta, expectedSlashingDelta, "final slashing delta should match expected");
        assertEq(stakingManager.totalStaked(), expectedTotalStaked, "totalStaked should match expected");
        assertEq(stakingManager.pendingUnstakes(), expectedPending, "pendingUnstakes should match expected");
        assertTrue(stakingManager.hasExitableUnstakes(), "hasExitableUnstakes should be true");

        IStakingManager.StakingState memory finalState = stakingManager.getStakingState();
        assertEq(finalState.stakedAmount, expectedTotalStaked, "staking state stakedAmount should match");
        assertEq(finalState.pendingUnstakeAmount, expectedPending, "staking state pendingUnstakeAmount should match");
        assertEq(finalState.withdrawableAmount, expectedWithdrawable, "staking state withdrawableAmount should match");

        // Verify cursor resets after completion; accumulators retain values (deferred reset at next pass start)
        assertEq(_getAttesterStateCursor(), 0, "cursor should reset after completion");
        assertEq(
            _getSlashingDeltaAccumulated(),
            expectedSlashingDelta,
            "slashing delta accumulator should retain value until next pass"
        );
        assertEq(
            _getStakedTotalAccumulated(),
            expectedTotalStaked,
            "staked total accumulator should retain value until next pass"
        );

        uint256 pendingAccumRaw = uint256(vm.load(address(stakingManager), bytes32(cursorSlot + 8)));
        uint256 withdrawableAccumRaw = uint256(vm.load(address(stakingManager), bytes32(cursorSlot + 9)));
        assertEq(pendingAccumRaw, expectedPending, "pending unstake accumulator should retain value until next pass");
        assertEq(
            withdrawableAccumRaw, expectedWithdrawable, "withdrawable accumulator should retain value until next pass"
        );
    }
}
