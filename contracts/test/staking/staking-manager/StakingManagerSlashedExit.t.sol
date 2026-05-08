// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IAztecRollup } from "src/staking/interfaces/IAztecRollup.sol";
import { IMockAztecRollup } from "src/staking/mocks/IMockAztecRollup.sol";
import { Exit } from "src/staking/libraries/AztecTypes.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerSlashedExitFinalizationTest
/// @notice Verifies that zombie exits (isRecipient=false) are properly handled by the StakingManager.
///
/// Background:
///   In the real Aztec staking system (StakingLib.sol), when a validator is slashed the rollup
///   creates an Exit with `isRecipient = false` (a "zombie" exit). Before `finalizeWithdraw()`
///   can succeed, the withdrawer must first call `initiateWithdraw()` to set `isRecipient = true`
///   and designate a recipient.
///
///   The fix: in _refreshSingleAttester(), when an Active attester has a zombie exit (isRecipient=false),
///   the StakingManager calls rollup.initiateWithdraw() to claim the exit before transitioning to Exiting.
///   This ensures finalizeWithdraw() will succeed when the exit becomes exitable.
contract StakingManagerSlashedExitFinalizationTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                    Zombie exits are properly claimed and finalized
    //////////////////////////////////////////////////////////////*/

    /// @notice A zombie exit with a future exitableAt is claimed on first refresh and finalized on second.
    /// @dev Phase 1: refreshAttesterState() detects the zombie, calls initiateWithdraw() to set
    ///      isRecipient=true, and transitions the attester to Exiting.
    ///      Phase 2: After warping past exitableAt, refreshAttesterState() finalizes the exit
    ///      and funds become claimable.
    function test_ZombieExit_ClaimedAndFinalizedAfterRefresh() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;
        address[] memory attesters = _attesterAddresses(1);

        // Create a zombie exit that is NOT yet exitable.
        rollup.setExternalExit(attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        // Verify the rollup exit has isRecipient=false
        Exit memory exitOnRollup = rollup.getExit(attester);
        assertTrue(exitOnRollup.exists, "exit should exist on rollup");
        assertFalse(exitOnRollup.isRecipient, "zombie exit should have isRecipient=false");

        // ── Phase 1: Refresh claims the zombie via initiateWithdraw ──
        stakingManager.refreshAttesterState(attesters);

        // Zombie was claimed: isRecipient should now be true on rollup
        Exit memory claimedExit = rollup.getExit(attester);
        assertTrue(claimedExit.isRecipient, "exit should have isRecipient=true after claim");

        // Attester is locally Exiting
        assertTrue(stakingManager.isUnstakePending(attester), "attester should be locally Exiting after sync");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "should have 1 pending unstake");

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(
            state.pendingUnstakeAmount,
            ACTIVATION_THRESHOLD,
            "pendingUnstakeAmount should reflect the zombie exit amount"
        );

        // Not yet claimable (exit not exitable yet)
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, 0, "no funds should be received yet");
        assertEq(exitAmount, 0, "no exit amount should be claimable yet");

        // ── Phase 2: Warp past exitableAt - finalization succeeds ──
        vm.warp(block.timestamp + 1 days);

        // Refresh now finalizes the exit successfully
        stakingManager.refreshAttesterState(attesters);

        // Attester is no longer Exiting
        assertFalse(
            stakingManager.isUnstakePending(attester), "attester should no longer be Exiting after finalization"
        );

        // Funds are now claimable
        vm.prank(core);
        (uint256 receivedAfter, uint256 exitAmountAfter) = stakingManager.getUnstakedFunds();
        assertEq(receivedAfter, ACTIVATION_THRESHOLD, "funds should be received after finalization");
        assertEq(exitAmountAfter, ACTIVATION_THRESHOLD, "exit amount should be claimable");
    }

    /// @notice A zombie exit does NOT block refresh of other legitimate attesters in the same call.
    /// @dev With the fix, refreshAttesterState claims the zombie via initiateWithdraw, so the
    ///      entire batch processes without reverting.
    function test_RefreshAttesterState_ZombieExitDoesNotBlockOtherAttesters() external {
        // Stake 3 attesters
        _setupMultipleActiveAttesters(3);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(3);

        // Create zombie exit on attester[0] (isRecipient=false, immediately exitable)
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        // Unstake attester[1] via normal flow - creates isRecipient=true exit
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // refreshAttesterState with all attesters succeeds - zombie is claimed, not reverted
        address[] memory allAttesters = _attesterAddresses(3);
        stakingManager.refreshAttesterState(allAttesters);

        // Zombie was claimed and finalized (immediately exitable)
        Exit memory zombieExit = rollup.getExit(keys[0].attester);
        assertFalse(zombieExit.exists, "zombie exit should be finalized");

        // attester[0] is no longer pending (finalized in same refresh)
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "zombie attester should be finalized");
    }

    /// @notice A rollup revert while claiming a zombie exit should not revert the refresh batch.
    function test_RefreshAttesterState_ZombieExitRevertDoesNotBlockBatch() external {
        _setupMultipleActiveAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        address zombieAttester = keys[0].attester;
        address healthyAttester = keys[1].attester;

        rollup.setExternalExit(zombieAttester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        vm.mockCallRevert(
            address(rollup),
            abi.encodeWithSelector(IAztecRollup.initiateWithdraw.selector, zombieAttester, address(stakingManager)),
            "AZTEC_ZOMBIE_CLAIM_FAILED"
        );

        address[] memory allAttesters = _attesterAddresses(2);
        stakingManager.refreshAttesterState(allAttesters);

        assertTrue(stakingManager.isUnstakePending(zombieAttester), "zombie attester should still be tracked exiting");
        assertFalse(stakingManager.isUnstakePending(healthyAttester), "healthy attester should still be active");
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "healthy attester should remain active");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "zombie exit should be tracked for retry");

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.pendingUnstakeAmount, ACTIVATION_THRESHOLD, "zombie exit amount should be tracked");
    }

    /// @notice Once a zombie exit is claimed during refresh, unstake() operates on healthy attesters
    ///         without interference from the zombie.
    function test_Unstake_WorksAfterZombieClaimedByRefresh() external {
        // Stake 2 attesters
        _setupMultipleActiveAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        address zombieAttester = keys[0].attester;
        address healthyAttester = keys[1].attester;

        // Create zombie exit on attester[0] with future exitableAt
        rollup.setExternalExit(zombieAttester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        // Refresh claims the zombie and transitions it to Exiting
        address[] memory zombieOnly = new address[](1);
        zombieOnly[0] = zombieAttester;
        stakingManager.refreshAttesterState(zombieOnly);

        // Zombie is now locally Exiting and claimed on rollup
        assertTrue(
            stakingManager.isUnstakePending(zombieAttester), "zombie attester should be locally Exiting after claim"
        );
        Exit memory claimedExit = rollup.getExit(zombieAttester);
        assertTrue(claimedExit.isRecipient, "zombie exit should be claimed (isRecipient=true)");

        // unstake() operates on the healthy attester (only Active attesters)
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "only healthy attester should be active");
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "no active attesters should remain");
        assertTrue(stakingManager.isUnstakePending(healthyAttester), "healthy attester should now be Exiting");

        // Warp past exitableAt - both exits can now be finalized
        vm.warp(block.timestamp + 1 days);

        address[] memory bothAttesters = _attesterAddresses(2);
        stakingManager.refreshAttesterState(bothAttesters);

        // Both finalized
        assertFalse(stakingManager.isUnstakePending(zombieAttester), "zombie attester should be finalized");
        assertFalse(stakingManager.isUnstakePending(healthyAttester), "healthy attester should be finalized");

        // Funds claimable
        vm.prank(core);
        (uint256 received,) = stakingManager.getUnstakedFunds();
        assertEq(received, 2 * ACTIVATION_THRESHOLD, "both exit amounts should be received");
    }

    /// @notice An immediately-exitable zombie exit is claimed and finalized in a single refresh call.
    /// @dev The Active->Exiting block calls initiateWithdraw to claim the zombie, then the
    ///      Exiting block detects it's exitable and calls finalizeWithdraw - all in one refresh.
    function test_ZombieExit_ImmediatelyExitable_ClaimedAndFinalizedInSingleRefresh() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        // Create zombie exit that is immediately exitable
        rollup.setExternalExit(attester, ACTIVATION_THRESHOLD, block.timestamp);

        // Single refresh both claims and finalizes
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        // Exit is fully finalized
        Exit memory exitAfter = rollup.getExit(attester);
        assertFalse(exitAfter.exists, "exit should be finalized on rollup");

        assertFalse(
            stakingManager.isUnstakePending(attester), "attester should not be Exiting (finalized in same call)"
        );

        // Funds are claimable
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, ACTIVATION_THRESHOLD, "funds should be received");
        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exit amount should be claimable");
    }
}
