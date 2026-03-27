// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IAztecRollup } from "src/staking/interfaces/IAztecRollup.sol";

/// @title StakingManagerEdgeCasesTest
/// @notice Tests covering untested branches and functions in StakingManager.sol.
contract StakingManagerEdgeCasesTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Storage slot for MockAztecRollup.stakes mapping (slot 1, after _activationThreshold at slot 0).
    ///      The actual mapping key is keccak256(abi.encode(attester, ROLLUP_STAKES_MAPPING_SLOT)).
    uint256 internal constant ROLLUP_STAKES_MAPPING_SLOT = 1;

    /// @dev Storage slot for StakingManager._aggregateState.stakedAmount (proxy slot 9).
    ///      Layout: slot 8 = slashingDelta, slot 9 = stakedAmount, slot 10 = pendingUnstakeAmount.
    uint256 internal constant STAKING_MANAGER_STAKED_AMOUNT_SLOT = 9;

    /// @dev Storage slot for StakingManager._aggregateState.pendingUnstakeAmount (proxy slot 10).
    uint256 internal constant STAKING_MANAGER_PENDING_UNSTAKE_SLOT = 10;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AttesterStateRefreshed(address indexed attester, uint256 oldBalance, uint256 newBalance);

    /*//////////////////////////////////////////////////////////////
                  _setAttesterStatus SAME-STATUS GUARD
    //////////////////////////////////////////////////////////////*/

    function test_SetAttesterStatus_SameStatus_NoOp() external {
        // Setup: stake one attester (becomes Active)
        _setupStakedAttester();
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "should have 1 active attester");

        // Refresh the attester without any state change on rollup
        // This exercises _refreshSingleAttester where the attester remains Active
        // and no status transition occurs
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        // Attester should remain Active
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester should still be active");
    }

    /*//////////////////////////////////////////////////////////////
               _removeAttester WITH ACTIVE STATUS REVERT
    //////////////////////////////////////////////////////////////*/

    function test_RemoveAttester_ActiveAttesterExternallyCleared() external {
        // Setup: stake one attester
        _setupStakedAttester();

        address attester = address(uint160(1));

        // Externally clear the attester on rollup (simulates full external exit + finalization)
        rollup.clearAttester(attester);

        // Refresh should detect zero balance + no exit for Active attester
        // This should transition to Exiting then remove
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        // Attester should be removed
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "active count should be 0 after removal");
    }

    /*//////////////////////////////////////////////////////////////
         FAILED initiateWithdraw PATH (SECURITY-CRITICAL)
    //////////////////////////////////////////////////////////////*/

    function test_Unstake_InitiateWithdrawFails_ExitExists_SetsExiting() external {
        // Setup: stake one attester
        _setupStakedAttester();
        address attester = address(uint160(1));

        // Simulate an existing exit on rollup (as if someone else initiated)
        rollup.setExternalExit(attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        // Mock initiateWithdraw to return false
        vm.mockCall(
            address(rollup),
            abi.encodeWithSelector(IAztecRollup.initiateWithdraw.selector, attester, address(stakingManager)),
            abi.encode(false)
        );

        // Unstake should NOT revert because exit.exists is true
        // It should set status to Exiting and return 0 for this attester
        vm.prank(core);
        uint256 unstaked = stakingManager.unstake(ACTIVATION_THRESHOLD);

        // exitAmount returned is 0 for the failed path
        assertEq(unstaked, 0, "unstaked should be 0 when initiateWithdraw fails with existing exit");
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "active count should decrease");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "exiting count should increase");
    }

    function test_RevertWhen_Unstake_InitiateWithdrawFails_NoExit() external {
        // Setup: stake one attester
        _setupStakedAttester();
        address attester = address(uint160(1));

        // Mock initiateWithdraw to return false (and no exit exists on rollup)
        vm.mockCall(
            address(rollup),
            abi.encodeWithSelector(IAztecRollup.initiateWithdraw.selector, attester, address(stakingManager)),
            abi.encode(false)
        );

        // Unstake should revert with UnstakeFailed because no exit exists
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnstakeFailed.selector, attester));
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
    }

    /*//////////////////////////////////////////////////////////////
          BALANCE INCREASE IN _refreshSingleAttester
    //////////////////////////////////////////////////////////////*/

    /// @dev    DEFENSIVE TEST -- not reachable on the current Aztec rollup. Aztec's
    ///         effectiveBalance never increases; sequencer rewards are tracked separately via
    ///         getSequencerRewards() and do not affect GSE effectiveBalance. This test guards
    ///         against future GSE changes where balance could increase (e.g. re-staking rewards).
    function test_RefreshAttesterState_BalanceIncrease() external {
        // Setup: stake one attester at ACTIVATION_THRESHOLD
        _setupStakedAttester();
        address attester = address(uint160(1));

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        // Increase the attester's balance on rollup (simulating rewards)
        uint256 rewardAmount = 5 ether;
        bytes32 slot = keccak256(abi.encode(attester, ROLLUP_STAKES_MAPPING_SLOT));
        vm.store(address(rollup), slot, bytes32(ACTIVATION_THRESHOLD + rewardAmount));

        // Refresh should detect the balance increase
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(
            stateAfter.stakedAmount, stateBefore.stakedAmount + rewardAmount, "staked amount should increase by reward"
        );
    }

    /*//////////////////////////////////////////////////////////////
       UNDERFLOW GUARDS IN _refreshSingleAttester
    //////////////////////////////////////////////////////////////*/

    function test_RefreshAttesterState_StakedAmountUnderflowGuard() external {
        // Setup: stake 2 attesters
        _setupMultipleStakedAttesters(2);

        address attester1 = address(uint160(1));

        // Slash attester1 to 0 on rollup (large decrease > aggregate stakedAmount per attester)
        bytes32 slot = keccak256(abi.encode(attester1, ROLLUP_STAKES_MAPPING_SLOT));
        vm.store(address(rollup), slot, bytes32(uint256(0)));

        // Refresh -- the decrease is ACTIVATION_THRESHOLD but should be handled gracefully
        address[] memory attesters = _attesterAddresses(2);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        // Should handle the decrease without underflow
        assertEq(stateAfter.stakedAmount, ACTIVATION_THRESHOLD, "remaining attester should have threshold staked");
        // Pure slashing (balance decreased, no exit) should increment slashingDelta
        assertEq(stateAfter.slashingDelta, ACTIVATION_THRESHOLD, "slashingDelta should track the full slash amount");
    }

    function test_RefreshAttesterState_PendingUnstakeUnderflowGuard_ExternalFinalize() external {
        // Setup: stake then unstake (creates Exiting attester with pendingUnstakeAmount)
        _setupStakedAttester();
        address attester = address(uint160(1));

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "should have 1 exiting attester");

        // Externally finalize the exit on rollup (clears exit record, transfers funds)
        rollup.finalizeWithdraw(attester);

        // Now the exit doesn't exist on rollup but StakingManager still thinks it's Exiting
        // Refresh should detect and reconcile
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        // Attester should be removed, pendingUnstake should be reconciled
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "exiting count should be 0 after reconciliation");
        assertTrue(stakingManager.hasFinalizedUnstakes(), "should have claimable funds");
    }

    function test_RefreshAttesterState_ExitableExitFinalization() external {
        // Setup: stake then unstake
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Exit is already exitable (mock sets exitableAt = block.timestamp)
        // Refresh should finalize the exit
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        // Attester removed, funds should be claimable
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "exiting count should be 0 after finalization");
        assertTrue(stakingManager.hasFinalizedUnstakes(), "should have claimable funds after finalization");
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL EXIT DETECTION
    //////////////////////////////////////////////////////////////*/

    function test_RefreshAttesterState_ExternalExitDetection() external {
        // Setup: stake 2 attesters
        _setupMultipleStakedAttesters(2);

        address attester1 = address(uint160(1));

        // Simulate external exit for attester1 (full recovery, no slashing)
        rollup.setExternalExit(attester1, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        // Refresh should detect the external exit
        address[] memory attesters = _attesterAddresses(2);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "only 1 attester should remain active");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "1 attester should be exiting");
        // Full recovery: exitAmount == oldBalance, so no slashing loss
        assertEq(stateAfter.slashingDelta, 0, "no slashingDelta when exit recovers full stake");
    }

    function test_RefreshAttesterState_ExternalExitWithSlashing() external {
        // Setup: stake 2 attesters
        _setupMultipleStakedAttesters(2);

        address attester1 = address(uint160(1));

        // Simulate external exit with partial recovery (75% recovered, 25% slashed)
        uint256 recoveredAmount = ACTIVATION_THRESHOLD * 3 / 4;
        rollup.setExternalExit(attester1, recoveredAmount, block.timestamp + 1 days);

        address[] memory attesters = _attesterAddresses(2);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        uint256 expectedSlashLoss = ACTIVATION_THRESHOLD - recoveredAmount;
        assertEq(stateAfter.slashingDelta, expectedSlashLoss, "slashingDelta should track external exit loss");
        assertEq(stateAfter.pendingUnstakeAmount, recoveredAmount, "pendingUnstake should be the exit amount");
    }

    /*//////////////////////////////////////////////////////////////
                _isExitExitable NOT-EXISTS GUARD
    //////////////////////////////////////////////////////////////*/

    function test_RefreshAttesterState_ExitNotYetExitable() external {
        // Setup: stake then unstake
        _setupStakedAttester();
        address attester = address(uint160(1));

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Set exit to be far in the future (not yet exitable)
        rollup.setExitReady(attester, block.timestamp + 365 days);

        // Refresh -- exit exists but not exitable, so attester remains Exiting
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        // Attester should still be Exiting (not removed)
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "attester should remain exiting");
    }

    /*//////////////////////////////////////////////////////////////
      SATURATING SUBTRACTION FALLBACKS IN _refreshSingleAttester
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests line 517: _aggregateState.stakedAmount saturates to 0
    ///         when the balance decrease exceeds the corrupted aggregate.
    function test_RefreshAttesterState_StakedAmountSaturatesToZero() external {
        // Setup: stake one attester at ACTIVATION_THRESHOLD
        _setupStakedAttester();

        // Corrupt stakedAmount to 1 wei -- much less than ACTIVATION_THRESHOLD
        vm.store(address(stakingManager), bytes32(STAKING_MANAGER_STAKED_AMOUNT_SLOT), bytes32(uint256(1)));

        // Verify corruption
        IStakingManager.StakingState memory corrupted = stakingManager.getStakingState();
        assertEq(corrupted.stakedAmount, 1, "corrupted stakedAmount should be 1");

        // Slash attester to 0 on rollup -> decrease = ACTIVATION_THRESHOLD > 1
        address attester = address(uint160(1));
        bytes32 rollupSlot = keccak256(abi.encode(attester, ROLLUP_STAKES_MAPPING_SLOT));
        vm.store(address(rollup), rollupSlot, bytes32(uint256(0)));

        // Refresh should saturate to 0 rather than underflow
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, 0, "stakedAmount should saturate to 0");
        // Pure slashing (balance decreased, no exit) should still increment slashingDelta
        assertEq(stateAfter.slashingDelta, ACTIVATION_THRESHOLD, "slashingDelta should track full slash");
    }

    /// @notice Tests line 556: _aggregateState.pendingUnstakeAmount saturates to 0
    ///         when an externally finalized exit's pendingExit exceeds the corrupted aggregate.
    function test_RefreshAttesterState_PendingUnstakeAmountSaturatesToZero_ExternalFinalize() external {
        // Setup: stake then unstake (creates Exiting attester with pendingUnstakeAmount)
        _setupStakedAttester();
        address attester = address(uint160(1));

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "should have 1 exiting attester");

        // Corrupt pendingUnstakeAmount to 1 wei
        vm.store(address(stakingManager), bytes32(STAKING_MANAGER_PENDING_UNSTAKE_SLOT), bytes32(uint256(1)));

        IStakingManager.StakingState memory corrupted = stakingManager.getStakingState();
        assertEq(corrupted.pendingUnstakeAmount, 1, "corrupted pendingUnstakeAmount should be 1");

        // Externally finalize the exit on rollup (clears exit record)
        rollup.finalizeWithdraw(attester);

        // Refresh should detect externally-finalized exit, and saturate pendingUnstake to 0
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.pendingUnstakeAmount, 0, "pendingUnstakeAmount should saturate to 0");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "exiting count should be 0 after reconciliation");
    }

    /// @notice Tests line 575: _aggregateState.pendingUnstakeAmount saturates to 0
    ///         when a locally-finalized (exitable) exit's pendingExit exceeds the corrupted aggregate.
    function test_RefreshAttesterState_PendingUnstakeAmountSaturatesToZero_ExitableFinalize() external {
        // Setup: stake then unstake
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "should have 1 exiting attester");

        // Corrupt pendingUnstakeAmount to 1 wei
        vm.store(address(stakingManager), bytes32(STAKING_MANAGER_PENDING_UNSTAKE_SLOT), bytes32(uint256(1)));

        IStakingManager.StakingState memory corrupted = stakingManager.getStakingState();
        assertEq(corrupted.pendingUnstakeAmount, 1, "corrupted pendingUnstakeAmount should be 1");

        // The exit is already exitable (mock sets exitableAt = block.timestamp by default)
        // Refresh should finalize the exit and saturate pendingUnstake to 0
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.pendingUnstakeAmount, 0, "pendingUnstakeAmount should saturate to 0");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "exiting count should be 0 after finalization");
    }
}
